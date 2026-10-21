import AVFoundation
import SwiftUI

/// Barra inferior no estilo da Câmera do iPhone: controles do texto à esquerda,
/// gravar ao centro, câmera e formato à direita.
struct ControlsBar: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var prompter: PrompterModel
    @EnvironmentObject private var capture: CaptureEngine

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            HStack(spacing: 18) {
                textControls
                RecordButton(active: app.isRecordingOrCounting) { app.toggleRecording() }
                cameraControls
            }
        }
        .animation(.smooth(duration: 0.25), value: prompter.followVoice)
        .animation(.smooth(duration: 0.25), value: app.showPrompter)
    }

    private var textControls: some View {
        HStack(spacing: 2) {
            if app.showPrompter { prompterControls } else {
                BarButton("text.viewfinder", help: L("Mostrar teleprompter  H", "Show teleprompter  H")) { app.setTeleprompter(true) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    @ViewBuilder
    private var prompterControls: some View {
            BarButton("square.and.pencil", help: L("Editar roteiro  E", "Edit script  E")) { app.setEditing(true) }
            BarButton(prompter.isPlaying ? "pause.fill" : "play.fill",
                      help: prompter.followVoice ? L("Ouvir e acompanhar  Espaço", "Listen and follow  Space") : L("Rolar ou pausar  Espaço", "Scroll or pause  Space")) {
                app.togglePlay()
            }
            VoiceButton()
            PlacementButton()
            if !prompter.followVoice {
                BarButton("tortoise.fill", help: L("Mais devagar  ↓", "Slower  ↓")) { prompter.adjustSpeed(-1) }
                Text("\(prompter.speed)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .help(L("Velocidade", "Speed"))
                BarButton("hare.fill", help: L("Mais rápido  ↑", "Faster  ↑")) { prompter.adjustSpeed(1) }
            }
            BarButton("textformat.size.smaller", help: L("Texto menor  ⌘−", "Smaller text  ⌘−")) { prompter.adjustFont(-4) }
            BarButton("textformat.size.larger", help: L("Texto maior  ⌘=", "Larger text  ⌘=")) { prompter.adjustFont(4) }
            BarButton("eye.slash", help: L("Ocultar teleprompter (só gravar)  H", "Hide teleprompter (record only)  H")) { app.setTeleprompter(false) }
    }

    private var cameraControls: some View {
        HStack(spacing: 2) {
            MicLevel(meter: capture.meter, enabled: capture.micAccess == .granted)
            if capture.cameras.count > 1 {
                BarButton("arrow.triangle.2.circlepath.camera", help: L("Trocar câmera", "Switch camera")) { capture.nextCamera() }
                    .disabled(capture.isRecording)
            }
            ScreenButton()
            LightButton()
            AdjustmentsButton()
            LUTButton()
            AspectBadge()
            FormatBadge()
            MoreMenu()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }
}

struct BarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @ViewState private var hovering = false

    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 32)
                .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct VoiceButton: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var prompter: PrompterModel
    @ViewState private var hovering = false

    var body: some View {
        Button { app.toggleFollowVoice() } label: {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: app.voiceStatus == .listening)
                .foregroundStyle(prompter.followVoice ? Color.yellow : Color.white)
                .frame(width: 34, height: 32)
                .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(prompter.followVoice
              ? L("Modo voz ligado: o texto acompanha a sua fala  V", "Voice mode on: the text follows your speech  V")
              : L("Modo tempo: rolagem em velocidade constante  V", "Timed mode: constant-speed scrolling  V"))
        .onHover { hovering = $0 }
    }
}

struct RecordButton: View {
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4)
                RoundedRectangle(cornerRadius: active ? 7 : 26)
                    .fill(Color(red: 1, green: 0.23, blue: 0.19))
                    .frame(width: active ? 26 : 52, height: active ? 26 : 52)
            }
            .frame(width: 64, height: 64)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(active ? L("Parar  R", "Stop  R") : L("Gravar  R", "Record  R"))
        .animation(.snappy(duration: 0.25), value: active)
    }
}

struct MicLevel: View {
    @ObservedObject var meter: AudioMeter
    let enabled: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: enabled ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 13))
                .foregroundStyle(enabled ? Color.secondary : Color.red)
            Capsule()
                .fill(.white.opacity(0.15))
                .frame(width: 30, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(meter.level > 0.92 ? Color.red : Color.green)
                        .frame(width: 30 * CGFloat(enabled ? meter.level : 0))
                }
        }
        .padding(.horizontal, 8)
        .help(enabled ? L("Nível do microfone", "Microphone level") : L("Sem acesso ao microfone — verifique em Ajustes do Sistema", "No microphone access — check System Settings"))
    }
}

