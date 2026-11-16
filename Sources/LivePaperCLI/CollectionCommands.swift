// CollectionCommands — `livepaper collection …`: named, ordered sets of scenes (ARCHITECTURE §4.6, §9).
//
// A collection is named by its name (any letter case) or its id. Changing the collection the
// screen saver plays (`publish --collection`, the app's "Use as Screen Saver") republishes it when
// the saver is installed, so the saver follows the collection like it does from the app.
import Foundation
import LivePaperCore

enum CollectionCommands {
    struct Subcommand {
        var name: String
        var synopsis: String
        var run: ([String]) throws -> Int32
    }

    static let subcommands: [Subcommand] = [
        Subcommand(name: "list", synopsis: "[--json]", run: list),
        Subcommand(name: "show", synopsis: "<collection> [--json]", run: show),
        Subcommand(name: "new", synopsis: "<name> [<scene-id>…] [--json]", run: new),
        Subcommand(name: "rename", synopsis: "<collection> <new-name> [--json]", run: rename),
        Subcommand(name: "delete", synopsis: "<collection> [--json]", run: delete),
        Subcommand(name: "add", synopsis: "<collection> <scene-id>… [--at <position>] [--json]", run: add),
        Subcommand(name: "remove", synopsis: "<collection> <scene-id>… [--json]", run: remove),
        Subcommand(name: "move", synopsis: "<collection> <scene-id>… (--to <position> | --before <scene-id> | --after <scene-id>) [--json]",
                   run: move),
        Subcommand(name: "export", synopsis: "<collection> [--out <file.lpcollection>|<folder>] [--force] [--json]", run: export),
        Subcommand(name: "import", synopsis: "<file.lpcollection> [--merge|--copy] [--json]", run: importFile),
    ]

    static var all: [CLICommand] {
        let lines = subcommands.map { "\($0.name) \($0.synopsis)" }
        let synopsis = lines.first! + lines.dropFirst().map { "\n       livepaper collection " + $0 }.joined()
        return [CLICommand(name: "collection", synopsis: synopsis,
                           summary: "collections of scenes: list, show, new, rename, delete, add, remove, move, export, import",
                           run: run)]
    }

    static func run(_ argv: [String]) async throws -> Int32 {
        guard let name = argv.first else { throw UsageError("missing subcommand (list, show, new, rename, delete, add, remove, move, export, import)") }
        guard let sub = subcommands.first(where: { $0.name == name }) else {
            throw UsageError("unknown subcommand '\(name)' (list, show, new, rename, delete, add, remove, move, export, import)")
        }
        do {
            return try sub.run(Array(argv.dropFirst()))
        } catch let e as UsageError {
            stderr("livepaper collection \(sub.name): \(e.description)\nusage: livepaper collection \(sub.name) \(sub.synopsis)")
            return ExitCode.usage
        }
    }

    private static var services: LivePaperServices { CLIServices.live }

    // MARK: - JSON

    struct CollectionSummary: Encodable {
        var id: String
        var name: String
        /// In order, as stored (also scenes that aren't in the library any more).
        var scenes: [String]
        /// How many of them are in the library.
        var count: Int
        /// Scenes it names that the library doesn't have (they are skipped).
        var missing: [String]
        /// The screen saver plays this collection (publish --collection).
        var playing: Bool
        var created: Date?
        var updated: Date?

        init(_ c: SceneCollection, available: Set<String>, playing: String?) {
            id = c.id; name = c.name; scenes = c.sceneIDs
            count = c.sceneIDs.filter(available.contains).count
            missing = c.sceneIDs.filter { !available.contains($0) }
            self.playing = c.id == playing
            created = c.created; updated = c.updated
        }
    }

    struct EditSummary: Encodable {
        var collection: CollectionSummary
        var changed: [String]
        /// "updated" (republished), "stored" (settings only: no saver installed), "failed", or absent.
        var screenSaver: String?
    }

    // MARK: - Reading

