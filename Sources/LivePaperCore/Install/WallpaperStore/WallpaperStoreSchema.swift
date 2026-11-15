// WallpaperStoreSchema — a Swift Codable mirror of the model WallpaperAgent (macOS 26) decodes
// Index.plist into, reconstructed from the agent's Swift field metadata (docs/RESEARCH.md §5).
//
// Why it matters: the agent reads the store with PropertyListDecoder at launch. If that decode
// throws, it logs "Unable to read Index", builds a *default* store and writes it back — wiping the
// user's Desktop choices. So before LivePaper ever puts a file in place it must decode with this
// mirror. The mirror is deliberately strict about every structure LivePaper writes (record type
// tags, slot and choice keys and their types) and permissive only about values LivePaper never
// produces or edits (`Files` entries, `Shuffle`), whose exact Codable shape isn't known.
//
// Encoding mirrors the agent too: with PropertyListEncoder (binary) a decoded real store re-encodes
// to the identical bytes, which the self tests check against a copy of the real store when one is
// available. Optionals the agent writes as "$null" are encoded with `encode(_:forKey:)`, which is
// how PropertyListEncoder produces that string.
import Foundation

public enum WallpaperStoreSchema {
    /// `StoreIndex`: the root of Index.plist.
    public struct Index: Codable, Sendable, Equatable {
        /// "Show on all Spaces"-style override; always "$null" (nil) in every store observed.
        public var allSpacesAndDisplays: Record?
        public var systemDefault: Record
        /// Keyed by Space UUID ("" is the first space).
        public var spaces: [String: SpaceRecord]
        /// Keyed by display UUID.
        public var displays: [String: Record]

        public init(allSpacesAndDisplays: Record? = nil, systemDefault: Record, spaces: [String: SpaceRecord] = [:],
                    displays: [String: Record] = [:]) {
            self.allSpacesAndDisplays = allSpacesAndDisplays; self.systemDefault = systemDefault
            self.spaces = spaces; self.displays = displays
        }

        enum CodingKeys: String, CodingKey {
            case allSpacesAndDisplays = "AllSpacesAndDisplays", systemDefault = "SystemDefault", spaces = "Spaces", displays = "Displays"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            allSpacesAndDisplays = try c.decodeIfPresent(Record.self, forKey: .allSpacesAndDisplays)
            systemDefault = try c.decode(Record.self, forKey: .systemDefault)
            // The agent's SystemDefault type only has these two cases.
            switch systemDefault {
            case .individual, .linked: break
            case .desktop, .idle:
                throw DecodingError.dataCorruptedError(forKey: .systemDefault, in: c,
                                                       debugDescription: "SystemDefault must be an individual or linked record")
            }
            spaces = try c.decode([String: SpaceRecord].self, forKey: .spaces)
            displays = try c.decode([String: Record].self, forKey: .displays)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(allSpacesAndDisplays, forKey: .allSpacesAndDisplays)   // nil → "$null"
            try c.encode(systemDefault, forKey: .systemDefault)
            try c.encode(spaces, forKey: .spaces)
            try c.encode(displays, forKey: .displays)
        }
    }

    /// One Space: its default record plus per-display records.
    public struct SpaceRecord: Codable, Sendable, Equatable {
        public var `default`: Record
        public var displays: [String: Record]
        public init(default: Record, displays: [String: Record] = [:]) { self.default = `default`; self.displays = displays }
        enum CodingKeys: String, CodingKey { case `default` = "Default", displays = "Displays" }
    }

    /// `Record`: an enum tagged by the `Type` key. Every record observed is `individual`.
    public enum Record: Codable, Sendable, Equatable {
        case individual(desktop: Slot, idle: Slot)
        case desktop(Slot)
        case idle(Slot)
        /// One slot shared by Desktop and Idle (never observed; LivePaper refuses to edit such stores).
        case linked(Slot)

        enum CodingKeys: String, CodingKey { case type = "Type", desktop = "Desktop", idle = "Idle", linked = "Linked" }

        /// The on-disk `Type` tag.
        public var type: String {
            switch self {
            case .individual: return "individual"
            case .desktop: return "desktop"
            case .idle: return "idle"
            case .linked: return "linked"
            }
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "individual": self = .individual(desktop: try c.decode(Slot.self, forKey: .desktop), idle: try c.decode(Slot.self, forKey: .idle))
            case "desktop": self = .desktop(try c.decode(Slot.self, forKey: .desktop))
            case "idle": self = .idle(try c.decode(Slot.self, forKey: .idle))
            case "linked": self = .linked(try c.decode(Slot.self, forKey: .linked))
            case let other:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown record type \(other)")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(type, forKey: .type)
            switch self {
            case .individual(let desktop, let idle):
                try c.encode(desktop, forKey: .desktop)
                try c.encode(idle, forKey: .idle)
            case .desktop(let slot): try c.encode(slot, forKey: .desktop)
            case .idle(let slot): try c.encode(slot, forKey: .idle)
            case .linked(let slot): try c.encode(slot, forKey: .linked)
            }
        }
    }

