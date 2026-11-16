// LivePaper app entry point: a menu-bar extra, the main window and the Settings scene.
import AppKit
import LivePaperCore
import SwiftUI

@main
enum LivePaperMain {
    static func main() {
        #if DEBUG
        // Developer tool: `LivePaper --snapshot <dir>` renders key screens with mock data to PNGs
        // (see Snapshot/SnapshotHarness.swift) and exits without ever showing a window.
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
            MenuBarLabel(busy: !model.runningSessions.isEmpty)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// The status-item icon; it also hands SwiftUI's window opener to AppKit callbacks (reopen).
private struct MenuBarLabel: View {
    let busy: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: busy ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack")
            .accessibilityLabel(busy ? "LivePaper, AI jobs running" : "LivePaper")
            .onAppear { WindowRouter.shared.openMainWindow = { openWindow(id: WindowID.main) } }
    }
}

/// Lets AppKit code (the app delegate) open SwiftUI windows.
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()
    var openMainWindow: (() -> Void)?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// SIGTERM (`kill`, scripts/dev-install.sh, an uninstall script) quits like ⌘Q, so running AI
    /// sessions' agents are stopped first instead of being left running on their own (their output
    /// would reach no one).
    private var terminationSignal: DispatchSourceSignal?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu-bar app: no Dock icon until the main window appears (DockIconPolicy). Info.plist
        // sets LSUIElement too; this also covers `swift run`, where there is no Info.plist.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppBootstrap.model
        if !model.environment.isMock { EmbeddedRenderServer.start() }
        // The helper opens LivePaper with `--lock-refused <reason>` when it refused a lock while the
        // app wasn't running.
        let refusedAtLaunch = model.environment.isMock ? nil : LPLockRefusal.fromLaunchArguments(CommandLine.arguments)
        Task {
            await model.start()
            if let refusedAtLaunch { Self.present(refusedAtLaunch, model: model) }
        }
        if !model.environment.isMock { observeLockState(model) }
        observeActivation(model)
        observeScreens(model)
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
    }

    /// Connecting a display gives it a wallpaper-store record copied from SystemDefault; if that is
    /// macOS's default while LivePaper owns the selection, the model re-applies it (debounced, at
    /// most once per burst of changes; AppModel.screenParametersDidChange).
    private func observeScreens(_ model: AppModel) {
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                      queue: .main) { _ in
            MainActor.assumeIsolated { model.screenParametersDidChange() }
        }))
    }

    /// The disk watcher (AppModel.startWatchingDisk) reports changes other processes make; becoming
    /// active re-reads them anyway, as a cheap safety net.
    private func observeActivation(_ model: AppModel) {
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = Task { await model.refreshFromDisk() } }
        }))
    }

    /// The helper's refusals (shown at once: the user just asked to lock) and the moment the user
    /// leaves System Settings (where the password setting may have changed: Lock Now's state).
    private func observeLockState(_ model: AppModel) {
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(forName: .init(LPNotification.lockRefused), object: nil, queue: .main) { note in
            guard let refusal = LPLockRefusal.fromUserInfo(note.userInfo) else { return }
            MainActor.assumeIsolated { Self.present(refusal, model: model) }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didDeactivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == SystemActions.systemSettingsBundleID else { return }
                MainActor.assumeIsolated { _ = Task { await model.refreshInstallStatus() } }
            }))
        }
    }

    private static func present(_ refusal: LPLockRefusal, model: AppModel) {
        model.showLockRefusal(refusal)
        Task { await model.refreshInstallStatus() }
        WindowRouter.shared.openMainWindow?()
        NSApp.activate()
    }

    /// Launching LivePaper again (Finder, Spotlight, the helper relaying the saver's "Open
    /// LivePaper…") while it runs in the menu bar brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowRouter.shared.openMainWindow?() }
        return true
    }

    /// Double-clicking a .lpscene package or a .lpcollection file (declared in Info.plist) opens it: a
    /// scene or collection that is already in the library just opens; anything else is imported
    /// (AppModel.openScenePackage, AppModel.importCollection).
    func application(_ application: NSApplication, open urls: [URL]) {
        let model = AppBootstrap.model
        for url in urls {
            switch url.pathExtension.lowercased() {
            case SceneManifest.packageExtension: Task { await model.openScenePackage(at: url) }
            case CollectionArchive.fileExtension: Task { await model.importCollection(at: url) }
            default: continue
            }
        }
        WindowRouter.shared.openMainWindow?()
    }

    /// Closing the main window keeps LivePaper running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Agents run in their own process groups and don't die with LivePaper: quitting (the menu,
    /// ⌘Q, logout, the end of an uninstall) waits until they are gone — also those of sessions still
    /// being started, whose harnesses launch once their workspaces are built — for at most a few seconds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppBootstrap.model
        guard model.hasAgentsToStop else { return .terminateNow }
        Task { @MainActor in
            await model.stopAllAgents()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Fallback for a quit that skipped applicationShouldTerminate (normally a no-op by now).
        for session in AppBootstrap.model.runningSessions { session.cancel() }
        AppBootstrap.model.stopWatchingDisk()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }
}

/// Menu commands and keyboard shortcuts for the main window.
struct LivePaperCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    /// Published by the focused library card, the scene detail view or the Screen Saver screen.
    @FocusedValue(\.fullScreenPreview) private var fullScreenPreview

    /// The scene whose detail view is on screen (opened from the Library).
    private var currentScene: LibraryEntry? {
        guard model.section == .library else { return nil }
        return model.libraryPath.last.flatMap { model.entry(id: $0) }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Scene\u{2026}") { show(.create) }
                .keyboardShortcut("n")
            Button("New Collection\u{2026}") {
                openWindow(id: WindowID.main)
                model.collectionAction = .new(sceneIDs: [])
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Import Scene\u{2026}") {
                if let url = SystemActions.chooseScenePackage() { Task { await model.openScenePackage(at: url) } }
            }
            .keyboardShortcut("o")
            Button("Import Collection\u{2026}") {
                for url in SystemActions.chooseCollectionFiles() { Task { await model.importCollection(at: url) } }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("Library") { show(.library) }.keyboardShortcut("1")
            Button("Create") { show(.create) }.keyboardShortcut("2")
            Button("Screen Saver") { show(.playlist) }.keyboardShortcut("3")
            Divider()
            Button("Reload Library") { Task { await model.reloadLibrary() } }.keyboardShortcut("r")
        }
        CommandMenu("Scene") {
            Button("Preview Full Screen") { fullScreenPreview?.run() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(fullScreenPreview == nil)
            Divider()
            Button("Use as Screen Saver") { if let e = currentScene { Task { await model.useAsScreenSaver(e.id) } } }
                .disabled(currentScene == nil)
            Button("Add to Playlist") { if let e = currentScene { Task { await model.addToPlaylist(e.id) } } }
                .disabled(currentScene == nil)
            Divider()
            Button("Clone\u{2026}") { if let e = currentScene { model.sceneAction = .clone(e.id) } }
                .keyboardShortcut("d")
                .disabled(currentScene == nil)
            Button("Modify with AI\u{2026}") { if let e = currentScene { model.sceneAction = .modify(e.id) } }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(currentScene == nil || currentScene?.manifest.kind == .video)
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
        CommandGroup(after: .appSettings) {
            Button("Set Up LivePaper\u{2026}") {
                openWindow(id: WindowID.main)
                model.showOnboarding = true
            }
        }
    }

    private func show(_ section: AppModel.Section) {
        openWindow(id: WindowID.main)
        model.section = section
    }
}
