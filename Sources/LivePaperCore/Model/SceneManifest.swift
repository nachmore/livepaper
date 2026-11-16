// SceneManifest — scene.json inside a <id>.lpscene package. See docs/ARCHITECTURE.md §4.2.
import Foundation

public struct SceneManifest: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchema = 1
    public static let fileName = "scene.json"
    public static let packageExtension = "lpscene"

    public enum Kind: String, Codable, Sendable { case web, video }

    public struct Clock: Codable, Sendable, Equatable {
        public var position: LPClockPosition
        public init(position: LPClockPosition = .top) { self.position = position }
    }

    public struct Video: Codable, Sendable, Equatable {
        public var file: String
        public var fit: LPVideoFit
        public var loop: Bool
        public init(file: String, fit: LPVideoFit = .fill, loop: Bool = true) { self.file = file; self.fit = fit; self.loop = loop }
    }

    public struct Performance: Codable, Sendable, Equatable {
        /// Heaviest sampled bench at 1512×982@2x (ms/frame).
        public var benchMs: Double?
        /// Optional live CPU energy in battery mode (mW).
        public var energyMw: Double?
        public var checkedAt: Date?
        public init(benchMs: Double? = nil, energyMw: Double? = nil, checkedAt: Date? = nil) {
            self.benchMs = benchMs; self.energyMw = energyMw; self.checkedAt = checkedAt
        }
    }

    public var schema: Int
    public var id: String
    public var name: String
    public var description: String
    public var kind: Kind
    /// Runtime API major version for web scenes.
    public var runtime: Int?
    public var clock: Clock
    public var video: Video?
    public var author: String?
    public var created: Date?
    public var updated: Date?
    /// Scene id this one was cloned from.
    public var parent: String?
    public var tags: [String]
    public var performance: Performance?
    /// "Span across displays": `true` declares that this web scene is a pure function of lp.t, the
    /// seed and the canvas size, so it may stretch across all displays (SCENE_API.md "Spanning
    /// several displays"; `livepaper check` verifies it). Videos span unless this is `false`.
    public var span: Bool?

    public init(id: String, name: String, description: String = "", kind: Kind, runtime: Int? = 1,
                clock: Clock = .init(), video: Video? = nil, author: String? = nil, created: Date? = Date(),
                updated: Date? = Date(), parent: String? = nil, tags: [String] = [], performance: Performance? = nil,
                span: Bool? = nil) {
        self.schema = SceneManifest.currentSchema
        self.id = id; self.name = name; self.description = description; self.kind = kind
        self.runtime = kind == .web ? (runtime ?? 1) : nil
        self.clock = clock; self.video = video; self.author = author; self.created = created; self.updated = updated
        self.parent = parent; self.tags = tags; self.performance = performance; self.span = span
    }

    /// Whether the scene stretches across displays in "Span across displays": videos by default (one
    /// shared player shows every display its crop, exact by construction), web scenes only when they
    /// declare `"span": true`.
    public var spans: Bool { kind == .video ? (span ?? true) : (span == true) }

    // Tolerant decoding: AI agents write this file, so missing optional fields must not fail.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? SceneManifest.currentSchema
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .web
        runtime = try c.decodeIfPresent(Int.self, forKey: .runtime) ?? (kind == .web ? 1 : nil)
        clock = try c.decodeIfPresent(Clock.self, forKey: .clock) ?? .init()
        video = try c.decodeIfPresent(Video.self, forKey: .video)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        created = try? c.decodeIfPresent(Date.self, forKey: .created)
        updated = try? c.decodeIfPresent(Date.self, forKey: .updated)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        performance = try? c.decodeIfPresent(Performance.self, forKey: .performance)
        span = (try? c.decodeIfPresent(Bool.self, forKey: .span)).flatMap { $0 }
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }

    public static func load(package url: URL) throws -> SceneManifest {
        try decoder().decode(SceneManifest.self, from: Data(contentsOf: url.appendingPathComponent(fileName)))
    }

    public func write(package url: URL) throws {
        try SceneManifest.encoder().encode(self).write(to: url.appendingPathComponent(SceneManifest.fileName), options: .atomic)
    }

    /// kebab-case, 1–64 chars, [a-z0-9-].
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
            && !id.hasPrefix("-") && !id.hasSuffix("-")
    }

    public static func slug(from name: String) -> String {
        let lowered = name.lowercased().map { c -> Character in
            (("a"..."z").contains(c) || ("0"..."9").contains(c)) ? c : "-"
        }
        let collapsed = String(lowered).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "scene" : String(collapsed.prefix(64))
    }
}
