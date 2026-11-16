// Self tests for collections in the app: the Library's sections (collections, Your Scenes, Included;
// search inside each, collapsing remembered per collection id, keyboard order across sections),
// multi-selection, what a drop on a collection does, the "Add to Collection ▸" rules and the banners'
// wording, the Screen Saver screen's sources, the full-screen order, the disk watcher, and AppModel
// over the mock services (seeded with MockSampleData.collections()).
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
        TestCase(name: "app.collections.library-sections") {
            func entry(_ id: String, _ name: String, builtin: Bool = false, kind: SceneManifest.Kind = .web, tags: [String] = []) -> LibraryEntry {
                LibraryEntry(item: SceneItem(manifest: SceneManifest(id: id, name: name, kind: kind, video: kind == .video ? .init(file: "v.mov") : nil,
                                                                     tags: tags),
                                             packageURL: URL(fileURLWithPath: "/nonexistent/\(id).lpscene"), isBuiltin: builtin),
                             hasAIHistory: false)
            }
            let entries = [entry("mine", "Mine", tags: ["night"]), entry("clip", "Clip", kind: .video), entry("aurora", "Aurora", builtin: true, tags: ["night"]),
                           entry("zen", "Zen", builtin: true)]
            let night = SceneCollection(id: "n", name: "Night", sceneIDs: ["aurora", "gone", "mine", "aurora"])
            let empty = SceneCollection(id: "e", name: "Empty")
            // Collections first (in the order given), then Your Scenes, then Included; a collection's
            // scenes in its order, once each, those the library lacks skipped.
            var sections = LibrarySections.make(entries: entries, collections: [empty, night], query: LibraryQuery(), collapsed: [])
            try expectEqual(sections.map(\.id), [.collection("e"), .collection("n"), .yourScenes, .builtin])
            try expectEqual(sections.map(\.title), ["Empty", "Night", "Your Scenes", "Included with LivePaper"])
            try expectEqual(sections[1].sceneIDs, ["aurora", "mine"])
            try expectEqual(sections[2].sceneIDs, ["mine", "clip"]); try expectEqual(sections[3].sceneIDs, ["aurora", "zen"])
            try expect(sections[0].entries.isEmpty && sections[0].collection == empty, "an empty collection still shows (its drop hint)")
            try expectEqual(sections.map(\.countText), ["0", "2", "2", "2"])
            // The same scene in several sections: each card is its section's; ← → walk them in order,
            // across sections; the selection's order has each scene once.
            try expectEqual(LibrarySections.cards(sections).map(\.scene), ["aurora", "mine", "mine", "clip", "aurora", "zen"])
            try expectEqual(LibrarySections.sceneOrder(sections), ["aurora", "mine", "clip", "zen"])
            let first = LibraryCardID(section: .collection("n"), scene: "mine")
            try expectEqual(LibrarySections.card(first, movedBy: 1, in: sections), LibraryCardID(section: .yourScenes, scene: "mine"))
            try expectEqual(LibrarySections.card(LibraryCardID(section: .collection("n"), scene: "aurora"), movedBy: -1, in: sections), nil)
            // Collapsed: the header stays, its cards leave the keyboard order (and the selection's).
            sections = LibrarySections.make(entries: entries, collections: [empty, night], query: LibraryQuery(), collapsed: ["your-scenes"])
            try expect(sections[2].isCollapsed && sections[2].entries.count == 2)
            try expectEqual(LibrarySections.card(first, movedBy: 1, in: sections), LibraryCardID(section: .builtin, scene: "aurora"))
            try expectEqual(LibrarySections.sceneOrder(sections), ["aurora", "mine", "zen"])
            try expectEqual(LibrarySections.focusAfterCollapsing(.yourScenes, focus: .card(LibraryCardID(section: .yourScenes, scene: "clip"))),
                            .header(.yourScenes))
            try expectEqual(LibrarySections.focusAfterCollapsing(.yourScenes, focus: .card(first)), .card(first))
            // Searching applies inside every section; sections without matches go, collapsed or not.
            var q = LibraryQuery(); q.text = "night"
            sections = LibrarySections.make(entries: entries, collections: [empty, night], query: q, collapsed: ["builtin"])
            try expectEqual(sections.map(\.id), [.collection("n"), .yourScenes, .builtin])
            try expectEqual(sections.map(\.countText), ["2", "1 of 2", "1 of 2"])
            try expect(sections[2].isCollapsed)
            q.text = ""; q.kind = .video
            try expectEqual(LibrarySections.make(entries: entries, collections: [empty, night], query: q, collapsed: []).map(\.id), [.yourScenes])
            try expect(LibrarySections.hides("n", entries: entries, collections: [night], query: q))
            try expect(!LibrarySections.hides("n", entries: entries, collections: [night], query: LibraryQuery()))
            // Your Scenes and Included only when there are some.
            try expectEqual(LibrarySections.make(entries: [entries[2]], collections: [], query: LibraryQuery(), collapsed: []).map(\.id), [.builtin])
            // Keys: per collection id (a rename keeps it).
            for id in [LibrarySectionID.collection("5c0e-1"), .yourScenes, .builtin] { try expectEqual(LibrarySectionID(key: id.key), id) }
            try expect(LibrarySectionID(key: "collection:") == nil && LibrarySectionID(key: "results") == nil)
            let prefs = InMemoryPreferences()
            try expectEqual(LibraryCollapsedSections.load(prefs), [])
            LibraryCollapsedSections.save(["collection:n", "builtin"], to: prefs)
            try expectEqual(LibraryCollapsedSections.load(prefs), ["collection:n", "builtin"])
            prefs.set(Data(#"["builtin", "nonsense", 3]"#.utf8), forKey: LibraryCollapsedSections.preferenceKey)
            try expectEqual(LibraryCollapsedSections.load(prefs), [])   // unreadable: all expanded
            prefs.set(Data(#"["builtin", "nonsense"]"#.utf8), forKey: LibraryCollapsedSections.preferenceKey)
            try expectEqual(LibraryCollapsedSections.load(prefs), ["builtin"])
            LibraryCollapsedSections.save([], to: prefs)
            try expect(prefs.data(forKey: LibraryCollapsedSections.preferenceKey) == nil)
        },
        TestCase(name: "app.collections.drop-rule") {
            let c = SceneCollection(id: "c", name: "Night", sceneIDs: ["a", "b", "c"])
            func plan(_ ids: [String], from source: String?, card: String? = nil, header: Bool = false) -> CollectionDropPlan {
                CollectionDropPlan.plan(sceneIDs: ids, source: source, onto: c, card: card, onHeader: header)
            }
            // From Your Scenes / Included: added (at the card, or the end).
            try expectEqual(plan(["x"], from: nil), .add(["x"], .end, copiedFrom: nil))
            try expectEqual(plan(["x", "y"], from: nil, card: "b"), .add(["x", "y"], .before("b"), copiedFrom: nil))
            try expectEqual(plan(["x"], from: nil, header: true), .add(["x"], .end, copiedFrom: nil))
            // From another collection: added too (a copy; they stay there).
            try expectEqual(plan(["x"], from: "other", card: "a"), .add(["x"], .before("a"), copiedFrom: "other"))
            // Within the collection: reordered (onto a card: its place); nothing on the header or itself.
            try expectEqual(plan(["a"], from: "c", card: "c"), .reorder(["a"], .after("c")))
            try expectEqual(plan(["c"], from: "c", card: "a"), .reorder(["c"], .before("a")))
            try expectEqual(plan(["a"], from: "c"), .reorder(["a"], .end))
            try expectEqual(plan(["a"], from: "c", header: true), .none)
            try expectEqual(plan(["a", "b"], from: "c", card: "a"), .none)
            try expectEqual(plan([], from: nil), .none)
            // Dragged from here with scenes it lacks (a selection across sections): those are added.
            try expectEqual(plan(["a", "x"], from: "c", card: "b"), .add(["a", "x"], .before("b"), copiedFrom: nil))
            // What the drop target says.
            try expectEqual(CollectionText.dropLabel(plan(["x"], from: nil), collection: "Night"), "Add to \u{201C}Night\u{201D}")
            try expectEqual(CollectionText.dropLabel(plan(["x", "y"], from: "o"), collection: "Night"), "Add 2 to \u{201C}Night\u{201D}")
            try expectEqual(CollectionText.dropLabel(plan(["a"], from: "c", card: "c"), collection: "Night"), "Move here")
            try expectEqual(CollectionText.dropLabel(.none, collection: "Night"), nil)
            try expectEqual(CollectionText.copiedNote(["x"], from: "Calm"),
                            "It stays in \u{201C}Calm\u{201D} too. To move scenes instead, use Move to Collection in their menu.")
        },
        TestCase(name: "app.collections.selection-section") {
            let night = LibrarySectionID.collection("n").key, mine = LibrarySectionID.yourScenes.key
            var s = LibrarySelection()
            try expect(s.section == nil)
            _ = s.click("a", .toggle, order: ["a", "b", "c"], section: night)
            _ = s.click("c", .extend, order: ["a", "b", "c"], section: night)
            try expectEqual(s.section, night)
            try expectEqual(s.ordered(["c", "b", "a"]), ["c", "b", "a"])
            // A card chosen in another section: no single section any more.
            _ = s.click("z", .toggle, order: ["z"], section: mine)
            try expect(s.section == nil)
            // Deselecting everything starts over.
            for id in ["a", "b", "c", "z"] { _ = s.click(id, .toggle, order: [], section: mine) }
            try expect(s.isEmpty)
            _ = s.click("z", .toggle, order: ["z"], section: mine)
            try expectEqual(s.section, mine)
            // ⇧-click ranges are in the clicked section's order; an anchor from elsewhere adds one card.
            var r = LibrarySelection()
            _ = r.click("b", .toggle, order: ["a", "b", "c", "d"], section: night)
            _ = r.click("d", .extend, order: ["d", "c", "b"], section: night)
            try expectEqual(r.ids, ["b", "c", "d"])
            _ = r.click("x", .extend, order: ["x", "y"], section: mine)
            try expectEqual(r.ids, ["b", "c", "d", "x"])
            // Select All: in a section, or the whole Library (no section).
            r.selectAll(["a", "b"], section: night)
            try expectEqual(r.section, night)
            r.selectAll(["a", "b", "x"])
            try expect(r.section == nil)
            r.retain([])
            try expect(r.isEmpty && r.section == nil)
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
                model.libraryPath = ["neon-rain"]
                try awaitMain { created = await model.createCollection(name: "Favourites") }
                let fav = try unwrap(created)
                // An empty one is revealed: its Library section, expanded and scrolled to.
                try expectEqual(model.section, .library)
                try expectEqual(model.libraryPath, [])
                try expectEqual(model.libraryReveal, .collection(fav.id))
                try expect(model.librarySections.contains { $0.id == .collection(fav.id) && $0.entries.isEmpty && !$0.isCollapsed })
                model.libraryReveal = nil
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
                try expect(model.libraryReveal == nil)
                try expectEqual(model.banners.banners.last?.actions.map(\.title), ["Show"])
                model.banners.banners.last?.actions.first?.perform()
                let pair = try unwrap(created).id
                try expectEqual(model.libraryReveal, .collection(pair))
                model.libraryReveal = nil

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
                // Cards chosen in a collection's section that leave it end the selection.
                let favKey = LibrarySectionID.collection(fav.id).key
                _ = model.selection.click("ink-bloom", .toggle, order: ["ink-bloom"], section: favKey)
                try expectEqual(model.selection.section, favKey)
                try awaitMain { await model.removeFromCollection(["ink-bloom"], fav.id) }
                try expect(model.selection.isEmpty)
                try expectEqual(model.collection(id: fav.id)?.sceneIDs, [])
                // Changing screens drops the selection.
                _ = model.selection.click("aurora-lake", .toggle, order: ["aurora-lake"])
                model.section = .playlist
                try expect(model.selection.isEmpty)
                model.section = .library
                // Deleting a collection: its scenes stay; a selection chosen in it ends, and its
                // remembered collapsed state goes (a later collection starts expanded).
                model.setCollapsed(.collection(night), true)
                _ = model.selection.click("neon-rain", .toggle, order: ["neon-rain"], section: LibrarySectionID.collection(night).key)
                try awaitMain { await model.deleteCollection(night) }
                try expect(model.selection.isEmpty)
                try expect(!model.collapsedSections.contains(LibrarySectionID.collection(night).key))
                try expect(!model.librarySections.contains { $0.id == .collection(night) })
                try expect(model.collection(id: night) == nil)
                try expect(model.entry(id: "neon-rain") != nil)
                try expectEqual(model.banners.banners.last?.message, "Its 4 scenes stay in your library.")
            }
        },
        TestCase(name: "app.model.library-sections") {
            try withModel("library-sections") { model, fx in
                let nightKey = LibrarySectionID.collection(night).key
                try expectEqual(model.librarySections.map(\.id), [.collection(calm), .collection(night), .collection(warm), .yourScenes, .builtin])
                // Collapsing is remembered across launches, per collection id: a rename keeps it.
                model.setCollapsed(.collection(night), true)
                model.setCollapsed(.builtin, true)
                try expect(model.isCollapsed(.collection(night)) && model.isCollapsed(.builtin))
                try awaitMain { _ = await model.renameCollection(night, to: "Starry") }
                let relaunched = AppModel(services: fx.services, environment: model.environment)
                try expectEqual(relaunched.collapsedSections, [nightKey, "builtin"])
                try expect(relaunched.isCollapsed(.collection(night)) && !relaunched.isCollapsed(.collection(calm)))
                // New collections start expanded.
                var created: SceneCollection?
                try awaitMain { created = await model.createCollection(name: "Later", sceneIDs: ["ink-bloom"]) }
                let later = try unwrap(created).id
                try expect(!model.isCollapsed(.collection(later)))
                model.setCollapsed(.builtin, false)
                try expectEqual(AppModel(services: fx.services, environment: model.environment).collapsedSections, [nightKey])
                // Collapsing a section whose cards are selected (and shown nowhere else) ends their selection.
                let calmOrder = model.librarySections.first { $0.id == .collection(calm) }?.sceneIDs ?? []
                _ = model.selection.click("tidal-glass", .toggle, order: calmOrder, section: LibrarySectionID.collection(calm).key)
                model.setCollapsed(.collection(calm), true)
                try expect(model.selection.contains("tidal-glass"), "still shown in Your Scenes")
                model.setCollapsed(.yourScenes, true)
                try expect(model.selection.isEmpty)
                model.setCollapsed(.yourScenes, false)
                // Revealing a collection: the Library, expanded, scrolled to; a search hiding it is cleared.
                model.section = .playlist
                model.query.text = "volcano"
                model.revealCollection(night)
                try expectEqual(model.section, .library)
                try expect(!model.isCollapsed(.collection(night)) && model.query.text.isEmpty)
                try expectEqual(model.libraryReveal, .collection(night))
                model.query.text = "lanterns"
                model.revealCollection(night)
                try expectEqual(model.query.text, "lanterns")   // it has a match: the search stays
                model.query = LibraryQuery()
            }
        },
        TestCase(name: "app.model.library-drops") {
            try withModel("library-drops") { model, _ in
                // From Your Scenes onto a card of Night Skies: added at its place.
                var plan = model.dropPlan(["ink-bloom"], from: nil, onto: night, card: "neon-rain")
                try expectEqual(plan, .add(["ink-bloom"], .before("neon-rain"), copiedFrom: nil))
                model.libraryDrag = LibraryDrag(sceneIDs: ["ink-bloom"], sourceCollection: nil)
                try awaitMain { await model.performDrop(plan, onto: night) }
                try expect(model.libraryDrag == nil)
                try expectEqual(model.collection(id: night)?.sceneIDs, ["aurora-lake", "ink-bloom", "neon-rain", "paper-lanterns", "orbiting-garden"])
                try expectEqual(model.banners.banners.last?.title, "Added \u{201C}Ink Bloom\u{201D} to \u{201C}Night Skies\u{201D}")
                // Within Night Skies: reordered, no banner.
                let before = model.banners.banners.count
                plan = model.dropPlan(["orbiting-garden"], from: night, onto: night, card: "aurora-lake")
                try awaitMain { await model.performDrop(plan, onto: night) }
                try expectEqual(model.collection(id: night)?.sceneIDs, ["orbiting-garden", "aurora-lake", "ink-bloom", "neon-rain", "paper-lanterns"])
                try expectEqual(model.banners.banners.count, before)
                // From Night Skies to Calm Water: a copy, and the banner says how to move instead.
                plan = model.dropPlan(["neon-rain"], from: night, onto: calm, card: nil, onHeader: true)
                try awaitMain { await model.performDrop(plan, onto: calm) }
                try expectEqual(model.collection(id: calm)?.sceneIDs.last, "neon-rain")
                try expect(model.collection(id: night)?.sceneIDs.contains("neon-rain") == true)
                try expectEqual(model.banners.banners.last?.message,
                                "It stays in \u{201C}Night Skies\u{201D} too. To move scenes instead, use Move to Collection in their menu.")
                try expectEqual(model.banners.banners.last?.actions.map(\.title), ["Show"])
                // Dropped back on its own header: nothing. An unknown collection: nothing.
                try expectEqual(model.dropPlan(["neon-rain"], from: night, onto: night, card: nil, onHeader: true), .none)
                try expectEqual(model.dropPlan(["neon-rain"], from: nil, onto: "gone", card: nil), .none)
                // Already there: an info banner, nothing changes.
                plan = model.dropPlan(["neon-rain"], from: nil, onto: calm, card: nil)
                try awaitMain { await model.performDrop(plan, onto: calm) }
                try expectEqual(model.banners.banners.last?.style, .info)
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
                // Deleted elsewhere while cards were chosen in its section: the selection ends.
                let id = try unwrap(model.collections.first { $0.name == "From the CLI" }).id
                try expect(model.librarySections.contains { $0.id == .collection(id) })
                _ = model.selection.click("ink-bloom", .toggle, order: ["ink-bloom"], section: LibrarySectionID.collection(id).key)
                try fx.services.collections.delete(id: id)
                try awaitMain { await model.refreshFromDisk(.collections) }
                try expect(model.selection.isEmpty)
                try expect(!model.librarySections.contains { $0.id == .collection(id) })
            }
        },
    ] }
}
