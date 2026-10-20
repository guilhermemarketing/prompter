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
    }

    private var textControls: some View {
        HStack(spacing: 2) {
            BarButton("square.and.pencil", help: "Editar roteiro  E") { app.setEditing(true) }
            BarButton(prompter.isPlaying ? "pause.fill" : "play.fill",
                      help: prompter.followVoice ? "Ouvir e acompanhar  Espaço" : "Rolar ou pausar  Espaço") {
                app.togglePlay()
            }
            VoiceButton()
            PlacementButton()
            if !prompter.followVoice {
                BarButton("tortoise.fill", help: "Mais devagar  ↓") { prompter.adjustSpeed(-1) }
                Text("\(prompter.speed)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .help("Velocidade")
                BarButton("hare.fill", help: "Mais rápido  ↑") { prompter.adjustSpeed(1) }
            }
            BarButton("textformat.size.smaller", help: "Texto menor  ⌘−") { prompter.adjustFont(-4) }
            BarButton("textformat.size.larger", help: "Texto maior  ⌘=") { prompter.adjustFont(4) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    private var cameraControls: some View {
        HStack(spacing: 2) {
            MicLevel(meter: capture.meter, enabled: capture.micAccess == .granted)
            if capture.cameras.count > 1 {
                BarButton("arrow.triangle.2.circlepath.camera", help: "Trocar câmera") { capture.nextCamera() }
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
              ? "Modo voz ligado: o texto acompanha a sua fala  V"
              : "Modo tempo: rolagem em velocidade constante  V")
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
        .help(active ? "Parar  R" : "Gravar  R")
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
        .help(enabled ? "Nível do microfone" : "Sem acesso ao microfone — verifique em Ajustes do Sistema")
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
        .help("Formato \(aspect.rawValue) — clique para alternar  F")
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
        .help("Resolução, taxa de quadros e fundo")
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
            section("Formato") {
                Segments(options: AspectRatio.allCases, selection: $capture.settings.aspect) { Text($0.rawValue) }
            }
            section("Resolução") {
                Segments(options: Resolution.allCases,
                         selection: Binding(get: { capture.effective.resolution }, set: { capture.settings.resolution = $0 }),
                         isEnabled: { capture.supportedResolutions.contains($0) }) { Text($0.rawValue) }
            }
            section("Taxa de quadros") {
                Segments(options: VideoSettings.frameRates,
                         selection: Binding(get: { capture.effective.frameRate }, set: { capture.settings.frameRate = $0 }),
                         isEnabled: { capture.supportedFrameRates.contains($0) }) { Text("\($0)") }
            }
            section("Fundo chroma key") {
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
            section("Estilo do recorte") {
                VStack(alignment: .leading, spacing: 8) {
                    Segments(options: ChromaStyle.allCases, selection: $capture.settings.chromaStyle) {
                        Text($0.label).font(.system(size: 13, weight: .semibold))
                    }
                    if capture.settings.chromaStyle != .plain {
                        StyleTuning()
                        HStack(spacing: 10) {
                            StyleSwatches(colors: capture.settings.styleColors)
                            Spacer()
                            Button("Personalizar estilo…") { openWindow(id: "styleColors") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            section("Qualidade") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Qualidade", selection: $capture.settings.quality) {
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
            section("Sincronia da câmera") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Compensação atual: \(Int(((capture.activeLatency ?? 0) * 1000).rounded())) ms. Depois de cada gravação o app confere a boca × voz e corrige o arquivo sozinho.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    AdjustmentRow(title: "Ajuste fino",
                                  value: Binding(get: { capture.activeTrim * 1000 }, set: { capture.setTrim($0 / 1000) }),
                                  range: -150...150) { "\($0 >= 0 ? "+" : "")\(Int($0.rounded())) ms" }
                    Text("Se a voz parece vir depois da boca, puxe para a esquerda; se vem antes, para a direita. Vale para as próximas gravações.")
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
        var text = "\(Int(size.width))×\(Int(size.height)) · \(codec) · \(Int(settings.videoMbps)) Mbps · ~\(perMinute) por minuto."
        if settings.background != .none {
            text += " O fundo atrás de você vira cor sólida para recortar na edição; luz uniforme melhora o contorno."
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
                Picker("Câmera", selection: Binding(get: { capture.activeCameraID }, set: { capture.cameraID = $0 })) {
                    ForEach(capture.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                Picker("Microfone", selection: Binding(get: { capture.activeMicID }, set: { capture.micID = $0 })) {
                    ForEach(capture.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
            }
            .disabled(capture.isRecording)
            if capture.isRecording {
                Text("Câmera e microfone mudam depois de parar a gravação")
            }
            Divider()
            Toggle("Espelhar prévia", isOn: $prompter.mirror)
            Toggle("Microfone mono nos dois lados (L = R)", isOn: $capture.monoMic)
                .disabled(capture.isRecording)
            Divider()
            Text("Sincronia labial: \(Int(((capture.activeLatency ?? 0) * 1000).rounded())) ms compensados, ajuste automático pela fala")
            Divider()
            Button("Abrir pasta de gravações") { capture.revealFolder() }
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
        .help("Câmera, microfone e ajustes")
    }
}
