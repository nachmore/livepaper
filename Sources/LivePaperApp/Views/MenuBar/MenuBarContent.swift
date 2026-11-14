// MenuBarContent — the menu-bar extra: lock now, what the screen saver plays, next scene, AI jobs,
// and the way back into the app.
import AppKit
import LivePaperCore
import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(lockTitle) { SystemActions.lockNow(model) }
        Divider()
        Text("Screen saver: \(model.playlistSummary)")
        Button("Next Scene") { Task { await model.advanceScene() } }
            .disabled(!model.canAdvanceScene || model.isPublishing)
        Divider()
        aiSection
        Divider()
        Button("Open LivePaper") { openMain() }
            .keyboardShortcut("o")
        SettingsLink { Text("Settings\u{2026}") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit LivePaper") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// "Lock Now (⌃⌘L)" — the helper's shortcut is shown so people learn it.
    private var lockTitle: String {
        guard let hotkey = model.sharedState.lock.hotkey else { return "Lock Now" }
        return "Lock Now (\(HotkeyRecorder.display(hotkey)))"
    }

    @ViewBuilder
    private var aiSection: some View {
        let running = model.runningSessions
        let waiting = model.sessions.filter { $0.state.package != nil && $0.resolution == nil }
        if running.isEmpty && waiting.isEmpty {
            Text("No AI jobs running")
        } else {
            if !running.isEmpty {
                Text(running.count == 1 ? "1 AI job running" : "\(running.count) AI jobs running")
            }
            ForEach(running + waiting) { session in
                Button("\(session.title) \u{2014} \(session.state.lastStatus)") {
                    model.section = .session(session.id)
                    openMain()
                }
            }
            if !running.isEmpty {
                Button("Stop All AI Jobs") { running.forEach { $0.cancel() } }
            }
        }
    }

    private func openMain() {
        openWindow(id: WindowID.main)
        NSApp.activate()
    }
}