    /// A Desktop or Idle (screen saver) slot.
    public struct Slot: Codable, Sendable, Equatable {
        public var lastSet: Date
        public var lastUse: Date
        public var content: Content
        public init(lastSet: Date, lastUse: Date, content: Content) { self.lastSet = lastSet; self.lastUse = lastUse; self.content = content }
        enum CodingKeys: String, CodingKey { case lastSet = "LastSet", lastUse = "LastUse", content = "Content" }
    }

    public struct Content: Codable, Sendable, Equatable {
        public var choices: [Choice]
        /// Always "$null" (nil) in observed stores; its real Codable shape isn't known.
        public var shuffle: AnyValue?
        /// A nested binary plist (`{values = {...}}`).
        public var encodedOptionValues: Data?

        public init(choices: [Choice], shuffle: AnyValue? = nil, encodedOptionValues: Data?) {
            self.choices = choices; self.shuffle = shuffle; self.encodedOptionValues = encodedOptionValues
        }

        enum CodingKeys: String, CodingKey { case choices = "Choices", shuffle = "Shuffle", encodedOptionValues = "EncodedOptionValues" }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            choices = try c.decode([Choice].self, forKey: .choices)
            shuffle = try c.decodeIfPresent(AnyValue.self, forKey: .shuffle)
            encodedOptionValues = try c.decodeIfPresent(Data.self, forKey: .encodedOptionValues)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(choices, forKey: .choices)
            try c.encode(shuffle, forKey: .shuffle)                           // nil → "$null"
            try c.encode(encodedOptionValues, forKey: .encodedOptionValues)   // nil → "$null"
        }
    }

    /// `Choice`: what a slot shows. For a legacy `.saver`, Provider is
    /// "com.apple.wallpaper.choice.screen-saver" and Configuration is a binary plist
    /// `{module = {relative = "<file URL>"}}`.
    public struct Choice: Codable, Sendable, Equatable {
        public var provider: String
        public var files: [AnyValue]
        public var configuration: Data
        public init(provider: String, files: [AnyValue] = [], configuration: Data) {
            self.provider = provider; self.files = files; self.configuration = configuration
        }
        enum CodingKeys: String, CodingKey { case provider = "Provider", files = "Files", configuration = "Configuration" }
    }

    /// Any property-list value, for fields whose exact type LivePaper doesn't rely on.
    public indirect enum AnyValue: Codable, Sendable, Equatable {
        case string(String), bool(Bool), integer(Int64), real(Double), date(Date), data(Data)
        case array([AnyValue]), dictionary([String: AnyValue])

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        public init(from decoder: Decoder) throws {
            if let keyed = try? decoder.container(keyedBy: Key.self) {
                var dict: [String: AnyValue] = [:]
                for key in keyed.allKeys { dict[key.stringValue] = try keyed.decode(AnyValue.self, forKey: key) }
                self = .dictionary(dict)
                return
            }
            if var unkeyed = try? decoder.unkeyedContainer() {
                var array: [AnyValue] = []
                while !unkeyed.isAtEnd { array.append(try unkeyed.decode(AnyValue.self)) }
                self = .array(array)
                return
            }
            let single = try decoder.singleValueContainer()
            if let v = try? single.decode(String.self) { self = .string(v) }
            else if let v = try? single.decode(Bool.self) { self = .bool(v) }
            else if let v = try? single.decode(Int64.self) { self = .integer(v) }
            else if let v = try? single.decode(Double.self) { self = .real(v) }
            else if let v = try? single.decode(Date.self) { self = .date(v) }
            else if let v = try? single.decode(Data.self) { self = .data(v) }
            else { throw DecodingError.dataCorruptedError(in: single, debugDescription: "unsupported value") }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let v): try c.encode(v)
            case .bool(let v): try c.encode(v)
            case .integer(let v): try c.encode(v)
            case .real(let v): try c.encode(v)
            case .date(let v): try c.encode(v)
            case .data(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .dictionary(let v): try c.encode(v)
            }
        }
    }

    // MARK: - Coding

    /// Decodes Index.plist bytes the way WallpaperAgent does (PropertyListDecoder).
    public static func decode(_ data: Data) throws -> Index {
        try PropertyListDecoder().decode(Index.self, from: data)
    }

    /// Encodes the way WallpaperAgent writes the store (PropertyListEncoder, binary).
    public static func encode(_ index: Index) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(index)
    }
}
