// ServiceFactory — decides between live and mock services and builds the AppModel once.
import Foundation
import LivePaperCore
import LivePaperRenderKit

enum AppMode {
    /// LIVEPAPER_MOCK=1: sample data under a temporary directory; nothing on the system changes.
    static var isMock: Bool { ProcessInfo.processInfo.environment["LIVEPAPER_MOCK"] == "1" }
}

@MainActor
enum AppBootstrap {
    /// The one model for the whole process (SwiftUI may create the App struct more than once).
    static let model: AppModel = {
        let (services, environment) = ServiceFactory.make(mock: AppMode.isMock)
        return AppModel(services: services, environment: environment)
    }()
}

enum ServiceFactory {
    /// Builds services + environment. In mock mode every LivePaper path is redirected into a
    /// temporary root *before* anything reads LPPaths, so even code that bypasses the services
    /// (state.json, preview cache) stays out of the user's real files.
    @MainActor
    static func make(mock: Bool, pace: Double = 1) -> (LivePaperServices, AppEnvironment) {
        if !mock {
            // Constructing the live services is cheap and writes nothing (LivePaperServices.live()).
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent("LivePaperPreviews")
            return (LivePaperServices.live(), environment(mock: false, defaults: UserDefaults.standard, cache: cache))
        }
        let root = MockServices.temporaryRoot()
        redirectPaths(into: root)
        let env = environment(mock: true, defaults: InMemoryPreferences(), cache: root.appendingPathComponent("Previews"))
        return (mockServices(root: root, pace: pace), env)
    }

    /// Points LPPaths (via its environment overrides) at a scratch root.
    static func redirectPaths(into root: URL) {
        let fm = FileManager.default
        let home = root.appendingPathComponent("Support"), savers = root.appendingPathComponent("Screen Savers")
        let store = root.appendingPathComponent("Wallpaper/Index.plist")
        let agents = root.appendingPathComponent("LaunchAgents")
        for dir in [home, savers, store.deletingLastPathComponent(), agents] { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        setenv("LIVEPAPER_HOME", home.path, 1)
        setenv("LIVEPAPER_SAVERS_DIR", savers.path, 1)
        setenv("LIVEPAPER_WALLPAPER_STORE", store.path, 1)
        setenv("LIVEPAPER_LAUNCH_AGENTS_DIR", agents.path, 1)
    }

    @MainActor
    static func mockServices(root: URL, pace: Double) -> LivePaperServices {
        do {
            return try MockServices.make(root: root, pace: pace)
        } catch {
            // The temporary directory is unusable; there is nothing sensible to show.
            fatalError("LivePaper couldn't create its sample library in \(root.path): \(error.localizedDescription)")
        }
    }

    @MainActor
    static func environment(mock: Bool, defaults: PreferenceStore, cache: URL) -> AppEnvironment {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0-dev"
        let appPath = (!mock && bundle.bundleURL.pathExtension == "app") ? bundle.bundleURL.path : nil
        // LPPaths already points at the scratch root in mock mode (redirectPaths runs first).
        let stateURL = LPPaths.stateFile
        // Mock mode never broadcasts a lock request or starts the screen saver (AppModel.lockNow
        // shows a notice instead); these are only placeholders.
        let helperLock: HelperLockChannel = mock ? FixedHelperLockChannel(answers: false) : DistributedHelperLockChannel()
        let startScreenSaver: @MainActor () async throws -> Void = mock ? {} : { try await SystemActions.startScreenSaverEngine() }
        return AppEnvironment(isMock: mock, defaults: defaults, stateURL: stateURL, saveState: { try $0.save(to: stateURL) },
                              helperLock: helperLock, startScreenSaver: startScreenSaver, previewCacheDirectory: cache,
                              appVersion: version, appBundlePath: appPath,
                              openLockScreenSettings: mock ? {} : { SystemActions.openLockScreenSettings() })
    }
}

/// Starts the in-process RenderService so thumbnails, AI validation stills and checks never need a
/// separate GUI-registered process while the app runs (ARCHITECTURE §2, focus-stealing rule).
@MainActor
enum EmbeddedRenderServer {
    /// Whatever the server hands back is retained for the life of the process.
    private static var server: Any?

    static func start() {
        guard server == nil else { return }
        do {
            server = try LivePaperRenderKit.RenderServer.startEmbeddedServer()
        } catch {
            // Not fatal: RenderClient falls back to the headless LivePaperRenderd.
            NSLog("LivePaper: couldn't start the embedded render server: \(error.localizedDescription)")
        }
    }
}