    static func list(_ argv: [String]) throws -> Int32 {
        let args = try Arguments(argv, flags: ["json"])
        guard args.positional.isEmpty else { throw UsageError("list takes no arguments") }
        let all = services.collections.collections()
        let available = Set(try services.library.scenes().map(\.id))
        let playing = services.publish.loadSettings().collectionID
        if args.flag("json") {
            printJSONObject(all.map { CollectionSummary($0, available: available, playing: playing) })
            return ExitCode.ok
        }
        guard !all.isEmpty else {
            print("No collections yet. Create one with `livepaper collection new <name> [<scene-id>…]`.")
            return ExitCode.ok
        }
        let rows = all.map { c -> [String] in
            let n = c.existingSceneIDs(available: available).count
            return [c.id == playing ? "●" : " ", c.name, "\(n)", c.id]
        }
        printTable(header: [" ", "NAME", "SCENES", "ID"], rows: rows)
        print("\n\(all.count) collection\(all.count == 1 ? "" : "s")" + (playing != nil ? " · ● = the screen saver plays it" : ""))
        return ExitCode.ok
    }

    static func show(_ argv: [String]) throws -> Int32 {
        let args = try Arguments(argv, flags: ["json"])
        let c = try resolve(try args.single("collection"))
        let scenes = try services.library.scenes()
        let byID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let playing = services.publish.loadSettings().collectionID
        if args.flag("json") {
            struct Shown: Encodable {
                var collection: CollectionSummary
                var items: [LibraryCommands.SceneSummary]
            }
            printJSONObject(Shown(collection: CollectionSummary(c, available: Set(byID.keys), playing: playing),
                                  items: c.sceneIDs.compactMap { byID[$0] }.map { LibraryCommands.SceneSummary($0, inPlaylist: nil) }))
            return ExitCode.ok
        }
        let present = c.existingSceneIDs(available: Set(byID.keys))
        print("\u{201C}\(c.name)\u{201D} \u{00B7} \(present.count) scene\(present.count == 1 ? "" : "s") \u{00B7} id \(c.id)" +
              (c.id == playing ? " \u{00B7} the screen saver plays it" : ""))
        guard !present.isEmpty else {
            print("It's empty. Add scenes with `livepaper collection add \(shellQuoted(c.name)) <scene-id>…`.")
            return ExitCode.ok
        }
        let rows = present.enumerated().compactMap { i, id -> [String]? in
            guard let s = byID[id] else { return nil }
            return ["\(i + 1)", s.id, s.manifest.name, s.manifest.kind.rawValue, s.isBuiltin ? "built-in" : "yours"]
        }
        printTable(header: ["#", "ID", "NAME", "KIND", "SOURCE"], rows: rows)
        let gone = c.sceneIDs.filter { byID[$0] == nil }
        if !gone.isEmpty { print("\nnot in the library (skipped): " + gone.joined(separator: ", ")) }
        return ExitCode.ok
    }

    // MARK: - Changing

    static func new(_ argv: [String]) throws -> Int32 {
        let args = try Arguments(argv, flags: ["json"])
        guard let name = args.positional.first else { throw UsageError("missing collection name") }
        let scenes = Array(args.positional.dropFirst())
        try requireKnownScenes(scenes)
        let c = try services.collections.create(name: name, sceneIDs: scenes)
        if args.flag("json") {
            printJSONObject(try EditSummary(collection: summary(c), changed: c.sceneIDs, screenSaver: nil))
        } else {
            print("created \u{201C}\(c.name)\u{201D} (\(c.id)) with \(c.sceneIDs.count) scene\(c.sceneIDs.count == 1 ? "" : "s")")
        }
        return ExitCode.ok
    }

    static func rename(_ argv: [String]) throws -> Int32 {
        let args = try Arguments(argv, flags: ["json"])
        guard args.positional.count == 2 else { throw UsageError("expected the collection and its new name") }
        let c = try resolve(args.positional[0])
        let renamed = try services.collections.rename(id: c.id, to: args.positional[1])
        if args.flag("json") {
            printJSONObject(try EditSummary(collection: summary(renamed), changed: [], screenSaver: nil))
        } else {
            print(renamed.name == c.name ? "\u{201C}\(c.name)\u{201D} already has that name"
                                         : "renamed \u{201C}\(c.name)\u{201D} to \u{201C}\(renamed.name)\u{201D}")
        }
        return ExitCode.ok
    }

