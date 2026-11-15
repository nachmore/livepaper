// WallpaperStore — the macOS 26 screen-saver selection, which lives in the "Idle" slots of
// ~/Library/Application Support/com.apple.wallpaper/Store/Index.plist (ARCHITECTURE §1,
// docs/RESEARCH.md §5).
//
// All reading and writing of that file goes through this type and the files in WallpaperStore/, so
// the rest of LivePaper doesn't depend on its (undocumented) schema:
//   PlistValue                  exact, lossless copy of a property list
//   WallpaperStoreSchema        Codable mirror of WallpaperAgent's model (the decode check)
//   WallpaperStoreDocument      records, Idle slots, edits that keep everything else intact
//   WallpaperChoice             the payload that selects a .saver; recognising LivePaper's choice
//   WallpaperStorePlanning      detection, select/restore plans, invariants, the backup manifest
//   WallpaperStoreApplier       the live sequence (quiet wait, atomic replace, agent restart, confirm)
//   WallpaperSystem             the system facts and the agent restart, behind a protocol
//
// Reading is always safe (no permission prompt; WallpaperAgent is never involved). Writing happens
// only through WallpaperStoreApplier, only on an explicit user action.
import Foundation

public struct WallpaperStore: Sendable {
    /// The store plist (LPPaths.wallpaperStore; redirected in tests via LIVEPAPER_WALLPAPER_STORE).
    public let url: URL
    /// LivePaper's saver bundle as the store refers to it.
    public let module: WallpaperSaverModule

    /// - Parameter saver: the installed LivePaper.saver (what a selection points at).
    public init(url: URL = LPPaths.wallpaperStore, saver: URL = LPPaths.installedSaver) {
        self.url = url
        self.module = WallpaperSaverModule(url: saver)
    }

    /// Reads and validates the store (it must decode with WallpaperAgent's model).
    public func read() throws -> WallpaperStoreDocument {
        guard let data = FileManager.default.contents(atPath: url.path) else { throw WallpaperStoreError.storeMissing(url.path) }
        return try WallpaperStoreDocument(data: data)
    }

    /// Which Idle slots choose LivePaper; nil when the store is missing or not in the known format.
    public func selection() -> WallpaperSelection? {
        (try? read())?.selection(of: module)
    }

    /// True when any display's (or the default) screen-saver choice is the LivePaper saver.
    ///
    /// A store in an unknown format (a future macOS) falls back to a structural scan: any string or
    /// nested plist blob below an "Idle" key that names the saver bundle.
    public func isSelected() -> Bool {
        if let selection = selection() { return selection.isSelected }
        guard let data = FileManager.default.contents(atPath: url.path), let root = try? PlistValue.parse(data) else { return false }
        return Self.mentions(root, needles: [module.url.lastPathComponent, LPPaths.saverBundleID], inIdle: false, depth: 0)
    }

    /// True when every display and Space resolves to LivePaper (WallpaperSelection.isSelectedEverywhere).
    public func isSelectedEverywhere() -> Bool { selection()?.isSelectedEverywhere ?? false }

    /// The applier that writes this store (LIVE PATH with a LiveWallpaperSystem).
    public func applier(system: WallpaperSystem, clock: WallpaperClock = SystemWallpaperClock(),
                        options: WallpaperApplyOptions = WallpaperApplyOptions(), lockURL: URL? = nil,
                        snapshotURL: URL? = nil) -> WallpaperStoreApplier {
        WallpaperStoreApplier(storeURL: url, system: system, clock: clock, options: options, lockURL: lockURL, snapshotURL: snapshotURL)
    }

    /// True while some Idle slot would point at a missing module once the installed saver is
    /// deleted: it names this LivePaper.saver, or a LivePaper.saver at a location that doesn't exist.
    /// A copy at another location that exists (e.g. /Library/Screen Savers) doesn't count. A store in
    /// an unknown format counts whenever its Idle subtrees mention LivePaper (`isSelected()`).
    public func dependsOnSaver(moduleExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> Bool {
        guard let document = try? read() else { return isSelected() }
        return document.records.contains { record in
            guard let idle = record.idle else { return false }
            return WallpaperSlot.moduleURLs(idle).contains { url in
                module.names(url) && !module.isOtherExistingCopy(url, moduleExists: moduleExists)
            }
        }
    }

    // MARK: - Fallback scan

    /// Nested blobs are rarely more than a few levels deep; the cap guards against hostile input.
    private static let maxDepth = 32

    private static func mentions(_ value: PlistValue, needles: [String], inIdle: Bool, depth: Int) -> Bool {
        guard depth < maxDepth else { return false }
        switch value {
        case .dictionary(let dict):
            return dict.contains { key, child in mentions(child, needles: needles, inIdle: inIdle || key == "Idle", depth: depth + 1) }
        case .array(let array):
            return array.contains { mentions($0, needles: needles, inIdle: inIdle, depth: depth + 1) }
        case .string(let string):
            guard inIdle else { return false }
            let decoded = string.removingPercentEncoding ?? string
            return needles.contains { string.contains($0) || decoded.contains($0) }
        case .data(let data):
            guard inIdle else { return false }
            if let inner = try? PlistValue.parse(data) { return mentions(inner, needles: needles, inIdle: true, depth: depth + 1) }
            return needles.contains { data.range(of: Data($0.utf8)) != nil }
        default:
            return false
        }
    }
}
