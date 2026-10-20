import AppKit
import CoreGraphics
import CoreImage
import Metal
import OSLog
@preconcurrency import ScreenCaptureKit

/// Diagnóstico da captura de tela: `log show --predicate 'subsystem == "marketing.gui.prompter"'`.
let screenLog = Logger(subsystem: "marketing.gui.prompter", category: "screen")

/// Captura de tela, janela ou área via ScreenCaptureKit. O próprio Prompter fica fora
/// da captura (senão a prévia filmaria a si mesma). Guarda só o quadro mais recente.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Choice: Identifiable, Hashable {
        let source: ScreenSource
        let title: String
        let detail: String
        var id: ScreenSource { source }
    }

    enum Failure: LocalizedError {
        case notAuthorized, sourceUnavailable
        var errorDescription: String? {
            switch self {
            case .notAuthorized: L("O Prompter precisa da permissão de Gravação de Tela (Ajustes do Sistema › Privacidade e Segurança).", "Prompter needs Screen Recording permission (System Settings › Privacy & Security).")
            case .sourceUnavailable: L("A tela ou janela escolhida não está mais disponível.", "The chosen screen or window is no longer available.")
            }
        }
    }

    private let queue = DispatchQueue(label: "marketing.gui.prompter.screen", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    private var latest: CVPixelBuffer?
    private(set) var captureSize: CGSize = .zero
    private var statusCounts: [Int: Int] = [:]
    private var lastReport = CFAbsoluteTimeGetCurrent()
    var onStop: ((Error?) -> Void)?

    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Abre o pedido do sistema (só aparece uma vez; depois, só pelos Ajustes).
    @discardableResult
    static func requestAuthorization() -> Bool { CGRequestScreenCaptureAccess() }

    var latestFrame: CVPixelBuffer? { lock.withLock { latest } }

    /// Cópias dos quadros recentes (~0,5 s): permitem casar a tela com a câmera, que chega atrasada.
    /// São cópias porque o ScreenCaptureKit tem poucos buffers e pararia se segurássemos os dele.
    private var history: [(t: Double, buffer: CVPixelBuffer)] = []
    private var copyPool: CVPixelBufferPool?
    private let copyContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
        }
        return CIContext(options: [.workingColorSpace: NSNull()])
    }()
    private var copySize = CGSize.zero

    /// Quadro da tela exibido no instante `t` (o mais recente até ele).
    func frame(atOrBefore t: Double) -> CVPixelBuffer? {
        lock.withLock { history.last(where: { $0.t <= t })?.buffer }
    }

    private func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let size = CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        if copyPool == nil || copySize != size {
            copyPool = nil
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &copyPool)
            copySize = size
        }
        guard let copyPool else { return nil }
        var target: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, copyPool, &target)
        guard let target else { return nil }
        // Cópia pela GPU (sem gerenciamento de cor: bits idênticos); poupa a CPU de copiar
        // 8–33 MB por quadro.
        copyContext.render(CIImage(cvPixelBuffer: source), to: target,
                           bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
        CVBufferPropagateAttachments(source, target)
        return target
    }

    // MARK: Fontes

    /// Telas e janelas disponíveis (sem o Prompter, sem janelas minúsculas ou sem título).
    static func availableChoices() async throws -> (displays: [Choice], windows: [Choice]) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownBundle = Bundle.main.bundleIdentifier
        let displays = content.displays.enumerated().map { index, display in
            let scale = NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 2
            return Choice(source: .display(id: display.displayID),
                          title: content.displays.count == 1 ? L("Tela inteira", "Entire screen") : L("Tela \(index + 1)", "Screen \(index + 1)"),
                          detail: "\(Int(CGFloat(display.width) * scale))×\(Int(CGFloat(display.height) * scale))")
        }
        let windows = content.windows
            .filter { window in
                window.windowLayer == 0 && window.frame.width >= 120 && window.frame.height >= 80
                    && window.owningApplication?.bundleIdentifier != ownBundle
                    && !(window.title ?? "").isEmpty
            }
            .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
            .map { window in
                let app = window.owningApplication?.applicationName ?? L("Janela", "Window")
                return Choice(source: .window(id: window.windowID, title: "\(app) — \(window.title ?? "")"),
                              title: app, detail: window.title ?? "")
            }
        return (displays, windows)
    }

    // MARK: Captura

    /// Inicia (ou troca) a captura. `maxSize` limita a resolução capturada ao necessário.
    func start(_ source: ScreenSource, fps: Int, showsCursor: Bool, maxSize: CGSize) async throws {
        screenLog.info("start: authorized=\(Self.isAuthorized, privacy: .public) source=\(String(describing: source), privacy: .public) fps=\(fps)")
        guard Self.isAuthorized else { throw Failure.notAuthorized }
        await stop()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let config = SCStreamConfiguration()
        let filter: SCContentFilter
        var pointSize: CGSize

        switch source {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw Failure.sourceUnavailable }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            pointSize = CGSize(width: display.width, height: display.height)
        case .area(let id, let x, let y, let w, let h):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw Failure.sourceUnavailable }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            config.sourceRect = CGRect(x: x, y: y, width: w, height: h)
            pointSize = CGSize(width: w, height: h)
        case .window(let id, _):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw Failure.sourceUnavailable }
            filter = SCContentFilter(desktopIndependentWindow: window)
            pointSize = window.frame.size
        }

        // Resolução nativa (pixels), limitada ao tamanho do vídeo final.
        let scale = CGFloat(SCShareableContent.info(for: filter).pointPixelScale)
        var pixels = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
        let fit = min(1, maxSize.width / pixels.width, maxSize.height / pixels.height)
        pixels = CGSize(width: CGFloat(Int(pixels.width * fit) & ~1), height: CGFloat(Int(pixels.height * fit) & ~1))

        config.width = Int(pixels.width)
        config.height = Int(pixels.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = showsCursor
        config.queueDepth = 6
        config.scalesToFit = true

        screenLog.info("config: points=\(pointSize.width, privacy: .public)x\(pointSize.height, privacy: .public) scale=\(scale, privacy: .public) pixels=\(config.width)x\(config.height) sourceRect=\(String(describing: config.sourceRect), privacy: .public)")
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        do {
            try await stream.startCapture()
            screenLog.info("startCapture ok")
        } catch {
            screenLog.error("startCapture falhou: \(error.localizedDescription, privacy: .public) (\((error as NSError).code))")
            throw error
        }
        lock.withLock {
            self.stream = stream
            self.captureSize = pixels
        }
    }

    func stop() async {
        let current = lock.withLock { () -> SCStream? in
            defer { stream = nil; latest = nil; history = [] }
            return stream
        }
        try? await current?.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let raw = attachments?.first?[.status] as? Int ?? -1
        statusCounts[raw, default: 0] += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastReport > 3 {
            // status: 0 completo, 1 ocioso, 2 em branco, 3 suspenso, 4 início, 5 parado, -1 sem anexo
            screenLog.info("quadros nos últimos 3 s por status: \(String(describing: self.statusCounts), privacy: .public)")
            statusCounts = [:]
            lastReport = now
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), SCFrameStatus(rawValue: raw) == .complete else { return }
        let shown = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let copied = copy(buffer)
        lock.withLock {
            latest = buffer
            if let copied {
                history.append((shown, copied))
                history.removeAll { $0.t < shown - 0.5 }
                if history.count > 40 { history.removeFirst(history.count - 40) }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        screenLog.error("stream parou: \(error.localizedDescription, privacy: .public) (\((error as NSError).code))")
        lock.withLock { if self.stream === stream { self.stream = nil } }
        DispatchQueue.main.async { self.onStop?(error) }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