/// Proporção atual desenhada como um retângulo; clique alterna 16:9 → 9:16 → 4:5.
struct AspectBadge: View {
    @EnvironmentObject private var capture: CaptureEngine
    @ViewState private var hovering = false

    var body: some View {
        let aspect = capture.settings.aspect
        let size = aspect.value >= 1 ? CGSize(width: 24, height: 24 / aspect.value) : CGSize(width: 22 * aspect.value, height: 22)
        Button { capture.settings.aspect = aspect.next } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3.5)
                    .strokeBorder(.white, lineWidth: 1.6)
                    .frame(width: size.width, height: size.height)
                Text(aspect.rawValue)
                    .font(.system(size: 7.5, weight: .heavy, design: .rounded))
            }
            .frame(width: 38, height: 32)
            .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
            .contentShape(Rectangle())
            .animation(.snappy(duration: 0.25), value: aspect)
        }
        .buttonStyle(.plain)
        .disabled(capture.isRecording)
        .help(L("Formato \(aspect.rawValue) — clique para alternar  F", "Format \(aspect.rawValue) — click to switch  F"))
        .onHover { hovering = $0 }
    }
}

/// Selo "2K / 60" como na Câmera do iPhone; abre o painel de formato.
struct FormatBadge: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var prompter: PrompterModel
    @EnvironmentObject private var capture: CaptureEngine
    @ViewState private var hovering = false

    var body: some View {
        Button { app.showFormatPanel.toggle() } label: {
            VStack(spacing: -2) {
                Text(capture.effective.resolution.rawValue)
                Text("\(capture.effective.frameRate)")
            }
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .overlay(alignment: .topTrailing) {
                if let rgb = capture.settings.background.rgb {
                    Circle()
                        .fill(Color(red: rgb.r, green: rgb.g, blue: rgb.b))
                        .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                        .frame(width: 8, height: 8)
                        .offset(x: 7, y: -3)
                }
            }
            .frame(width: 38, height: 32)
            .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Resolução, taxa de quadros e fundo", "Resolution, frame rate and background"))
        .onHover { hovering = $0 }
        .popover(isPresented: $app.showFormatPanel, arrowEdge: .top) {
            FormatPanel()
                .environmentObject(app)
                .environmentObject(prompter)
                .environmentObject(capture)
        }
    }
}

