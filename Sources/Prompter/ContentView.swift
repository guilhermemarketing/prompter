import AVFoundation
import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var prompter: PrompterModel
    @EnvironmentObject private var capture: CaptureEngine

    @ViewState private var controlsVisible = true
    @ViewState private var hoveringBar = false
    @ViewState private var hideTask: Task<Void, Never>?

    /// Enquanto rola ou grava, os controles somem sozinhos para não distrair.
    private var busy: Bool { prompter.isPlaying || app.isRecordingOrCounting }

    var body: some View {
        GeometryReader { geo in
            let video = Self.fit(aspect: capture.effective.aspect.value, in: geo.size)
            ZStack(alignment: .top) {
                Color.black

                if capture.screen.mode == .screen || capture.cameraAccess == .granted {
                    // No modo tela a prévia não é espelhada: o texto da tela sairia invertido.
                    VideoPreview(layer: capture.displayLayer,
                                 mirrored: prompter.mirror && capture.screen.mode == .camera)
                        .frame(width: video.width, height: video.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if capture.cameraAccess == .denied {
                    AccessNotice().frame(maxHeight: .infinity, alignment: .center)
                }

                if app.showPrompter, app.placement == .overlay {
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.8), location: 0),
                        .init(color: .black.opacity(0.55), location: 0.5),
                        .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                    .frame(height: geo.size.height * 0.62)
                    .allowsHitTesting(false)

                    PrompterText(model: prompter)
                        .frame(height: geo.size.height * 0.5)
                        .allowsHitTesting(false)

                    PrompterCloseButton()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, capture.recordingStartedAt == nil ? 14 : 58)
                        .padding(.trailing, 14)
                        .opacity(controlsVisible ? 1 : 0)

                    if prompter.script.isEmpty {
                        Text(L("Pressione E para escrever seu roteiro.", "Press E to write your script."))
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.top, max(geo.size.height * 0.15, 64))
                    }
                }
            }
            .overlay {
                if capture.screen.mode == .screen, capture.screen.bubble.visible, capture.cameraAccess == .granted {
                    BubbleEditor(video: video)
                        .frame(width: video.width, height: video.height)
                }
            }
            .overlay {
                // Sem permissão a captura não chega: avisa na própria prévia, não só no painel.
                if capture.screen.mode == .screen, let status = capture.screenStatus {
                    ScreenNotice(message: status)
                }
            }
            .animation(.smooth(duration: 0.35), value: capture.settings.aspect)
            .overlay(alignment: .topTrailing) {
                if let start = capture.recordingStartedAt {
                    RecordingPill(start: start).padding(14).transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 14) {
                    if let toast = app.toast {
                        ToastView(toast: toast).transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    ControlsBar()
                        .onHover { hoveringBar = $0; if $0 { reveal() } }
                        .opacity(controlsVisible ? 1 : 0)
                        .offset(y: controlsVisible ? 0 : 20)
                        .allowsHitTesting(controlsVisible)
                }
                .padding(.bottom, 20)
            }
            .overlay {
                if prompter.isEditing {
                    ScriptEditor().transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        .onContinuousHover { phase in
            if case .active = phase { reveal() }
        }
        .onChange(of: busy) { scheduleHide() }
        .dropDestination(for: URL.self) { urls, _ in app.load(urls) }
        .animation(.smooth(duration: 0.3), value: controlsVisible)
        .animation(.smooth(duration: 0.25), value: prompter.isEditing)
        .animation(.smooth(duration: 0.3), value: app.toast)
        .animation(.smooth(duration: 0.3), value: capture.recordingStartedAt)
        .onAppear {
            app.bootstrap()
            DispatchQueue.main.async { Updater.shared.start() }
        }
    }

    /// Maior retângulo com a proporção do vídeo que cabe na janela.
    static func fit(aspect: CGFloat, in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        return size.width / size.height > aspect
            ? CGSize(width: (size.height * aspect).rounded(), height: size.height)
            : CGSize(width: size.width, height: (size.width / aspect).rounded())
    }

    private func reveal() {
        if !controlsVisible { controlsVisible = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard busy else { controlsVisible = true; return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled, busy, !hoveringBar, !prompter.isEditing, !app.showFormatPanel, !app.showAdjustmentsPanel, !app.showLUTPanel, !app.showScreenPanel else { return }
            controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

/// Exibe os quadros já processados (recorte + chroma): a prévia é o arquivo final.
struct VideoPreview: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let mirrored: Bool

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.wantsLayer = true
        view.layer?.addSublayer(layer)
        view.displayLayer = layer
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.mirrored = mirrored
        view.needsLayout = true
    }

    final class HostView: NSView {
        var displayLayer: AVSampleBufferDisplayLayer?
        var mirrored = true

        override func layout() {
            super.layout()
            guard let displayLayer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer.bounds = bounds
            displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            displayLayer.transform = CATransform3DMakeScale(mirrored ? -1 : 1, 1, 1)
            CATransaction.commit()
        }
    }
}

// MARK: - Sobreposições

struct RecordingPill: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            HStack(spacing: 7) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                Text(Self.format(context.date.timeIntervalSince(start)))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct ToastView: View {
    let toast: AppState.Toast

    var body: some View {
        HStack(spacing: 10) {
            switch toast.style {
            case .saved(let url):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(toast.message).fontWeight(.medium)
                Button(L("Mostrar no Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.link)
            case .info:
                Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
                Text(toast.message).fontWeight(.medium)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(toast.message).fontWeight(.medium)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}

struct AccessNotice: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash.fill").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(L("O Prompter precisa de acesso à câmera", "Prompter needs camera access")).font(.title3.weight(.semibold))
            Button(L("Abrir Ajustes do Sistema", "Open System Settings")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, 120)
    }
}

// MARK: - Editor do roteiro

struct ScriptEditor: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var prompter: PrompterModel
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(L("Roteiro", "Script")).font(.system(size: 26, weight: .bold))
                    Text(stats).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Concluído", "Done")) { app.setEditing(false) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .help(L("⌘↩ ou Esc", "⌘↩ or Esc"))
                }
                TextEditor(text: $prompter.script)
                    .font(.system(size: 19))
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
            }
            .frame(maxWidth: 780)
            .padding(.horizontal, 40)
            .padding(.top, 48)
            .padding(.bottom, 28)
        }
        .onAppear { focused = true }
    }

    private var stats: String {
        let words = prompter.words.count
        let seconds = Int((Double(words) / 150 * 60).rounded())
        let time = "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
        return L("\(words) palavras · ~\(time) de fala", "\(words) words · ~\(time) of speech")
    }
}
