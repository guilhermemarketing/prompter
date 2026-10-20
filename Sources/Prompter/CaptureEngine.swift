@preconcurrency import AVFoundation
import AppKit

/// Nível do microfone isolado num objeto próprio para não redesenhar a janela inteira a 15 Hz.
final class AudioMeter: ObservableObject {
    @Published var level: Float = 0
}

/// Câmera e microfone → FrameProcessor → prévia (AVSampleBufferDisplayLayer) e MovieWriter.
/// A prévia mostra exatamente o quadro que vai para o arquivo.
final class CaptureEngine: NSObject, ObservableObject {
    enum Access { case unknown, granted, denied }

    @Published private(set) var cameraAccess: Access = .unknown
    @Published private(set) var micAccess: Access = .unknown
    @Published private(set) var cameras: [AVCaptureDevice] = []
    @Published private(set) var microphones: [AVCaptureDevice] = []
    /// Verdadeiro do pedido de gravação até o arquivo ser finalizado.
    @Published private(set) var isRecording = false
    /// Momento do primeiro quadro gravado (nil enquanto a gravação não começou).
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var supportedResolutions = Set(Resolution.allCases)
    @Published private(set) var supportedFrameRates = Set(VideoSettings.frameRates)
    /// Dispositivos em uso agora. Podem diferir das preferências (`cameraID`/`micID`) quando o
    /// preferido está desconectado; a preferência nunca é sobrescrita por um substituto.
    @Published private(set) var activeCameraID = ""
    @Published private(set) var activeMicID = ""
    /// Configuração realmente aplicada: as preferências limitadas ao que a câmera atual suporta.
    @Published private(set) var effective: VideoSettings

    /// Câmera preferida (persistida).
    @Published var cameraID: String = UserDefaults.standard.string(forKey: "cameraID") ?? "" {
        didSet {
            guard cameraID != oldValue else { return }
            UserDefaults.standard.set(cameraID, forKey: "cameraID")
            applyInputs()
        }
    }
    /// Microfone preferido (persistido).
    @Published var micID: String = UserDefaults.standard.string(forKey: "micID") ?? "" {
        didSet {
            guard micID != oldValue else { return }
            UserDefaults.standard.set(micID, forKey: "micID")
            applyInputs()
        }
    }
    /// Preferências de vídeo escolhidas pelo usuário (persistidas exatamente como escolhidas).
    @Published var settings: VideoSettings = CaptureEngine.loadSettings() {
        didSet {
            guard settings != oldValue else { return }
            schedulePersist(settings, key: "videoSettings")
            updateEffective()
            if settings.resolution != oldValue.resolution || settings.frameRate != oldValue.frameRate
                || settings.aspect != oldValue.aspect {
                applyInputs()
            }
        }
    }

    /// Modo tela: fonte, câmera em destaque e arquivos separados (persistido).
    @Published var screen: ScreenSettings = CaptureEngine.loadScreen() {
        didSet {
            guard screen != oldValue else { return }
            schedulePersist(screen, key: "screenSettings")
            lock.withLock { liveScreen = screen }
            if screen.mode != oldValue.mode {
                updateEffective()
                applyInputs()
                updateScreenCapture()
            } else if screen.source != oldValue.source || screen.showsCursor != oldValue.showsCursor {
                updateScreenCapture()
            }
            // Com ou sem câmera.mov, a câmera precisa de formatos diferentes.
            if screen.mode == .screen, screen.outputs.contains(.camera) != oldValue.outputs.contains(.camera) {
                applyInputs()
            }
        }
    }
    /// Problema atual da captura de tela (nil quando tudo certo).
    @Published private(set) var screenStatus: String?