struct FormatPanel: View {
    @EnvironmentObject private var capture: CaptureEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section(L("Formato", "Format")) {
                Segments(options: AspectRatio.allCases, selection: $capture.settings.aspect) { Text($0.rawValue) }
            }
            section(L("Resolução", "Resolution")) {
                Segments(options: Resolution.allCases,
                         selection: Binding(get: { capture.effective.resolution }, set: { capture.settings.resolution = $0 }),
                         isEnabled: { capture.supportedResolutions.contains($0) }) { Text($0.rawValue) }
            }
            section(L("Taxa de quadros", "Frame rate")) {
                Segments(options: VideoSettings.frameRates,
                         selection: Binding(get: { capture.effective.frameRate }, set: { capture.settings.frameRate = $0 }),
                         isEnabled: { capture.supportedFrameRates.contains($0) }) { Text("\($0)") }
            }
            section(L("Fundo chroma key", "Chroma key background")) {
                Segments(options: ChromaBackground.allCases, selection: $capture.settings.background) { background in
                    if let rgb = background.rgb {
                        Circle()
                            .fill(Color(red: rgb.r, green: rgb.g, blue: rgb.b))
                            .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                            .frame(width: 18, height: 18)
                            .help(background.label)
                    } else {
                        Image(systemName: "circle.slash").help(background.label)
                    }
                }
            }
            section(L("Estilo do recorte", "Cutout style")) {
                VStack(alignment: .leading, spacing: 8) {
                    Segments(options: ChromaStyle.allCases, selection: $capture.settings.chromaStyle) {
                        Text($0.label).font(.system(size: 13, weight: .semibold))
                    }
                    if capture.settings.chromaStyle != .plain {
                        StyleTuning()
                        HStack(spacing: 10) {
                            StyleSwatches(colors: capture.settings.styleColors)
                            Spacer()
                            Button(L("Personalizar estilo…", "Customize style…")) { openWindow(id: "styleColors") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            section(L("Qualidade", "Quality")) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(L("Qualidade", "Quality"), selection: $capture.settings.quality) {
                        ForEach(QualityPreset.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    Text(capture.settings.quality.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if capture.settings.quality == .custom {
                        HStack(spacing: 10) {
                            Slider(value: $capture.settings.customMbps, in: 1...VideoSettings.cinemaCeilingMbps, step: 1)
                                .controlSize(.small)
                            Text("\(Int(capture.settings.customMbps)) Mbps")
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                }
            }
            section(L("Sincronia da câmera", "Camera sync")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Compensação atual: \(Int(((capture.activeLatency ?? 0) * 1000).rounded())) ms. Depois de cada gravação o app confere a boca × voz e corrige o arquivo sozinho.",
                       "Current compensation: \(Int(((capture.activeLatency ?? 0) * 1000).rounded())) ms. After each recording, the app checks lips against voice and fixes the file automatically."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    AdjustmentRow(title: L("Ajuste fino", "Fine-tune"),
                                  value: Binding(get: { capture.activeTrim * 1000 }, set: { capture.setTrim($0 / 1000) }),
                                  range: -150...150) { "\($0 >= 0 ? "+" : "")\(Int($0.rounded())) ms" }
                    Text(L("Se a voz parece vir depois da boca, puxe para a esquerda; se vem antes, para a direita. Vale para as próximas gravações.", "If the voice seems to come after the lips, drag left; if before, drag right. Applies to future recordings."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 320)
        .disabled(capture.isRecording)
    }

    private var footnote: String {
        let settings = capture.settings
        let size = settings.outputSize
        let codec = settings.usesProRes ? "ProRes 422 HQ + PCM 24-bit" : "HEVC + AAC"
        let perMinute = settings.megabytesPerMinute >= 1000
            ? String(format: "%.1f GB", settings.megabytesPerMinute / 1000)
            : "\(Int(settings.megabytesPerMinute.rounded())) MB"
        var text = "\(Int(size.width))×\(Int(size.height)) · \(codec) · \(Int(settings.videoMbps)) Mbps · ~\(perMinute) " + L("por minuto.", "per minute.")
        if settings.background != .none {
            text += L(" O fundo atrás de você vira cor sólida para recortar na edição; luz uniforme melhora o contorno.", " The background behind you becomes a solid color to key out in editing; even lighting improves the edge.")
        }
        return text
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Controle segmentado no estilo da Câmera do iPhone: fundo translúcido, opção ativa em branco.
struct Segments<Value: Hashable, Label: View>: View {
    let options: [Value]
    @Binding var selection: Value
    var isEnabled: (Value) -> Bool = { _ in true }
    @ViewBuilder let label: (Value) -> Label

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                let enabled = isEnabled(option)
                Button { selection = option } label: {
                    label(option)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selected ? Color.black : Color.white.opacity(enabled ? 1 : 0.3))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background {
                            if selected { RoundedRectangle(cornerRadius: 11).fill(.white) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 15).fill(.white.opacity(0.1)))
        .animation(.snappy(duration: 0.2), value: selection)
    }
}

struct MoreMenu: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var prompter: PrompterModel
    @EnvironmentObject private var capture: CaptureEngine

    var body: some View {
        Menu {
            // Dispositivos e formato do áudio não mudam no meio de uma gravação.
            Group {
                Picker(L("Câmera", "Camera"), selection: Binding(get: { capture.activeCameraID }, set: { capture.cameraID = $0 })) {
                    ForEach(capture.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                Picker(L("Microfone", "Microphone"), selection: Binding(get: { capture.activeMicID }, set: { capture.micID = $0 })) {
                    ForEach(capture.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
            }
            .disabled(capture.isRecording)
            if capture.isRecording {
                Text(L("Câmera e microfone mudam depois de parar a gravação", "Camera and microphone change after you stop recording"))
            }
            Divider()
            Toggle(L("Espelhar prévia", "Mirror preview"), isOn: $prompter.mirror)
            Toggle(L("Microfone mono nos dois lados (L = R)", "Mono microphone on both sides (L = R)"), isOn: $capture.monoMic)
                .disabled(capture.isRecording)
            Divider()
            Text(L("Sincronia labial: \(Int(((capture.activeLatency ?? 0) * 1000).rounded())) ms compensados, ajuste automático pela fala",
                    "Lip sync: \(Int(((capture.activeLatency ?? 0) * 1000).rounded())) ms compensated, auto-adjusted from speech"))
            Divider()
            Button(L("Abrir pasta de gravações", "Open recordings folder")) { capture.revealFolder() }
            CheckForUpdatesButton()
            AutomaticUpdatesToggle()
        } label: {
            // A área clicável é o quadro inteiro, não só o desenho das reticências.
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 34, height: 32)
        .contentShape(Rectangle())
        .help(L("Câmera, microfone e ajustes", "Camera, microphone and settings"))
    }
}
