import SwiftUI

@main
struct CherriApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        // A unique Window (not WindowGroup): "Open Cherri" focuses the one
        // existing window instead of spawning another.
        Window("Cherri", id: "main") {
            ContentView()
                .environmentObject(state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        // Menu bar presence: filled icon while interpreting, outline when idle.
        MenuBarExtra {
            StatusBarMenu()
                .environmentObject(state)
        } label: {
            Image(systemName: state.isRunning ? "waveform.circle.fill" : "waveform.circle")
                .accessibilityLabel(state.isRunning ? "Cherri — interpreting" : "Cherri — idle")
        }
    }
}

private struct StatusBarMenu: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text(statusLine)

            Divider()

            Button(state.isRunning ? "Stop Interpreting" : "Start Interpreting") {
                state.toggle()
            }
            .disabled(state.isStarting)

            if state.isRunning {
                Button(state.micMuted ? "Unmute Mic" : "Mute Mic") {
                    state.micMuted.toggle()
                }
            }
            Button(state.translateMeeting ? "Stop Translating Meeting" : "Translate Meeting") {
                state.translateMeeting.toggle()
            }
            Button(state.translateMine ? "Stop Translating My Voice" : "Translate My Voice") {
                state.translateMine.toggle()
            }

            Divider()

            Button("Open Cherri") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Quit Cherri") {
                state.stop()
                NSApp.terminate(nil)
            }
        }
    }

    private var statusLine: String {
        if state.isStarting { return "Starting…" }
        if state.isRunning {
            let pair = "\(AppState.languageName(for: state.meetingLanguageCode)) ↔ \(AppState.languageName(for: state.userLanguageCode))"
            var line = "Interpreting · \(pair)"
            if state.micMuted { line += " · mic muted" }
            if !state.translateMeeting { line += " · meeting untranslated" }
            return line
        }
        return "Cherri — ready"
    }
}
