// Self tests for collections (ARCHITECTURE §4.6): the ordering rules, tolerant decoding of
// collections.json, the store, the service's edits, a scene's delete cascading, the playlist following
// a collection, and .lpcollection export/import between two libraries (dedupe, clashing ids, merge
// and copy, hostile files). The app's side is in AppCollectionTests.swift, the CLI's in CLITests.swift.
import Foundation
import LivePaperCore

extension SelfTests {
    static var collections: [TestCase] { collectionModel + collectionService + collectionArchive }

    // MARK: - Ordering and decoding

    static var collectionModel: [TestCase] { [
        TestCase(name: "collections.order.add-remove-move") {
            let ids = ["a", "b", "c", "d", "e"]
            // Adding skips what is there and repeats; the placement is relative to the current order.
            var (out, added) = CollectionOrder.adding(["c", "x", "x", "y"], to: ids)
            try expectEqual(out, ["a", "b", "c", "d", "e", "x", "y"]); try expectEqual(added, ["x", "y"])
            (out, added) = CollectionOrder.adding(["x"], to: ids, at: .start)
            try expectEqual(out, ["x", "a", "b", "c", "d", "e"])
            (out, _) = CollectionOrder.adding(["x"], to: ids, at: .index(2))
            try expectEqual(out, ["a", "b", "x", "c", "d", "e"])
            (out, _) = CollectionOrder.adding(["x"], to: ids, at: .index(99))
            try expectEqual(out.last, "x")
            (out, _) = CollectionOrder.adding(["x"], to: ids, at: .before("c"))
            try expectEqual(out, ["a", "b", "x", "c", "d", "e"])
            (out, _) = CollectionOrder.adding(["x"], to: ids, at: .after("e"))
            try expectEqual(out.last, "x")
            (out, _) = CollectionOrder.adding(["x"], to: ids, at: .before("nope"))
            try expectEqual(out.last, "x")
            try expectEqual(CollectionOrder.adding(["a"], to: ids).added, [])
            // Removing reports only what was there.
            let removed = CollectionOrder.removing(["b", "zz", "d"], from: ids)
            try expectEqual(removed.ids, ["a", "c", "e"]); try expectEqual(removed.removed, ["b", "d"])
            // Moving keeps the moved scenes' relative order, measured against the others.
            try expectEqual(CollectionOrder.moving(["d"], in: ids, to: .start), ["d", "a", "b", "c", "e"])
            try expectEqual(CollectionOrder.moving(["a"], in: ids, to: .end), ["b", "c", "d", "e", "a"])
            try expectEqual(CollectionOrder.moving(["e", "b"], in: ids, to: .index(0)), ["b", "e", "a", "c", "d"])
            try expectEqual(CollectionOrder.moving(["a"], in: ids, to: .index(2)), ["b", "c", "a", "d", "e"])
            try expectEqual(CollectionOrder.moving(["a", "b"], in: ids, to: .after("d")), ["c", "d", "a", "b", "e"])
            try expectEqual(CollectionOrder.moving(["e"], in: ids, to: .before("b")), ["a", "e", "b", "c", "d"])
            // Relative to one of themselves, or nothing that is in the list: no change.
            try expectEqual(CollectionOrder.moving(["b", "c"], in: ids, to: .before("c")), ids)
            try expectEqual(CollectionOrder.moving(["zz"], in: ids, to: .start), ids)
            try expectEqual(CollectionOrder.unique(["a", "b", "a", "c", "b"]), ["a", "b", "c"])
        },
        TestCase(name: "collections.order.drop-placement") {
            // Grid drag and drop: dropped on a card, the dragged scenes take its place.
            let ids = ["a", "b", "c", "d", "e"]
            func drop(_ moving: [String], onto target: String) -> [String] {
                CollectionOrder.moving(moving, in: ids, to: CollectionOrder.dropPlacement(moving: moving, onto: target, in: ids))
            }
            try expectEqual(drop(["a"], onto: "b"), ["b", "a", "c", "d", "e"])   // forward onto the neighbour: swap
            try expectEqual(drop(["b"], onto: "a"), ["b", "a", "c", "d", "e"])   // back onto the neighbour: swap
            try expectEqual(drop(["a"], onto: "e"), ["b", "c", "d", "e", "a"])   // forward to the last card: the end
            try expectEqual(drop(["e"], onto: "a"), ["e", "a", "b", "c", "d"])   // back to the first card: the start
            try expectEqual(drop(["b", "d"], onto: "e"), ["a", "c", "e", "b", "d"])
            try expectEqual(drop(["b", "e"], onto: "c"), ["a", "b", "e", "c", "d"]) // mixed directions: before it
            try expectEqual(drop(["c"], onto: "c"), ids)
            try expectEqual(CollectionOrder.dropPlacement(moving: ["x"], onto: "c", in: ids), .before("c"))   // from outside
            try expectEqual(CollectionOrder.dropPlacement(moving: ["a"], onto: "gone", in: ids), .end)
        },
        TestCase(name: "collections.decode.tolerant") {
            let json = """
            {"schema": 7, "future": {"x": 1}, "collections": [
              {"id": "11111111-aaaa-4000-8000-000000000001", "name": "  Night Skies  ", "scenes": ["aurora", 42, "Bad Id", "aurora", "orbit", null],
               "created": "2026-11-10T08:00:00Z", "updated": "yesterday", "colour": "blue"},
              {"name": "No Id", "scenes": "not a list"},
              {"id": "11111111-aaaa-4000-8000-000000000001", "name": "Duplicate id"},
              {"id": "../etc", "name": ""},
              "not a collection",
              {"id": 5, "name": "No Id"}
            ]}
            """
            let file = try CollectionsFile.decode(Data(json.utf8))
            try expectEqual(file.collections.count, 5)
            let night = file.collections[0]
            try expectEqual(night.id, "11111111-aaaa-4000-8000-000000000001")
            try expectEqual(night.name, "Night Skies")
            try expectEqual(night.sceneIDs, ["aurora", "orbit"])
            try expectEqual(night.created, ISO8601DateFormatter().date(from: "2026-11-10T08:00:00Z"))
            try expect(night.updated == nil)
            // No usable id: one derived from the name, the same on every read; repeats made unique.
            try expectEqual(file.collections[1].id, "c-no-id"); try expectEqual(file.collections[1].sceneIDs, [])
            try expectEqual(file.collections[2].id, "11111111-aaaa-4000-8000-000000000001-2")
            try expectEqual(file.collections[3].name, SceneCollection.defaultName)
            try expectEqual(file.collections[3].id, "c-untitled-collection")
            try expectEqual(file.collections[4].id, "c-no-id-2")
            try expectEqual(try CollectionsFile.decode(Data(json.utf8)), file)
            // Written back: the current schema, the known fields.
            try expectEqual(file.schema, 7)   // as read (a newer LivePaper's file)
            let round = try CollectionsFile.decode(try file.encoded())
            try expectEqual(round.collections, file.collections)
            try expectEqual(round.schema, CollectionsFile.currentSchema)
            // A bare array is read too; so is an empty object.
            try expectEqual(try CollectionsFile.decode(Data(#"[{"id":"x1","name":"A","scenes":["a"]}]"#.utf8)).collections.map(\.sceneIDs), [["a"]])
            try expectEqual(try CollectionsFile.decode(Data("{}".utf8)).collections, [])
            // Names: one line, trimmed, capped; uniqueness ignores case and accents.
            try expectEqual(SceneCollection.displayName("Night\nSkies "), "Night Skies")
            try expectEqual(SceneCollection.displayName(String(repeating: "x", count: 500)).count, SceneCollection.maxNameLength)
            try expectEqual(SceneCollection.nameKey("Café Nights"), SceneCollection.nameKey(" cafe NIGHTS"))
            try expectEqual(SceneCollection.uniqueName("Night Skies", existing: ["night skies"]), "Night Skies 2")
            try expectEqual(SceneCollection.uniqueName("Night Skies 2", existing: ["Night Skies", "Night Skies 2"]), "Night Skies 3")
            try expectEqual(SceneCollection.uniqueName("Calm", existing: ["Night Skies"]), "Calm")
            try expect(SceneCollection.isValidID(SceneCollection.newID()))
            try expect(!SceneCollection.isValidID("a/b") && !SceneCollection.isValidID("") && !SceneCollection.isValidID(String(repeating: "a", count: 65)))
        },
        TestCase(name: "collections.playlist.following") {
            let night = SceneCollection(id: "n1", name: "Night", sceneIDs: ["b", "a"])
            var s = PlaylistSettings(mode: .sequence, sceneIDs: ["a"], collectionID: "n1")
            try expectEqual(s.following([night]).sceneIDs, ["b", "a"])
            // A collection that's gone: the stored copy.
            try expectEqual(s.following([]).sceneIDs, ["a"])
            s.collectionID = nil
            try expectEqual(s.following([night]), s)
            // Tolerant: a missing, malformed or blank collectionID is no collection; the rest is kept.
            let decoded = try JSONDecoder().decode(PlaylistSettings.self, from: Data(#"{"mode":"sequence","sceneIDs":["a"],"collectionID":"n1"}"#.utf8))
            try expectEqual(decoded.collectionID, "n1"); try expectEqual(decoded.mode, .sequence)
            for bad in [#"{"collectionID": 5}"#, #"{"collectionID": "  "}"#, #"{"collectionID": "../x"}"#, #"{"collectionID": null}"#] {
                let settings = try JSONDecoder().decode(PlaylistSettings.self, from: Data(bad.utf8))
                try expect(settings.collectionID == nil, bad)
            }
            let encoded = String(decoding: try JSONEncoder().encode(PlaylistSettings()), as: UTF8.self)
            try expect(!encoded.contains("collectionID"), "absent unless set: \(encoded)")
        },
        TestCase(name: "collections.store.atomic-and-unreadable") {
            let dir = try tempDir("collections-store")
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent(CollectionsFile.fileName)
            let store = CollectionStore(fileURL: url)
            try expectEqual(store.load().collections, [])
            try store.update { $0.collections.append(SceneCollection(id: "c1", name: "One")) }
            try expectEqual(store.load().collections.map(\.name), ["One"])
            // An edit that changes nothing doesn't write.
            let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            usleep(20_000)
            try store.update { _ in }
            try expectEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, before)
            // Unreadable: reads as empty, left alone by no-op edits, set aside (not lost) by the next change.
            try Data("{ this isn't json".utf8).write(to: url)
            try expectEqual(store.load().collections, [])
            try store.update { _ in }
            try expectEqual(try String(contentsOf: url, encoding: .utf8), "{ this isn't json")
            try store.update { $0.collections.append(SceneCollection(id: "c2", name: "Two")) }
            try expectEqual(store.load().collections.map(\.id), ["c2"])
            let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("collections.unreadable-") }
            try expectEqual(aside.count, 1)
            try expectEqual(try String(contentsOf: dir.appendingPathComponent(aside[0]), encoding: .utf8), "{ this isn't json")
            // A body that throws writes nothing.
            struct Stop: Error {}
            do { try store.update { $0.collections = []; throw Stop() } } catch is Stop {}
            try expectEqual(store.load().collections.map(\.id), ["c2"])
        },
    ] }

    // MARK: - Service

    static var collectionService: [TestCase] { [
        TestCase(name: "collections.service.edit") {
            try CoreSandbox.with("collections-edit") { sb in
                let lib = sb.makeLibrary()
                let mine = try lib.createWebScene(name: "Mine", description: "")
                let service = CollectionService(library: lib, store: CollectionStore(fileURL: sb.support.appendingPathComponent("collections.json")))
                let night = try service.create(name: " Night Skies ", sceneIDs: ["aurora", mine.id, "aurora"])
                try expectEqual(night.name, "Night Skies")
                try expectEqual(night.sceneIDs, ["aurora", "mine"])
                try expect(night.created != nil && night.created == night.updated)
                try expectCollectionError(.nameTaken("night skies")) { try service.create(name: "night skies", sceneIDs: []) }
                try expectCollectionError(.unknownScenes(["nope"])) { try service.create(name: "Other", sceneIDs: ["nope", "zen"]) }
                let calm = try service.create(name: "Calm", sceneIDs: [])
                try expectEqual(service.collections().map(\.name), ["Calm", "Night Skies"])

                // add / remove / move report what changed.
                var edit = try service.add(["zen", "aurora", "orbit"], to: night.id)
                try expectEqual(edit.changed, ["zen", "orbit"])
                try expectEqual(edit.collection.sceneIDs, ["aurora", "mine", "zen", "orbit"])
                edit = try service.add(["waves"], to: night.id, at: .index(1))
                try expectEqual(edit.collection.sceneIDs, ["aurora", "waves", "mine", "zen", "orbit"])
                try expectCollectionError(.unknownScenes(["ghost"])) { try service.add(["ghost"], to: night.id) }
                edit = try service.move(["orbit"], in: night.id, to: .start)
                try expectEqual(edit.collection.sceneIDs, ["orbit", "aurora", "waves", "mine", "zen"]); try expectEqual(edit.changed, ["orbit"])
                try expectEqual(try service.move(["orbit"], in: night.id, to: .start).changed, [])
                edit = try service.remove(["waves", "nope"], from: night.id)
                try expectEqual(edit.changed, ["waves"])
                try expectCollectionError(.notFound("missing")) { try service.add(["zen"], to: "missing") }

                // rename keeps the id; a taken name is refused; the same name changes nothing.
                let renamed = try service.rename(id: night.id, to: "Night Sky")
                try expectEqual(renamed.id, night.id)
                try expectCollectionError(.nameTaken("CALM")) { try service.rename(id: night.id, to: "CALM") }
                try expectEqual(try service.rename(id: calm.id, to: "calm").name, "calm")

                // find: id, name (any case), a unique id prefix; ambiguous names say so.
                try expectEqual(try service.find(night.id)?.id, night.id)
                try expectEqual(try service.find("night SKY")?.id, night.id)
                try expectEqual(try service.find(String(night.id.prefix(8)))?.id, night.id)
                let short = try service.find("nig"), blank = try service.find("")
                try expect(short == nil && blank == nil)
                try service.store.update { $0.collections.append(SceneCollection(id: "dup-1", name: "Night Sky")) }
                do { _ = try service.find("night sky"); throw TestFailure(description: "expected ambiguous") } catch CollectionError.ambiguous(_, let ids) {
                    try expectEqual(Set(ids), [night.id, "dup-1"])
                }

                // Deleting a collection never deletes its scenes.
                let deleted = try service.delete(id: night.id)
                try expectEqual(deleted.sceneIDs, ["orbit", "aurora", "mine", "zen"])
                try expect(service.collection(id: night.id) == nil)
                let kept = try lib.scene(id: "mine")
                try expect(kept != nil, "the scene stays")
                try expectCollectionError(.notFound(night.id)) { try service.delete(id: night.id) }
            }
        },
        TestCase(name: "collections.service.scene-delete-cascades") {
            try CoreSandbox.with("collections-cascade") { sb in
                let lib = sb.makeLibrary()
                let a = try lib.createWebScene(name: "A", description: ""), b = try lib.createWebScene(name: "B", description: "")
                let service = CollectionService(library: lib, store: CollectionStore(fileURL: sb.support.appendingPathComponent("collections.json")))
                let one = try service.create(name: "One", sceneIDs: [a.id, b.id, "zen"])
                let two = try service.create(name: "Two", sceneIDs: [b.id])
                let three = try service.create(name: "Three", sceneIDs: ["zen"])
                try lib.delete(id: b.id)
                let changed = try service.removeSceneEverywhere(b.id)
                try expectEqual(Set(changed.map(\.id)), [one.id, two.id])
                try expectEqual(service.collection(id: one.id)?.sceneIDs, [a.id, "zen"])
                try expectEqual(service.collection(id: two.id)?.sceneIDs, [])
                try expectEqual(service.collection(id: three.id)?.updated, three.updated)   // untouched
                try expectEqual(try service.removeSceneEverywhere("never-there"), [])
                // A scene removed some other way (Finder) is skipped where collections are used, and is
                // back if the scene is: the id stays.
                try FileManager.default.moveItem(at: a.packageURL, to: sb.root.appendingPathComponent("trash-a.lpscene"))
                let available = Set(try lib.scenes().map(\.id))
                try expectEqual(service.collection(id: one.id)?.existingSceneIDs(available: available), ["zen"])
                try FileManager.default.moveItem(at: sb.root.appendingPathComponent("trash-a.lpscene"), to: a.packageURL)
                try expectEqual(service.collection(id: one.id)?.existingSceneIDs(available: Set(try lib.scenes().map(\.id))), [a.id, "zen"])
            }
        },
        TestCase(name: "collections.publish.follows-collection") {
            try CoreSandbox.with("collections-publish") { sb in
                let lib = sb.makeLibrary()
                let store = CollectionStore(fileURL: sb.support.appendingPathComponent("collections.json"))
                let service = CollectionService(library: lib, store: store)
                let publish = PublishService(library: lib, compiler: CollectionTestCompiler(), settingsURL: sb.support.appendingPathComponent("playlist-settings.json"),
                                             saverURL: sb.saver, lockURL: sb.support.appendingPathComponent("publish.lock"), notify: { _ in },
                                             collections: store)
                try sb.installFakeSaver()
                let c = try service.create(name: "Pair", sceneIDs: ["zen", "orbit"])
                // The stored copy of the scenes is stale on purpose: publish plays the collection as it is.
                try publish.saveSettings(PlaylistSettings(mode: .sequence, sceneIDs: ["aurora"], collectionID: c.id))
                try expectEqual(try publish.publish().scenes.map(\.id), ["zen", "orbit"])
                try service.add(["waves"], to: c.id, at: .start)
                try expectEqual(try publish.publish().scenes.map(\.id), ["waves", "zen", "orbit"])
                // Empty: every scene plays (never a blank screen saver), like an empty selection.
                try service.remove(["waves", "zen", "orbit"], from: c.id)
                try expectEqual(try publish.publish().scenes.count, try lib.scenes().count)
                // Gone: the stored copy plays.
                try service.delete(id: c.id)
                try expectEqual(try publish.publish().scenes.map(\.id), ["aurora"])
            }
        },
    ] }

    // MARK: - Export / import

    /// Two libraries on one Mac: A exports, B imports. B has its own built-ins (fewer: "zen" only)
    /// and its own scenes, some with A's ids.
    final class TwoLibraries {
        let sb: CoreSandbox
        let a: LibraryService, b: LibraryService
        let aCollections: CollectionService, bCollections: CollectionService
        var out: URL { sb.root.appendingPathComponent("out") }

        init(_ sb: CoreSandbox) throws {
            self.sb = sb
            let bBuiltins = sb.root.appendingPathComponent("b-builtins")
            try sb.writeWebScene(in: bBuiltins, id: "zen", name: "Zen")
            a = sb.makeLibrary()
            b = LibraryService(libraryDirectory: sb.root.appendingPathComponent("b-library"), builtinDirectory: bBuiltins, templateDirectory: sb.template)
            aCollections = CollectionService(library: a, store: CollectionStore(fileURL: sb.root.appendingPathComponent("a-collections.json")))
            bCollections = CollectionService(library: b, store: CollectionStore(fileURL: sb.root.appendingPathComponent("b-collections.json")))
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        }

        /// A user scene with its own code, so no two are the same scene.
        @discardableResult
        func scene(_ library: LibraryService, _ name: String, js: String) throws -> SceneItem {
            let item = try library.createWebScene(name: name, description: "")
            try Data("LivePaper.scene({ draw(lp) { /* \(js) */ } });\n".utf8).write(to: item.packageURL.appendingPathComponent("scene.js"))
            return item
        }
    }

    static var collectionArchive: [TestCase] { [
        TestCase(name: "collections.archive.round-trip-dedupe") {
            try CoreSandbox.with("collections-archive") { sb in
                let t = try TwoLibraries(sb)
                let glow = try t.scene(t.a, "Glow", js: "glow from A")
                let ember = try t.scene(t.a, "Ember", js: "ember from A")
                let gone = try t.scene(t.a, "Gone", js: "deleted before export")
                let night = try t.aCollections.create(name: "Night Skies", sceneIDs: [ember.id, "zen", glow.id, "aurora", gone.id])
                try t.a.delete(id: gone.id)   // outside LivePaper's cascade: the id stays, export leaves it out

                let file = t.out.appendingPathComponent(CollectionArchive.suggestedFileName(for: night.name))
                try expectEqual(file.lastPathComponent, "Night Skies.lpcollection")
                let export = try t.aCollections.export(id: night.id, to: file)
                try expectEqual(export.includedScenes, [ember.id, glow.id])
                try expectEqual(export.builtinScenes, ["zen", "aurora"])
                try expectEqual(export.missingScenes, [gone.id])
                // One zip file: collection.json and scenes/ at its root, no checks or thumbnails' clutter.
                try expect(FileManager.default.fileExists(atPath: file.path) && !isDirectory(file))
                let unzipped = try unzip(file, in: sb.root)
                try expectEqual(children(unzipped), ["collection.json", "scenes"])
                try expectEqual(children(unzipped.appendingPathComponent("scenes")), ["ember.lpscene", "glow.lpscene"])
                let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: unzipped.appendingPathComponent("collection.json"))) as? [String: Any]
                try expectEqual(manifest?["format"] as? String, "livepaper-collection")
                try expectEqual(manifest?["id"] as? String, night.id)
                try expectEqual((manifest?["scenes"] as? [[String: Any]])?.map { $0["id"] as? String ?? "" }, ["ember", "zen", "glow", "aurora"])

                // B: an unrelated "Glow" with A's id, an identical copy of A's Ember under another id,
                // and a collection that already has the name.
                let bGlow = try t.scene(t.b, "Glow", js: "glow from B")
                let emberCopy = try t.b.importPackage(at: ember.packageURL)
                try expectEqual(emberCopy.id, "ember")
                var m = emberCopy.manifest; m.name = "My Ember"; try t.b.update(m)
                _ = try t.bCollections.create(name: "night skies", sceneIDs: [bGlow.id])

                let first = try t.bCollections.importCollection(at: file)
                try expectEqual(first.outcome, .created)
                try expectEqual(first.collection.id, night.id)   // the id travels with the file
                try expectEqual(first.collection.name, "Night Skies 2")
                // Ember is B's own copy (same contents), Glow came in next to B's ("glow-2"), Aurora isn't a
                // built-in of B's LivePaper.
                try expectEqual(first.collection.sceneIDs, ["ember", "zen", "glow-2"])
                try expectEqual(first.importedScenes.map(\.id), ["glow-2"])
                try expectEqual(Set(first.existingScenes), ["ember", "zen"])
                try expectEqual(first.missing.map(\.name), ["Aurora"])
                try expect(first.missing[0].reason.contains("built-in"), first.missing[0].reason)
                try expectEqual(try t.b.scene(id: bGlow.id)?.manifest.name, "Glow")   // B's own Glow is untouched
                let glow2 = try unwrap(try t.b.scene(id: "glow-2"))
                let glow2JS = try String(contentsOf: glow2.packageURL.appendingPathComponent("scene.js"), encoding: .utf8)
                try expect(glow2JS.contains("glow from A"), glow2JS)

                // Again: nothing imported, nothing changed.
                let countBefore = try t.b.scenes().count
                let again = try t.bCollections.importCollection(at: file)
                try expectEqual(again.outcome, .alreadyPresent)
                try expectEqual(again.lacking, [])
                try expectEqual(try t.b.scenes().count, countBefore)
                try expectEqual(t.bCollections.collections().count, 2)

                // After removing a scene there, a re-import doesn't put it back on its own …
                try t.bCollections.remove(["glow-2"], from: night.id)
                let lacking = try t.bCollections.importCollection(at: file)
                try expectEqual(lacking.outcome, .alreadyPresent)
                try expectEqual(lacking.lacking, ["Glow"])
                try expectEqual(t.bCollections.collection(id: night.id)?.sceneIDs, ["ember", "zen"])
                // … merging adds what it lacks (at the end, reusing the scene imported before) …
                let merged = try t.bCollections.importCollection(at: file, mode: .merge)
                try expectEqual(merged.outcome, .merged)
                try expectEqual(merged.added, ["glow-2"])
                try expectEqual(merged.importedScenes, [])
                try expectEqual(merged.collection.sceneIDs, ["ember", "zen", "glow-2"])
                try expectEqual(try t.b.scenes().count, countBefore)
                // … and a copy is a separate collection with the same scenes.
                let copy = try t.bCollections.importCollection(at: file, mode: .copy)
                try expectEqual(copy.outcome, .created)
                try expect(copy.collection.id != night.id)
                try expectEqual(copy.collection.name, "Night Skies 3")
                try expectEqual(copy.collection.sceneIDs, ["ember", "zen", "glow-2"])
                try expectEqual(try t.b.scenes().count, countBefore)

                // Back into A, after A deleted the collection: same scenes, same id, nothing new.
                try t.aCollections.delete(id: night.id)
                let home = try t.aCollections.importCollection(at: file)
                try expectEqual(home.outcome, .created)
                try expectEqual(home.collection.id, night.id)
                try expectEqual(home.collection.sceneIDs, [ember.id, "zen", glow.id, "aurora"])
                try expectEqual(home.importedScenes, [])

                // An unpacked collection (a folder) imports the same way.
                try t.aCollections.delete(id: night.id)
                try expectEqual(try t.aCollections.importCollection(at: unzipped).collection.sceneIDs, [ember.id, "zen", glow.id, "aurora"])
                // Exporting over an existing file replaces it; onto a plain folder is refused.
                _ = try t.aCollections.export(id: night.id, to: file)
                try expectCollectionError(nil) { try t.aCollections.export(id: night.id, to: t.out) }
            }
        },
        TestCase(name: "collections.archive.hostile-and-broken") {
            try CoreSandbox.with("collections-hostile") { sb in
                let t = try TwoLibraries(sb)
                let fm = FileManager.default
                // Not a collection at all.
                let junk = t.out.appendingPathComponent("junk.lpcollection")
                try Data("hello".utf8).write(to: junk)
                try expectCollectionError(nil) { _ = try t.bCollections.importCollection(at: junk) }
                let empty = t.out.appendingPathComponent("empty")
                try fm.createDirectory(at: empty, withIntermediateDirectories: true)
                try expectCollectionError(nil) { _ = try t.bCollections.importCollection(at: empty) }
                try expectCollectionError(nil) { _ = try t.bCollections.importCollection(at: t.out.appendingPathComponent("nothing-here")) }

                // Hand-made: paths out of the file, a link, a broken entry, a broken package, a good one.
                let dir = t.out.appendingPathComponent("hand-made")
                let scenes = dir.appendingPathComponent("scenes")
                try sb.writeWebScene(in: scenes, id: "fine", name: "Fine", js: "LivePaper.scene({ draw(lp) { /* fine */ } });\n")
                try sb.writeWebScene(in: sb.root, id: "outside", name: "Outside", js: "LivePaper.scene({ draw(lp) { /* outside */ } });\n")
                try fm.createSymbolicLink(at: scenes.appendingPathComponent("linked.lpscene"), withDestinationURL: sb.root.appendingPathComponent("outside.lpscene"))
                try fm.createDirectory(at: scenes.appendingPathComponent("broken.lpscene"), withIntermediateDirectories: true)
                try Data("""
                {"schema": 1, "id": "7e57c011-0000-4000-8000-000000000001", "name": "Hand Made", "scenes": [
                  {"id": "escape", "name": "Escape", "package": "scenes/../../outside.lpscene"},
                  {"id": "absolute", "name": "Absolute", "package": "\(sb.root.path)/outside.lpscene"},
                  {"id": "linked", "name": "Linked", "package": "scenes/linked.lpscene"},
                  {"id": "Not An Id", "name": "Bad"},
                  {"id": "broken", "name": "Broken"},
                  {"id": "fine", "name": "Fine"},
                  {"id": "fine", "name": "Fine again"}
                ]}
                """.utf8).write(to: dir.appendingPathComponent("collection.json"))
                let result = try t.bCollections.importCollection(at: dir)
                try expectEqual(result.collection.sceneIDs, ["fine"])
                try expectEqual(result.missing.map(\.name), ["Escape", "Absolute", "Linked", "Broken"])
                let outside = try t.b.scene(id: "outside")
                try expect(outside == nil, "nothing from outside the file")
                try expectEqual(try t.b.scenes().filter { !$0.isBuiltin }.map(\.id), ["fine"])

                // Every scene failing is an error, not an empty collection.
                try Data(#"{"id": "7e57c011-0000-4000-8000-000000000002", "name": "Nothing", "scenes": [{"id": "broken"}]}"#.utf8)
                    .write(to: dir.appendingPathComponent("collection.json"))
                try expectCollectionError(nil) { _ = try t.bCollections.importCollection(at: dir) }
                // An empty collection is fine.
                try Data(#"{"name": "Empty", "scenes": []}"#.utf8).write(to: dir.appendingPathComponent("collection.json"))
                let none = try t.bCollections.importCollection(at: dir)
                try expectEqual(none.collection.name, "Empty"); try expectEqual(none.collection.sceneIDs, [])
                try expect(SceneCollection.isValidID(none.collection.id))
            }
        },
    ] }
}

/// Compiles by wrapping scene.js in a page.
final class CollectionTestCompiler: SceneCompiling, @unchecked Sendable {
    func compile(package: URL, to output: URL) throws {
        let js = try String(contentsOf: package.appendingPathComponent("scene.js"), encoding: .utf8)
        try Data("<!doctype html><script>\(js)</script>".utf8).write(to: output)
    }
}

/// `body` throws a CollectionError (equal to `expected`, when given).
func expectCollectionError(_ expected: CollectionError?, file: String = #fileID, line: Int = #line, _ body: () throws -> Void) throws {
    do { try body() } catch let error as CollectionError {
        if let expected { try expect(error == expected, "threw \(error), expected \(expected)", file: file, line: line) }
        return
    } catch {
        throw TestFailure(description: "\(file):\(line) threw \(error), expected a CollectionError")
    }
    throw TestFailure(description: "\(file):\(line) didn't throw")
}

private func children(_ url: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted() }
private func isDirectory(_ url: URL) -> Bool { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue }

/// Unpacks a zip with ditto into a new folder under `dir`.
private func unzip(_ zip: URL, in dir: URL) throws -> URL {
    let out = dir.appendingPathComponent("unzipped-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let result = try SystemCommandRunner().run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path], timeout: 60)
    guard result.succeeded else { throw TestFailure(description: "ditto: \(result.stderr)") }
    return out
}
