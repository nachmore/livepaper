// Self tests for collections in the app: multi-selection in a grid, the "Add to Collection ▸"
// rules and the banners' wording, the Screen Saver screen's sources, the full-screen order, the disk
// watcher, and AppModel over the mock services (seeded with MockSampleData.collections()).
import Foundation
import LivePaperCore

extension SelfTests {
    static var appCollections: [TestCase] { appCollectionLogic + appCollectionModel }

    private static let night = MockSampleData.nightSkiesID, calm = MockSampleData.calmWaterID, warm = MockSampleData.warmToneID

    // MARK: - Logic

    static var appCollectionLogic: [TestCase] { [
        TestCase(name: "app.collections.selection") {
            let order = ["a", "b", "c", "d", "e"]
            var s = LibrarySelection()
            try expectEqual(LibrarySelection.Click(command: true, shift: false), .toggle)
            try expectEqual(LibrarySelection.Click(command: false, shift: true), .extend)
            try expectEqual(LibrarySelection.Click(command: true, shift: true), .extend)
            try expectEqual(LibrarySelection.Click(command: false, shift: false), .plain)
            // ⌘-click toggles; ⇧-click adds the range from the last card clicked.
            try expectEqual(s.click("b", .toggle, order: order), .changed)
            try expectEqual(s.click("d", .extend, order: order), .changed)
            try expectEqual(s.ordered(order), ["b", "c", "d"])
            _ = s.click("c", .toggle, order: order)
            try expectEqual(s.ordered(order), ["b", "d"])
            _ = s.click("a", .extend, order: order)   // from c (the last clicked) back to a
            try expectEqual(s.ordered(order), ["a", "b", "c", "d"])
            // ⇧-click without a start: just that card.
            var fresh = LibrarySelection()
            _ = fresh.click("e", .extend, order: order)
            try expectEqual(fresh.ordered(order), ["e"])
            // A drag or menu of a selected card acts on the selection; of another card, on that card.
            try expectEqual(s.targets(for: "c", order: order), ["a", "b", "c", "d"])
            try expectEqual(s.targets(for: "e", order: order), ["e"])
            // Cards that are no longer shown leave it.
            s.retain(["a", "c", "e"])
            try expectEqual(s.ordered(order), ["a", "c"])
            s.selectAll(order)
            try expectEqual(s.count, 5)
            // A plain click opens the card and ends the selection.
            try expectEqual(s.click("b", .plain, order: order), .open("b"))
            try expect(s.isEmpty)
            var one = LibrarySelection()
            _ = one.click("b", .toggle, order: order)
            try expectEqual(one.targets(for: "b", order: order), ["b"])
        },
        TestCase(name: "app.collections.menu-and-text") {
            let c = SceneCollection(id: "c", name: "Night Skies", sceneIDs: ["a", "b"])
            try expectEqual(CollectionMembership(["a"], in: c), .all)
            try expectEqual(CollectionMembership(["a", "b"], in: c), .all)
            try expectEqual(CollectionMembership(["a", "x"], in: c), .some)
            try expectEqual(CollectionMembership(["x"], in: c), .none)
            try expectEqual(CollectionMembership([], in: c), .none)
            try expect(CollectionMembership(["a"], in: c).choosingRemoves && !CollectionMembership(["a", "x"], in: c).choosingRemoves)
            try expectEqual(CollectionText.defaultNewName(existing: []), "New Collection")
            try expectEqual(CollectionText.defaultNewName(existing: ["new collection", "New Collection 2"]), "New Collection 3")
            try expectEqual(CollectionText.validatedName("  Calm  "), "Calm")
            try expect(CollectionText.validatedName("   ") == nil)
            try expect(CollectionText.isTaken("NIGHT SKIES", in: [c]) && !CollectionText.isTaken("Night Skies", in: [c], except: "c"))
            try expectEqual(CollectionText.added(["a"], to: "Night Skies", names: ["a": "Aurora"]), "Added \u{201C}Aurora\u{201D} to \u{201C}Night Skies\u{201D}")
            try expectEqual(CollectionText.added(["a", "b", "x"], to: "Night Skies", names: [:]), "Added 3 scenes to \u{201C}Night Skies\u{201D}")
            try expectEqual(CollectionText.removedFromCollections([]), nil)
            try expectEqual(CollectionText.removedFromCollections([c]), "It was also removed from \u{201C}Night Skies\u{201D}.")
            let calm = SceneCollection(id: "d", name: "Calm", sceneIDs: [])
            try expectEqual(CollectionText.removedFromCollections([c, calm]), "It was also removed from \u{201C}Calm\u{201D} and \u{201C}Night Skies\u{201D}.")
            try expectEqual(CollectionText.removedFromCollections([c, calm, c]), "It was also removed from 3 collections.")
            try expectEqual(CollectionText.deleteSubtitle(c, sceneCount: 2), "Its 2 scenes stay in your library.")
            try expectEqual(CollectionText.deleteSubtitle(c, sceneCount: 1), "Its scene stays in your library.")
            // Import banners.
            var result = CollectionImport(outcome: .created, collection: c, added: ["a", "b"],
                                          importedScenes: [SceneItem(manifest: SceneManifest(id: "a", name: "A", kind: .web), packageURL: URL(fileURLWithPath: "/x/a.lpscene"), isBuiltin: false)],
                                          existingScenes: ["b"])
            var banner = CollectionText.importBanner(result, fileName: "Night Skies.lpcollection")
            try expectEqual(banner.style, .success)
            try expectEqual(banner.title, "Imported the collection \u{201C}Night Skies\u{201D}")
            try expectEqual(banner.message, "2 scenes: 1 new to your library, 1 you already had.")
            result.missing = [.init(name: "Ringed Giant", reason: "it\u{2019}s a built-in scene this version of LivePaper doesn\u{2019}t have")]
            banner = CollectionText.importBanner(result, fileName: "x")
            try expectEqual(banner.style, .warning)
            try expect(banner.message?.contains("\u{201C}Ringed Giant\u{201D} couldn\u{2019}t be added") == true, banner.message ?? "")
            banner = CollectionText.importBanner(CollectionImport(outcome: .alreadyPresent, collection: c), fileName: "x")
            try expectEqual(banner.style, .info); try expect(banner.message == nil)
            banner = CollectionText.importBanner(CollectionImport(outcome: .alreadyPresent, collection: c, lacking: ["Glow", "Ember"]),
                                                 fileName: "Night Skies.lpcollection")
            try expectEqual(banner.style, .warning)
            try expectEqual(banner.message, "Night Skies.lpcollection has 2 scenes it doesn\u{2019}t: \u{201C}Glow\u{201D}, \u{201C}Ember\u{201D}.")
            banner = CollectionText.importBanner(CollectionImport(outcome: .merged, collection: c, added: ["x"]), fileName: "f")
            try expectEqual(banner.title, "Added 1 scene to \u{201C}Night Skies\u{201D}")
            try expectEqual(CollectionText.exportMessage(CollectionExport(url: URL(fileURLWithPath: "/x"), collection: c, includedScenes: ["a", "b"],
                                                                          builtinScenes: ["z"], missingScenes: [])),
                            "2 of your scenes are in the file; 1 built-in scene is named, not copied (every LivePaper has it).")
        },
        TestCase(name: "app.collections.playlist-source") {
            let available = ["a", "b", "c", "d"]
            let c = SceneCollection(id: "c1", name: "Pair", sceneIDs: ["c", "a", "gone"])
            var draft = PlaylistDraft(PlaylistSettings())
            try expectEqual(draft.source, .all)
            draft.setSource(.collection("c1"), available: available, collections: [c])
            try expectEqual(draft.source, .collection("c1"))
            try expectEqual(draft.settings.sceneIDs, ["c", "a", "gone"])   // the stored copy
            try expectEqual(PlaylistDraft(draft.settings.following([c])).effectiveSceneIDs(available: available), ["c", "a"])
            // Choosing scenes from a collection: a copy of what it has, no longer following it.
            draft.setSource(.chosen, available: available, collections: [c])
            try expectEqual(draft.source, .chosen)
            try expectEqual(draft.settings.sceneIDs, ["c", "a"])
            try expect(draft.settings.collectionID == nil)
            draft.setSource(.all, available: available, collections: [c])
            try expectEqual(draft.settings.sceneIDs, [])
            draft.setSource(.chosen, available: available, collections: [c])
            try expectEqual(draft.settings.sceneIDs, available)   // from every scene: every scene, like before
            // Unknown collection: nothing changes. "One scene" with a collection of several plays in order.
            let before = draft
            draft.setSource(.collection("nope"), available: available, collections: [c])
            try expectEqual(draft, before)
            draft.settings.mode = .single
            draft.follow(c)
            try expectEqual(draft.settings.mode, .sequence)
            try expectEqual(draft.settings.collectionID, "c1")
            draft.useOnly("b")
            try expect(draft.settings.collectionID == nil, "one scene stops following")
            draft.follow(c)
            draft.setIncludesAllScenes(true, available: available)
            try expect(draft.settings.collectionID == nil)
            // The summary names the collection.
            var s = PlaylistSettings(mode: .shuffle, cycleMinutes: 5, collectionID: "c1")
            s = s.following([c])
            try expectEqual(PlaylistDraft.summary(s, available: available, names: [:], collection: c),
                            "\u{201C}Pair\u{201D} \u{00B7} Shuffle \u{00B7} 2 scenes \u{00B7} every 5 minutes")
            let empty = SceneCollection(id: "e", name: "Empty")
            try expectEqual(PlaylistDraft.summary(PlaylistSettings(collectionID: "e"), available: available, names: [:], collection: empty),
                            "\u{201C}Empty\u{201D} is empty \u{00B7} Shuffle \u{00B7} all 4 scenes \u{00B7} every 5 minutes")
        },
        TestCase(name: "app.collections.fullscreen-order") {
            let r = try unwrap(FullScreenPreviewRequest.collection(["c", "gone", "a", "b"], available: ["a", "b", "c"], start: "a",
                                                                   playlist: PlaylistSettings(cycleMinutes: 5, showClock: false)))
            try expectEqual(r.sequence.source, .collection)
            try expectEqual(r.sequence.current, "a")
            var seq = r.sequence
            seq.step(1)
            try expectEqual(seq.current, "b")
            seq.step(1)
            try expectEqual(seq.current, "c")   // wraps around in the collection's order
            try expect(r.autoAdvanceInterval == nil, "only playlist previews move on by themselves")
            try expectEqual(r.showClock, false)
            try expect(FullScreenPreviewRequest.collection(["gone"], available: ["a"], playlist: PlaylistSettings()) == nil)
            try expectEqual(FullScreenPreviewRequest.collection(["b", "a"], available: ["a", "b"], playlist: PlaylistSettings())?.sequence.current, "b")
        },
        TestCase(name: "app.collections.watcher") {
            try expectEqual(LibraryWatcher.classify(relative: ["collections.json"]), .collections)
            try expectEqual(LibraryWatcher.classify(relative: ["collections.json", "x"]), [])
            try expectEqual(LibraryWatcher.classify(relative: ["collections.lock"]), [])
            try expectEqual(LibraryWatcher.classify(relative: ["collections.unreadable-20261116T120000Z.json"]), [])
            try expect(DiskChanges.all.contains(.collections))
        },
    ] }