    /// Grava o microfone em "dual mono" (mesmo sinal em L e R), ignorando canais mortos.
    @Published var monoMic: Bool = UserDefaults.standard.object(forKey: "monoMic") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(monoMic, forKey: "monoMic")
            lock.withLock { liveMonoMic = monoMic }
        }
    }

    /// Compensação de sincronia de cada câmera (segundos), por `uniqueID`: quanto o vídeo chega
    /// atrasado em relação ao áudio. A gravação desconta; a análise labial pós-gravação refina.
    @Published private(set) var cameraLatency: [String: Double] =
        UserDefaults.standard.dictionary(forKey: "cameraLatency") as? [String: Double] ?? [:]

    /// Ajuste fino por câmera (segundos, ±0,15), somado à latência medida.
    @Published private(set) var syncTrim: [String: Double] =
        UserDefaults.standard.dictionary(forKey: "cameraSyncTrim") as? [String: Double] ?? [:]

    /// Latência medida da câmera em uso (nil = ainda não calibrada).
    var activeLatency: Double? { cameraLatency[activeCameraID] }
    var activeTrim: Double { syncTrim[activeCameraID] ?? 0 }

    func setLatency(_ seconds: Double, forCamera id: String) {
        cameraLatency[id] = seconds
        UserDefaults.standard.set(cameraLatency, forKey: "cameraLatency")
        refreshLiveLatency()
    }

    func setTrim(_ seconds: Double) {
        guard !activeCameraID.isEmpty else { return }
        syncTrim[activeCameraID] = min(max(seconds, -0.15), 0.15)
        UserDefaults.standard.set(syncTrim, forKey: "cameraSyncTrim")
        refreshLiveLatency()
    }

    /// Compensação aplicada na fila de captura: latência medida + ajuste fino.
    private func refreshLiveLatency() {
        let total = max(0, (cameraLatency[activeCameraID] ?? 0) + (syncTrim[activeCameraID] ?? 0))
        lock.withLock { liveLatency = total }
    }

    /// Chamado na fila de captura com cada bloco de áudio do microfone.
    var onAudioSample: ((CMSampleBuffer) -> Void)?
    var onFinishedRecording: ((Result<URL, Error>) -> Void)?

    let session = AVCaptureSession()
    let meter = AudioMeter()
    let displayLayer = AVSampleBufferDisplayLayer()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "marketing.gui.prompter.session")
    private let dataQueue = DispatchQueue(label: "marketing.gui.prompter.data", qos: .userInteractive)
    /// Espera a GPU e entrega quadros (e áudio) ao gravador e à prévia, em ordem.
    private let outputQueue = DispatchQueue(label: "marketing.gui.prompter.output", qos: .userInteractive)
    private let processor = FrameProcessor()
    private let lock = NSLock()
    private var liveSettings: VideoSettings
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var meterTimer: Timer?
    private var activity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    let screenRecorder = ScreenRecorder()
    private let compositor = ScreenCompositor()
    private let compositeQueue = DispatchQueue(label: "marketing.gui.prompter.composite", qos: .userInteractive)
    private var compositeTimer: DispatchSourceTimer?
    // Protegidos por `lock`.
    private var liveScreen: ScreenSettings
    private var liveComposite: VideoSettings
    private var latestCamera: CVPixelBuffer?
    /// Latência da câmera em uso (segundos), lida na fila de captura.
    private var liveLatency: Double = 0
    /// Instante de parede da última composição feita a partir da câmera (para o relógio de reserva).
    private var lastCameraCompositeWall: Double = 0
    /// Último quadro da composição feito a partir da câmera (relógio do host, em segundos).
    private var lastCameraComposite: Double = 0
    private var compositing = false
    private var compositesPending = 0
    let latency = LatencyMeter()
    let audioClock = AudioClockMonitor()
    let pipelineStats = PipelineStats()
    private var activeFormats: [AVCaptureDevice.Format] = []

    // Somente na outputQueue.
    private var writer: MovieWriter?
    /// Modo tela: composição + (opcional) tela e câmera separadas, com início comum.
    private var screenWriters: [MovieWriter] = []
    private var compositeWriter: MovieWriter?
    private var cameraWriter: MovieWriter?
    private var screenOnlyWriter: MovieWriter?
    private var recordingFolder: URL?
    private var lastAudioFormat: CMFormatDescription?
    private let audioMirror = AudioMirror()
    private var liveMonoMic = UserDefaults.standard.object(forKey: "monoMic") as? Bool ?? true
    private var displayFormat: CMVideoFormatDescription?
    /// Quadros enviados à GPU e ainda não entregues; acima do limite, o quadro é descartado.
    private var framesInFlight = 0
    private let maxFramesInFlight = 3

    override init() {
        let saved = CaptureEngine.loadSettings()
        let savedScreen = CaptureEngine.loadScreen()
        liveScreen = savedScreen
        liveComposite = saved
        liveSettings = Self.cameraSettings(saved, screen: savedScreen)
        effective = saved
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
    }

    private static func loadScreen() -> ScreenSettings {
        guard let data = UserDefaults.standard.data(forKey: "screenSettings"),
              let settings = try? JSONDecoder().decode(ScreenSettings.self, from: data) else { return ScreenSettings() }
        return settings
    }

    /// No modo tela a câmera é processada inteira em 16:9 (arquivo próprio e recorte da bolinha);
    /// a proporção escolhida vale para a composição.
    static func cameraSettings(_ settings: VideoSettings, screen: ScreenSettings) -> VideoSettings {
        var camera = settings
        if screen.mode == .screen { camera.aspect = .landscape }
        return camera
    }

    private static func loadSettings() -> VideoSettings {
        guard let data = UserDefaults.standard.data(forKey: "videoSettings"),
              let settings = try? JSONDecoder().decode(VideoSettings.self, from: data) else { return VideoSettings() }
        return settings
    }

    // MARK: Persistência

    private var pendingSaves: [String: DispatchWorkItem] = [:]

    /// Grava no disco ~0,4 s depois da última mudança: sliders e arrastes não escrevem a cada evento.
    private func schedulePersist<T: Encodable>(_ value: T, key: String) {
        pendingSaves[key]?.cancel()
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
        }
        pendingSaves[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Grava o que estiver pendente (ao sair do app).
    func flushPendingSaves() {
        for work in pendingSaves.values where !work.isCancelled { work.perform(); work.cancel() }
        pendingSaves = [:]
    }

    /// Posição da câmera durante o arraste: vai direto para o compositor, sem redesenhar
    /// a interface nem gravar preferências. Ao soltar, a View grava em `screen.bubble`.
    func previewBubble(_ bubble: BubbleSettings) {
        lock.withLock { liveScreen.bubble = bubble }
    }

    // MARK: Ciclo de vida

    func start() {
        guard !started else { return }
        started = true
        refreshDevices()
        observers = [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                self?.refreshDevices()
                self?.applyInputs()
            }
        }
        // Ao voltar dos Ajustes do Sistema, tenta de novo se a captura de tela estava bloqueada.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            guard let self, self.screen.mode == .screen, self.screenStatus != nil else { return }
            self.updateScreenCapture()
        })
        Task { @MainActor in
            let camera = await AVCaptureDevice.requestAccess(for: .video)
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            cameraAccess = camera ? .granted : .denied
            micAccess = mic ? .granted : .denied
            applyInputs()
            let settings = Self.cameraSettings(self.effective, screen: screen)
            let target = cameraFormatTarget()
            updateScreenCapture()
            sessionQueue.async { [self] in
                session.startRunning()
                if let device = videoInput?.device { configure(device, for: settings, target: target) }
            }
            startMeter()
        }
    }

    private func refreshDevices() {
        cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video, position: .unspecified).devices
        microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified).devices
    }

    /// Alterna para a próxima câmera disponível.
    func nextCamera() {
        guard cameras.count > 1 else { return }
        let index = cameras.firstIndex { $0.uniqueID == activeCameraID } ?? -1
        cameraID = cameras[(index + 1) % cameras.count].uniqueID
    }

    private func applyInputs() {
        let camera = cameraAccess == .granted
            ? cameras.first { $0.uniqueID == cameraID } ?? AVCaptureDevice.systemPreferredCamera ?? cameras.first
            : nil
        let mic = micAccess == .granted
            ? microphones.first { $0.uniqueID == micID } ?? AVCaptureDevice.default(for: .audio) ?? microphones.first
            : nil
        // O substituto só vale enquanto o preferido estiver ausente; a preferência fica intacta.
        activeCameraID = camera?.uniqueID ?? ""
        refreshLiveLatency()
        activeMicID = mic?.uniqueID ?? ""
        if let camera { updateCapabilities(for: camera) }
        let settings = Self.cameraSettings(self.effective, screen: screen)
        let target = cameraFormatTarget()

        sessionQueue.async { [self] in
            session.beginConfiguration()
            if videoInput?.device.uniqueID != camera?.uniqueID {
                if let old = videoInput { session.removeInput(old); videoInput = nil }
                if let camera, let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) {
                    session.addInput(input)
                    videoInput = input
                }
            }
            if audioInput?.device.uniqueID != mic?.uniqueID {
                if let old = audioInput { session.removeInput(old); audioInput = nil }
                if let mic, let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
                    session.addInput(input)
                    audioInput = input
                }
            }
            if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                ]
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
                session.addOutput(videoOutput)
            }
            if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
                audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
                session.addOutput(audioOutput)
            }
            if let device = videoInput?.device {
                configure(device, for: settings, target: target)
            }
            session.commitConfiguration()
            // No macOS a sessão pode reaplicar o preset ao confirmar ou iniciar; reforça o formato.
            if let device = videoInput?.device {
                configure(device, for: settings, target: target)
            }
        }
    }

    // MARK: Formato da câmera

    private static func videoFormats(of device: AVCaptureDevice) -> [AVCaptureDevice.Format] {
        device.formats.filter { CMFormatDescriptionGetMediaType($0.formatDescription) == kCMMediaType_Video }
    }

    private static func dimensions(_ format: AVCaptureDevice.Format) -> CMVideoDimensions {
        CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    }

    private static func supports(_ format: AVCaptureDevice.Format, fps: Int) -> Bool {
        format.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= Double(fps) + 0.5 && $0.maxFrameRate >= Double(fps) - 0.5
        }
    }

    /// Menor formato nativo que cobre o recorte de saída no fps pedido (ou o maior, se nenhum cobrir).
    private static func bestFormat(for device: AVCaptureDevice, settings: VideoSettings,
                                   target: CGSize? = nil) -> AVCaptureDevice.Format? {
        let output = target ?? settings.outputSize
        let candidates = videoFormats(of: device).filter { supports($0, fps: settings.frameRate) }
        func coverage(_ format: AVCaptureDevice.Format) -> CGFloat {
            let d = dimensions(format)
            let crop = VideoSettings.centerCrop(CGRect(x: 0, y: 0, width: Int(d.width), height: Int(d.height)),
                                                aspect: output.width / output.height)
            return crop.width / output.width
        }
        func pixels(_ format: AVCaptureDevice.Format) -> Int32 {
            let d = dimensions(format)
            return d.width * d.height
        }
        let covering = candidates.filter { coverage($0) >= 0.98 }
        if let smallest = covering.min(by: { pixels($0) < pixels($1) }) { return smallest }
        return candidates.max { pixels($0) < pixels($1) }
    }

    private func configure(_ device: AVCaptureDevice, for settings: VideoSettings, target: CGSize? = nil) {
        guard let format = Self.bestFormat(for: device, settings: settings, target: target),
              (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if device.activeFormat != format { device.activeFormat = format }
        let d = Self.dimensions(format)
        screenLog.info("formato da câmera: \(d.width)x\(d.height) @ \(settings.frameRate) fps")
        let fps = Double(settings.frameRate)
        if let range = format.videoSupportedFrameRateRanges.first(where: {
            $0.minFrameRate <= fps + 0.5 && $0.maxFrameRate >= fps - 0.5
        }) {
            let duration = fps <= range.maxFrameRate && fps >= range.minFrameRate
                ? CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
                : range.minFrameDuration
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
    }

    /// Formato da câmera quando ela só vira bolinha: o suficiente para a maior bolinha possível,
    /// sem trocar de formato a cada redimensionamento. Menos dados pelo USB e menos decodificação.
    private func cameraFormatTarget() -> CGSize? {
        guard screen.mode == .screen, !screen.outputs.contains(.camera) else { return nil }
        let height = CGFloat(BubbleSettings.sizeRange.upperBound) * effective.outputSize.height
        return CGSize(width: (height * 16 / 9).rounded(), height: height.rounded())
    }

    /// Resoluções que a câmera entrega nativamente.
    private func updateCapabilities(for device: AVCaptureDevice) {
        activeFormats = Self.videoFormats(of: device)
        let longest = activeFormats.map { Int(max(Self.dimensions($0).width, Self.dimensions($0).height)) }.max() ?? 1920
        var resolutions = Set(Resolution.allCases.filter { $0.longSide <= longest + 40 })
        resolutions.insert(.hd)
        supportedResolutions = resolutions
        updateEffective()
    }

    /// Taxas de quadros que a câmera atual entrega na resolução indicada.
    private func frameRates(at resolution: Resolution) -> Set<Int> {
        guard !activeFormats.isEmpty else { return Set(VideoSettings.frameRates) }
        let longest = activeFormats.map { Int(max(Self.dimensions($0).width, Self.dimensions($0).height)) }.max() ?? 1920
        let target = min(resolution.longSide, longest)
        let candidates = activeFormats.filter { Int(max(Self.dimensions($0).width, Self.dimensions($0).height)) >= target - 40 }
        let rates = Set(VideoSettings.frameRates.filter { fps in candidates.contains { Self.supports($0, fps: fps) } })
        return rates.isEmpty ? [30] : rates
    }

    /// Recalcula a configuração aplicada sem tocar nas preferências salvas.
    private func updateEffective() {
        var adjusted = settings
        if !supportedResolutions.contains(adjusted.resolution) {
            adjusted.resolution = Resolution.allCases.last { supportedResolutions.contains($0) } ?? .hd
        }
        let rates = frameRates(at: adjusted.resolution)
        if !rates.contains(adjusted.frameRate) {
            adjusted.frameRate = rates.filter { $0 <= adjusted.frameRate }.max() ?? rates.min()!
        }
        supportedFrameRates = rates
        if adjusted != effective {
            let previous = effective
            effective = adjusted
            if screen.mode == .screen,
               previous.frameRate != adjusted.frameRate || previous.resolution != adjusted.resolution {
                updateScreenCapture()
            }
        }
        let camera = Self.cameraSettings(adjusted, screen: screen)
        lock.withLock {
            liveSettings = camera
            liveComposite = adjusted
        }
    }

    // MARK: Gravação

    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        recordingStartedAt = nil
        if screen.mode == .screen {
            startScreenRecording()
            return
        }
        let url = Self.nextFileURL()
        let settings = self.effective
        let withAudio = micAccess == .granted
        outputQueue.async { [self] in
            do {
                writer = try MovieWriter(url: url, settings: settings, audioFormat: withAudio ? lastAudioFormat : nil)
            } catch {
                DispatchQueue.main.async { self.finish(.failure(error)) }
            }
        }
    }

    func stopRecording() {
        outputQueue.async { [self] in
            if !screenWriters.isEmpty {
                finishScreenRecording()
                return
            }
            guard let writer else { return }
            self.writer = nil
            let url = writer.url
            writer.finish { error in
                DispatchQueue.main.async { self.finish(error.map { .failure($0) } ?? .success(url)) }
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        isRecording = false
        recordingStartedAt = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        onFinishedRecording?(result)
    }

    static var folder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Prompter", isDirectory: true)
        try? FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        return movies
    }

    private static func nextFileURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'às' HH.mm.ss"
        return folder.appendingPathComponent("Prompter \(formatter.string(from: Date())).mov")
    }

    func revealFolder() {
        NSWorkspace.shared.open(Self.folder)
    }

    // MARK: Medidor de áudio

    private func startMeter() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            let channels = audioOutput.connection(with: .audio)?.audioChannels ?? []
            let db = channels.map(\.averagePowerLevel).max() ?? -160
            let target = max(0, min(1, (db + 50) / 50))
            let current = meter.level
            // Subida imediata, descida suave.
            let next = target > current ? target : current * 0.75 + target * 0.25
            if abs(next - current) > 0.005 { meter.level = next }
        }
    }

    // MARK: Quadros (dataQueue → GPU → outputQueue)

    private func handleVideo(_ sample: CMSampleBuffer) {
        guard let source = CMSampleBufferGetImageBuffer(sample) else { return }
        let admitted = lock.withLock { () -> Bool in
            guard framesInFlight < maxFramesInFlight else { return false }
            framesInFlight += 1
            return true
        }
        pipelineStats.camera(admitted: admitted)
        guard admitted else { return }
        let settings = lock.withLock { liveSettings }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard let frame = processor.process(source, settings: settings, size: cameraProcessingSize()) else {
            lock.withLock { framesInFlight -= 1 }
            return
        }
        outputQueue.async { [self] in
            frame.wait()
            lock.withLock { framesInFlight -= 1 }
            deliver(frame.buffer, at: time)
        }
    }

    /// No modo tela sem câmera.mov, a câmera só vira a bolinha: processa no tamanho dela (16:9),
    /// em vez da resolução cheia. Na fila de captura.
    private func cameraProcessingSize() -> CGSize? {
        let (screen, composite) = lock.withLock { (liveScreen, liveComposite) }
        guard screen.mode == .screen, !screen.outputs.contains(.camera) else { return nil }
        var output = composite.outputSize
        if !screen.outputs.contains(.composite) { output = Self.previewSize(for: output) }
        let height = max(120, (CGFloat(screen.bubble.size) * output.height).rounded())
        let width = (height * 16 / 9).rounded()
        return CGSize(width: CGFloat(Int(width) & ~1), height: CGFloat(Int(height) & ~1))
    }

    /// Composição só para a prévia (não gravada): no máximo 1280 px no lado maior.
    static func previewSize(for output: CGSize) -> CGSize {
        let scale = min(1, 1280 / max(output.width, output.height))
        return CGSize(width: CGFloat(Int(output.width * scale) & ~1), height: CGFloat(Int(output.height * scale) & ~1))
    }

    private func deliver(_ frame: CVPixelBuffer, at time: CMTime) {
        if lock.withLock({ liveScreen.mode }) == .screen {
            // Modo tela: a câmera vira a bolinha e o arquivo câmera.mov. A composição é montada
            // a partir deste quadro e leva o instante da captura dele, não o da montagem: assim a
            // boca fica sincronizada com o áudio, que também usa o instante de captura.
            let lag = lock.withLock { CMTime(seconds: liveLatency, preferredTimescale: 1_000_000) }
            let captured = hostTime(time) - lag
            lock.withLock { latestCamera = frame }
            cameraWriter?.append(video: frame, at: captured)
            latency.record(video: CMClockGetTime(CMClockGetHostTimeClock()) - captured)
            let admitted = lock.withLock { () -> Bool in
                guard compositesPending < 2 else { return false }
                compositesPending += 1
                return true
            }
            pipelineStats.composite(admitted: admitted)
            if admitted {
                compositeQueue.async { [self] in
                    lock.withLock { compositesPending -= 1 }
                    composite(at: captured, camera: frame, drivenByCamera: true)
                }
            }
            return
        }
        if let writer {
            let wasStarted = writer.hasStarted
            // Instante real do quadro: o carimbo da câmera menos a latência medida dela.
            writer.append(video: frame, at: time - lock.withLock { CMTime(seconds: liveLatency, preferredTimescale: 1_000_000) })
            if !wasStarted, writer.hasStarted {
                DispatchQueue.main.async { [self] in
                    recordingStartedAt = Date()
                    activity = ProcessInfo.processInfo.beginActivity(
                        options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Gravando vídeo")
                }
            }
        }
        display(frame, at: time)
    }

    private func display(_ frame: CVPixelBuffer, at time: CMTime) {
        if let current = displayFormat, !CMVideoFormatDescriptionMatchesImageBuffer(current, imageBuffer: frame) {
            displayFormat = nil
        }
        if displayFormat == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frame, formatDescriptionOut: &displayFormat)
        }
        guard let displayFormat else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: frame, formatDescription: displayFormat,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    private func handleAudio(_ sample: CMSampleBuffer) {
        onAudioSample?(sample)
        if lock.withLock({ liveScreen.mode }) == .screen {
            latency.record(audio: CMClockGetTime(CMClockGetHostTimeClock()) - hostTime(CMSampleBufferGetPresentationTimeStamp(sample)))
        }
        let mirrored = lock.withLock { liveMonoMic } ? audioMirror.process(sample) : nil
        let recorded = mirrored ?? sample
        outputQueue.async { [self] in
            lastAudioFormat = CMSampleBufferGetFormatDescription(recorded)
            writer?.append(audio: recorded)
            if !screenWriters.isEmpty, let retimed = retimedToHost(recorded) {
                for screenWriter in screenWriters { screenWriter.append(audio: retimed) }
            }
        }
    }
}

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOutput {
            handleVideo(sampleBuffer)
        } else {
            audioClock.record(sampleBuffer)
            handleAudio(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === audioOutput { audioClock.recordDrop() }
    }
}