    static func delete(_ argv: [String]) throws -> Int32 {
        let args = try Arguments(argv, flags: ["json"])
        let c = try resolve(try args.single("collection"))
        try services.collections.delete(id: c.id)
        // The screen saver keeps playing what it played: the scenes the collection had, as a list.
        var settings = services.publish.loadSettings()
        let wasPlaying = settings.collectionID == c.id
        if wasPlaying {
            settings = settings.following([c])
            settings.collectionID = nil
            try services.publish.saveSettings(settings)
        }
        if args.flag("json") {
            printJSONObject(EditSummary(collection: CollectionSummary(c, available: [], playing: nil), changed: [],
                                        screenSaver: wasPlaying ? "stored" : nil))
        } else {
            print("deleted the collection \u{201C}\(c.name)\u{201D}; its \(c.sceneIDs.count) scene\(c.sceneIDs.count == 1 ? "" : "s") stay in the library")
            if wasPlaying { print("the screen saver keeps playing those scenes (it no longer follows a collection)") }
        }
        return ExitCode.ok
    }

    static func add(_ argv: [String]) throws -> Int32 {
        let args = try Arguments(argv, flags: ["json"], options: ["at"])
        guard args.positional.count >= 2 else { throw UsageError("expected the collection and at least one scene id") }
        let c = try resolve(args.positional[0])
        let scenes = Array(args.positional.dropFirst())
        try requireKnownScenes(scenes)
        var placement = CollectionPlacement.end
        if let at = try args.int("at") {
            guard at >= 1 else { throw UsageError("--at is a position from 1 (the first scene)") }
            placement = .index(at - 1)
        }
        let edit = try services.collections.add(scenes, to: c.id, at: placement)
        return try report(edit, verb: "added", to: "to", skippedNote: "already in it", requested: scenes, json: args.flag("json"))
    }

    static func remove(_ argv: [String]) throws -> Int32 {
        let args = try Arguments(argv, flags: ["json"])
        guard args.positional.count >= 2 else { throw UsageError("expected the collection and at least one scene id") }
        let c = try resolve(args.positional[0])
        let scenes = Array(args.positional.dropFirst())
        let edit = try services.collections.remove(scenes, from: c.id)
        return try report(edit, verb: "removed", to: "from", skippedNote: "not in it", requested: scenes, json: args.flag("json"))
    }

    static func move(_ argv: [String]) throws -> Int32 {
        let args = try Arguments(argv, flags: ["json"], options: ["to", "before", "after"])
        guard args.positional.count >= 2 else { throw UsageError("expected the collection and at least one scene id") }
        let c = try resolve(args.positional[0])
        let scenes = Array(args.positional.dropFirst())
        let given = [args.string("to"), args.string("before"), args.string("after")].compactMap { $0 }
        guard given.count == 1 else { throw UsageError("use one of --to <position>, --before <scene-id> or --after <scene-id>") }
        let placement: CollectionPlacement
        if let to = args.string("to") {
            switch to.lowercased() {
            case "first", "start": placement = .start
            case "last", "end": placement = .end
            default:
                guard let n = Int(to), n >= 1 else { throw UsageError("--to is a position from 1, or first / last") }
                placement = .index(n - 1)
            }
        } else if let before = args.string("before") {
            guard c.sceneIDs.contains(before) else { throw UsageError("\(before) isn't in \u{201C}\(c.name)\u{201D}") }
            placement = .before(before)
        } else {
            let after = args.string("after")!
            guard c.sceneIDs.contains(after) else { throw UsageError("\(after) isn't in \u{201C}\(c.name)\u{201D}") }
            placement = .after(after)
        }
        let unknown = scenes.filter { !c.sceneIDs.contains($0) }
        guard unknown.isEmpty else { throw UsageError("not in \u{201C}\(c.name)\u{201D}: \(unknown.joined(separator: ", "))") }
        let edit = try services.collections.move(scenes, in: c.id, to: placement)
        return try report(edit, verb: "moved", to: "in", skippedNote: nil, requested: scenes, json: args.flag("json"))
    }

