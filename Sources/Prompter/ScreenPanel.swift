import AppKit
import SwiftUI

/// Botão do modo tela: amarelo quando gravando a tela.
struct ScreenButton: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var prompter: PrompterModel
    @EnvironmentObject private var capture: CaptureEngine
    @ViewState private var hovering = false

    var body: some View {
        let active = capture.screen.mode == .screen
        Button { app.showScreenPanel.toggle() } label: {
            Image(systemName: active ? "display" : "display")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? Color.yellow : Color.white)
                .overlay(alignment: .topTrailing) {
                    if active, capture.screenStatus != nil {
                        Circle().fill(.red).frame(width: 6, height: 6).offset(x: 4, y: -2)
                    }
                }
                .frame(width: 34, height: 32)
                .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(active ? L("Gravando a tela com a câmera em destaque", "Recording the screen with your camera on top") : L("Gravar a tela, uma janela ou uma área", "Record the screen, a window or an area"))
        .onHover { hovering = $0 }
        .popover(isPresented: $app.showScreenPanel, arrowEdge: .top) {
            ScreenPanel()
                .environmentObject(app)
                .environmentObject(capture)
        }
    }
}

struct ScreenPanel: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var capture: CaptureEngine
    @ViewState private var displays: [ScreenRecorder.Choice] = []
    @ViewState private var windows: [ScreenRecorder.Choice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section(L("Gravar", "Record")) {
                Segments(options: CaptureMode.allCases, selection: $capture.screen.mode) { Text($0.label) }
            }

            if capture.screen.mode == .screen {
                if let status = capture.screenStatus {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(status, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.yellow)
                            .fixedSize(horizontal: false, vertical: true)
                        if !ScreenRecorder.isAuthorized {
                            HStack {
                                Button(L("Pedir permissão", "Request permission")) { ScreenRecorder.requestAuthorization() }
                                Button(L("Abrir Ajustes", "Open Settings")) {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            }
                        }
                    }
                }

                section(L("Fonte", "Source")) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(displays) { choice in sourceRow(choice, symbol: "display") }
                        sourceRow(title: L("Área da tela…", "Screen area…"), detail: areaDetail, symbol: "rectangle.dashed",
                                  selected: isArea) { app.selectArea() }
                        if !windows.isEmpty {
                            Text(L("Janelas", "Windows")).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(windows) { choice in sourceRow(choice, symbol: "macwindow") }
                                }
                            }
                            .frame(maxHeight: 150)
                        }
                    }
                }

                section(L("Câmera em destaque", "Camera overlay")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(L("Mostrar a câmera sobre a tela", "Show the camera over the screen"), isOn: $capture.screen.bubble.visible)
                        if capture.screen.bubble.visible {
                            Segments(options: BubbleShape.allCases, selection: $capture.screen.bubble.shape) {
                                Label($0.label, systemImage: $0.symbol).labelStyle(.iconOnly).help($0.label)
                            }
                            AdjustmentRow(title: L("Tamanho", "Size"), value: $capture.screen.bubble.size,
                                          range: BubbleSettings.sizeRange) { "\(Int(($0 * 100).rounded()))%" }
                        }
                    }
                }

                section(L("Arquivos da gravação", "Recording files")) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ScreenOutput.allCases) { output in
                            Toggle(output.label, isOn: Binding(
                                get: { capture.screen.outputs.contains(output) },
                                set: { on in
                                    var outputs = capture.screen.outputs
                                    if on { outputs.insert(output) } else { outputs.remove(output) }
                                    if !outputs.isEmpty { capture.screen.outputs = outputs }   // ao menos um
                                }))
                        }
                        Text(L("Cada arquivo a mais usa um codificador de vídeo e pesa no Mac. Para aulas longas, só a composição é o mais leve.", "Each extra file uses another video encoder and adds load to the Mac. For long classes, the composite alone is the lightest."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(capture.isRecording)
                Toggle(L("Mostrar o cursor", "Show the cursor"), isOn: $capture.screen.showsCursor)
                    .disabled(capture.isRecording)

                Text(L("Arraste a câmera na prévia para posicioná-la e use o canto para redimensionar. Os arquivos escolhidos saem sincronizados numa pasta por gravação.",
                       "Drag the camera in the preview to position it and use the corner to resize. The selected files come out in sync, in one folder per recording."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 360)
        .disabled(capture.isRecording && capture.screen.mode == .camera)
        .task(id: capture.screen.mode) { await loadChoices() }
    }

    private var isArea: Bool {
        if case .area = capture.screen.source { return true }
        return false
    }

    private var areaDetail: String {
        if case .area(_, _, _, let w, let h) = capture.screen.source { return "\(Int(w))×\(Int(h)) pt" }
        return L("Desenhe um retângulo", "Draw a rectangle")
    }

    private func loadChoices() async {
        guard capture.screen.mode == .screen, ScreenRecorder.isAuthorized,
              let choices = try? await ScreenRecorder.availableChoices() else { return }
        displays = choices.displays
        windows = choices.windows
    }

    private func sourceRow(_ choice: ScreenRecorder.Choice, symbol: String) -> some View {
        sourceRow(title: choice.title, detail: choice.detail, symbol: symbol,
                  selected: capture.screen.source == choice.source) { capture.screen.source = choice.source }
    }

    private func sourceRow(title: String, detail: String, symbol: String, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(selected ? Color.black.opacity(0.6) : .secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.black : Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.white : Color.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(capture.isRecording)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Alça invisível sobre a câmera na prévia: arrastar move, o canto redimensiona.
/// Durante o gesto, a posição fica só aqui e no compositor (sem republicar estado do app);
/// ao soltar, vira preferência.
struct BubbleEditor: View {
    @EnvironmentObject private var capture: CaptureEngine
    let video: CGSize
    @ViewState private var dragStart: BubbleSettings?
    @ViewState private var live: BubbleSettings?
    @ViewState private var hovering = false

    var body: some View {
        let output = capture.effective.outputSize
        let bubble = live ?? capture.screen.bubble
        let frame = bubble.frame(in: output)
        let scale = video.width / max(output.width, 1)
        let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        let active = hovering || dragStart != nil

        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: bubble.shape == .circle ? rect.width / 2 : 8)
                .strokeBorder(.white.opacity(active ? 0.9 : 0), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? bubble
                        if dragStart == nil { dragStart = start }
                        var moved = start
                        moved.centerX = start.centerX + value.translation.width / video.width
                        moved.centerY = start.centerY + value.translation.height / video.height
                        moved.clamp(in: output)
                        update(moved)
                    }
                    .onEnded { _ in commit() })
            Circle()
                .fill(.white)
                .overlay(Circle().strokeBorder(.black, lineWidth: 2))
                .frame(width: 14, height: 14)
                .opacity(active ? 1 : 0)
                .offset(x: 4, y: 4)
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? bubble
                        if dragStart == nil { dragStart = start }
                        var resized = start
                        let delta = (value.translation.width / start.shape.aspect + value.translation.height) / video.height
                        resized.size = min(max(start.size + delta, BubbleSettings.sizeRange.lowerBound),
                                           BubbleSettings.sizeRange.upperBound)
                        resized.clamp(in: output)
                        update(resized)
                    }
                    .onEnded { _ in commit() })
                .help(L("Arraste para redimensionar", "Drag to resize"))
        }
        .frame(width: rect.width, height: rect.height)
        .onHover { hovering = $0 }
        .help(L("Arraste para mover a câmera", "Drag to move the camera"))
        .position(x: rect.midX, y: rect.midY)
    }

    private func update(_ bubble: BubbleSettings) {
        live = bubble
        capture.previewBubble(bubble)
    }

    private func commit() {
        if let live { capture.screen.bubble = live }
        live = nil
        dragStart = nil
    }
}

/// Aviso sobre a prévia quando a captura de tela não está chegando.
struct ScreenNotice: View {
    @EnvironmentObject private var capture: CaptureEngine
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack {
                if !ScreenRecorder.isAuthorized {
                    Button(L("Abrir Ajustes", "Open Settings")) {
                        ScreenRecorder.requestAuthorization()
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.glassProminent)
                }
                Button(L("Tentar de novo", "Try again")) { capture.updateScreenCapture() }
                    .buttonStyle(.glass)
            }
        }
        .padding(24)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}
