import CoreImage
import CoreVideo
import Metal
import QuartzCore
import Vision

/// Transforma o quadro da câmera no quadro final, tudo na GPU:
/// luz automática (prioridade ao rosto) → ajustes de cor → fundo chroma → recorte e escala.
/// Luz e cor entram antes do chroma para a cor de fundo sair exata.
///
/// `process` não é thread-safe: chame sempre da mesma fila. Segmentação e medição de luz rodam
/// em filas próprias e cada quadro usa o resultado mais recente, então não limitam o fps.
final class FrameProcessor {
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private let hasToneMap = CIFilter(name: "CIToneMapHeadroom") != nil

    // Segmentação (fundo chroma).
    private let segmentation = VNGeneratePersonSegmentationRequest()
    private let sequence = VNSequenceRequestHandler()
    private let maskQueue = DispatchQueue(label: "marketing.gui.prompter.mask", qos: .userInitiated)
    private let maskLock = NSLock()
    private var maskBusy = false
    private var latestMask: CIImage?

    // Medição de luz.
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let lightQueue = DispatchQueue(label: "marketing.gui.prompter.light", qos: .userInitiated)
    private let lightLock = NSLock()
    private var lightBusy = false
    private var lastMeasure: CFTimeInterval = 0
    private var targetEV: Double = 0
    private var currentEV: Double = 0

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "Prompter"])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    /// Compensação de exposição aplicada no último quadro (EV), para diagnóstico.
    var exposureCompensation: Double { currentEV }

    /// Quadro final ainda em renderização: chame `wait()` antes de usar o buffer.
    struct Frame {
        let buffer: CVPixelBuffer
        let task: CIRenderTask?
        func wait() { _ = try? task?.waitUntilCompleted() }
    }

    /// Enfileira a renderização na GPU e retorna sem esperar, para o próximo quadro
    /// ser preparado enquanto este renderiza.
    /// - Parameter size: tamanho de saída; por padrão, o da configuração. No modo tela sem câmera.mov,
    ///   a câmera é processada no tamanho da bolinha, o que poupa GPU.
    func process(_ source: CVPixelBuffer, settings: VideoSettings, size: CGSize? = nil) -> Frame? {
        var image = CIImage(cvPixelBuffer: source)
        let extent = image.extent

        image = applyLight(to: image, source: source, enabled: settings.autoLight)
        image = apply(settings.adjustments, liftShadows: settings.autoLight, to: image, extent: extent)
        if let id = settings.lutID, settings.lutIntensity > 0.001, let cube = LUTLibrary.shared.cube(for: id) {
            image = applyLUT(cube, intensity: settings.lutIntensity, to: image, extent: extent)
        }

        if settings.needsPersonMask {
            requestMask(for: source)
        } else {
            maskLock.withLock { latestMask = nil }
        }
        if settings.needsPersonMask, let lowMask = maskLock.withLock({ latestMask }) {
            var background = image
            if let rgb = settings.background.rgb {
                let ciColor = CIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1, colorSpace: colorSpace)
                    ?? CIColor(red: rgb.r, green: rgb.g, blue: rgb.b)
                background = CIImage(color: ciColor).cropped(to: extent)
            }
            image = ChromaStylizer.composite(person: image, background: background, lowMask: lowMask, extent: extent,
                                             style: settings.chromaStyle, colors: settings.styleColors,
                                             colorSpace: colorSpace, celStrength: settings.celStrength,
                                             stickerBorder: settings.stickerBorderWidth,
                                             stickerOutline: settings.stickerOutlineWidth)
        }

        let output = size ?? settings.outputSize
        let crop = VideoSettings.centerCrop(extent, aspect: output.width / output.height)
        let scale = output.width / crop.width
        image = image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        if abs(scale - 1) > 0.001 {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        }
        image = image.cropped(to: CGRect(origin: .zero, size: output))

        guard let buffer = makeBuffer(size: output) else { return nil }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        // Curva sRGB: é como a prévia exibe estes pixels. Marcar Rec.709 faz o macOS (ColorSync/QuickTime)
        // clarear as sombras e achatar o contraste do arquivo em relação à prévia.
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = colorSpace
        let task = try? context.startTask(toRender: image, from: CGRect(origin: .zero, size: output),
                                          to: destination, at: .zero)
        return Frame(buffer: buffer, task: task)
    }

    // MARK: Luz automática

    /// Exposição suavizada rumo ao alvo medido no rosto; acima de 0 EV o tone mapping
    /// segura os realces. O preenchimento de sombras entra na curva de `apply(_:)`.
    private func applyLight(to image: CIImage, source: CVPixelBuffer, enabled: Bool) -> CIImage {
        if enabled { requestMeasure(for: source) }
        let target = enabled ? lightLock.withLock { targetEV } : 0
        // ~0,4 s para assentar: a mudança fica imperceptível no vídeo.
        currentEV += (target - currentEV) * 0.08
        if !enabled, abs(currentEV) < 0.01 { currentEV = 0; return image }

        var result = image
        if abs(currentEV) >= 0.01 {
            result = result.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: currentEV])
            if currentEV > 0, hasToneMap {
                result = result.applyingFilter("CIToneMapHeadroom", parameters: [
                    "inputSourceHeadroom": Float(pow(2, currentEV)),
                    "inputTargetHeadroom": Float(1),
                ])
            }
        }
        return result
    }

    /// Mede o brilho do rosto até ~12 vezes por segundo.
    private func requestMeasure(for source: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        let start = lightLock.withLock { () -> Bool in
            guard !lightBusy, now - lastMeasure > 1.0 / 12 else { return false }
            lightBusy = true
            lastMeasure = now
            return true
        }
        guard start else { return }
        lightQueue.async { [self] in
            let ev = measureExposure(source)
            lightLock.withLock {
                targetEV = ev
                lightBusy = false
            }
        }
    }

    private func measureExposure(_ source: CVPixelBuffer) -> Double {
        let image = CIImage(cvPixelBuffer: source)
        let extent = image.extent
        try? VNImageRequestHandler(cvPixelBuffer: source).perform([faceRequest])
        let face = faceRequest.results?.max {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }

        // Sem rosto não há o que compensar: a câmera já faz a exposição da cena.
        guard let face else { return 0 }
        let rect = VNImageRectForNormalizedRect(face.boundingBox, Int(extent.width), Int(extent.height))
        // Miolo do rosto: evita cabelo e fundo.
        let region = rect.insetBy(dx: rect.width * 0.22, dy: rect.height * 0.22).intersection(extent)
        let targetLuma = 0.56
        guard !region.isEmpty else { return 0 }

        let average = image.cropped(to: region)
            .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: region)])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 16, bounds: average.extent,
                       format: .RGBAf, colorSpace: sRGB)
        let luma = Double(0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2])
        let ev = log2(Self.linear(targetLuma) / max(Self.linear(luma), 0.002))
        // Zona morta evita "caçar" exposição por variações pequenas.
        return abs(ev) < 0.12 ? 0 : min(max(ev, -1), 1.5)
    }

    private static func linear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    // MARK: LUT

    /// LUTs de vídeo esperam valores Rec.709 de exibição: o filtro converte para esse espaço,
    /// consulta a tabela e volta. A intensidade mistura com a imagem sem LUT.
    private func applyLUT(_ cube: LUTCube, intensity: Double, to image: CIImage, extent: CGRect) -> CIImage {
        guard let graded = CIFilter(name: "CIColorCubeWithColorSpace", parameters: [
            kCIInputImageKey: image,
            "inputCubeDimension": cube.dimension,
            "inputCubeData": cube.data,
            "inputColorSpace": colorSpace,
        ])?.outputImage else { return image }
        guard intensity < 0.999 else { return graded.cropped(to: extent) }
        return image.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: graded, kCIInputTimeKey: intensity,
        ]).cropped(to: extent)
    }

    // MARK: Ajustes de cor

    /// Pretos, brancos, sombras, contraste e brilho num único passe em espaço perceptual
    /// (o pivô do contraste fica no cinza médio visual).
    private func apply(_ a: ImageAdjustments, liftShadows: Bool, to image: CIImage, extent: CGRect) -> CIImage {
        guard !a.isNeutral || liftShadows else { return image }
        var result = image
        if a.contrast != 0 || a.brightness != 0 || a.hasToneCurve || liftShadows {
            result = result.applyingFilter("CILinearToSRGBToneCurve")
            if a.hasToneCurve || liftShadows {
                result = result.applyingFilter("CIToneCurve", parameters: Self.toneCurve(a, liftShadows: liftShadows))
            }
            if a.contrast != 0 || a.brightness != 0 {
                result = result.applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1 + 0.5 * a.contrast,
                    kCIInputBrightnessKey: 0.15 * a.brightness,
                    kCIInputSaturationKey: 1,
                ])
            }
            result = result.applyingFilter("CISRGBToneCurveToLinear")
        }
        if a.hue != 0 {
            result = result.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: a.hue * .pi / 180])
        }
        if a.sharpness > 0 {
            // Convolução 3×3 (Laplaciano): uma passada só, barata até em 4K60.
            let k = 0.9 * a.sharpness
            result = result.applyingFilter("CIConvolution3X3", parameters: [
                kCIInputWeightsKey: CIVector(values: [0, -k, 0, -k, 1 + 4 * k, -k, 0, -k, 0], count: 9),
                kCIInputBiasKey: 0,
            ])
        }
        return result.cropped(to: extent)
    }

    /// Curva de 5 pontos (valores perceptuais 0…1):
    /// - pretos: + levanta o ponto preto (look desbotado), − esmaga as sombras profundas;
    /// - brancos: + estoura os realces mais cedo, − rebaixa o branco;
    /// - sombras: + abre, − fecha a faixa dos tons escuros;
    /// - luz automática: preenchimento leve das sombras do rosto.
    static func toneCurve(_ a: ImageAdjustments, liftShadows: Bool) -> [String: Any] {
        let p0 = a.blacks >= 0 ? CGPoint(x: 0, y: 0.12 * a.blacks) : CGPoint(x: 0.12 * -a.blacks, y: 0)
        let p4 = a.whites >= 0 ? CGPoint(x: 1 - 0.12 * a.whites, y: 1) : CGPoint(x: 1, y: 1 + 0.12 * a.whites)
        let fill = liftShadows ? 0.04 : 0
        // Mantém a curva crescente mesmo com pretos levantados e sombras fechadas.
        let p1 = CGPoint(x: 0.18, y: max(0.18 + 0.09 * a.shadows + fill, p0.y + 0.03))
        let p2 = CGPoint(x: 0.42, y: 0.42 + 0.035 * a.shadows + fill * 0.75)
        let p3 = CGPoint(x: 0.75, y: 0.75)
        return ["inputPoint0": CIVector(cgPoint: p0), "inputPoint1": CIVector(cgPoint: p1),
                "inputPoint2": CIVector(cgPoint: p2), "inputPoint3": CIVector(cgPoint: p3),
                "inputPoint4": CIVector(cgPoint: p4)]
    }

    // MARK: Fundo chroma

    /// Dispara a segmentação do quadro se a anterior já terminou; senão, descarta.
    private func requestMask(for source: CVPixelBuffer) {
        let start = maskLock.withLock { () -> Bool in
            guard !maskBusy else { return false }
            maskBusy = true
            return true
        }
        guard start else { return }
        maskQueue.async { [self] in
            try? sequence.perform([segmentation], on: source)
            let mask = segmentation.results?.first.map { CIImage(cvPixelBuffer: $0.pixelBuffer) }
            maskLock.withLock {
                if let mask { latestMask = mask }
                maskBusy = false
            }
        }
    }

    private func makeBuffer(size: CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary,
                                    attributes as CFDictionary, &pool)
            poolSize = size
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}