/// Quadros da câmera aceitos/descartados (GPU sem folga) e composições feitas/puladas, a cada 5 s.
final class PipelineStats {
    private let lock = NSLock()
    private var cam = (ok: 0, dropped: 0), comp = (ok: 0, skipped: 0)
    private var last = CFAbsoluteTimeGetCurrent()
    func camera(admitted: Bool) { lock.withLock { if admitted { cam.ok += 1 } else { cam.dropped += 1 } }; report() }
    func composite(admitted: Bool) { lock.withLock { if admitted { comp.ok += 1 } else { comp.skipped += 1 } } }
    private func report() {
        let line: String? = lock.withLock {
            let now = CFAbsoluteTimeGetCurrent(); guard now - last > 5 else { return nil }
            defer { cam = (0, 0); comp = (0, 0); last = now }
            let span = now - last
            return String(format: "pipeline: câmera %.1f q/s (descartados %d), composição %.1f q/s (puladas %d)",
                          Double(cam.ok) / span, cam.dropped, Double(comp.ok) / span, comp.skipped)
        }
        if let line { screenLog.info("\(line, privacy: .public)") }
    }
}

/// Saúde do relógio do áudio capturado: amostras recebidas × tempo dos carimbos, lacunas e descartes.
/// Registra no log a cada 30 s (diagnóstico; não altera nada).
final class AudioClockMonitor {
    private var firstPTS = CMTime.invalid, expected = CMTime.invalid
    private var frames: Int64 = 0, rate = 48_000.0
    private var gaps = 0, gapTotal = 0.0, overlaps = 0, drops = 0
    private var lastReport = CFAbsoluteTimeGetCurrent()

