// WallpaperStoreDocument — Index.plist held as an exact PlistValue tree, with typed access to its
// records and their Idle (screen saver) slots. Edits replace whole Idle slots and nothing else; every
// other byte-level field (Desktop slots, timestamps, nested option blobs, keys LivePaper doesn't
// know) is carried through untouched.
import Foundation

/// Where a record lives in the store. The Idle slot of the record is `keyPath + ["Idle"]`.
public enum WallpaperRecordPath: Hashable, Sendable, Comparable, CustomStringConvertible, Codable {
    case allSpacesAndDisplays
    case systemDefault
    case display(String)
    case spaceDefault(String)
    case spaceDisplay(space: String, display: String)

    /// Dictionary keys from the store's root to the record.
    public var keyPath: [String] {
        switch self {
        case .allSpacesAndDisplays: return ["AllSpacesAndDisplays"]
        case .systemDefault: return ["SystemDefault"]
        case .display(let d): return ["Displays", d]
        case .spaceDefault(let s): return ["Spaces", s, "Default"]
        case .spaceDisplay(let s, let d): return ["Spaces", s, "Displays", d]
        }
    }

    public init?(keyPath: [String]) {
        switch keyPath.count {
        case 1 where keyPath[0] == "AllSpacesAndDisplays": self = .allSpacesAndDisplays
        case 1 where keyPath[0] == "SystemDefault": self = .systemDefault
        case 2 where keyPath[0] == "Displays": self = .display(keyPath[1])
        case 3 where keyPath[0] == "Spaces" && keyPath[2] == "Default": self = .spaceDefault(keyPath[1])
        case 4 where keyPath[0] == "Spaces" && keyPath[2] == "Displays": self = .spaceDisplay(space: keyPath[1], display: keyPath[3])
        default: return nil
        }
    }

    /// True for the records nothing else falls back to (an Idle slot there can't "inherit").
    public var isRoot: Bool { self == .systemDefault || self == .allSpacesAndDisplays }

    /// e.g. `Spaces/""/Displays/<uuid>` (the first Space's key is the empty string).
    public var description: String { keyPath.map { $0.isEmpty ? "\"\"" : $0 }.joined(separator: "/") }

    /// Document order (`WallpaperStoreDocument.records`): AllSpacesAndDisplays, SystemDefault,
    /// Displays by id, then each Space by id with its Default before its displays.
    public static func < (a: WallpaperRecordPath, b: WallpaperRecordPath) -> Bool { a.sortKey.lexicographicallyPrecedes(b.sortKey) }

    private var sortKey: [String] {
        switch self {
        case .allSpacesAndDisplays: return ["0"]
        case .systemDefault: return ["1"]
        case .display(let d): return ["2", d]
        case .spaceDefault(let s): return ["3", s, "0"]
        case .spaceDisplay(let s, let d): return ["3", s, "1", d]
        }
    }

    public init(from decoder: Decoder) throws {
        let keys = try decoder.singleValueContainer().decode([String].self)
        guard let path = WallpaperRecordPath(keyPath: keys) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a record path: \(keys)"))
        }
        self = path
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(keyPath)
    }
}

/// One record of the store.
public struct WallpaperRecord: Sendable, Equatable {
    public var path: WallpaperRecordPath
    /// The `Type` tag: individual, desktop, idle or linked.
    public var type: String
    public var desktop: PlistValue?
    public var idle: PlistValue?
    public var linked: PlistValue?
}

/// What LivePaper reads from an Idle slot.
public enum WallpaperSlot {
    /// Provider of the placeholder choice that means "use the next record up" (ultimately SystemDefault).
    public static let inheritProvider = "default"
    /// Provider of a legacy `.saver` choice.
    public static let screenSaverProvider = "com.apple.wallpaper.choice.screen-saver"

    /// The slot's choices as (provider, configuration) pairs; nil if the slot isn't shaped like one.
    public static func choices(_ slot: PlistValue) -> [(provider: String, configuration: Data)]? {
        guard let choices = slot.value(at: ["Content", "Choices"])?.arrayValue else { return nil }
        var result: [(String, Data)] = []
        for choice in choices {
            guard let provider = choice["Provider"]?.stringValue, let configuration = choice["Configuration"]?.dataValue else { return nil }
            result.append((provider, configuration))
        }
        return result
    }

    /// A placeholder slot: every choice is the `default` provider (it inherits).
    public static func isInherit(_ slot: PlistValue) -> Bool {
        guard let choices = choices(slot), !choices.isEmpty else { return false }
        return choices.allSatisfy { $0.provider == inheritProvider }
    }

