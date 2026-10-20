import SwiftUI

@main
struct PrompterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var app = AppState.shared

    var body: some Scene {
        Window("Prompter", id: "main") {
            ContentView()
                .environmentObject(app)
                .environmentObject(app.prompter)
                .environmentObject(app.capture)
                .frame(minWidth: 640, minHeight: 420)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1120, height: 700)
        .defaultPosition(.top)
        // Sempre abre a janela principal, mesmo que a restauração do macOS não a traga.
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Controles") {
                Button(app.isRecordingOrCounting ? "Parar gravação" : "Gravar") { app.toggleRecording() }
                    .keyboardShortcut("r")
                Button("Editar roteiro") { app.setEditing(!app.prompter.isEditing) }
                    .keyboardShortcut("e")
                Button("Alternar modo voz / tempo") { app.toggleFollowVoice() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Luz automática") { app.toggleAutoLight() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Picker("Teleprompter", selection: $app.placement) {
                    ForEach(PrompterPlacement.allCases) { Text($0.label).tag($0) }
                }
                Divider()
                Button("Voltar ao início") { app.prompter.rewind() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Texto maior") { app.prompter.adjustFont(4) }
                    .keyboardShortcut("=")
                Button("Texto menor") { app.prompter.adjustFont(-4) }
                    .keyboardShortcut("-")
                Divider()
                Button("Abrir pasta de gravações") { app.capture.revealFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }

        Window("Estilo do recorte", id: "styleColors") {
            StyleColorsView()
                .environmentObject(app.capture)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.trailing)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// O motor (câmera, captura, atalhos) inicia com o app, sem depender de a janela aparecer.
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if DemoRenderer.isRequested { DemoRenderer.run() } else { AppState.shared.bootstrap() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Garante que as preferências estejam no disco antes de sair.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.capture.flushPendingSaves() }
        UserDefaults.standard.synchronize()
    }

    /// Nunca perde uma gravação: se estiver gravando, finaliza o arquivo antes de sair.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let capture = AppState.shared.capture
        guard capture.isRecording else { return .terminateNow }
        capture.onFinishedRecording = { _ in NSApp.reply(toApplicationShouldTerminate: true) }
        capture.stopRecording()
        return .terminateLater
    }
}