    /// Prints what an edit did and, when the screen saver plays the collection, republishes it.
    private static func report(_ edit: CollectionEdit, verb: String, to preposition: String, skippedNote: String?,
                               requested: [String], json: Bool) throws -> Int32 {
        let (state, note) = edit.changed.isEmpty ? (nil, nil) : followUp(edit.collection)
        if json {
            printJSONObject(try EditSummary(collection: summary(edit.collection), changed: edit.changed, screenSaver: state))
        } else {
            let n = edit.changed.count
            print(n == 0 ? "nothing changed in \u{201C}\(edit.collection.name)\u{201D}"
                         : "\(verb) \(n) scene\(n == 1 ? "" : "s") \(preposition) \u{201C}\(edit.collection.name)\u{201D}")
            let skipped = CollectionOrder.unique(requested).filter { !edit.changed.contains($0) }
            if let skippedNote, !skipped.isEmpty { print("  \(skippedNote): " + skipped.joined(separator: ", ")) }
            if let note { print(note) }
        }
        return state == "failed" ? ExitCode.failed : ExitCode.ok
    }

    /// The screen saver follows the collection it plays: keep the stored settings' copy of its
    /// scenes current and publish again when a saver is installed. Returns what happened, for --json,
    /// and a line for people (nil, nil when the screen saver plays something else).
    static func followUp(_ c: SceneCollection) -> (state: String?, note: String?) {
        let publish = services.publish
        let settings = publish.loadSettings()
        guard settings.collectionID == c.id else { return (nil, nil) }
        let next = settings.following([c])
        do {
            if next != settings { try publish.saveSettings(next) }
            guard FileManager.default.fileExists(atPath: LPPaths.installedSaver.appendingPathComponent("Contents/Info.plist").path) else {
                return ("stored", "the screen saver plays this collection once it is installed")
            }
            let result = try publish.publishReport()
            for (id, why) in result.skipped.sorted(by: { $0.key < $1.key }) { stderr("  skipped \(id): \(why)") }
            return ("updated", "updated the screen saver, which plays this collection (generation \(result.playlist.generation))")
        } catch {
            stderr("livepaper collection: couldn't update the screen saver: \(error.localizedDescription)")
            return ("failed", nil)
        }
    }

    // MARK: - Export / import

    static func export(_ argv: [String]) throws -> Int32 {
        let args = try Arguments(argv, flags: ["json", "force"], options: ["out"])
        let c = try resolve(try args.single("collection"))
        let fm = FileManager.default
        var url = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(CollectionArchive.suggestedFileName(for: c.name))
        if let out = args.string("out") {
            let given = URL(fileURLWithPath: (out as NSString).expandingTildeInPath).standardizedFileURL
            var isDir: ObjCBool = false
            let folder = fm.fileExists(atPath: given.path, isDirectory: &isDir) && isDir.boolValue
                && given.pathExtension.lowercased() != CollectionArchive.fileExtension
            url = folder ? given.appendingPathComponent(CollectionArchive.suggestedFileName(for: c.name)) : given
        }
        if fm.fileExists(atPath: url.path) && !args.flag("force") {
            throw UsageError("\(displayPath(url)) already exists (--force replaces it)")
        }
        let result = try services.collections.export(id: c.id, to: url)
        if args.flag("json") {
            struct Exported: Encodable { var path: String; var collection: String; var scenes: [String]; var builtin: [String]; var missing: [String] }
            printJSONObject(Exported(path: url.path, collection: c.id, scenes: result.includedScenes, builtin: result.builtinScenes,
                                     missing: result.missingScenes))
        } else {
            print("exported \u{201C}\(c.name)\u{201D} to \(displayPath(url))")
            print("  \(result.includedScenes.count) of your scenes included" +
                  (result.builtinScenes.isEmpty ? "" : ", \(result.builtinScenes.count) built-in scene\(result.builtinScenes.count == 1 ? "" : "s") referenced by id"))
            if !result.missingScenes.isEmpty { print("  left out (not in the library): " + result.missingScenes.joined(separator: ", ")) }
        }
        return ExitCode.ok
    }

