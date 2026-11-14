// WallpaperStore — the macOS 26 screen-saver selection, which lives in the "Idle" choices of
// ~/Library/Application Support/com.apple.wallpaper/Store/Index.plist (ARCHITECTURE §1).
//
// All reading and writing of that file goes through this type so the rest of LivePaper doesn't
// depend on its (undocumented) schema. Detection is implemented; writing a selection is pending
// the wallpaper-store research and deliberately does nothing yet (see `select(backupTo:)`).
import Foundation

public struct WallpaperStore: Sendable {
    /// The store plist (LPPaths.wallpaperStore; redirected in tests via LIVEPAPER_WALLPAPER_STORE).
    public let url: URL
    /// Strings that identify the LivePaper saver inside an Idle choice: its bundle id and bundle
    /// name (the configuration embeds the module's file URL, which contains the name).
    public let needles: [String]

    public init(url: URL = LPPaths.wallpaperStore,
                needles: [String] = [LPPaths.saverBundleID, LPPaths.saverName]) {
        self.url = url
        self.needles = needles.filter { !$0.isEmpty }
    }

    /// True when any display's (or the default) screen-saver choice is the LivePaper saver.
    ///
    /// The Idle choices carry their configuration as nested data blobs (often binary plists that in
    /// turn contain the module path), so the scan descends into every dictionary, array, string and
    /// decodable plist blob below an "Idle" key, and also matches raw bytes of undecodable blobs.
    public func isSelected() -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return false }
        return containsSaver(root, inIdle: false, depth: 0)
    }

    /// Makes LivePaper the selected screen saver for every display.
    ///
    /// - Returns: false — automatic selection isn't implemented yet; the app then shows the one-click
    ///   guided step (InstallService.openScreenSaverSettings()).
    ///
    /// TODO(wallpaper-store research): once the Idle choice schema and the way to make WallpaperAgent
    /// pick up a change are known, implement as: (1) if `backup` doesn't exist yet, copy the current
    /// store there (so uninstall restores the choice from *before* LivePaper, however often this is
    /// called); (2) write the LivePaper Idle choice for all displays; (3) notify WallpaperAgent;
    /// (4) return `isSelected()`.
    public func select(backupTo backup: URL) throws -> Bool {
        false
    }

    /// Puts back the store saved by `select(backupTo:)`. A missing backup means LivePaper never
    /// changed the selection, so there is nothing to do (idempotent).
    ///
    /// TODO(wallpaper-store research): WallpaperAgent keeps the store in memory and may rewrite the
    /// file; restore only the Idle choices and notify the agent once that mechanism is known. Until
    /// then no backup is ever written, so this only runs against redirected stores in tests.
    public func restore(from backup: URL) throws {
        guard FileManager.default.fileExists(atPath: backup.path) else { return }
        let data = try Data(contentsOf: backup)
        // Never replace the live store with something that isn't a property list.
        _ = try PropertyListSerialization.propertyList(from: data, format: nil)
        try FileOps.writeAtomically(data, to: url)
    }

    // MARK: - Scanning

    /// Nested blobs are rarely more than a few levels deep; the cap guards against hostile input.
    private static let maxDepth = 32

    private func containsSaver(_ value: Any, inIdle: Bool, depth: Int) -> Bool {
        guard depth < Self.maxDepth else { return false }
        switch value {
        case let dict as [String: Any]:
            return dict.contains { key, child in containsSaver(child, inIdle: inIdle || key == "Idle", depth: depth + 1) }
        case let array as [Any]:
            return array.contains { containsSaver($0, inIdle: inIdle, depth: depth + 1) }
        case let string as String:
            return inIdle && matches(string)
        case let data as Data:
            guard inIdle else { return false }
            if let inner = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                return containsSaver(inner, inIdle: true, depth: depth + 1)
            }
            return needles.contains { data.range(of: Data($0.utf8)) != nil }
        default:
            return false
        }
    }

    private func matches(_ string: String) -> Bool {
        let decoded = string.removingPercentEncoding ?? string
        return needles.contains { string.contains($0) || decoded.contains($0) }
    }
}