    func recordDrop() { drops += 1 }

    func record(_ sample: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let n = CMSampleBufferGetNumSamples(sample)
        if let d = CMSampleBufferGetFormatDescription(sample), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
            rate = asbd.mSampleRate
        }
        if !firstPTS.isValid { firstPTS = pts }
        if expected.isValid {
            let gap = (pts - expected).seconds
            if gap > 0.002 { gaps += 1; gapTotal += gap } else if gap < -0.002 { overlaps += 1; gapTotal += gap }
        }
        expected = pts + CMTime(value: CMTimeValue(n), timescale: CMTimeScale(rate))
        frames += Int64(n)
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastReport > 30 else { return }
        lastReport = now
        let span = (expected - firstPTS).seconds, content = Double(frames) / rate
        screenLog.info("relógio do áudio: \(String(format: "%.1f", span), privacy: .public) s de carimbos, \(String(format: "%.3f", content), privacy: .public) s de amostras (diferença \(String(format: "%+.3f", content - span), privacy: .public) s); lacunas \(self.gaps) (soma \(String(format: "%+.3f", self.gapTotal), privacy: .public) s), sobreposições \(self.overlaps), descartados \(self.drops)")
    }
}

// MARK: - Modo tela

/// Mede o atraso entre a captura e a chegada ao app (vídeo da câmera e áudio) e registra no log.
final class LatencyMeter {
    private let lock = NSLock()
    private var video: [Double] = [], audio: [Double] = []
    private var last = CFAbsoluteTimeGetCurrent()

