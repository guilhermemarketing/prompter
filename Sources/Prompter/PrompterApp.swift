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
            CommandMenu(L("Controles", "Controls")) {
                Button(app.isRecordingOrCounting ? L("Parar gravação", "Stop recording") : L("Gravar", "Record")) { app.toggleRecording() }
                    .keyboardShortcut("r")
                Button(L("Editar roteiro", "Edit script")) { app.setEditing(!app.prompter.isEditing) }
                    .keyboardShortcut("e")
                Button(L("Alternar modo voz / tempo", "Toggle voice / timed mode")) { app.toggleFollowVoice() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button(L("Luz automática", "Auto light")) { app.toggleAutoLight() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Picker("Teleprompter", selection: $app.placement) {
                    ForEach(PrompterPlacement.allCases) { Text($0.label).tag($0) }
                }
                Divider()
                Button(L("Voltar ao início", "Back to start")) { app.prompter.rewind() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button(L("Texto maior", "Larger text")) { app.prompter.adjustFont(4) }
                    .keyboardShortcut("=")
                Button(L("Texto menor", "Smaller text")) { app.prompter.adjustFont(-4) }
                    .keyboardShortcut("-")
                Divider()
                Button(L("Abrir pasta de gravações", "Open recordings folder")) { app.capture.revealFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }

        Window(L("Estilo do recorte", "Cutout style"), id: "styleColors") {
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
