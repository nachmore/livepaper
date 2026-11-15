// SystemActions — AppKit side effects triggered by explicit user actions (panels, Finder, System
// Settings, locking, moving the app to the Trash). Kept out of AppModel so the model stays testable.
import AppKit
import LivePaperCore
import UniformTypeIdentifiers

@MainActor
enum SystemActions {
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Asks where to export a scene package.
    static func chooseExportDestination(for entry: LibraryEntry) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export \u{201C}\(entry.manifest.name)\u{201D}"
        panel.nameFieldStringValue = "\(entry.id).\(SceneManifest.packageExtension)"
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks for a .lpscene package to import (packages are directories).
    static func chooseScenePackage() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import Scene"
        panel.message = "Choose a LivePaper scene (.\(SceneManifest.packageExtension))."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks for a video file.
    static func chooseVideo() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Video"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Lock Now's fallback when no helper answers: start the screen saver. With "require password
    /// immediately" the saver locks, and loginwindow draws the lock UI over the running scene
    /// (ARCHITECTURE §1, §7). Only ever called for an explicit "Lock Now".
    static func startScreenSaverEngine() async throws {
        let engine = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: engine, configuration: config)
    }

    /// System Settings › Lock Screen (for "Require password after screen saver begins").
    static func openLockScreenSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// System Settings › General › Login Items (where macOS asks the user to allow the helper).
    static func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }

    /// Final uninstall step: move the app bundle to the Trash and quit.
    static func moveAppToTrashAndQuit(_ model: AppModel) {
        guard let path = model.environment.appBundlePath else {
            model.banners.post(.success, "LivePaper was uninstalled",
                               message: "This copy isn't running from an app bundle, so there's nothing to move to the Trash.")
            return
        }
        NSWorkspace.shared.recycle([URL(fileURLWithPath: path)]) { _, error in
            Task { @MainActor in
                if let error {
                    model.banners.error("Couldn't move LivePaper to the Trash", error)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

/// Shows the Dock icon only while the main window is open (the app otherwise lives in the menu
/// bar). Switching to `.accessory` while active hands focus back to the previous app, which is the
/// expected behaviour when the user closes the window.
///
/// SwiftUI may keep and reuse the NSWindow of a `Window` scene after it is closed, so the policy
/// keeps observing every main window it has seen: becoming key again (reopened from the menu bar,
/// the Dock or a relaunch) restores the Dock icon even if the view hierarchy wasn't rebuilt.
@MainActor
final class DockIconPolicy {
    static let shared = DockIconPolicy()
    /// Off in the snapshot harness, which must never become a regular (focus-taking) app.
    var isEnabled = true
    private var observed: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    private var open = Set<ObjectIdentifier>()

    func mainWindowAppeared(_ window: NSWindow) {
        guard isEnabled else { return }
        let key = ObjectIdentifier(window)
        if observed[key] == nil {
            let nc = NotificationCenter.default
            observed[key] = [
                nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated { if let window { self?.shown(window) } }
                },
                nc.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.closed(key) }
                },
            ]
        }
        shown(window)
    }

    private func shown(_ window: NSWindow) {
        open.insert(ObjectIdentifier(window))
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func closed(_ key: ObjectIdentifier) {
        open.remove(key)
        if open.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