    func record(video lag: CMTime) { add(lag.seconds, toVideo: true) }
    func record(audio lag: CMTime) { add(lag.seconds, toVideo: false) }

    private func add(_ value: Double, toVideo: Bool) {
        let report: (Double, Double, Double)? = lock.withLock {
            if toVideo { video.append(value) } else { audio.append(value) }
            let now = CFAbsoluteTimeGetCurrent()
            guard now - last > 3, !video.isEmpty, !audio.isEmpty else { return nil }
            defer { video.removeAll(); audio.removeAll(); last = now }
            return (video.reduce(0, +) / Double(video.count), video.max() ?? 0, audio.reduce(0, +) / Double(audio.count))
        }
        if let (v, vMax, a) = report {
            screenLog.info("latência até o app: câmera \(Int(v * 1000)) ms (máx \(Int(vMax * 1000))), áudio \(Int(a * 1000)) ms")
        }
    }
}

extension CaptureEngine {
    /// Liga, troca ou desliga a captura de tela e o relógio de composição conforme o modo.
    func updateScreenCapture() {
        updateCompositeTimer()
        guard screen.mode == .screen else {
            screenStatus = nil
            lock.withLock { latestCamera = nil }
            Task { await screenRecorder.stop() }
            return
        }
        screenLog.info("updateScreenCapture: mode=screen authorized=\(ScreenRecorder.isAuthorized, privacy: .public) source=\(String(describing: self.screen.source), privacy: .public)")
        if !ScreenRecorder.isAuthorized, !CaptureEngine.requestedScreenAccess {
            // Primeiro bloqueio nesta sessão: dispara o pedido do sistema em vez de só avisar.
            CaptureEngine.requestedScreenAccess = true
            ScreenRecorder.requestAuthorization()
        }
        guard ScreenRecorder.isAuthorized else {
            screenStatus = "Sem permissão de Gravação de Tela. Em Ajustes do Sistema › Privacidade e Segurança › Gravação de Tela e Áudio do Sistema, ligue o Prompter. Se ele já estiver ligado, remova-o com − e adicione de novo; reabra o app se o macOS pedir."
            return
        }
        let settings = effective
        let screenSettings = screen
        screenRecorder.onStop = { [weak self] error in
            guard let self, self.screen.mode == .screen else { return }
            self.screenStatus = "A captura parou: \(error?.localizedDescription ?? "fonte indisponível"). Escolha a fonte de novo."
        }
        Task { @MainActor in
            do {
                guard let source = screenSettings.source else {
                    // Sem fonte escolhida: começa pela tela principal.
                    if let first = try await ScreenRecorder.availableChoices().displays.first {
                        screen.source = first.source
                    }
                    return
                }
                let side = CGFloat(settings.resolution.longSide)
                try await screenRecorder.start(source, fps: settings.frameRate, showsCursor: screenSettings.showsCursor,
                                               maxSize: CGSize(width: side, height: side))
                screenStatus = nil
            } catch {
                screenLog.error("captura não iniciou: \(error.localizedDescription, privacy: .public)")
                screenStatus = error.localizedDescription
            }
        }
    }

