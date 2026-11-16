import AppKit
import CoreImage

/// Imagens do README (uso de desenvolvimento): `--render-looks FOTO PASTA`.
/// Passa uma foto pelo mesmo FrameProcessor da gravação, com chroma key, estilos, presets de cor,
/// LUTs (com intensidade) e luz automática, e salva cada resultado em PNG. Não abre a câmera.
@MainActor
enum LookRenderer {
    static var arguments: (input: URL, output: URL)? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-looks"), args.count > i + 2 else { return nil }
        return (URL(fileURLWithPath: args[i + 1]), URL(fileURLWithPath: args[i + 2], isDirectory: true))
    }

    private static let context = CIContext()

    /// `--render-framing-demo FOTO PASTA`: simula a pessoa se movendo no quadro (a foto desliza) e
    /// grava, quadro a quadro, a saída 9:16 sem e com o enquadramento automático.
    static var framingDemoArguments: (input: URL, output: URL)? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-framing-demo"), args.count > i + 2 else { return nil }
        return (URL(fileURLWithPath: args[i + 1]), URL(fileURLWithPath: args[i + 2], isDirectory: true))
    }

    static func renderFramingDemo(input: URL, output: URL) async throws {
        guard let photo = CIImage(contentsOf: input) else { throw CocoaError(.fileReadCorruptFile) }
        let extent = photo.extent
        for (name, auto) in [("desligado", false), ("ligado", true)] {
            let folder = output.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var settings = VideoSettings()
            settings.aspect = .portrait
            settings.autoFrame = auto
            let processor = FrameProcessor()
            let frames = 30 * 9
            for frame in 0..<frames {
                // A pessoa vai da direita para a esquerda e volta (9 s), com uma pausa no meio.
                let t = Double(frame) / Double(frames)
                let phase = t < 0.4 ? t / 0.4 : t < 0.55 ? 1 : 1 - (t - 0.55) / 0.45
                let eased = (1 - cos(phase * .pi)) / 2
                let window = CGRect(x: extent.minX + extent.width * 0.32 * eased, y: extent.minY,
                                    width: extent.width * 0.68, height: extent.height)
                let source = try buffer(from: photo.cropped(to: window))
                let result = processor.process(source, settings: settings)
                result?.wait()
                if let result {
                    try context.writePNGRepresentation(of: CIImage(cvPixelBuffer: result.buffer),
                                                       to: folder.appendingPathComponent(String(format: "f%04d.png", frame)),
                                                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                }
                try await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    static func render(input: URL, output: URL) async throws {
        guard let photo = CIImage(contentsOf: input) else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let source = try buffer(from: photo)
        // Ambiente escuro simulado (−1,3 EV) para mostrar a luz automática corrigindo o rosto.
        let dim = try buffer(from: photo.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -1.3]))

        var base = VideoSettings()
        base.resolution = .hd
        base.aspect = .landscape

        func look(_ name: String, from buffer: CVPixelBuffer? = nil, frames: Int = 90, _ change: (inout VideoSettings) -> Void) async throws {
            var settings = base
            change(&settings)
            try await save(buffer ?? source, settings: settings, frames: frames, to: output.appendingPathComponent("\(name).png"))
        }

        // Zoom digital e enquadramento automático (rosto deslocado para a esquerda do quadro).
        for zoom in [1.0, 1.5, 2.0] {
            try await look(String(format: "zoom-%.1fx", zoom)) { $0.zoom = zoom }
        }
        let extent = photo.extent
        let offCenter = try buffer(from: photo.cropped(to: CGRect(x: extent.minX + extent.width * 0.3, y: extent.minY,
                                                                   width: extent.width * 0.7, height: extent.height)))
        try await look("enquadramento-desligado-16x9", from: offCenter) { _ in }
        try await look("enquadramento-ligado-16x9", from: offCenter, frames: 200) { $0.autoFrame = true; $0.zoom = VideoSettings.autoFrameStartZoom }
        try await look("enquadramento-desligado-9x16", from: offCenter) { $0.aspect = .portrait }
        try await look("enquadramento-ligado-9x16", from: offCenter, frames: 200) { $0.aspect = .portrait; $0.autoFrame = true }
        // Rosto grande no quadro (perto da câmera), com zoom: a cabeça precisa caber com folga em cima.
        try await look("enquadramento-ligado-9x16-2x", from: offCenter, frames: 200) { $0.aspect = .portrait; $0.autoFrame = true; $0.zoom = 2 }
        try await look("enquadramento-ligado-16x9-2x", from: offCenter, frames: 200) { $0.autoFrame = true; $0.zoom = 2 }
        if CommandLine.arguments.contains("--only-framing") { return }

        try await look("original") { _ in }
        for background in [ChromaBackground.green, .blue, .red] {
            try await look("chroma-\(background.rawValue)") { $0.background = background }
        }
        try await look("estilo-cel") { $0.background = .green; $0.chromaStyle = .cel }
        try await look("estilo-adesivo") { $0.background = .blue; $0.chromaStyle = .sticker }
        for (index, preset) in ColorPreset.builtIns.enumerated() {
            try await look("preset-\(index)-\(preset.name.lowercased())") { $0.adjustments = preset.adjustments }
        }
        for lut in LUTLibrary.builtIns {
            try await look("lut-\(lut.id.replacingOccurrences(of: "builtin.", with: ""))") { $0.lutID = lut.id; $0.lutIntensity = 1 }
        }
        for step in 0...20 {
            let intensity = Double(step) / 20
            try await look(String(format: "intensidade-%02d", step)) { $0.lutID = "builtin.midsommar"; $0.lutIntensity = intensity }
        }
        try await look("luz-desligada", from: dim) { $0.autoLight = false }
        try await look("luz-automatica", from: dim) { $0.autoLight = true }
    }

    /// Processa a mesma foto várias vezes: a máscara de pessoa e a medição do rosto rodam em
    /// segundo plano e a exposição assenta aos poucos, como nos primeiros segundos de câmera.
    private static func save(_ source: CVPixelBuffer, settings: VideoSettings, frames: Int = 90, to url: URL) async throws {
        let processor = FrameProcessor()
        var last: FrameProcessor.Frame?
        for _ in 0..<frames {
            last = processor.process(source, settings: settings)
            last?.wait()
            try await Task.sleep(for: .milliseconds(15))
        }
        guard let frame = last else { return }
        let image = CIImage(cvPixelBuffer: frame.buffer)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        try context.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: sRGB)
    }

    private static func buffer(from image: CIImage) throws -> CVPixelBuffer {
        let extent = image.extent.integral
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(extent.width), Int(extent.height), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &buffer)
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        context.render(image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)),
                       to: buffer, bounds: CGRect(origin: .zero, size: extent.size),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }
}