    /// The module URL of a screen-saver choice's configuration (`{module = {relative, base?}}`).
    public static func moduleURL(fromConfiguration data: Data) -> URL? {
        guard let config = try? PlistValue.parse(data), let module = config["module"] else { return nil }
        if let string = module.stringValue { return URL(string: string) }
        guard let relative = module["relative"]?.stringValue else { return nil }
        let base = module["base"].flatMap { WallpaperSlot.urlValue($0) }
        return URL(string: relative, relativeTo: base)?.absoluteURL
    }

    /// The screen-saver modules a slot's choices point at.
    public static func moduleURLs(_ slot: PlistValue) -> [URL] {
        (choices(slot) ?? []).compactMap { $0.provider == screenSaverProvider ? moduleURL(fromConfiguration: $0.configuration) : nil }
    }

    /// Slot content (`Content`) plus `LastSet` — the slot without its `LastUse`, which WallpaperAgent
    /// bumps whenever the slot is shown. Used to compare slots across an agent restart.
    public static func identity(_ slot: PlistValue) -> PlistValue {
        guard var dict = slot.dictionaryValue else { return slot }
        dict.removeValue(forKey: "LastUse")
        return .dictionary(dict)
    }

    private static func urlValue(_ value: PlistValue) -> URL? {
        if let s = value.stringValue { return URL(string: s) }
        guard let relative = value["relative"]?.stringValue else { return nil }
        return URL(string: relative, relativeTo: value["base"].flatMap(urlValue))
    }
}

public struct WallpaperStoreDocument: Sendable, Equatable {
    /// The whole store, exactly as read.
    public let root: PlistValue

    /// Wraps an already-parsed tree (no validation).
    public init(root: PlistValue) { self.root = root }

    /// Parses store bytes and checks that WallpaperAgent's own decoder would accept them.
    /// - Throws: `WallpaperStoreError.undecodable` when either check fails.
    public init(data: Data) throws {
        do {
            root = try PlistValue.parse(data)
        } catch {
            throw WallpaperStoreError.undecodable("not a property list (\(error.localizedDescription))")
        }
        guard root.dictionaryValue != nil else { throw WallpaperStoreError.undecodable("the root isn't a dictionary") }
        try Self.checkDecodable(data)
    }

    /// Throws `.undecodable` unless the bytes decode with WallpaperStoreSchema (the agent's model).
    public static func checkDecodable(_ data: Data) throws {
        do {
            _ = try WallpaperStoreSchema.decode(data)
        } catch {
            throw WallpaperStoreError.undecodable(describe(error))
        }
    }

    /// Binary property list of the tree.
    public func data() throws -> Data { try root.binaryData() }

    /// Every record, in a stable order: AllSpacesAndDisplays (when set), SystemDefault, Displays/*,
    /// then each Space's Default and Displays/*.
    public var records: [WallpaperRecord] {
        var paths: [WallpaperRecordPath] = [.allSpacesAndDisplays, .systemDefault]
        paths += (root["Displays"]?.dictionaryValue?.keys.sorted() ?? []).map { .display($0) }
        for space in root["Spaces"]?.dictionaryValue?.keys.sorted() ?? [] {
            paths.append(.spaceDefault(space))
            let displays = root.value(at: ["Spaces", space, "Displays"])?.dictionaryValue?.keys.sorted() ?? []
            paths += displays.map { .spaceDisplay(space: space, display: $0) }
        }
        return paths.compactMap(record(at:))
    }

    /// The record at `path`, or nil when there is none (e.g. AllSpacesAndDisplays = "$null").
    public func record(at path: WallpaperRecordPath) -> WallpaperRecord? {
        guard let dict = root.value(at: path.keyPath)?.dictionaryValue, let type = dict["Type"]?.stringValue else { return nil }
        return WallpaperRecord(path: path, type: type, desktop: dict["Desktop"], idle: dict["Idle"], linked: dict["Linked"])
    }

    /// The Idle slot of the record at `path`.
    public func idleSlot(at path: WallpaperRecordPath) -> PlistValue? { record(at: path)?.idle }

    /// A copy with the given Idle slots replaced. Every record must exist and already have an Idle slot.
    public func replacingIdleSlots(_ slots: [WallpaperRecordPath: PlistValue]) throws -> WallpaperStoreDocument {
        var tree = root
        for (path, slot) in slots.sorted(by: { $0.key < $1.key }) {
            guard idleSlot(at: path) != nil else { throw WallpaperStoreError.unsupportedShape("\(path) has no Idle slot") }
            tree = try tree.setting(slot, at: path.keyPath + ["Idle"])
        }
        return WallpaperStoreDocument(root: tree)
    }

    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        func at(_ path: [CodingKey]) -> String { path.map(\.stringValue).joined(separator: "/") }
        switch decoding {
        case .keyNotFound(let key, let ctx): return "missing \(key.stringValue) at \(at(ctx.codingPath))"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            return "\(ctx.debugDescription) at \(at(ctx.codingPath))"
        @unknown default: return error.localizedDescription
        }
    }
}
