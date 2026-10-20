import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Botão "LUT" da barra: amarelo quando há um LUT ativo.
struct LUTButton: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var prompter: PrompterModel
    @EnvironmentObject private var capture: CaptureEngine
    @ViewState private var hovering = false

    private var active: Bool { capture.settings.lutID != nil && capture.settings.lutIntensity > 0.001 }

    var body: some View {
        Button { app.showLUTPanel.toggle() } label: {
            Text("LUT")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(active ? Color.black : Color.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(active ? Color.yellow : .clear))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(active ? Color.clear : .white, lineWidth: 1.4))
                .frame(width: 38, height: 32)
                .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(active ? "LUT: \(LUTLibrary.shared.name(for: capture.settings.lutID) ?? "")" : "LUTs de cor")
        .onHover { hovering = $0 }
        .popover(isPresented: $app.showLUTPanel, arrowEdge: .top) {
            LUTPanel()
                .environmentObject(app)
                .environmentObject(capture)
                .environmentObject(LUTLibrary.shared)
        }
    }
}

struct LUTPanel: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var capture: CaptureEngine
    @EnvironmentObject private var library: LUTLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("LUT").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Importar .cube…") { app.importLUTs() }
                    .buttonStyle(.borderless)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                chip(title: "Nenhum", id: nil)
                ForEach(library.all) { info in
                    chip(title: info.name, id: info.id)
                        .contextMenu {
                            if !info.builtIn {
                                Button("Remover LUT", role: .destructive) {
                                    if capture.settings.lutID == info.id { capture.settings.lutID = nil }
                                    library.remove(info)
                                }
                            }
                        }
                }
            }

            AdjustmentRow(title: "Intensidade", value: $capture.settings.lutIntensity, range: 0...1) {
                "\(Int(($0 * 100).rounded()))%"
            }
            .disabled(capture.settings.lutID == nil)

            Text("LUTs 3D .cube (Rec.709) de até 64³. Entram depois dos ajustes de cor e antes do chroma, na prévia e na gravação.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 340)
    }

    private func chip(title: String, id: String?) -> some View {
        let selected = capture.settings.lutID == id
        return Button { capture.settings.lutID = id } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(selected ? Color.black : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.white : Color.white.opacity(0.1)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
