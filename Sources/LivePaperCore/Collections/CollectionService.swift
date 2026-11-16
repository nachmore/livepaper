// CollectionService — collections of scenes (CollectionServicing, ARCHITECTURE §4.6): editing them
// in collections.json (CollectionStore) and moving them between libraries as .lpcollection files.
//
// Works over any LibraryServicing (the live library, or the app's mock one), which it asks which
// scenes exist, which are built in, and which it exports and imports scene by scene.
import Foundation
import os

public final class CollectionService: CollectionServicing, @unchecked Sendable {
    public let store: CollectionStore
    private let library: LibraryServicing
    private let runner: CommandRunning
    private let clock: @Sendable () -> Date
    /// One import at a time in this process: the same file opened twice at once (two copies selected
    /// together in Finder, a second double-click) imports its scenes and its collection once.
    private let importLock = NSLock()
    private let log = Logger(subsystem: LPPaths.bundleID, category: "collections")

    public init(library: LibraryServicing, store: CollectionStore = CollectionStore(), runner: CommandRunning = SystemCommandRunner(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.library = library
        self.store = store
        self.runner = runner
        self.clock = now
    }

    /// Whole seconds, like everything else LivePaper writes as ISO 8601.
    private func now() -> Date { Date(timeIntervalSince1970: clock().timeIntervalSince1970.rounded(.down)) }

    // MARK: - Reading

    public func collections() -> [SceneCollection] { SceneCollection.sorted(store.load().collections) }

    public func collection(id: String) -> SceneCollection? { store.load().collections.first { $0.id == id } }

    public func find(_ nameOrID: String) throws -> SceneCollection? {
        try Self.find(nameOrID, in: store.load().collections)
    }

    static func find(_ query: String, in all: [SceneCollection]) throws -> SceneCollection? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        if let exact = all.first(where: { $0.id == q }) { return exact }
        let key = SceneCollection.nameKey(q)
        let named = all.filter { SceneCollection.nameKey($0.name) == key }
        if named.count == 1 { return named[0] }
        if named.count > 1 { throw CollectionError.ambiguous(SceneCollection.displayName(q), named.map(\.id)) }
        let lower = q.lowercased()
        let prefixed = all.filter { $0.id.lowercased().hasPrefix(lower) }
        return lower.count >= 4 && prefixed.count == 1 ? prefixed[0] : nil
    }

    // MARK: - Changing

    @discardableResult
    public func create(name: String, sceneIDs: [String]) throws -> SceneCollection {
        let scenes = try knownScenes(sceneIDs)
        let date = now()
        return try store.update { file in
            let name = SceneCollection.displayName(name)
            try Self.requireFreeName(name, in: file.collections, except: nil)
            let collection = SceneCollection(name: name, sceneIDs: scenes, created: date, updated: date)
            file.collections.append(collection)
            log.info("created collection \(collection.id, privacy: .public)")
            return collection
        }
    }

    @discardableResult
    public func rename(id: String, to name: String) throws -> SceneCollection {
        let date = now()
        return try store.update { file in
            let i = try Self.index(of: id, in: file)
            let name = SceneCollection.displayName(name)
            guard name != file.collections[i].name else { return file.collections[i] }
            try Self.requireFreeName(name, in: file.collections, except: id)
            file.collections[i].name = name
            file.collections[i].updated = date
            return file.collections[i]
        }
    }

    @discardableResult
    public func delete(id: String) throws -> SceneCollection {
        try store.update { file in
            let i = try Self.index(of: id, in: file)
            log.info("deleted collection \(id, privacy: .public)")
            return file.collections.remove(at: i)
        }
    }

    @discardableResult
    public func add(_ sceneIDs: [String], to id: String, at placement: CollectionPlacement) throws -> CollectionEdit {
        let scenes = try knownScenes(sceneIDs)
        let date = now()
        return try store.update { file in
            let i = try Self.index(of: id, in: file)
            let (ids, added) = CollectionOrder.adding(scenes, to: file.collections[i].sceneIDs, at: placement)
            if !added.isEmpty { file.collections[i].sceneIDs = ids; file.collections[i].updated = date }
            return CollectionEdit(collection: file.collections[i], changed: added)
        }
    }

