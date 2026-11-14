// SnapshotHarness — renders key screens with mock data to PNGs for design review (debug builds).
//
//   swift build --target LivePaperApp && .build/debug/LivePaper --snapshot /tmp/lp-shots [--only library,create]
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

        // Onboarding first: it shows the initial (nothing installed) state.
        shoot("onboarding-welcome", CGSize(width: 800, height: 580), dark: false, OnboardingView(initialStep: .welcome))
        wait { await model.installSaverOnly() }
        shoot("onboarding-saver", CGSize(width: 800, height: 580), dark: true,
              OnboardingView(initialStep: .screenSaver, showGuidedSelection: true))
        shoot("onboarding-lock", CGSize(width: 800, height: 580), dark: false, OnboardingView(initialStep: .lock))
        shoot("onboarding-scene", CGSize(width: 800, height: 580), dark: true, OnboardingView(initialStep: .firstScene))

        model.section = .library
        model.banners.post(.success, "Screen saver updated", message: "9 scenes published.")
        shoot("library-light", main, dark: false, MainWindowView())
        shoot("library-dark", main, dark: true, MainWindowView())
        model.banners.dismissAll()
        model.libraryPath = ["paper-lanterns"]
        shoot("detail-dark", main, dark: true, MainWindowView())
        model.libraryPath = []
        model.section = .create
        shoot("create-light", main, dark: false, MainWindowView())
        shoot("create-dark", main, dark: true, MainWindowView())
        if let running { model.section = .session(running.id) }
        shoot("session-running-dark", main, dark: true, MainWindowView())
        if let done { model.section = .session(done.id) }
        shoot("session-done-light", main, dark: false, MainWindowView())
        model.section = .playlist
        shoot("playlist-light", main, dark: false, MainWindowView())
        shoot("settings-lock", CGSize(width: 640, height: 600), dark: false, SettingsView(initialTab: .lock))
        shoot("settings-ai", CGSize(width: 640, height: 560), dark: true, SettingsView(initialTab: .ai))
        shoot("uninstall", CGSize(width: 520, height: 470), dark: false, UninstallSheet())

        running?.cancel()
        print("snapshot: wrote PNGs to \(dir.path)")
    }

    // MARK: rendering

    private static func render<V: View>(_ name: String, size: CGSize, dark: Bool, view: V, model: AppModel, into dir: URL) {
        let root = view
            .environment(model)
            .environment(\.livePreviewsEnabled, false)
            .frame(width: size.width, height: size.height)
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
