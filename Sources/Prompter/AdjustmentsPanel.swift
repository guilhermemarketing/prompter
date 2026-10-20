import SwiftUI

/// Presets de cor: os de fábrica mais os salvos pelo usuário.
@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var custom: [ColorPreset] = []
    private let key = "colorPresets"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([ColorPreset].self, from: data) {
            custom = saved
        }
    }

    var all: [ColorPreset] { ColorPreset.builtIns + custom }

    func save(name: String, adjustments: ImageAdjustments) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let index = custom.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            custom[index].adjustments = adjustments
        } else {
            custom.append(ColorPreset(name: name, adjustments: adjustments))
        }
        persist()
    }

    func remove(_ preset: ColorPreset) {
        custom.removeAll { $0.id == preset.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Liga a compensação automática de luz no rosto.
struct LightButton: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var capture: CaptureEngine
    @ViewState private var hovering = false

    var body: some View {
        Button { app.toggleAutoLight() } label: {
            Image(systemName: capture.settings.autoLight ? "sun.max.fill" : "sun.max")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(capture.settings.autoLight ? Color.yellow : Color.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 32)
                .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(capture.settings.autoLight
              ? L("Luz automática ligada: exposição e sombras ajustadas pelo rosto  L", "Auto light on: exposure and shadows follow your face  L")
              : L("Luz automática desligada  L", "Auto light off  L"))
        .onHover { hovering = $0 }
    }
}

/// Abre os ajustes finos de cor; o ponto amarelo indica ajustes ativos.
struct AdjustmentsButton: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var prompter: PrompterModel
    @EnvironmentObject private var capture: CaptureEngine
    @ViewState private var hovering = false

    var body: some View {
        Button { app.showAdjustmentsPanel.toggle() } label: {
            Image(systemName: "camera.filters")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 32)
                .overlay(alignment: .topTrailing) {
                    if !capture.settings.adjustments.isNeutral {
                        Circle().fill(.yellow).frame(width: 6, height: 6).offset(x: -5, y: 5)
                    }
                }
                .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Ajustes de cor e presets", "Color adjustments and presets"))
        .onHover { hovering = $0 }
        .popover(isPresented: $app.showAdjustmentsPanel, arrowEdge: .top) {
            AdjustmentsPanel()
                .environmentObject(app)
                .environmentObject(app.presets)
                .environmentObject(prompter)
                .environmentObject(capture)
        }
    }
}

struct AdjustmentsPanel: View {
    @EnvironmentObject private var presets: PresetStore
    @EnvironmentObject private var capture: CaptureEngine
    @ViewState private var newName = ""

    private var adjustments: Binding<ImageAdjustments> { $capture.settings.adjustments }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("Ajustes de cor", "Color adjustments")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(L("Redefinir", "Reset")) { capture.settings.adjustments = .neutral }
                    .buttonStyle(.borderless)
                    .disabled(capture.settings.adjustments.isNeutral)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(presets.all) { preset in
                    presetChip(preset)
                }
            }

            VStack(spacing: 10) {
                AdjustmentRow(title: L("Contraste", "Contrast"), value: adjustments.contrast, range: -1...1) { "\(Int(($0 * 100).rounded()))" }
                AdjustmentRow(title: L("Brilho", "Brightness"), value: adjustments.brightness, range: -1...1) { "\(Int(($0 * 100).rounded()))" }
                AdjustmentRow(title: L("Pretos", "Blacks"), value: adjustments.blacks, range: -1...1) { "\(Int(($0 * 100).rounded()))" }
                AdjustmentRow(title: L("Sombras", "Shadows"), value: adjustments.shadows, range: -1...1) { "\(Int(($0 * 100).rounded()))" }
                AdjustmentRow(title: L("Brancos", "Whites"), value: adjustments.whites, range: -1...1) { "\(Int(($0 * 100).rounded()))" }
                AdjustmentRow(title: L("Nitidez", "Sharpness"), value: adjustments.sharpness, range: 0...1) { "\(Int(($0 * 100).rounded()))" }
                AdjustmentRow(title: L("Matiz", "Hue"), value: adjustments.hue, range: -180...180) { "\(Int($0.rounded()))°" }
            }

            HStack(spacing: 8) {
                TextField(L("Nome do novo preset", "New preset name"), text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button(L("Salvar", "Save"), action: save)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(L("Os ajustes valem para a prévia e para a gravação. Clique duas vezes no nome de um ajuste para zerá-lo.", "Adjustments apply to the preview and the recording. Double-click an adjustment's name to reset it."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 340)
    }

    private func save() {
        presets.save(name: newName, adjustments: capture.settings.adjustments)
        newName = ""
    }

    @ViewBuilder
    private func presetChip(_ preset: ColorPreset) -> some View {
        let selected = capture.settings.adjustments == preset.adjustments
        Button { capture.settings.adjustments = preset.adjustments } label: {
            Text(preset.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(selected ? Color.black : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.white : Color.white.opacity(0.1)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !preset.builtIn {
                Button(L("Atualizar com os ajustes atuais", "Update with current adjustments")) {
                    presets.save(name: preset.name, adjustments: capture.settings.adjustments)
                }
                Button(L("Apagar preset", "Delete preset"), role: .destructive) { presets.remove(preset) }
            }
        }
        .help(preset.builtIn ? preset.name : L("\(preset.name) — clique com o botão direito para editar ou apagar", "\(preset.name) — right-click to edit or delete"))
    }
}

struct AdjustmentRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13))
                .frame(width: 70, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { value = 0 }
            Slider(value: $value, in: range)
                .controlSize(.small)
            Text(format(value))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}
