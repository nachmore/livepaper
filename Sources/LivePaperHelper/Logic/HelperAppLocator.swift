// HelperAppLocator — finds the LivePaper app the helper should open for LPNotification.openApp.
//
// The helper ships inside the app (LivePaper.app/Contents/Helpers/LivePaperHelper), so the app that
// launched it is two directories up from the executable. That copy wins over whatever Launch
// Services prefers, so a helper from one copy of LivePaper (say ~/Applications) never opens another
// (a stale build elsewhere). Unbundled runs (`swift run`) fall back to a lookup by bundle identifier.
//
// Pure logic with the file system and Launch Services injected; also compiled into LivePaperSelfTest.
import Foundation
import LivePaperCore

/// Where the LivePaper app is, and how it was found.
struct HelperAppLocation: Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        /// The app bundle that contains this helper.
        case enclosingBundle
        /// Launch Services' copy for the bundle identifier.
        case bundleIdentifier
        case notFound
    }
    var url: URL?
    var source: Source
}

struct HelperAppLocator {
    /// Reads CFBundleIdentifier of the bundle at a URL (nil = not a bundle / no identifier).
    var bundleIdentifier: (URL) -> String?
    /// Launch Services lookup by bundle identifier.
    var lookup: (String) -> URL?
    var expectedBundleID: String = LPPaths.bundleID

    /// Production file-system access; `lookup` is supplied by the caller (Launch Services).
    static func live(lookup: @escaping (String) -> URL?) -> HelperAppLocator {
        HelperAppLocator(bundleIdentifier: infoPlistBundleIdentifier, lookup: lookup)
    }

    /// Resolves the app for a helper executable (symlinks are resolved first).
    func locate(executable: URL) -> HelperAppLocation {
        if let app = Self.enclosingApp(ofExecutable: executable.resolvingSymlinksInPath()),
           bundleIdentifier(app) == expectedBundleID {
            return HelperAppLocation(url: app, source: .enclosingBundle)
        }
        if let app = lookup(expectedBundleID) { return HelperAppLocation(url: app, source: .bundleIdentifier) }
        return HelperAppLocation(url: nil, source: .notFound)
    }

    /// `…/X.app/Contents/Helpers/<exe>` (or `Contents/MacOS/<exe>`) → `…/X.app`; nil for any other layout.
    static func enclosingApp(ofExecutable executable: URL) -> URL? {
        let folder = executable.deletingLastPathComponent()
        guard ["Helpers", "MacOS"].contains(folder.lastPathComponent) else { return nil }
        let contents = folder.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents" else { return nil }
        let app = contents.deletingLastPathComponent()
        guard app.pathExtension.lowercased() == "app" else { return nil }
        return app
    }

    /// CFBundleIdentifier of a bundle.
    static func infoPlistBundleIdentifier(_ bundle: URL) -> String? { infoPlist(bundle)?["CFBundleIdentifier"] as? String }

    /// CFBundleShortVersionString of a bundle (nil for unbundled builds).
    static func infoPlistVersion(_ bundle: URL) -> String? { infoPlist(bundle)?["CFBundleShortVersionString"] as? String }

    /// `<bundle>/Contents/Info.plist`, read directly: Foundation's Bundle caches instances per path,
    /// which would hide a bundle replaced in place by an update.
    static func infoPlist(_ bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
