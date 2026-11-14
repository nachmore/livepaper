// ServiceFactory — decides between live and mock services and builds the AppModel once.
import AppKit
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
        let (services, environment, notice) = ServiceFactory.make(mock: AppMode.isMock)
        let model = AppModel(services: services, environment: environment)
        if let notice { model.banners.post(.warning, notice.title, message: notice.message) }
        return model
    }()
}

enum ServiceFactory {
    struct Notice { var title: String; var message: String }

    /// Builds services + environment. In mock mode every LivePaper path is redirected into a
    /// temporary root *before* anything reads LPPaths, so even code that bypasses the services
    /// (state.json, preview cache) stays out of the user's real files.
    @MainActor
    static func make(mock: Bool, pace: Double = 1) -> (LivePaperServices, AppEnvironment, Notice?) {
        if mock {
            let root = MockServices.temporaryRoot()
            redirectPaths(into: root)
            let defaults = UserDefaults(suiteName: "\(LPPaths.bundleID).mock") ?? .standard
            return (mockServices(root: root, pace: pace), environment(mock: true, defaults: defaults, cache: root.appendingPathComponent("Previews")), nil)
        }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("LivePaperPreviews")
        if let live = liveServices() {
            return (live, environment(mock: false, defaults: .standard, cache: cache), nil)
        }
        // Temporary: LivePaperServices.live() isn't in this tree yet. Fall back to sample data
        // (in a temporary directory) rather than half-working live services.
        let root = MockServices.temporaryRoot()
        redirectPaths(into: root)
        return (mockServices(root: root, pace: pace),
                environment(mock: true, defaults: UserDefaults(suiteName: "\(LPPaths.bundleID).mock") ?? .standard,
                            cache: root.appendingPathComponent("Previews")),
                Notice(title: "Showing sample scenes",
                       message: "This build doesn't include LivePaper's system services yet, so nothing on your Mac will change."))
    }

    private static func liveServices() -> LivePaperServices? {
        #if LIVEPAPER_HAS_LIVE_SERVICES
        return try? LivePaperServices.live()
        #else
        return nil
        #endif
    }

    static func redirectPaths(into root: URL) {
        let fm = FileManager.default
        let home = root.appendingPathComponent("Support"), savers = root.appendingPathComponent("Screen Savers")
        let store = root.appendingPathComponent("Wallpaper/Index.plist")
        for dir in [home, savers, store.deletingLastPathComponent()] { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        setenv("LIVEPAPER_HOME", home.path, 1)
        setenv("LIVEPAPER_SAVERS_DIR", savers.path, 1)
        setenv("LIVEPAPER_WALLPAPER_STORE", store.path, 1)
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

    private static func environment(mock: Bool, defaults: UserDefaults, cache: URL) -> AppEnvironment {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0-dev"
        let appPath = (!mock && bundle.bundleURL.pathExtension == "app") ? bundle.bundleURL.path : nil
        let stateURL = LPPaths.stateFile
        return AppEnvironment(isMock: mock, defaults: defaults, stateURL: stateURL,
                              saveState: { try $0.save(to: stateURL) }, previewCacheDirectory: cache,
                              appVersion: version, appBundlePath: appPath)
    }
}

/// Starts the in-process RenderService so thumbnails, AI validation stills and checks never need a
/// separate GUI-registered process while the app runs (ARCHITECTURE §2, focus-stealing rule).
enum EmbeddedRenderServer {
    static func start() {
        #if LIVEPAPER_HAS_RENDERSERVER
        _ = try? LivePaperRenderKit.RenderServer.startEmbeddedServer()
        #else
        // Temporary: LivePaperRenderKit.RenderServer isn't in this tree yet; RenderClient falls back
        // to launching LivePaperRenderd on demand.
        NSLog("LivePaper: embedded render server unavailable in this build (RenderKit \(LivePaperRenderKit.version))")
        #endif
    }
}
