import AppKit
import SwiftUI

/// Onde o texto do teleprompter aparece.
enum PrompterPlacement: String, CaseIterable, Identifiable {
    /// Sobre a prévia, no topo da janela (padrão).
    case overlay
    /// Caixa solta, arrastável e redimensionável, sempre à frente.
    case floating
    /// Fixa no topo da tela, colada à câmera do iMac/MacBook.
    case top

    var id: String { rawValue }
    var label: String {
        switch self {
        case .overlay: "Na janela"
        case .floating: "Caixa solta"
        case .top: "Fixo ao topo"
        }
    }
    var symbol: String {
        switch self {
        case .overlay: "rectangle.topthird.inset.filled"
        case .floating: "macwindow.on.rectangle"
        case .top: "menubar.rectangle"
        }
    }
    var next: PrompterPlacement {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Janelas do teleprompter fora da janela principal. Não viram janela-chave:
/// o teclado continua com a janela principal; o trackpad rola o texto nelas também.
@MainActor
final class PrompterPanels {
    static let identifierPrefix = "prompter-panel"
    private var floating: NSPanel?
    private var top: NSPanel?

    func apply(_ placement: PrompterPlacement, model: PrompterModel) {
        if placement != .floating { floating?.orderOut(nil); floating = nil }
        if placement != .top { top?.orderOut(nil); top = nil }
        switch placement {
        case .overlay: break
        case .floating: if floating == nil { floating = makeFloating(model: model) }
        case .top: if top == nil { top = makeTop(model: model) }
        }
    }

    private func makeFloating(model: PrompterModel) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 280),
                            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("\(Self.identifierPrefix)-floating")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.minSize = NSSize(width: 360, height: 140)
        configure(panel)
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: FloatingPrompterView(model: model))
        let name = "PrompterFloatingPanel"
        if !panel.setFrameUsingName(name), let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 380, y: frame.maxY - 280 - 12))
        }
        panel.setFrameAutosaveName(name)
        panel.orderFrontRegardless()
        return panel
    }

    private func makeTop(model: PrompterModel) -> NSPanel {
        // A tela principal é a que tem a barra de menus — e a câmera embutida.
        let screen = NSScreen.screens.first ?? NSScreen.main!
        let width = min(900, screen.frame.width * 0.46), height: CGFloat = 220
        let frame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("\(Self.identifierPrefix)-top")
        configure(panel)
        // Acima da barra de menus, para colar o texto na borda superior, rente à lente.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior.insert(.stationary)
        panel.contentView = NSHostingView(rootView: TopPrompterView(model: model))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        return panel
    }

    private func configure(_ panel: NSPanel) {
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }
}

struct FloatingPrompterView: View {
    let model: PrompterModel

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.black.opacity(0.84))
                .gesture(WindowDragGesture())
            PrompterText(model: model, reading: ReadingLine(fraction: 0.28, minimum: 36))
                .padding(.top, 4)
                .allowsHitTesting(false)
            Capsule()
                .fill(.white.opacity(0.25))
                .frame(width: 44, height: 5)
                .padding(.top, 8)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .help("Arraste para mover; puxe as bordas para redimensionar")
    }
}

struct TopPrompterView: View {
    let model: PrompterModel

    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: 28, bottomTrailingRadius: 28, style: .continuous)
                .fill(.black)
            PrompterText(model: model, reading: .top)
                .padding(.top, 6)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

struct PlacementButton: View {
    @EnvironmentObject private var app: AppState
    @ViewState private var hovering = false

    var body: some View {
        Button { app.placement = app.placement.next } label: {
            Image(systemName: app.placement.symbol)
                .font(.system(size: 15, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 32)
                .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Teleprompter: \(app.placement.label) — clique para alternar  T")
        .onHover { hovering = $0 }
    }
}

// MARK: - Estilos do recorte

/// Força (cel-shading) ou espessuras (adesivo), conforme o estilo ativo.
struct StyleTuning: View {
    @EnvironmentObject private var capture: CaptureEngine

    var body: some View {
        switch capture.settings.chromaStyle {
        case .plain:
            EmptyView()
        case .cel:
            AdjustmentRow(title: "Força", value: $capture.settings.celStrength, range: 0...1) {
                "\(Int(($0 * 100).rounded()))%"
            }
            .help("Intensidade das cores chapadas e sombras. Os contornos ficam sempre inteiros.")
        case .sticker:
            VStack(spacing: 8) {
                AdjustmentRow(title: "Borda", value: $capture.settings.stickerBorderWidth,
                              range: VideoSettings.stickerBorderRange) { "\(Int($0.rounded())) px" }
                AdjustmentRow(title: "Contorno", value: $capture.settings.stickerOutlineWidth,
                              range: VideoSettings.stickerOutlineRange) { "\(Int($0.rounded())) px" }
            }
            .help("Espessuras medidas em 1080p; acompanham a resolução escolhida.")
        }
    }
}

struct StyleSwatches: View {
    let colors: StyleColors

    var body: some View {
        HStack(spacing: 6) {
            ForEach([colors.outline, colors.border, colors.shadow], id: \.self) { color in
                Circle()
                    .fill(Color(color))
                    .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
                    .frame(width: 16, height: 16)
            }
        }
    }
}

/// Janela própria: o seletor de cores do sistema fecharia um popover.
struct StyleColorsView: View {
    @EnvironmentObject private var capture: CaptureEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Estilo", selection: $capture.settings.chromaStyle) {
                ForEach(ChromaStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if capture.settings.chromaStyle == .plain {
                Text("Escolha Cel-shading ou Adesivo para personalizar contornos, bordas e sombras.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let sticker = capture.settings.chromaStyle == .sticker
                StyleTuning()
                Divider()
                colorRow("Contorno", sticker ? "Linha externa do adesivo" : "Contorno da silhueta e linhas internas", \.outline)
                colorRow("Borda", sticker ? "Faixa do adesivo" : "Halo externo ao contorno", \.border)
                colorRow("Sombra", sticker ? "Sombra dura deslocada" : "Tom das áreas escuras", \.shadow)
                HStack {
                    Text("Opacidade zero desliga o elemento.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restaurar padrão") {
                        let defaults = VideoSettings()
                        if sticker {
                            capture.settings.stickerColors = .stickerDefault
                            capture.settings.stickerBorderWidth = defaults.stickerBorderWidth
                            capture.settings.stickerOutlineWidth = defaults.stickerOutlineWidth
                        } else {
                            capture.settings.celColors = .celDefault
                            capture.settings.celStrength = defaults.celStrength
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func colorRow(_ title: String, _ detail: String, _ key: WritableKeyPath<StyleColors, RGBAColor>) -> some View {
        HStack(spacing: 12) {
            ColorPicker(title, selection: binding(key), supportsOpacity: true)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func binding(_ key: WritableKeyPath<StyleColors, RGBAColor>) -> Binding<Color> {
        Binding(
            get: { Color(capture.settings.styleColors[keyPath: key]) },
            set: { color in
                let value = RGBAColor(color)
                if capture.settings.chromaStyle == .sticker {
                    capture.settings.stickerColors[keyPath: key] = value
                } else {
                    capture.settings.celColors[keyPath: key] = value
                }
            })
    }
}

extension Color {
    init(_ c: RGBAColor) { self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }
}

extension RGBAColor {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent),
                  b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }
}
