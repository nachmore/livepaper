// LivePaper app entry point: a menu-bar extra, the main window and the Settings scene.
import AppKit
import LivePaperCore
import SwiftUI

@main
enum LivePaperMain {
    static func main() {
        #if DEBUG
        // Developer tool: `LivePaper --snapshot <dir>` renders key screens with mock data to PNGs
        // (see Snapshot/SnapshotHarness.swift) and exits without showing any window.
        if let dir = SnapshotHarness.requestedOutputDirectory() {
            MainActor.assumeIsolated { SnapshotHarness.run(into: dir) }
            return
        }
        #endif
        LivePaperApp.main()
    }
}

enum WindowID {
    static let main = "main"
}

struct LivePaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppBootstrap.model

    var body: some Scene {
        Window("LivePaper", id: WindowID.main) {
            MainWindowView()
                .environment(model)
        }
        .defaultSize(width: 1120, height: 740)
        .windowToolbarStyle(.unified)
        .commands { LivePaperCommands(model: model) }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            Label("LivePaper", systemImage: model.runningSessions.isEmpty ? "sparkles.rectangle.stack" : "sparkles.rectangle.stack.fill")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu-bar app: no Dock icon until the main window appears (DockIconPolicy). Info.plist
        // sets LSUIElement too; this also covers `swift run`, where there is no Info.plist.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppBootstrap.model
        if !model.environment.isMock { EmbeddedRenderServer.start() }
        Task { await model.start() }
    }

    /// Closing the main window keeps LivePaper running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        let model = AppBootstrap.model
        for session in model.runningSessions { session.cancel() }
    }
}

/// Menu commands and keyboard shortcuts for the main window.
struct LivePaperCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var currentScene: LibraryEntry? {
        guard model.section == .library, let id = model.libraryPath.last else { return nil }
        return model.entry(id: id)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Scene\u{2026}") { show(.create) }
                .keyboardShortcut("n")
            Button("Import Scene\u{2026}") {
                if let url = SystemActions.chooseScenePackage() { Task { await model.importPackage(at: url) } }
            }
            .keyboardShortcut("o")
        }
        CommandGroup(after: .sidebar) {
            Button("Library") { show(.library) }.keyboardShortcut("1")
            Button("Create") { show(.create) }.keyboardShortcut("2")
            Button("Playlist") { show(.playlist) }.keyboardShortcut("3")
            Divider()
            Button("Reload Library") { Task { await model.reloadLibrary() } }.keyboardShortcut("r")
        }
        CommandMenu("Scene") {
            Button("Use as Screen Saver") { if let e = currentScene { Task { await model.useAsScreenSaver(e.id) } } }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(currentScene == nil)
            Button("Add to Playlist") { if let e = currentScene { Task { await model.addToPlaylist(e.id) } } }
                .disabled(currentScene == nil)
            Divider()
            Button("Clone\u{2026}") { if let e = currentScene { model.sceneAction = .clone(e.id) } }
                .keyboardShortcut("d")
                .disabled(currentScene == nil)
            Button("Modify with AI\u{2026}") { if let e = currentScene { model.sceneAction = .modify(e.id) } }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(currentScene == nil)
            Button("Export\u{2026}") {
                if let e = currentScene, let url = SystemActions.chooseExportDestination(for: e) { Task { await model.export(e.id, to: url) } }
            }
            .keyboardShortcut("e")
            .disabled(currentScene == nil)
            Button("Reveal in Finder") { if let e = currentScene { SystemActions.revealInFinder(e.item.packageURL) } }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(currentScene == nil)
            Divider()
            Button("Delete\u{2026}") { if let e = currentScene { model.sceneAction = .delete(e.id) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(currentScene?.item.isBuiltin ?? true)
        }
    }

    private func show(_ section: AppModel.Section) {
        openWindow(id: WindowID.main)
        model.section = section
    }
}
