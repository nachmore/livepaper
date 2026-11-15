// WallpaperChoice — the exact Idle-slot payload that selects a legacy `.saver`, as System Settings
// writes it on macOS 26 (docs/RESEARCH.md §5), and how to recognise LivePaper's choice in a slot.
import Foundation

/// The screen-saver bundle a choice points at (LivePaper's, normally ~/Library/Screen Savers/LivePaper.saver).
public struct WallpaperSaverModule: Sendable, Equatable {
    /// File URL of the `.saver` bundle.
    public let url: URL

    public init(url: URL) { self.url = url.standardizedFileURL }

    /// The module URL as System Settings stores it: percent-encoded (`Screen%20Savers`), no trailing
    /// slash, no base — e.g. `file:///Users/user/Library/Screen%20Savers/LivePaper.saver`.
    /// (`URL(fileURLWithPath:)` on the existing bundle would append a slash because it's a directory.)
    public var moduleURLString: String { URL(fileURLWithPath: url.path, isDirectory: false).absoluteString }

    /// The choice's `Configuration`: binary plist `{module = {relative = "<moduleURLString>"}}`.
    /// For `/Users/<8-letter name>/…/LivePaper.saver` this is 132 bytes, identical to what System
    /// Settings writes for a saver of the same path.
    public func configuration() throws -> Data {
        try PlistValue.dictionary(["module": .dictionary(["relative": .string(moduleURLString)])]).binaryData()
    }

    /// The single choice LivePaper puts in an Idle slot.
    public func choice() throws -> PlistValue {
        .dictionary(["Provider": .string(WallpaperSlot.screenSaverProvider), "Files": .array([]), "Configuration": .data(try configuration())])
    }

    /// A complete Idle slot selecting this module, set and used at `date`.
    public func slot(at date: Date) throws -> PlistValue {
        .dictionary([
            "Content": .dictionary([
                "Choices": .array([try choice()]),
                "Shuffle": .string(WallpaperChoicePayload.nullString),
                "EncodedOptionValues": .data(WallpaperChoicePayload.emptyOptionValues),
            ]),
            "LastSet": .date(date),
            "LastUse": .date(date),
        ])
    }

    /// True when `moduleURL` names this saver bundle (same file name, any folder — a home folder
    /// that was renamed or a copy in /Library/Screen Savers still counts as LivePaper).
    public func names(_ moduleURL: URL) -> Bool {
        moduleURL.standardizedFileURL.lastPathComponent.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame
    }

    /// True when `moduleURL` is exactly this bundle's location.
    public func isLocation(_ moduleURL: URL) -> Bool {
        Self.normalizedPath(moduleURL) == Self.normalizedPath(url)
    }

    /// True when any choice of the Idle slot is this saver.
    public func isChosen(in slot: PlistValue) -> Bool {
        WallpaperSlot.moduleURLs(slot).contains(where: names)
    }

    /// True when the slot already holds exactly this saver at this location (nothing to write).
    public func isCurrentChoice(in slot: PlistValue) -> Bool {
        guard let choices = WallpaperSlot.choices(slot), choices.count == 1, choices[0].provider == WallpaperSlot.screenSaverProvider,
              let module = WallpaperSlot.moduleURL(fromConfiguration: choices[0].configuration) else { return false }
        return isLocation(module)
    }

    private static func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// Fixed values of the store format.
public enum WallpaperChoicePayload {
    /// PropertyListEncoder's spelling of nil, used for `Shuffle` and AllSpacesAndDisplays.
    public static let nullString = "$null"

    /// `EncodedOptionValues` of a saver or placeholder slot: binary plist `{values = {}}` (54 bytes,
    /// byte-identical to what WallpaperAgent writes itself).
    public static let emptyOptionValues: Data = {
        // Encoding an empty dictionary can't fail.
        (try? PlistValue.dictionary(["values": .dictionary([:])]).binaryData()) ?? Data()
    }()

    /// The placeholder slot (`Provider = "default"`) that makes a record use the next record up.
    public static func inheritSlot(at date: Date) -> PlistValue {
        .dictionary([
            "Content": .dictionary([
                "Choices": .array([.dictionary(["Provider": .string(WallpaperSlot.inheritProvider), "Files": .array([]),
                                                "Configuration": .data(Data())])]),
                "Shuffle": .string(nullString),
                "EncodedOptionValues": .data(emptyOptionValues),
            ]),
            "LastSet": .date(date),
            "LastUse": .date(date),
        ])
    }
}
