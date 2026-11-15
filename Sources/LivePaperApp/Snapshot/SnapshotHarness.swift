// SnapshotHarness — renders key screens with mock data to PNGs for design review (debug builds).
//
//   swift build --product LivePaperApp && .build/debug/LivePaperApp --snapshot /tmp/lp-shots [--only library,create]
//
// Focus-safety: the process uses the `.prohibited` activation policy (no Dock icon, can never become
// the active app or take key focus), the Dock-icon policy is disabled, live previews (WebKit/AV) are
// off, and every window is borderless and parked far off-screen. Services are the mocks, rooted in a
// temporary directory, so nothing on the system changes. One run renders every screen and exits.
#if DEBUG
import AppKit
import LivePaperCore
import SwiftUI

@MainActor
enum SnapshotHarness {
    static func requestedOutputDirectory() -> URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    private static var onlyNames: Set<String>? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--only"), i + 1 < args.count else { return nil }
        return Set(args[i + 1].split(separator: ",").map(String.init))
    }

    static func run(into dir: URL) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        DockIconPolicy.shared.isEnabled = false
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let root = fm.temporaryDirectory.appendingPathComponent("livepaper-snapshot-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: root) }
        ServiceFactory.redirectPaths(into: root)
        guard let services = try? MockServices.make(root: root, pace: 0) else {
            print("snapshot: couldn't create mock services"); return
        }
        let prefs = InMemoryPreferences([AppEnvironment.onboardingCompletedKey: true])
        let env = ServiceFactory.environment(mock: true, defaults: prefs, cache: root.appendingPathComponent("Previews"))
        let model = AppModel(services: services, environment: env)
        wait { await model.start() }

        // One finished session (succeeded) and one frozen mid-run.
        let harness = model.harnesses.first ?? AIHarness(kind: .claude, name: "Claude Code", executable: "claude", version: "2.1.4")
        let done = model.startSession(.create(prompt: "Paper lanterns drifting upward through a warm summer night"),
                                      harness: harness, model: nil)
        waitUntil { done?.isRunning == false }
        (services.ai as? MockAIService)?.holdAfterSteps = 13
        let running = model.startSession(.create(prompt: "A calm aurora over a mirror-still lake, slowly shifting greens and violets"),
                                         harness: harness, model: "opus")
        waitUntil { (running?.state.stills.count ?? 0) >= 1 }

        let main = CGSize(width: 1180, height: 760)
        func shoot<V: View>(_ name: String, _ size: CGSize, dark: Bool, _ view: V) {
            if let only = onlyNames, !only.contains(name) { return }
            render(name, size: size, dark: dark, view: view, model: model, into: dir)
        }

        // Onboarding first: it starts from the initial (nothing installed) state.
        let sheet = CGSize(width: 800, height: 580)
        shoot("onboarding-welcome-light", sheet, dark: false, OnboardingView(initialStep: .welcome))
        try? services.install.installSaver()
        wait { await model.refreshInstallStatus() }
        shoot("onboarding-saver-dark", sheet, dark: true, OnboardingView(initialStep: .screenSaver, showGuidedSelection: true))
        shoot("onboarding-lock-light", sheet, dark: false, OnboardingView(initialStep: .lock))
        shoot("onboarding-lock-dark", sheet, dark: true, OnboardingView(initialStep: .lock))
        shoot("onboarding-scene-light", sheet, dark: false, OnboardingView(initialStep: .firstScene))

        // Library: banners, both appearances, a narrow window and an empty search.
        model.section = .library
        model.banners.post(.success, "Screen saver updated", message: "9 scenes published.")
        shoot("library-light", main, dark: false, MainWindowView())
        shoot("library-dark", main, dark: true, MainWindowView())
        clearBanners(model)
        model.banners.error("Couldn't update the screen saver", SnapshotError(), retry: {})
        shoot("library-narrow-light", CGSize(width: 900, height: 700), dark: false, MainWindowView())
        clearBanners(model)
        model.query.text = "volcano"
        shoot("library-noresults-dark", CGSize(width: 900, height: 500), dark: true, MainWindowView())
        model.query.text = ""
        model.libraryPath = ["paper-lanterns"]
        shoot("detail-dark", main, dark: true, MainWindowView())
        model.libraryPath = []

        // The full-screen preview's overlay (hint bar, message) over a scene's thumbnail; the live
        // scene itself isn't rendered here.
        func fullScreen(_ name: String, _ size: CGSize, scene: String?, position: String?, canStep: Bool, clockOn: Bool = true,
                        lock: Bool = false, message: String? = nil) {
            let state = FullScreenPreviewState()
            state.sceneName = scene.flatMap { model.entry(id: $0)?.manifest.name } ?? "Neon Rain"
            state.position = position
            state.hintItems = FullScreenHint.items(canStep: canStep, clockOn: clockOn, lockPreview: lock)
            state.hintVisible = true
            state.message = message
            shoot(name, size, dark: true, FullScreenSnapshot(entry: scene.flatMap { model.entry(id: $0) }, state: state))
        }
        fullScreen("fullscreen-hint", CGSize(width: 1512, height: 982), scene: "aurora-lake", position: "2 of 9", canStep: true)
        fullScreen("fullscreen-lock-wide", CGSize(width: 2560, height: 720), scene: "paper-lanterns", position: nil, canStep: false,
                   clockOn: false, lock: true)
        fullScreen("fullscreen-error", CGSize(width: 1280, height: 800), scene: nil, position: "3 of 3", canStep: true,
                   message: "\u{201C}Neon Rain\u{201D} can\u{2019}t be shown: scene.js has a syntax error on line 42 (Unexpected token \u{2018})\u{2019}).")

        model.section = .create
        shoot("create-light", main, dark: false, MainWindowView())
        shoot("create-narrow-dark", CGSize(width: 880, height: 760), dark: true, MainWindowView())
        if let running { model.section = .session(running.id) }
        shoot("session-running-dark", main, dark: true, MainWindowView())
        if let done { model.section = .session(done.id) }
        shoot("session-done-light", main, dark: false, MainWindowView())

        // An explicit playlist: per-card markers and the ordered list with remove buttons; one scene
        // is left out of the publish (PublishResult.skipped).
        (services.publish as? MockPublishService)?.simulatedSkips =
            ["neon-rain": "neon-rain: scene.js has a syntax error on line 42 (Unexpected token ')')."]
        wait {
            await model.useAsScreenSaver("paper-lanterns")
            await model.addToPlaylist("neon-rain")
            await model.addToPlaylist("aurora-lake")
        }
        clearBanners(model)
        model.section = .playlist
        shoot("playlist-dark", main, dark: true, MainWindowView())
        model.section = .library
        shoot("library-explicit-dark", main, dark: true, MainWindowView())

        let shortSheet = CGSize(width: 480, height: 170)
        shoot("sheet-clone-light", shortSheet, dark: false, SceneActionSheet(action: .clone("aurora-lake")))
        shoot("sheet-modify-dark", CGSize(width: 480, height: 330), dark: true, SceneActionSheet(action: .modify("aurora-lake")))
        shoot("sheet-delete-light", shortSheet, dark: false, SceneActionSheet(action: .delete("neon-rain")))
        shoot("settings-saver-light", CGSize(width: 640, height: 520), dark: false, SettingsView(initialTab: .screenSaver))
        shoot("settings-lock-light", CGSize(width: 640, height: 600), dark: false, SettingsView(initialTab: .lock))
        (services.install as? MockInstallService)?.simulateHelperApprovalPending()
        wait {
            await model.setLockKeysShowScene(true)
            await model.refreshInstallStatus()
        }
        shoot("settings-lock-approval-dark", CGSize(width: 640, height: 600), dark: true, SettingsView(initialTab: .lock))
        shoot("onboarding-lock-approval-light", sheet, dark: false, OnboardingView(initialStep: .lock))
        shoot("settings-performance-light", CGSize(width: 640, height: 520), dark: false, SettingsView(initialTab: .performance))
        model.aiSettings.setModel("opus", for: .claude)
        model.aiSettings.customTemplate = "mytool --task {prompt_file} --cwd {workspace} --model {nope}"
        shoot("settings-ai-dark", CGSize(width: 640, height: 720), dark: true, SettingsView(initialTab: .ai))
        shoot("settings-about-dark", CGSize(width: 640, height: 440), dark: true, SettingsView(initialTab: .about))
        shoot("uninstall-dark", CGSize(width: 520, height: 470), dark: true, UninstallSheet())
        let home = NSHomeDirectory()
        let log: [InstallStep] = [
            InstallStep(title: "Unregister the helper login item", outcome: .done),
            InstallStep(title: "Restore the previous screen saver choice", outcome: .done),
            InstallStep(title: InstallService.restoreLockKeysTitle, outcome: .done),
            InstallStep(title: "Restore changed system settings", outcome: .skipped("nothing changed")),
            InstallStep(title: "Remove \(home)/Library/Screen Savers/LivePaper.saver", outcome: .done),
            InstallStep(title: "Delete LivePaper's caches, workspaces and backups (keeping the scene library)", outcome: .done),
        ]
        shoot("uninstall-done-light", CGSize(width: 520, height: 470), dark: false, UninstallSheet(report: .make(log)))
        var failed = log
        failed[4].outcome = .failed("\u{201C}LivePaper.saver\u{201D} couldn\u{2019}t be moved because you don\u{2019}t have permission to access \u{201C}Screen Savers\u{201D}.")
        shoot("uninstall-failed-dark", CGSize(width: 520, height: 520), dark: true, UninstallSheet(report: .make(failed)))

        running?.cancel()
        print("snapshot: wrote PNGs to \(dir.path)")
    }

    /// A scene's thumbnail standing in for the live scene, with the full-screen overlay on top.
    private struct FullScreenSnapshot: View {
        let entry: LibraryEntry?
        let state: FullScreenPreviewState

        // The overlay sets the size; the fill-scaled thumbnail behind it must not (at 32:9 it is taller).
        var body: some View {
            FullScreenPreviewOverlay(state: state)
                .background {
                    Color.black.overlay {
                        if let entry {
                            ThumbnailImage(url: entry.thumbnail, maxPixel: 2560, placeholderSymbol: entry.badge.symbolName)
                        }
                    }
                    .clipped()
                }
        }
    }

    private static func clearBanners(_ model: AppModel) {
        model.banners.banners.forEach { model.banners.dismiss($0.id) }
    }

    private struct SnapshotError: LocalizedError {
        var errorDescription: String? { "The screen saver bundle is busy. Try again in a moment." }
    }

    // MARK: rendering

    private static func render<V: View>(_ name: String, size: CGSize, dark: Bool, view: V, model: AppModel, into dir: URL) {
        // cacheDisplay doesn't capture the window's own background, so paint it into the view.
        let root = view
            .environment(model)
            .environment(\.livePreviewsEnabled, false)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.97, alpha: 1)
        window.contentView = hosting
        // Far off-screen and never key: SwiftUI only runs appearance callbacks (.task, .onAppear)
        // for views in an ordered window. A .prohibited app can't activate, so this takes no focus.
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        pump(1.5)
        hosting.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil); window.contentView = nil }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let url = dir.appendingPathComponent("\(name).png")
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            print("snapshot: \(name)")
        }
    }

    // MARK: run-loop helpers (MainActor work is drained by the main run loop)

    @MainActor private final class Flag { var value = false }

    private static func wait(timeout: TimeInterval = 15, _ work: @escaping @MainActor () async -> Void) {
        let flag = Flag()
        Task { @MainActor in
            await work()
            flag.value = true
        }
        waitUntil(timeout: timeout) { flag.value }
    }

    private static func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: min(end, Date().addingTimeInterval(0.05))) }
    }
}
#endif
