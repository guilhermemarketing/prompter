import Combine
import Sparkle
import SwiftUI

/// Atualizações pelo Sparkle. O feed (appcast.xml) fica na Release mais recente do GitHub e cada
/// pacote é assinado com EdDSA (chave pública em Info.plist › SUPublicEDKey). Na segunda abertura
/// o Sparkle pergunta se pode verificar sozinho; com o sim, consulta o GitHub uma vez por dia.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController
    private var started = false
    @Published private(set) var canCheckForUpdates = false

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    /// Chamado quando a janela principal aparece. Se o Sparkle abrisse a pergunta de verificação
    /// antes, o SwiftUI deixaria de apresentar a janela principal na abertura.
    func start() {
        guard !started, !DemoRenderer.isRequested else { return }
        started = true
        controller.startUpdater()
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    /// Verificação diária no GitHub (a pergunta da segunda abertura grava esta mesma preferência).
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { objectWillChange.send(); controller.updater.automaticallyChecksForUpdates = newValue }
    }
}

/// "Verificar atualizações…" (menu do app e menu ⋯).
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Button(L("Verificar atualizações…", "Check for Updates…")) { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

/// Liga e desliga a verificação automática de atualizações.
struct AutomaticUpdatesToggle: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Toggle(L("Verificar atualizações automaticamente", "Check for updates automatically"),
               isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
    }
}