    static func importFile(_ argv: [String]) throws -> Int32 {
        let args = try Arguments(argv, flags: ["json", "merge", "copy"])
        let path = try args.single("collection file")
        if args.flag("merge") && args.flag("copy") { throw UsageError("use either --merge or --copy") }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw UsageError("\(path) doesn't exist") }
        let mode: CollectionImportMode = args.flag("merge") ? .merge : args.flag("copy") ? .copy : .automatic
        let result = try services.collections.importCollection(at: url, mode: mode)
        let (state, note) = result.added.isEmpty ? (nil, nil) : followUp(result.collection)
        let c = result.collection
        if args.flag("json") {
            struct Imported: Encodable {
                struct Missing: Encodable { var name: String; var reason: String }
                var outcome: String
                var collection: CollectionSummary
                var added: [String]
                var lacking: [String]
                var importedScenes: [String]
                var existingScenes: [String]
                var missing: [Missing]
                var screenSaver: String?
            }
            let outcome: String
            switch result.outcome {
            case .created: outcome = "created"
            case .merged: outcome = "merged"
            case .alreadyPresent: outcome = "alreadyPresent"
            }
            printJSONObject(try Imported(outcome: outcome, collection: summary(c), added: result.added, lacking: result.lacking,
                                         importedScenes: result.importedScenes.map(\.id), existingScenes: result.existingScenes,
                                         missing: result.missing.map { .init(name: $0.name, reason: $0.reason) }, screenSaver: state))
        } else {
            let n = result.importedScenes.count, had = result.existingScenes.count
            switch result.outcome {
            case .created:
                print("imported the collection \u{201C}\(c.name)\u{201D} (\(c.id)) with \(c.sceneIDs.count) scene\(c.sceneIDs.count == 1 ? "" : "s")")
                print("  \(n) new to your library, \(had) you already had")
            case .merged:
                print(result.added.isEmpty ? "\u{201C}\(c.name)\u{201D} already has every scene in \(url.lastPathComponent)"
                                           : "added \(result.added.count) scene\(result.added.count == 1 ? "" : "s") to \u{201C}\(c.name)\u{201D}")
                if n > 0 { print("  \(n) new to your library") }
            case .alreadyPresent:
                print("\u{201C}\(c.name)\u{201D} is already in your library (\(c.id))")
                if !result.lacking.isEmpty {
                    print("  \(url.lastPathComponent) has \(result.lacking.count) scene\(result.lacking.count == 1 ? "" : "s") it doesn't: " +
                          result.lacking.joined(separator: ", "))
                    print("  run again with --merge to add them, or --copy to import it as a separate collection")
                }
            }
            for m in result.missing { print("  couldn't add \u{201C}\(m.name)\u{201D}: \(m.reason)") }
            if let note { print(note) }
        }
        return state == "failed" ? ExitCode.failed : ExitCode.ok
    }

    // MARK: - Helpers

    /// The collection an argument names (name or id); a usage error when there is none.
    static func resolve(_ argument: String) throws -> SceneCollection {
        guard let c = try services.collections.find(argument) else {
            throw UsageError("there is no collection \u{201C}\(argument)\u{201D} (see `livepaper collection list`)")
        }
        return c
    }

    private static func requireKnownScenes(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let known = Set(try services.library.scenes().map(\.id))
        let unknown = CollectionOrder.unique(ids).filter { !known.contains($0) }
        guard unknown.isEmpty else {
            throw UsageError("unknown scene id\(unknown.count == 1 ? "" : "s"): \(unknown.joined(separator: ", ")) (see `livepaper list`)")
        }
    }

    private static func summary(_ c: SceneCollection) throws -> CollectionSummary {
        CollectionSummary(c, available: Set(try services.library.scenes().map(\.id)), playing: services.publish.loadSettings().collectionID)
    }
}