    private func updateCompositeTimer() {
        compositeTimer?.cancel()
        compositeTimer = nil
        guard screen.mode == .screen else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: compositeQueue)
        timer.schedule(deadline: .now(), repeating: 1 / Double(effective.frameRate), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.compositeTick() }
        timer.resume()
        compositeTimer = timer
    }

    /// Relógio de reserva: só compõe quando a câmera não está entregando quadros
    /// (sem câmera, sem permissão ou câmera desconectada).
    private func compositeTick() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let (fps, last) = lock.withLock { (liveComposite.frameRate, lastCameraCompositeWall) }
        guard now.seconds - last > 2.5 / Double(fps) else { return }
        composite(at: now, camera: lock.withLock { latestCamera }, drivenByCamera: false)
    }

    /// Um quadro da composição (tela mais recente + câmera), carimbado em `time`.
    /// Roda na compositeQueue; se a anterior ainda estiver na GPU, descarta.
    private func composite(at time: CMTime, camera: CVPixelBuffer?, drivenByCamera: Bool) {
        let (screenSettings, settings, busy) = lock.withLock { () -> (ScreenSettings, VideoSettings, Bool) in
            let wasBusy = compositing
            compositing = true
            if drivenByCamera {
                lastCameraComposite = time.seconds
                lastCameraCompositeWall = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            }
            return (liveScreen, liveComposite, wasBusy)
        }
        guard !busy else { return }
        defer { lock.withLock { compositing = false } }
        guard screenSettings.mode == .screen else { return }
        // Tela do mesmo instante real que a câmera (a câmera chega atrasada; a tela, não).
        let screenFrame = drivenByCamera
            ? screenRecorder.frame(atOrBefore: time.seconds) ?? screenRecorder.latestFrame
            : screenRecorder.latestFrame
        let size = screenSettings.outputs.contains(.composite) ? settings.outputSize : Self.previewSize(for: settings.outputSize)
        guard let frame = compositor.render(screen: screenFrame, camera: camera, bubble: screenSettings.bubble,
                                            size: size) else { return }
        frame.wait()
        outputQueue.async { [self] in
            display(frame.buffer, at: time)
            compositeWriter?.append(video: frame.buffer, at: time)
            if let screenFrame { screenOnlyWriter?.append(video: screenFrame, at: time) }
        }
    }

    fileprivate func startScreenRecording() {
        let folder = Self.nextSessionFolder()
        let settings = effective
        let cameraSettings = Self.cameraSettings(settings, screen: screen)
        var outputs = screen.outputs.isEmpty ? [.composite] : screen.outputs
        if cameraAccess != .granted { outputs.remove(.camera) }
        if outputs.isEmpty { outputs = [.composite] }
        let withAudio = micAccess == .granted
        let screenSize = screenRecorder.captureSize
        outputQueue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                // Início comum no relógio do host: os arquivos se alinham pelo começo.
                let start = CMClockGetTime(CMClockGetHostTimeClock())
                let audio = withAudio ? lastAudioFormat : nil
                var writers: [MovieWriter] = []
                if outputs.contains(.composite) {
                    let w = try MovieWriter(url: folder.appendingPathComponent(ScreenOutput.composite.fileName),
                                            settings: settings, audioFormat: audio, startTime: start)
                    compositeWriter = w
                    writers.append(w)
                }
                if outputs.contains(.screen), screenSize.width > 0 {
                    let w = try MovieWriter(url: folder.appendingPathComponent(ScreenOutput.screen.fileName),
                                            settings: settings, size: screenSize, audioFormat: audio, startTime: start)
                    screenOnlyWriter = w
                    writers.append(w)
                }
                if outputs.contains(.camera) {
                    let w = try MovieWriter(url: folder.appendingPathComponent(ScreenOutput.camera.fileName),
                                            settings: cameraSettings, audioFormat: audio, startTime: start)
                    cameraWriter = w
                    writers.append(w)
                }
                screenWriters = writers
                recordingFolder = folder
                DispatchQueue.main.async { [self] in
                    recordingStartedAt = Date()
                    activity = ProcessInfo.processInfo.beginActivity(
                        options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Gravando tela")
                }
            } catch {
                DispatchQueue.main.async { self.finish(.failure(error)) }
            }
        }
    }

    /// Chamado na outputQueue.
    fileprivate func finishScreenRecording() {
        let writers = screenWriters
        let folder = recordingFolder
        screenWriters = []
        compositeWriter = nil
        cameraWriter = nil
        screenOnlyWriter = nil
        recordingFolder = nil
        let group = DispatchGroup()
        let errorLock = NSLock()
        var firstError: Error?
        for writer in writers {
            group.enter()
            writer.finish { error in
                if let error { errorLock.withLock { if firstError == nil { firstError = error } } }
                group.leave()
            }
        }
        group.notify(queue: .main) { [self] in
            if let error = errorLock.withLock({ firstError }) {
                finish(.failure(error))
            } else if let folder {
                finish(.success(folder))
            }
        }
    }

    nonisolated(unsafe) static var requestedScreenAccess = false
    /// Pasta de gravação de diagnóstico (só com `--diagnostic-record`).
    nonisolated(unsafe) static var diagnosticFolder: URL?

    // MARK: Relógios

    /// Converte um instante do relógio da sessão de captura para o relógio do host.
    func hostTime(_ time: CMTime) -> CMTime {
        guard let clock = session.synchronizationClock else { return time }
        return CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock())
    }

    fileprivate func retimedToHost(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        let original = CMSampleBufferGetPresentationTimeStamp(sample)
        let converted = hostTime(original)
        guard converted != original else { return sample }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample),
                                        presentationTimeStamp: converted, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &copy)
        return copy
    }

    static func nextSessionFolder() -> URL {
        if let diagnosticFolder { return diagnosticFolder.appendingPathComponent("sessão-\(Int(Date().timeIntervalSince1970))", isDirectory: true) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'às' HH.mm.ss"
        return folder.appendingPathComponent("Prompter \(formatter.string(from: Date())) — tela", isDirectory: true)
    }
}