    // MARK: - AppModel

    static var appCollectionModel: [TestCase] { [
        TestCase(name: "app.model.collections-edit") {
            try withModel("collections-edit") { model, _ in
                try expectEqual(model.collections.map(\.name), ["Calm Water", "Night Skies", "Warm Evenings"])
                try expectEqual(model.collectionEntries(night).map(\.id), ["aurora-lake", "neon-rain", "paper-lanterns", "orbiting-garden"])
                try expectEqual(model.sceneCount(of: try unwrap(model.collection(id: warm))), 0)
                try expectEqual(model.collections(containing: "neon-rain").map(\.id), [night])

                // New (empty: shown at once), rename, a taken name, delete (never the scenes).
                var created: SceneCollection?
                try awaitMain { created = await model.createCollection(name: "Favourites") }
                let fav = try unwrap(created)
                try expectEqual(model.section, .collection(fav.id))
                model.collectionPath = ["neon-rain"]
                try awaitMain { _ = await model.renameCollection(fav.id, to: "Best") }
                try expectEqual(model.collection(id: fav.id)?.name, "Best")
                var ok = true
                try awaitMain { ok = await model.renameCollection(fav.id, to: "night skies") }
                try expect(!ok)
                try expect(model.banners.banners.last?.style == .error)
                // Made with scenes: stays where it is and offers Show.
                model.section = .library
                try awaitMain { created = await model.createCollection(name: "Pair", sceneIDs: ["ink-bloom", "drifting-dunes"]) }
                try expectEqual(model.section, .library)
                try expectEqual(model.banners.banners.last?.actions.map(\.title), ["Show"])

                // Add / toggle / remove with banners.
                try awaitMain { await model.addToCollection(["ink-bloom", "tidal-glass"], fav.id) }
                try expectEqual(model.collection(id: fav.id)?.sceneIDs, ["ink-bloom", "tidal-glass"])
                try expectEqual(model.banners.banners.last?.title, "Added 2 scenes to \u{201C}Best\u{201D}")
                try awaitMain { await model.addToCollection(["ink-bloom"], fav.id) }
                try expectEqual(model.banners.banners.last?.style, .info)
                try awaitMain { await model.toggleCollection(["ink-bloom"], fav.id) }   // in it: comes out
                try expectEqual(model.collection(id: fav.id)?.sceneIDs, ["tidal-glass"])
                try awaitMain { await model.toggleCollection(["ink-bloom", "tidal-glass"], fav.id) }   // some: the rest go in
                try expectEqual(model.collection(id: fav.id)?.sceneIDs, ["tidal-glass", "ink-bloom"])
                // Drag reorder and "Move to".
                try awaitMain { await model.moveScenes(["ink-bloom"], in: fav.id, to: CollectionOrder.dropPlacement(moving: ["ink-bloom"], onto: "tidal-glass", in: ["tidal-glass", "ink-bloom"])) }
                try expectEqual(model.collection(id: fav.id)?.sceneIDs, ["ink-bloom", "tidal-glass"])
                try awaitMain { await model.moveToCollection(["tidal-glass"], from: fav.id, to: calm) }
                try expectEqual(model.collection(id: fav.id)?.sceneIDs, ["ink-bloom"])
                try expectEqual(model.collection(id: calm)?.sceneIDs, ["coastline-at-dusk", "morning-fog", "tidal-glass"])
                // The selection follows what the collection screen shows.
                model.showCollection(fav.id)
                _ = model.selection.click("ink-bloom", .toggle, order: ["ink-bloom"])
                try awaitMain { await model.removeFromCollection(["ink-bloom"], fav.id) }
                try expect(model.selection.isEmpty)
                try expectEqual(model.collection(id: fav.id)?.sceneIDs, [])
                // Changing screens drops the selection and the opened scene.
                _ = model.selection.click("aurora-lake", .toggle, order: ["aurora-lake"])
                model.collectionPath = ["aurora-lake"]
                model.section = .collection(night)
                try expect(model.selection.isEmpty && model.collectionPath.isEmpty)
                // Deleting the collection on screen goes back to the library; its scenes stay.
                try awaitMain { await model.deleteCollection(night) }
                try expectEqual(model.section, .library)
                try expect(model.collection(id: night) == nil)
                try expect(model.entry(id: "neon-rain") != nil)
                try expectEqual(model.banners.banners.last?.message, "Its 4 scenes stay in your library.")
            }
        },
        TestCase(name: "app.model.collections-screen-saver-follows") {
            try withModel("collections-follow") { model, fx in
                try fx.services.install.installSaver()
                try awaitMain { await model.refreshInstallStatus() }
                // An empty collection isn't used.
                try awaitMain { await model.useCollectionAsScreenSaver(warm) }
                try expect(model.playlist.collectionID == nil)
                try expectEqual(model.banners.banners.last?.style, .info)

                try awaitMain { await model.useCollectionAsScreenSaver(night) }
                try expectEqual(model.playlist.collectionID, night)
                try expect(model.isFollowed(night))
                try expectEqual(model.lastPublished?.scenes.map(\.id), ["aurora-lake", "neon-rain", "paper-lanterns", "orbiting-garden"])
                try expectEqual(model.banners.banners.last?.title, "The screen saver plays \u{201C}Night Skies\u{201D}")
                try expect(model.playlistSummary.hasPrefix("\u{201C}Night Skies\u{201D} \u{00B7} Shuffle \u{00B7} 4 scenes"), model.playlistSummary)
                try expect(!model.canAdvanceScene, "its order is the collection's")
                try expect(model.isInPlaylist("neon-rain") && !model.isInPlaylist("ink-bloom"))

                // Changing the collection publishes it again, in its order.
                try awaitMain { await model.addToCollection(["ink-bloom"], night, at: .start) }
                try expectEqual(model.lastPublished?.scenes.map(\.id), ["ink-bloom", "aurora-lake", "neon-rain", "paper-lanterns", "orbiting-garden"])
                try expect(model.banners.banners.last?.message?.contains("screen saver plays this collection") == true)
                try awaitMain { await model.moveScenes(["aurora-lake"], in: night, to: .end) }
                try expectEqual(model.lastPublished?.scenes.map(\.id), ["ink-bloom", "neon-rain", "paper-lanterns", "orbiting-garden", "aurora-lake"])
                try expectEqual(fx.services.publish.loadSettings().sceneIDs, ["ink-bloom", "neon-rain", "paper-lanterns", "orbiting-garden", "aurora-lake"])
                // "Add to Playlist" adds to the collection the playlist is.
                try awaitMain { await model.addToPlaylist("tidal-glass") }
                try expectEqual(model.collection(id: night)?.sceneIDs.last, "tidal-glass")
                try expectEqual(model.lastPublished?.scenes.last?.id, "tidal-glass")
                // A change to another collection publishes nothing.
                let generation = model.lastPublished?.generation
                try awaitMain { await model.addToCollection(["ink-bloom"], calm) }
                try expectEqual(model.lastPublished?.generation, generation)

                // Deleting a scene: it leaves every collection, the screen saver too.
                try awaitMain { await model.addToCollection(["neon-rain"], calm) }
                try awaitMain { await model.delete("neon-rain") }
                try expect(!(model.collection(id: night)?.sceneIDs.contains("neon-rain") ?? true))
                try expect(!(model.collection(id: calm)?.sceneIDs.contains("neon-rain") ?? true))
                try expect(!(model.lastPublished?.scenes.map(\.id).contains("neon-rain") ?? true))
                try expectEqual(model.banners.banners.last?.message,
                                "It was also removed from \u{201C}Calm Water\u{201D} and \u{201C}Night Skies\u{201D}.")

                // Deleting the collection: the screen saver keeps playing its scenes, as a list.
                let scenes = try unwrap(model.collection(id: night)).sceneIDs
                try awaitMain { await model.deleteCollection(night) }
                try expect(model.playlist.collectionID == nil)
                try expectEqual(model.playlist.sceneIDs, scenes)
                try expect(model.canAdvanceScene == (model.playlist.mode != .shuffle))
                // One scene as the screen saver stops following too.
                try awaitMain { await model.useCollectionAsScreenSaver(calm) }
                try awaitMain { await model.useAsScreenSaver("ink-bloom") }
                try expect(model.playlist.collectionID == nil)
                try expectEqual(model.lastPublished?.scenes.map(\.id), ["ink-bloom"])
            }
        },
        TestCase(name: "app.model.collections-export-import") {
            try withModel("collections-files") { model, fx in
                let file = fx.root.appendingPathComponent("Night Skies.lpcollection")
                try awaitMain { await model.exportCollection(night, to: file) }
                try expect(FileManager.default.fileExists(atPath: file.path))
                try expectEqual(model.banners.banners.last?.title, "Exported \u{201C}Night Skies\u{201D} to Night Skies.lpcollection")
                try expect(model.banners.banners.last?.message?.contains("2 of your scenes") == true, model.banners.banners.last?.message ?? "")
                // The same library already has it: nothing changes.
                let scenesBefore = model.entries.count
                try awaitMain { await model.importCollection(at: file) }
                try expectEqual(model.banners.banners.last?.style, .info)
                try expectEqual(model.banners.banners.last?.title, "\u{201C}Night Skies\u{201D} is already in your library")
                try expectEqual(model.entries.count, scenesBefore)
                // Without a scene it had: offers to add it, or a copy.
                try awaitMain { await model.removeFromCollection(["paper-lanterns"], night) }
                try awaitMain { await model.importCollection(at: file) }
                let banner = try unwrap(model.banners.banners.last)
                try expectEqual(banner.style, .warning)
                try expectEqual(banner.actions.map(\.title), ["Add 1 Scene", "Import as a Copy"])
                banner.actions[0].perform()
                try awaitMain(until: { model.collection(id: night)?.sceneIDs.count == 4 })
                try expectEqual(model.collection(id: night)?.sceneIDs.last, "paper-lanterns")
                banner.actions[1].perform()
                try awaitMain(until: { model.collections.count == 4 })
                let copy = try unwrap(model.collections.first { $0.name == "Night Skies 2" })
                try expectEqual(copy.sceneIDs, ["aurora-lake", "neon-rain", "paper-lanterns", "orbiting-garden"])
                try expectEqual(model.entries.count, scenesBefore)   // no scene came twice
                // Not a collection.
                let junk = fx.root.appendingPathComponent("junk.lpcollection")
                try Data("nope".utf8).write(to: junk)
                try awaitMain { await model.importCollection(at: junk) }
                try expectEqual(model.banners.banners.last?.style, .error)
            }
        },
        TestCase(name: "app.model.collections-disk-changes") {
            // A change the CLI makes shows up through the disk watcher's refresh.
            try withModel("collections-disk") { model, fx in
                try fx.services.collections.create(name: "From the CLI", sceneIDs: ["ink-bloom"])
                try expect(!model.collections.contains { $0.name == "From the CLI" })
                try awaitMain { await model.refreshFromDisk(.collections) }
                try expect(model.collections.contains { $0.name == "From the CLI" })
                // The collection on screen deleted elsewhere: back to the library.
                let id = try unwrap(model.collections.first { $0.name == "From the CLI" }).id
                model.showCollection(id)
                try fx.services.collections.delete(id: id)
                try awaitMain { await model.refreshFromDisk(.collections) }
                try expectEqual(model.section, .library)
            }
        },
    ] }
}