    @discardableResult
    public func remove(_ sceneIDs: [String], from id: String) throws -> CollectionEdit {
        let date = now()
        return try store.update { file in
            let i = try Self.index(of: id, in: file)
            let (ids, removed) = CollectionOrder.removing(sceneIDs, from: file.collections[i].sceneIDs)
            if !removed.isEmpty { file.collections[i].sceneIDs = ids; file.collections[i].updated = date }
            return CollectionEdit(collection: file.collections[i], changed: removed)
        }
    }

    @discardableResult
    public func move(_ sceneIDs: [String], in id: String, to placement: CollectionPlacement) throws -> CollectionEdit {
        let date = now()
        return try store.update { file in
            let i = try Self.index(of: id, in: file)
            let before = file.collections[i].sceneIDs
            let after = CollectionOrder.moving(sceneIDs, in: before, to: placement)
            guard after != before else { return CollectionEdit(collection: file.collections[i], changed: []) }
            file.collections[i].sceneIDs = after
            file.collections[i].updated = date
            let moving = Set(sceneIDs)
            return CollectionEdit(collection: file.collections[i], changed: after.filter(moving.contains))
        }
    }

    @discardableResult
    public func removeSceneEverywhere(_ sceneID: String) throws -> [SceneCollection] {
        let date = now()
        return try store.update { file in
            var changed: [SceneCollection] = []
            for i in file.collections.indices where file.collections[i].sceneIDs.contains(sceneID) {
                file.collections[i].sceneIDs.removeAll { $0 == sceneID }
                file.collections[i].updated = date
                changed.append(file.collections[i])
            }
            return changed
        }
    }

    private static func index(of id: String, in file: CollectionsFile) throws -> Int {
        guard let i = file.collections.firstIndex(where: { $0.id == id }) else { throw CollectionError.notFound(id) }
        return i
    }

    private static func requireFreeName(_ name: String, in all: [SceneCollection], except id: String?) throws {
        let key = SceneCollection.nameKey(name)
        if all.contains(where: { $0.id != id && SceneCollection.nameKey($0.name) == key }) { throw CollectionError.nameTaken(name) }
    }

    /// The ids, without repeats, after checking that the library has every one of them.
    private func knownScenes(_ ids: [String]) throws -> [String] {
        let wanted = CollectionOrder.unique(ids)
        guard !wanted.isEmpty else { return [] }
        let known = Set(try library.scenes().map(\.id))
        let unknown = wanted.filter { !known.contains($0) }
        guard unknown.isEmpty else { throw CollectionError.unknownScenes(unknown) }
        return wanted
    }

    // MARK: - Export

