import AppKit
import UniformTypeIdentifiers
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    struct Toast: Equatable {
        enum Style { case saved(URL), info, error }
        let id = UUID()
        let message: String
        let style: Style
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    enum VoiceStatus: Equatable { case off, preparing, listening }

    let prompter = PrompterModel()
    let capture = CaptureEngine()
    let follower = SpeechFollower()
    let presets = PresetStore()

    @Published private(set) var toast: Toast?
    @Published private(set) var voiceStatus: VoiceStatus = .off
    @Published var showFormatPanel = false
    @Published var showAdjustmentsPanel = false
    @Published var showLUTPanel = false
    @Published var showScreenPanel = false
    private let areaSelector = AreaSelector()
    /// Onde o texto aparece (persistido).
    @Published var placement: PrompterPlacement =
        PrompterPlacement(rawValue: UserDefaults.standard.string(forKey: "prompterPlacement") ?? "") ?? .overlay {
        didSet {
            UserDefaults.standard.set(placement.rawValue, forKey: "prompterPlacement")
            panels.apply(placement, model: prompter)
            if placement != oldValue { show("Teleprompter: \(placement.label)", .info) }
        }
    }
    private let panels = PrompterPanels()

    private var toastTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    private var monitor: Any?

    var isRecordingOrCounting: Bool { capture.isRecording }

    /// Chamado quando a janela aparece (NSApp já existe).
    func bootstrap() {
        guard monitor == nil else { return }
        capture.onFinishedRecording = { [weak self] result in
            MainActor.assumeIsolated { self?.recordingFinished(result) }
        }
        capture.onAudioSample = { [follower] sample in follower.append(sample) }
        follower.onPosition = { [weak self] position in
            MainActor.assumeIsolated { self?.prompter.setSpoken(position) }
        }
        prompter.onSeek = { [follower] index in follower.reset(to: index) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consume(event) ?? false }
            return consumed ? nil : event
        }
        capture.start()
        panels.apply(placement, model: prompter)
        // Diagnóstico: --diagnostic-record SEGUNDOS PASTA grava sozinho e para (uso de desenvolvimento).
        if let i = CommandLine.arguments.firstIndex(of: "--diagnostic-record"), CommandLine.arguments.count > i + 2,
           let seconds = Double(CommandLine.arguments[i + 1]) {
            CaptureEngine.diagnosticFolder = URL(fileURLWithPath: CommandLine.arguments[i + 2], isDirectory: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [self] in
                toggleRecording()
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in toggleRecording() }
            }
        }
    }

    // MARK: Reprodução

    func togglePlay() { prompter.isPlaying ? pause() : play() }

    func play() {
        guard !prompter.isPlaying, !prompter.script.isEmpty else { return }
        prompter.isEditing = false
        prompter.play()
        if prompter.followVoice { startListening() }
    }

    func pause() {
        prompter.pause()
        stopListening()
    }

    func toggleFollowVoice() {
        let wasPlaying = prompter.isPlaying
        pause()
        prompter.setFollowVoice(!prompter.followVoice)
        show(prompter.followVoice ? "Modo voz: o texto acompanha a sua fala" : "Modo tempo: rolagem em velocidade constante", .info)
        if wasPlaying { play() }
    }

    private func startListening() {
        guard capture.micAccess == .granted else {
            show("O modo voz precisa de acesso ao microfone.", .error)
            prompter.pause()
            return
        }
        voiceStatus = .preparing
        let script = prompter.script
        let from = prompter.spokenCount
        listenTask?.cancel()
        listenTask = Task { @MainActor in
            do {
                try await follower.start(script: script, from: from) {
                    DispatchQueue.main.async { AppState.shared.show("Baixando o modelo de voz (só na primeira vez)…", .info) }
                }
                guard !Task.isCancelled else { return }
                voiceStatus = .listening
            } catch {
                guard !Task.isCancelled else { return }
                voiceStatus = .off
                prompter.pause()
                show(error.localizedDescription, .error)
            }
        }
    }

    private func stopListening() {
        listenTask?.cancel()
        listenTask = nil
        guard voiceStatus != .off else { return }
        voiceStatus = .off
        Task { await follower.stop() }
    }

    /// Importa um ou mais .cube; o último importado já fica ativo.
    func importLUTs() {
        let panel = NSOpenPanel()
        panel.title = "Importar LUT"
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        showLUTPanel = false
        guard panel.runModal() == .OK else { return }
        var failures: [String] = []
        for url in panel.urls {
            do {
                let info = try LUTLibrary.shared.importCube(from: url)
                capture.settings.lutID = info.id
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if let first = failures.first {
            show("Não foi possível importar \(first)", .error)
        } else {
            show(panel.urls.count == 1 ? "LUT importado" : "\(panel.urls.count) LUTs importados", .info)
        }
        showLUTPanel = true
    }

    /// Desenha a área a gravar e já passa para o modo tela.
    func selectArea() {
        showScreenPanel = false
        areaSelector.begin { [weak self] source in
            guard let self else { return }
            if let source {
                capture.screen.source = source
                capture.screen.mode = .screen
            }
            NSApp.activate()
            showScreenPanel = true
        }
    }

    // MARK: Sincronia labial

    /// Depois de cada gravação, mede a sincronia boca×voz em até 2 min de fala. Se a medição for
    /// confiável, corrige os arquivos (desloca o áudio, sem recodificar) e aproxima a compensação
    /// das próximas gravações. O desvio da câmera muda de sessão para sessão: daí corrigir sempre.
    private func correctLipSync(at url: URL) {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let files: [URL] = isFolder
            ? ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "mov" }
            : [url]
        // A câmera sem composição é o sinal mais limpo; a composição serve de reserva.
        let candidates = [files.first { $0.lastPathComponent == "câmera.mov" },
                          files.first { $0.lastPathComponent == "composição.mov" }].compactMap { $0 }
        let references = candidates.isEmpty ? Array(files.prefix(1)) : candidates
        guard !references.isEmpty else { return }
        let cameraID = capture.activeCameraID
        Task.detached(priority: .utility) { [weak self] in
            var found: LipSync.Estimate?
            for reference in references {
                if let estimate = await LipSync.estimate(reference), estimate.isReliable { found = estimate; break }
            }
            guard let estimate = found else { return }
            screenLog.info("sincronia labial: corrigir \(Int(estimate.residual * 1000)) ms, correlação \(String(format: "%.2f", estimate.correlation), privacy: .public), nitidez \(String(format: "%.2f", estimate.sharpness), privacy: .public)")
            guard estimate.isReliable, abs(estimate.residual) >= 0.03, abs(estimate.residual) <= 0.4 else { return }
            var fixed = 0
            for file in files {
                do { try await LipSync.shiftAudio(in: file, by: estimate.residual); fixed += 1 }
                catch { screenLog.error("não corrigiu \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)") }
            }
            await MainActor.run { [weak self] in
                guard let self, fixed > 0 else { return }
                // Metade do caminho: a próxima sessão tende a parecer com esta, mas varia.
                let current = capture.cameraLatency[cameraID] ?? 0
                capture.setLatency(min(max(current + estimate.residual / 2, 0), 0.5), forCamera: cameraID)
                show("Sincronia labial corrigida nesta gravação (\(estimate.residual > 0 ? "+" : "")\(Int((estimate.residual * 1000).rounded())) ms)", .saved(url))
            }
        }
    }

    func toggleAutoLight() {
        capture.settings.autoLight.toggle()
        show(capture.settings.autoLight ? "Luz automática ligada: exposição guiada pelo rosto" : "Luz automática desligada", .info)
    }

    // MARK: Gravação

    func toggleRecording() {
        if capture.isRecording {
            capture.stopRecording()
            pause()
        } else {
            startRecording()
        }
    }

    /// Começa na hora: o texto passa a rolar (ou ouvir) junto com o primeiro quadro.
    private func startRecording() {
        if capture.screen.mode == .screen {
            guard ScreenRecorder.isAuthorized, capture.screenStatus == nil else {
                screenLog.error("gravação recusada: autorizado=\(ScreenRecorder.isAuthorized, privacy: .public) status=\(self.capture.screenStatus ?? "-", privacy: .public)")
                show(capture.screenStatus ?? "O Prompter precisa da permissão de Gravação de Tela.", .error)
                showScreenPanel = true
                return
            }
        } else if capture.cameraAccess != .granted {
            show("O Prompter precisa de acesso à câmera.", .error)
            return
        }
        screenLog.info("gravação iniciada (modo \(self.capture.screen.mode.rawValue, privacy: .public))")
        prompter.isEditing = false
        showFormatPanel = false
        showAdjustmentsPanel = false
        showLUTPanel = false
        showScreenPanel = false
        capture.startRecording()
        if !prompter.isPlaying { play() }
    }

    private func recordingFinished(_ result: Result<URL, Error>) {
        pause()
        switch result {
        case .success(let url):
            show("Gravação salva", .saved(url))
            correctLipSync(at: url)
        case .failure(let error): show("Não foi possível salvar: \(error.localizedDescription)", .error)
        }
    }

    // MARK: Roteiro

    func load(_ urls: [URL]) -> Bool {
        guard let url = urls.first,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        pause()
        prompter.script = text.trimmingCharacters(in: .whitespacesAndNewlines)
        show("Roteiro carregado: \(url.lastPathComponent)", .info)
        return true
    }

    func setEditing(_ editing: Bool) {
        if editing { pause(); showFormatPanel = false; showAdjustmentsPanel = false }
        prompter.isEditing = editing
    }

    // MARK: Toast

    func show(_ message: String, _ style: Toast.Style) {
        toast = Toast(message: message, style: style)
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: Teclado e trackpad

    /// Retorna true quando o evento foi tratado e não deve seguir adiante.
    private func consume(_ event: NSEvent) -> Bool {
        let inPrompterPanel = event.window?.identifier?.rawValue.hasPrefix(PrompterPanels.identifierPrefix) == true
        if event.type == .scrollWheel, inPrompterPanel, !prompter.isEditing {
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            prompter.nudge(-event.scrollingDeltaY * factor)
            return true
        }
        // Popovers, menus e a janela de cores têm a própria janela: deixa os eventos passarem.
        if let window = event.window, window !== NSApp.mainWindow { return false }

        if event.type == .scrollWheel {
            guard !prompter.isEditing else { return false }
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            prompter.nudge(-event.scrollingDeltaY * factor)
            return true
        }

        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }

        if prompter.isEditing {
            if event.keyCode == 53 { setEditing(false); return true }   // Esc
            return false
        }

        switch event.keyCode {
        case 49: togglePlay()                                // Espaço
        case 126: prompter.adjustSpeed(1)                    // ↑
        case 125: prompter.adjustSpeed(-1)                   // ↓
        case 123: prompter.nudge(-prompter.lineStep * 2)     // ←
        case 124: prompter.nudge(prompter.lineStep * 2)      // →
        case 115: prompter.rewind()                          // Home
        case 53:                                             // Esc
            if showFormatPanel || showAdjustmentsPanel || showLUTPanel || showScreenPanel {
                showFormatPanel = false; showAdjustmentsPanel = false; showLUTPanel = false; showScreenPanel = false
            }
            else if capture.isRecording { toggleRecording() }
            else { pause() }
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r": toggleRecording()
            case "e": setEditing(true)
            case "v": toggleFollowVoice()
            case "l": toggleAutoLight()
            case "t": placement = placement.next
            case "f": if !capture.isRecording { capture.settings.aspect = capture.settings.aspect.next }
            default: return false
            }
        }
        return true
    }
}
