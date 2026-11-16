// SceneCollection — a named, ordered set of scenes (user and built-in), stored with every other
// collection in `collections.json` in the support directory (ARCHITECTURE §4.6).
//
// * A scene can be in any number of collections, at most once in each.
// * Collections hold scene ids only: renaming or deleting a collection never touches a scene, and
//   deleting a scene in LivePaper removes it from every collection (CollectionServicing
//   .removeSceneEverywhere). An id whose scene is gone some other way (moved to the Trash in Finder)
//   is skipped wherever the collection is shown, played or exported, and is back if the scene is.
// * The id is a lowercase UUID for collections LivePaper creates. It never changes (renaming keeps
//   it) and travels with an export, so importing the same collection again finds it.
// * Names are unique in a library, ignoring letter case and accents, so the CLI can name them.
//
// Decoding is tolerant (the file is plain JSON that people and other versions may edit): a
// collection that can't be read is dropped, a field that can't be read gets its default, scene ids
// that aren't valid are dropped, repeated ones are kept once.
import Foundation

public struct SceneCollection: Codable, Sendable, Equatable, Hashable, Identifiable {
    public static let defaultName = "Untitled Collection"
    public static let maxNameLength = 120

    public var id: String
    public var name: String
    /// Scene ids (user and built-in), in the collection's order, each at most once.
    public var sceneIDs: [String]
    public var created: Date?
    public var updated: Date?

    public init(id: String = SceneCollection.newID(), name: String, sceneIDs: [String] = [], created: Date? = nil, updated: Date? = nil) {
        self.id = id
        self.name = SceneCollection.displayName(name)
        self.sceneIDs = CollectionOrder.unique(sceneIDs)
        self.created = created
        self.updated = updated
    }

    enum CodingKeys: String, CodingKey { case id, name, scenes, created, updated }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An unusable id is filled in by CollectionsFile (derived from the name, made unique).
        id = SceneCollection.isValidID(rawID) ? rawID : ""
        name = SceneCollection.displayName(((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? "")
        let scenes = ((try? c.decodeIfPresent([Lossy<String>].self, forKey: .scenes)) ?? nil) ?? []
        sceneIDs = CollectionOrder.unique(scenes.compactMap(\.value).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(SceneManifest.isValidID))
        created = (try? c.decodeIfPresent(Date.self, forKey: .created)) ?? nil
        updated = (try? c.decodeIfPresent(Date.self, forKey: .updated)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(sceneIDs, forKey: .scenes)
        try c.encodeIfPresent(created, forKey: .created)
        try c.encodeIfPresent(updated, forKey: .updated)
    }

    /// A new collection's id.
    public static func newID() -> String { UUID().uuidString.lowercased() }

    /// 1–64 letters, digits and dashes (LivePaper's own ids are UUIDs; older or hand-written files
    /// may use other words). Never a path or anything that needs quoting.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
    }

    /// The name as stored: trimmed, single-line, at most `maxNameLength` characters; blank →
    /// "Untitled Collection".
    public static func displayName(_ name: String) -> String {
        let oneLine = name.components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultName }
        return String(trimmed.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
    }

    /// What makes two names the same name: letter case, accents and surrounding space don't count.
    public static func nameKey(_ name: String) -> String {
        displayName(name).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// `base`, or "base 2", "base 3", … — the first one no name in `existing` already is.
    public static func uniqueName(_ base: String, existing: [String]) -> String {
        let name = displayName(base)
        let taken = Set(existing.map(nameKey))
        guard taken.contains(nameKey(name)) else { return name }
        // "Night Skies 2" imported again becomes "Night Skies 3", not "Night Skies 2 2".
        var stem = name
        if let space = name.lastIndex(of: " "), Int(name[name.index(after: space)...]) != nil {
            stem = String(name[..<space])
        }
        var n = 2
        while taken.contains(nameKey("\(stem) \(n)")) { n += 1 }
        return "\(stem) \(n)"
    }

    /// The collection's scenes that exist (in `available`), in its order.
    public func existingSceneIDs(available: Set<String>) -> [String] { sceneIDs.filter(available.contains) }

    /// Sorted the way LivePaper lists collections: by name, then id.
    public static func sorted(_ collections: [SceneCollection]) -> [SceneCollection] {
        collections.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

/// `collections.json`: `{"schema": 1, "collections": [{id, name, scenes: [scene-id, …], created, updated}, …]}`.
public struct CollectionsFile: Codable, Sendable, Equatable {
    public static let fileName = "collections.json"
    public static let currentSchema = 1

    public var schema: Int
    /// In the order they were created (LivePaper lists them by name).
    public var collections: [SceneCollection]

    public init(collections: [SceneCollection] = []) {
        schema = CollectionsFile.currentSchema
        self.collections = collections
    }

    enum CodingKeys: String, CodingKey { case schema, collections }

    /// Also reads a bare array of collections. Collections without a usable id get one derived from
    /// their name (the same on every read); repeated ids are made unique.
    public init(from decoder: Decoder) throws {
        var items: [Lossy<SceneCollection>]
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            schema = ((try? c.decodeIfPresent(Int.self, forKey: .schema)) ?? nil) ?? CollectionsFile.currentSchema
            items = ((try? c.decodeIfPresent([Lossy<SceneCollection>].self, forKey: .collections)) ?? nil) ?? []
        } else {
            schema = CollectionsFile.currentSchema
            items = try decoder.singleValueContainer().decode([Lossy<SceneCollection>].self)
        }
        var seen = Set<String>()
        collections = items.compactMap(\.value).map { item in
            var item = item
            var id = item.id.isEmpty ? "c-" + SceneManifest.slug(from: item.name) : item.id
            if seen.contains(id) {
                let base = String(id.prefix(60))
                var n = 2
                while seen.contains("\(base)-\(n)") { n += 1 }
                id = "\(base)-\(n)"
            }
            seen.insert(id)
            item.id = id
            return item
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(CollectionsFile.currentSchema, forKey: .schema)
        try c.encode(collections, forKey: .collections)
    }

    public static func decode(_ data: Data) throws -> CollectionsFile {
        try SceneManifest.decoder().decode(CollectionsFile.self, from: data)
    }

    public func encoded() throws -> Data { try SceneManifest.encoder().encode(self) }
}

/// Decodes a `T`, or nil instead of failing the whole array it is in.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension Lossy: Sendable where T: Sendable {}

// MARK: - The playlist following a collection

public extension PlaylistSettings {
    /// The settings as the screen saver plays them: when the playlist follows a collection that
    /// exists, its scenes are the collection's, in its order (an empty collection plays every scene,
    /// like an empty selection; see PublishService). Otherwise unchanged: `sceneIDs` keeps the
    /// scenes the collection had when it was last saved, which is also what an older LivePaper plays.
    func following(_ collections: [SceneCollection]) -> PlaylistSettings {
        guard let id = collectionID, let collection = collections.first(where: { $0.id == id }) else { return self }
        var s = self
        s.sceneIDs = collection.sceneIDs
        return s
    }
}