    @discardableResult
    public func export(id: String, to url: URL) throws -> CollectionExport {
        guard let collection = collection(id: id) else { throw CollectionError.notFound(id) }
        let fm = FileManager.default
        if FileOps.isRealDirectory(url) && url.pathExtension.lowercased() != CollectionArchive.fileExtension {
            throw CollectionError.invalid("\(url.lastPathComponent) is a folder; choose a file name ending in .\(CollectionArchive.fileExtension).")
        }
        let byID = Dictionary(try library.scenes().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let work = fm.temporaryDirectory.appendingPathComponent("livepaper-collection-export-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        let scenesDir = work.appendingPathComponent(CollectionArchive.scenesDirectory)
        try fm.createDirectory(at: scenesDir, withIntermediateDirectories: true)

        var entries: [CollectionArchive.Entry] = [], included: [String] = [], builtins: [String] = [], missing: [String] = []
        for sceneID in collection.sceneIDs {
            guard let item = byID[sceneID] else { missing.append(sceneID); continue }
            if item.isBuiltin {
                entries.append(.init(id: item.id, name: item.manifest.name, builtin: true, package: nil))
                builtins.append(item.id)
                continue
            }
            let relative = "\(CollectionArchive.scenesDirectory)/\(item.id).\(SceneManifest.packageExtension)"
            try library.exportPackage(id: item.id, to: work.appendingPathComponent(relative))
            entries.append(.init(id: item.id, name: item.manifest.name, builtin: false, package: relative))
            included.append(item.id)
        }
        let manifest = CollectionArchive.Manifest(id: collection.id, name: collection.name, created: collection.created,
                                                  updated: collection.updated, exported: now(), scenes: entries)
        try SceneManifest.encoder().encode(manifest).write(to: work.appendingPathComponent(CollectionArchive.manifestName), options: .atomic)

        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // Built next to the destination so the final step is a same-volume atomic rename.
        let staging = FileOps.stagingURL(in: parent, tag: "livepaper-export")
        defer { try? FileOps.removeIfPresent(staging) }
        // Without --keepParent the archive's root is the folder's contents: collection.json, scenes/.
        let result = try runner.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", work.path, staging.path], timeout: 900)
        guard result.succeeded else {
            throw CollectionError.invalid("Couldn\u{2019}t create \(url.lastPathComponent): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        try FileOps.installReplacing(url, with: staging)
        log.info("exported collection \(collection.id, privacy: .public): \(included.count) scene(s), \(builtins.count) built-in")
        return CollectionExport(url: url, collection: collection, includedScenes: included, builtinScenes: builtins, missingScenes: missing)
    }

    // MARK: - Import

    public func importCollection(at url: URL, mode: CollectionImportMode) throws -> CollectionImport {
        importLock.lock(); defer { importLock.unlock() }
        let fm = FileManager.default
        var extracted: URL?
        defer { if let extracted { try? fm.removeItem(at: extracted) } }
        let name = url.lastPathComponent
        let root: URL
        if FileOps.isRealDirectory(url) {
            root = try CollectionArchive.locateRoot(in: url, name: name)
        } else {
            guard FileOps.isRegularFile(url) else { throw CollectionError.invalid("\(name) isn\u{2019}t a LivePaper collection.") }
            let dir = fm.temporaryDirectory.appendingPathComponent("livepaper-collection-import-\(UUID().uuidString)")
            extracted = dir
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // ditto drops ".." and leading "/" from entry names and writes links as plain files
            // (checked on macOS 26), so nothing lands outside `dir`; scenes are validated on import.
            let result = try runner.run("/usr/bin/ditto", ["-x", "-k", url.path, dir.path], timeout: 900)
            guard result.succeeded else {
                throw CollectionError.invalid("\(name) isn\u{2019}t a LivePaper collection (it couldn\u{2019}t be unpacked: " +
                                              "\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))).")
            }
            root = try CollectionArchive.locateRoot(in: dir, name: name)
        }
        let manifest = try CollectionArchive.readManifest(in: root, name: name)
        let existingCollection = mode == .copy ? nil : store.load().collections.first { $0.id == manifest.id }

        // The library's id for each of the file's scenes: one the library has (resolved now), or a
        // package to import (only once it is decided that anything is imported).
        enum Resolution { case existing(String), importable(URL), missing(String) }
        let all = try library.scenes()
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var resolutions: [(entry: CollectionArchive.Entry, resolution: Resolution)] = []
        for entry in manifest.scenes {
            if entry.builtin {
                if let item = byID[entry.id], item.isBuiltin {
                    resolutions.append((entry, .existing(item.id)))
                } else if byID[entry.id] != nil {
                    resolutions.append((entry, .missing("it\u{2019}s a built-in scene, and a scene of yours has its id \u{201C}\(entry.id)\u{201D}")))
                } else {
                    resolutions.append((entry, .missing("it\u{2019}s a built-in scene this version of LivePaper doesn\u{2019}t have")))
                }
                continue
            }
            guard let package = CollectionArchive.packageURL(entry, in: root) else {
                resolutions.append((entry, .missing("its scene package isn\u{2019}t in \(name)")))
                continue
            }
            if case .same(let item)? = try? library.existingScene(matching: package) {
                resolutions.append((entry, .existing(item.id)))
            } else {
                resolutions.append((entry, .importable(package)))
            }
        }
        let missingOf: [CollectionImport.Missing] = resolutions.compactMap {
            if case .missing(let why) = $0.resolution { return .init(name: $0.entry.name, reason: why) }
            return nil
        }

        if let existingCollection, mode == .automatic {
            // Already here: change nothing, say what the file has that the collection doesn't.
            let lacking = resolutions.compactMap { r -> String? in
                switch r.resolution {
                case .existing(let id): return existingCollection.sceneIDs.contains(id) ? nil : r.entry.name
                case .importable: return r.entry.name
                case .missing: return nil
                }
            }
            return CollectionImport(outcome: .alreadyPresent, collection: existingCollection, lacking: lacking,
                                    existingScenes: resolutions.compactMap { if case .existing(let id) = $0.resolution { return id }; return nil },
                                    missing: missingOf)
        }

        var ids: [String] = [], imported: [SceneItem] = [], existing: [String] = [], missing = missingOf
        for r in resolutions {
            switch r.resolution {
            case .existing(let id):
                ids.append(id); existing.append(id)
            case .importable(let package):
                do {
                    // Opened again under the library's lock: an identical scene imported meanwhile is reused.
                    switch try library.openPackage(at: package) {
                    case .imported(let item): ids.append(item.id); imported.append(item)
                    case .existing(.same(let item)): ids.append(item.id); existing.append(item.id)
                    case .existing(.otherVersion):
                        // Another version of one of yours: imported next to it, never over it.
                        let item = try library.importPackage(at: package)
                        ids.append(item.id); imported.append(item)
                    }
                } catch {
                    missing.append(.init(name: r.entry.name, reason: error.localizedDescription))
                }
            case .missing:
                break
            }
        }
        guard !ids.isEmpty || manifest.scenes.isEmpty else {
            throw CollectionError.invalid("None of the scenes in \(name) could be added: " +
                                          missing.map { "\u{201C}\($0.name)\u{201D}: \($0.reason)" }.joined(separator: "; "))
        }

        let date = now()
        return try store.update { file in
            if mode != .copy, let i = file.collections.firstIndex(where: { $0.id == manifest.id }) {
                let (merged, added) = CollectionOrder.adding(ids, to: file.collections[i].sceneIDs)
                if !added.isEmpty { file.collections[i].sceneIDs = merged; file.collections[i].updated = date }
                log.info("merged \(added.count) scene(s) into collection \(manifest.id, privacy: .public)")
                return CollectionImport(outcome: .merged, collection: file.collections[i], added: added, importedScenes: imported,
                                        existingScenes: existing, missing: missing)
            }
            let taken = Set(file.collections.map(\.id))
            let id = mode != .copy && SceneCollection.isValidID(manifest.id) && !taken.contains(manifest.id) ? manifest.id : SceneCollection.newID()
            let collection = SceneCollection(id: id, name: SceneCollection.uniqueName(manifest.name, existing: file.collections.map(\.name)),
                                             sceneIDs: ids, created: manifest.created ?? date, updated: date)
            file.collections.append(collection)
            log.info("imported collection \(id, privacy: .public): \(imported.count) new scene(s), \(existing.count) already in the library")
            return CollectionImport(outcome: .created, collection: collection, added: collection.sceneIDs, importedScenes: imported,
                                    existingScenes: existing, missing: missing)
        }
    }
}

/// The .lpcollection file: a zip archive whose root holds `collection.json` and `scenes/`, one
/// .lpscene package per user scene. Built-in scenes are named in collection.json only.
public enum CollectionArchive {
    public static let fileExtension = "lpcollection"
    public static let manifestName = "collection.json"
    public static let scenesDirectory = "scenes"
    public static let format = "livepaper-collection"
    /// collection.json is a short list; anything bigger isn't one.
    static let maxManifestBytes = 4 << 20
    static let maxScenes = 5_000

    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        /// Built-in scenes are referenced by id and not in the file.
        public var builtin: Bool
        /// A user scene's package inside the file: "scenes/<id>.lpscene".
        public var package: String?

        public init(id: String, name: String, builtin: Bool, package: String?) {
            self.id = id; self.name = name; self.builtin = builtin; self.package = package
        }

        enum CodingKeys: String, CodingKey { case id, name, builtin, package }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id).trimmingCharacters(in: .whitespaces)
            guard SceneManifest.isValidID(id) else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "not a scene id")
            }
            let n = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            name = n.isEmpty ? id : String(n.prefix(200))
            builtin = ((try? c.decodeIfPresent(Bool.self, forKey: .builtin)) ?? nil) ?? false
            package = (try? c.decodeIfPresent(String.self, forKey: .package)) ?? nil
        }
    }

    public struct Manifest: Codable, Sendable, Equatable {
        public var schema: Int
        public var format: String
        public var id: String
        public var name: String
        public var created: Date?
        public var updated: Date?
        public var exported: Date?
        /// In the collection's order.
        public var scenes: [Entry]

        public init(id: String, name: String, created: Date?, updated: Date?, exported: Date?, scenes: [Entry]) {
            schema = 1; format = CollectionArchive.format
            self.id = id; self.name = name; self.created = created; self.updated = updated; self.exported = exported; self.scenes = scenes
        }

        enum CodingKeys: String, CodingKey { case schema, format, id, name, created, updated, exported, scenes }

        /// Tolerant: a scene entry that can't be read is dropped; repeated scenes are kept once.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schema = ((try? c.decodeIfPresent(Int.self, forKey: .schema)) ?? nil) ?? 1
            format = ((try? c.decodeIfPresent(String.self, forKey: .format)) ?? nil) ?? CollectionArchive.format
            let rawID = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil)?.trimmingCharacters(in: .whitespaces) ?? ""
            id = SceneCollection.isValidID(rawID) ? rawID : ""
            name = SceneCollection.displayName(((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? "")
            created = (try? c.decodeIfPresent(Date.self, forKey: .created)) ?? nil
            updated = (try? c.decodeIfPresent(Date.self, forKey: .updated)) ?? nil
            exported = (try? c.decodeIfPresent(Date.self, forKey: .exported)) ?? nil
            let entries = ((try? c.decodeIfPresent([Lossy<Entry>].self, forKey: .scenes)) ?? nil) ?? []
            var seen = Set<String>()
            scenes = entries.compactMap(\.value).filter { seen.insert($0.id).inserted }
        }
    }

    /// "Night Skies.lpcollection": the name without characters that don't belong in a file name.
    public static func suggestedFileName(for name: String) -> String {
        var cleaned = SceneCollection.displayName(name).map { "/:\\".contains($0) ? "-" : $0 }.reduce(into: "") { $0.append($1) }
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "Collection" : String(cleaned.prefix(100))) + "." + fileExtension
    }

    /// The folder holding collection.json: `dir` itself, or its only subfolder that holds one
    /// (an archive made with its folder inside).
    static func locateRoot(in dir: URL, name: String) throws -> URL {
        if FileOps.isRegularFile(dir.appendingPathComponent(manifestName)) { return dir }
        let children = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let candidates = children.filter { $0.lastPathComponent != "__MACOSX" && FileOps.isRealDirectory($0)
            && FileOps.isRegularFile($0.appendingPathComponent(manifestName)) }
        guard candidates.count == 1, let only = candidates.first else {
            throw CollectionError.invalid("\(name) isn\u{2019}t a LivePaper collection (it has no \(manifestName)).")
        }
        return only
    }

    static func readManifest(in root: URL, name: String) throws -> Manifest {
        let url = root.appendingPathComponent(manifestName)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard FileOps.isRegularFile(url), size <= maxManifestBytes, let data = try? Data(contentsOf: url),
              var manifest = try? SceneManifest.decoder().decode(Manifest.self, from: data) else {
            throw CollectionError.invalid("\(name) isn\u{2019}t a LivePaper collection (its \(manifestName) can\u{2019}t be read).")
        }
        guard manifest.scenes.count <= maxScenes else {
            throw CollectionError.invalid("\(name) lists \(manifest.scenes.count) scenes; a collection holds at most \(maxScenes).")
        }
        if manifest.id.isEmpty { manifest.id = SceneCollection.newID() }
        return manifest
    }

    /// The package of a user scene inside the file, if the entry names a plain `scenes/<name>.lpscene`
    /// that is a real directory there (never a path out of the file, never a link).
    static func packageURL(_ entry: Entry, in root: URL) -> URL? {
        let relative = entry.package ?? "\(scenesDirectory)/\(entry.id).\(SceneManifest.packageExtension)"
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[0] == scenesDirectory, LibraryService.isPlainFileName(parts[1]),
              parts[1].lowercased().hasSuffix("." + SceneManifest.packageExtension) else { return nil }
        let url = root.appendingPathComponent(scenesDirectory).appendingPathComponent(parts[1])
        return FileOps.isRealDirectory(root.appendingPathComponent(scenesDirectory)) && FileOps.isRealDirectory(url) ? url : nil
    }
}
