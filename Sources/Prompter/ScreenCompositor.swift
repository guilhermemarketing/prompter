import CoreImage
import CoreVideo
import Metal

/// Monta o quadro final do modo tela: a tela encaixada (sem cortes) e a câmera em destaque,
/// com borda escura grossa e sombra dura (neobrutalismo). Não é thread-safe.
final class ScreenCompositor {
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "Prompter.screen"])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
    }

    func render(screen: CVPixelBuffer?, camera: CVPixelBuffer?, bubble: BubbleSettings, size: CGSize) -> FrameProcessor.Frame? {
        let extent = CGRect(origin: .zero, size: size)
        var image = CIImage(color: CIColor(red: 0.04, green: 0.04, blue: 0.05)).cropped(to: extent)
        if let screen {
            image = Self.fit(CIImage(cvPixelBuffer: screen), in: extent).composited(over: image)
        }
        if bubble.visible, let camera {
            image = Self.bubble(CIImage(cvPixelBuffer: camera), settings: bubble, output: size, colorSpace: colorSpace)
                .composited(over: image)
        }
        guard let buffer = makeBuffer(size: size) else { return nil }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, sRGB, .shouldPropagate)
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = colorSpace
        let task = try? context.startTask(toRender: image.cropped(to: extent), from: extent, to: destination, at: .zero)
        return FrameProcessor.Frame(buffer: buffer, task: task)
    }

    /// Encaixa sem cortar (letterbox), centralizado.
    static func fit(_ image: CIImage, in extent: CGRect) -> CIImage {
        let source = image.extent
        let scale = min(extent.width / source.width, extent.height / source.height)
        var scaled = image.transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
        // A captura já chega no tamanho do vídeo: quase sempre 1:1, sem custo de reamostragem.
        if abs(scale - 1) > 0.002 {
            scaled = scaled.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        }
        let w = source.width * scale, h = source.height * scale
        return scaled.transformed(by: CGAffineTransform(translationX: ((extent.width - w) / 2).rounded(),
                                                        y: ((extent.height - h) / 2).rounded()))
    }

    /// Câmera recortada no formato, com borda e sombra dura deslocada (sem desfoque).
    static func bubble(_ camera: CIImage, settings: BubbleSettings, output: CGSize, colorSpace: CGColorSpace) -> CIImage {
        let unit = output.height / 1080
        let border = 9 * unit, shadow = 12 * unit
        // Retângulo em coordenadas do Core Image (origem embaixo).
        let top = settings.frame(in: output)
        let rect = CGRect(x: top.minX, y: output.height - top.maxY, width: top.width, height: top.height).integral

        // Recorte central da câmera na proporção do formato, escalado para o retângulo.
        let crop = VideoSettings.centerCrop(camera.extent, aspect: settings.shape.aspect)
        let scale = rect.height / crop.height
        var face = camera.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        if abs(scale - 1) > 0.01 {
            face = face.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        }
        face = face.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))

        let outer = rect.insetBy(dx: -border, dy: -border)
        let radius = settings.shape == .circle ? 0 : 14 * unit
        func shape(_ r: CGRect, cornerRadius: CGFloat) -> CIImage {
            if settings.shape == .circle {
                let c = CGPoint(x: r.midX, y: r.midY), rad = r.width / 2
                return CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": CIVector(cgPoint: c), "inputRadius0": rad - 0.75, "inputRadius1": rad + 0.75,
                    "inputColor0": CIColor.white, "inputColor1": CIColor.clear,
                ])!.outputImage!.cropped(to: r.insetBy(dx: -2, dy: -2))
            }
            return CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: r), "inputRadius": cornerRadius, "inputColor": CIColor.white,
            ])!.outputImage!
        }
        func painted(_ mask: CIImage, _ color: RGBAColor) -> CIImage {
            let ci = CIColor(red: color.r, green: color.g, blue: color.b, alpha: 1, colorSpace: colorSpace)
                ?? CIColor(red: color.r, green: color.g, blue: color.b)
            return CIImage(color: ci).cropped(to: mask.extent)
                .applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: mask.applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(color.a)),
                    ]),
                ])
        }

        let outerMask = shape(outer, cornerRadius: radius + border)
        let shadowLayer = painted(outerMask.transformed(by: CGAffineTransform(translationX: shadow, y: -shadow)), settings.shadowColor)
        let borderLayer = painted(outerMask, settings.borderColor)
        let faceLayer = face.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: shape(rect, cornerRadius: radius),
        ])
        return faceLayer.composited(over: borderLayer.composited(over: shadowLayer))
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
