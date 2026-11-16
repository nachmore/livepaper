// Self tests for selecting LivePaper on every display (docs/RESEARCH.md §5.5, §5.8): stores shaped
// like a real macOS 26.7 store in the two states seen on 2026-11-16, WallpaperAgent's observed
// handling of SystemDefault, what "selected" means (every display / partly / none / unknown, with
// connected displays counted), the quiet re-apply, uninstall putting the placeholders — or a
// previous screen saver — back, and the app's re-apply triggers.
//
// The stores are generated with the store's Codable mirror (like StoreFixture) and anonymised:
// made-up display and Space ids, the user "user", no real paths. Only their structure follows the
// real ones. Nothing here touches the real store or WallpaperAgent.
import Foundation
import LivePaperCore

extension SelfTests {
    static var wallpaperEveryDisplay: [TestCase] { everyDisplayModel + everyDisplayApplier + everyDisplayInstall + everyDisplayRestore + everyDisplayApp }
}

// MARK: - Fixture

/// Stand-ins with the structure of a real macOS 26.7 store: 6 displays and 4 Spaces — the first
/// Space ("") has a record of every display, three more have one each — 20 records in all.
enum RealShapedStore {
    typealias Schema = WallpaperStoreSchema

    static func display(_ letter: Character) -> String { "D15B1A70-0000-4000-8000-00000000000\(letter)" }
    /// a and b chose LivePaper explicitly in an earlier selection (they aren't connected any more);
    /// c–f are the four displays in use.
    static let a = display("A"), b = display("B"), c = display("C"), d = display("D"), e = display("E"), f = display("F")
    static var displays: [String] { [a, b, c, d, e, f] }
    static let s1 = "5BACE000-0000-4000-8000-000000000001", s2 = "5BACE000-0000-4000-8000-000000000002",
               s3 = "5BACE000-0000-4000-8000-000000000003"
    /// The Spaces after the first, each with its one display record.
    static var otherSpaces: [(space: String, display: String)] { [(s1, e), (s2, d), (s3, b)] }
    /// What was on screen: the first Space on e (its slot went into SystemDefault too), s2 on d.
    static var spacesInUse: [(space: String, display: String)] { [("", e), (s2, d)] }

    static var placeholder: Schema.Slot { StoreFixture.idle(.inherit) }

    /// A screen-saver choice (LivePaper's, or another saver's) as the real store had it
    /// (EncodedOptionValues `{values = {}}`).
    static func livePaperSlot(_ path: String) -> Schema.Slot {
        Schema.Slot(lastSet: StoreFixture.setSaver, lastUse: StoreFixture.usedDesktop, content: Schema.Content(
            choices: [Schema.Choice(provider: WallpaperSlot.screenSaverProvider, configuration: StoreFixture.moduleConfiguration(path))],
            encodedOptionValues: WallpaperChoicePayload.emptyOptionValues))
    }

    static func record(_ idle: Schema.Slot) -> Schema.Record { .individual(desktop: StoreFixture.desktop(), idle: idle) }

    /// Every Idle slot on the placeholder: a Mac whose screen saver was never chosen.
    static func fresh() -> Schema.Index { reverted(livePaper: nil) }

    /// The state the lock screen showed macOS's default in: SystemDefault back on the placeholder
    /// (another screen saver's uninstaller put its own old copy back), a and b still on LivePaper
    /// (also in the first Space), every other slot — the 11 display slots of c–f
    /// (`placeholderDisplayPaths`) and every Space's Default — on the placeholder.
    static func reverted(livePaper path: String?) -> Schema.Index {
        let inherit = record(placeholder)
        let chosen = path.map { record(livePaperSlot($0)) } ?? inherit
        func pick(_ id: String) -> Schema.Record { id == a || id == b ? chosen : inherit }
        let byDisplay = Dictionary(uniqueKeysWithValues: displays.map { ($0, pick($0)) })
        var spaces = ["": Schema.SpaceRecord(default: inherit, displays: byDisplay)]
        for (space, id) in otherSpaces { spaces[space] = Schema.SpaceRecord(default: inherit, displays: [id: inherit]) }
        return Schema.Index(allSpacesAndDisplays: nil, systemDefault: inherit, spaces: spaces, displays: byDisplay)
    }

    /// What WallpaperAgent wrote after the 11 placeholder display slots were filled and it restarted:
    /// every display slot, SystemDefault and the Defaults of the Spaces in use ("" and s2) on
    /// LivePaper; the Defaults of s1 and s3 still on the placeholder.
    static func afterFill(livePaper path: String) -> Schema.Index {
        let chosen = record(livePaperSlot(path))
        var index = reverted(livePaper: path)
        index.systemDefault = chosen
        for id in displays { index.displays[id] = chosen }
        for (space, var spaceRecord) in index.spaces {
            for id in spaceRecord.displays.keys { spaceRecord.displays[id] = chosen }
            if space == "" || space == s2 { spaceRecord.default = chosen }
            index.spaces[space] = spaceRecord
        }
        return index
    }

    /// System Settings' own selection of `path` on the `reverted` Mac: SystemDefault and the explicit
    /// slots (a and b) choose it; the placeholders of c–f keep inheriting (§5.4).
    static func systemSettings(livePaper path: String) -> Schema.Index {
        var index = reverted(livePaper: path)
        index.systemDefault = record(livePaperSlot(path))
        return index
    }

    /// A Mac whose screen saver was never chosen, except `saver` in SystemDefault (as System Settings
    /// leaves a store whose display records all hold the placeholder).
    static func freshWithDefault(_ saver: String) -> Schema.Index {
        var index = fresh()
        index.systemDefault = record(livePaperSlot(saver))
        return index
    }

    /// `afterFill`, but the agent kept the placeholder in SystemDefault (the state a selection
    /// accepts when every display resolves to LivePaper).
    static func filledDefaultKept(livePaper path: String) -> Schema.Index {
        var index = afterFill(livePaper: path)
        index.systemDefault = record(placeholder)
        return index
    }

    /// s3's record of b: on the placeholder, but it falls back to b's own record (LivePaper).
    static var s3b: WallpaperRecordPath { .spaceDisplay(space: s3, display: b) }

    /// The 11 display slots on the placeholder in `reverted`.
    static var placeholderDisplayPaths: [WallpaperRecordPath] {
        [c, d, e, f].map { .display($0) } + [c, d, e, f].map { .spaceDisplay(space: "", display: $0) }
            + otherSpaces.map { .spaceDisplay(space: $0.space, display: $0.display) }
    }

    /// A display connected since: records copied from SystemDefault (docs/RESEARCH.md §5.4), in
    /// Displays and the first Space.
    static func connect(_ id: String, to index: Schema.Index) -> Schema.Index {
        var copy = index
        copy.displays[id] = index.systemDefault
        copy.spaces[""]?.displays[id] = index.systemDefault
        return copy
    }

    static func data(_ index: Schema.Index) throws -> Data { try Schema.encode(index) }
    static func document(_ index: Schema.Index) throws -> WallpaperStoreDocument { try WallpaperStoreDocument(data: data(index)) }

    /// What WallpaperAgent was seen doing when it restarted (docs/RESEARCH.md §5.5): it writes its
    /// model back, with the Idle slot of the display it shows the first Space on copied into
    /// SystemDefault, and the slot of the display each Space in use is shown on copied into that
    /// Space's Default — whole slots, placeholder or not. So a SystemDefault written alone, while
    /// that display holds the placeholder, is gone again at once.
    static func deriveDefaults(at store: URL) throws {
        var index = try Schema.decode(Data(contentsOf: store))
        func idle(_ record: Schema.Record?) -> Schema.Slot? {
            if case .individual(_, let idle)? = record { return idle }
            return nil
        }
        func setting(_ slot: Schema.Slot, in record: Schema.Record) -> Schema.Record {
            if case .individual(let desktop, _) = record { return .individual(desktop: desktop, idle: slot) }
            return record
        }
        for (space, id) in spacesInUse {
            guard var spaceRecord = index.spaces[space], let slot = idle(spaceRecord.displays[id]) else { continue }
            spaceRecord.default = setting(slot, in: spaceRecord.default)
            index.spaces[space] = spaceRecord
            if space == "" { index.systemDefault = setting(slot, in: index.systemDefault) }
        }
        try Schema.encode(index).write(to: store, options: .atomic)
    }

    /// An agent that keeps the SystemDefault it had in memory (the placeholder) but every display slot.
    static func keepPlaceholderInSystemDefault(at store: URL) throws {
        var index = try Schema.decode(Data(contentsOf: store))
        index.systemDefault = record(placeholder)
        try Schema.encode(index).write(to: store, options: .atomic)
    }

    /// Every Idle slot that doesn't name `keeping` back on the placeholder (another tool's uninstaller
    /// putting its own old copy back, as seen on 2026-11-16), Desktop slots untouched.
    static func resetIdle(at store: URL, keeping module: WallpaperSaverModule? = nil) throws {
        let document = try WallpaperStoreDocument(data: Data(contentsOf: store))
        guard let inherit = try self.document(fresh()).idleSlot(at: .systemDefault) else { return }
        var slots: [WallpaperRecordPath: PlistValue] = [:]
        for record in document.records {
            guard let idle = record.idle, module.map({ !$0.isChosen(in: idle) }) ?? true else { continue }
            slots[record.path] = inherit
        }
        try document.replacingIdleSlots(slots).data().write(to: store, options: .atomic)
    }

    /// What every display record shows (resolved slot's first module file name; "default" for macOS's
    /// own), for comparing stores by what is shown.
    static func shown(_ document: WallpaperStoreDocument) -> [WallpaperRecordPath: String] {
        Dictionary(uniqueKeysWithValues: document.records.filter { $0.path.displayID != nil }.map { record in
            (record.path, document.resolvedSlot(of: record.path).flatMap { WallpaperSlot.moduleURLs($0.slot).first?.lastPathComponent } ?? "default")
        })
    }
}

/// Why the quiet re-apply leaves a store alone that names LivePaper nowhere.
private let notChosen = "LivePaper isn\u{2019}t chosen for any display any more (selecting it again is up to you)"

/// The Idle slots that differ between two documents.
private func changedIdlePaths(_ a: WallpaperStoreDocument, _ b: WallpaperStoreDocument) -> [WallpaperRecordPath] {
    let before = idleSlots(a), after = idleSlots(b)
    return Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
}

// MARK: - Model

extension SelfTests {
    fileprivate static var everyDisplayModel: [TestCase] { [
        TestCase(name: "wallpaper.every-display.fixture") {
            let module = StoreFixture.livePaper
            let store = RealShapedStore.self
            let revertedData = try store.data(store.reverted(livePaper: StoreFixture.livePaperPath))
            let reverted = try WallpaperStoreDocument(data: revertedData)
            try expectEqual(reverted.records.count, 20)
            try expectEqual(try WallpaperStoreSchema.encode(WallpaperStoreSchema.decode(revertedData)), revertedData)
            let selection = reverted.selection(of: module)
            try expectEqual(selection.displayIDs, store.displays.sorted())
            try expectEqual(selection.displaysWithLivePaper, [store.a, store.b].sorted())
            try expectEqual(selection.displaysWithoutLivePaper, [store.c, store.d, store.e, store.f].sorted())
            // Every placeholder display slot but s3's record of b, which falls back to b's own LivePaper.
            try expectEqual(selection.placeholderDisplays, store.placeholderDisplayPaths.filter { $0 != store.s3b }.sorted())
            try expect(selection.isSelected && selection.isPartlySelected, "uninstall has slots to undo; some displays use it")
            try expect(!selection.isSelectedOnEveryDisplay && !selection.isSelectedEverywhere)
            try expectEqual(selection.defaults[.systemDefault], .systemDefault)
            // Resolution: Space and display, then Space, then display, then SystemDefault.
            try expectEqual(reverted.resolution(of: .spaceDisplay(space: store.s3, display: store.b), module: module), .livePaper(at: .display(store.b)))
            try expectEqual(reverted.resolution(of: .spaceDisplay(space: store.s1, display: store.e), module: module), .systemDefault)
            try expectEqual(reverted.resolution(of: .spaceDisplay(space: "", display: store.a), module: module),
                            .livePaper(at: .spaceDisplay(space: "", display: store.a)))
            var spaceChoice = store.reverted(livePaper: StoreFixture.livePaperPath)
            spaceChoice.spaces[store.s1]?.default = store.record(store.livePaperSlot(StoreFixture.otherSaverPath))
            try expectEqual(try store.document(spaceChoice).resolution(of: .spaceDisplay(space: store.s1, display: store.e), module: module),
                            .other(at: .spaceDefault(store.s1)))
            try expectEqual(try store.document(spaceChoice).resolution(of: .display(store.e), module: module), .systemDefault)

            // After the fill: every record resolves to LivePaper, though two Space Defaults still hold the placeholder.
            let filled = try store.document(store.afterFill(livePaper: StoreFixture.livePaperPath))
            let filledSelection = filled.selection(of: module)
            try expect(filledSelection.isSelectedOnEveryDisplay && filledSelection.isSelectedEverywhere && filledSelection.placeholderDisplays.isEmpty)
            try expect(filled.idleSlot(at: .spaceDefault(store.s1)).map(WallpaperSlot.isInherit) == true)
            try expectEqual(filled.resolution(of: .spaceDefault(store.s1), module: module), .livePaper(at: .systemDefault))
            // The agent kept the placeholder in SystemDefault: every display still, but not everywhere.
            let kept = try store.document(store.filledDefaultKept(livePaper: StoreFixture.livePaperPath)).selection(of: module)
            try expect(kept.isSelectedOnEveryDisplay && !kept.isSelectedEverywhere && kept.placeholderDisplays.isEmpty)
            // System Settings' own selection: every display shows LivePaper, but c–f only through
            // SystemDefault (or the first Space's Default), which the agent derives from them.
            let byHand = try store.document(store.systemSettings(livePaper: StoreFixture.livePaperPath)).selection(of: module)
            try expect(byHand.isSelectedOnEveryDisplay, "every display shows it")
            try expectEqual(byHand.placeholderDisplays, store.placeholderDisplayPaths.filter { $0 != store.s3b }.sorted())
            try expectEqual(byHand.displays[.display(store.c)], .livePaper(at: .systemDefault))
        },
        TestCase(name: "wallpaper.every-display.status") {
            let store = RealShapedStore.self
            try StoreSandbox.with("every-display-status") { sb in
                let wallpaper = WallpaperStore(url: sb.store, saver: sb.saver)
                let states: [(String, WallpaperStoreSchema.Index, SaverSelection)] = [
                    ("reverted", store.reverted(livePaper: StoreFixture.livePaperPath), .partly(.init(displays: 6, missing: 4))),
                    ("after the fill", store.afterFill(livePaper: StoreFixture.livePaperPath), .everyDisplay),
                    ("SystemDefault kept", store.filledDefaultKept(livePaper: StoreFixture.livePaperPath), .everyDisplay),
                    ("a display connected since", store.connect(store.display("9"), to: store.filledDefaultKept(livePaper: StoreFixture.livePaperPath)),
                     .partly(.init(displays: 7, missing: 1))),
                    ("never chosen", store.fresh(), .none),
                    // System Settings' own selection: SystemDefault and the explicit slots, placeholders inheriting.
                    ("System Settings", StoreFixture.index(saver: StoreFixture.livePaperPath), .everyDisplay),
                    ("another saver", StoreFixture.index(), .none),
                    // No display record yet: SystemDefault decides.
                    ("no displays, LivePaper", .init(systemDefault: store.record(store.livePaperSlot(StoreFixture.livePaperPath))), .everyDisplay),
                    ("no displays, default", .init(systemDefault: store.record(store.placeholder)), .none),
                ]
                for (name, index, expected) in states {
                    try store.data(index).write(to: sb.store)
                    try expect(wallpaper.selectionState() == expected, "\(name): \(wallpaper.selectionState())")
                }
                // Explicitly another saver on a and b too: no display uses LivePaper.
                var other = store.reverted(livePaper: StoreFixture.otherSaverPath)
                other.systemDefault = store.record(store.livePaperSlot(StoreFixture.livePaperPath))
                try store.data(other).write(to: sb.store)
                try expectEqual(wallpaper.selectionState(), .partly(.init(displays: 6, missing: 2)))   // c–f inherit SystemDefault
                other.systemDefault = store.record(store.placeholder)
                try store.data(other).write(to: sb.store)
                try expectEqual(wallpaper.selectionState(), .none)
                // The connected displays are counted when they are known: c and d (both missing) of the
                // reverted store; or only a (showing LivePaper); a list naming no display of the store
                // tells nothing. CoreGraphics' UUID strings may differ in case.
                try store.data(store.reverted(livePaper: StoreFixture.livePaperPath)).write(to: sb.store)
                try expectEqual(wallpaper.selectionState(connectedDisplays: [store.c, store.d.lowercased()]),
                                .partly(.init(displays: 6, missing: 4, connected: 2, connectedMissing: 2)))
                try expectEqual(wallpaper.selectionState(connectedDisplays: [store.a]),
                                .partly(.init(displays: 6, missing: 4, connected: 1, connectedMissing: 0)))
                try expectEqual(wallpaper.selectionState(connectedDisplays: ["0E0E0E0E-0000-4000-8000-000000000000"]),
                                .partly(.init(displays: 6, missing: 4)))
                // A display with one record on LivePaper and one that isn't counts once, as missing.
                var split = store.reverted(livePaper: StoreFixture.livePaperPath)
                split.displays = [store.a: store.record(store.livePaperSlot(StoreFixture.livePaperPath))]
                split.spaces = ["": .init(default: store.record(store.placeholder), displays: [store.a: store.record(store.placeholder)]),
                                store.s1: .init(default: store.record(store.livePaperSlot(StoreFixture.otherSaverPath)),
                                                displays: [store.a: store.record(store.placeholder)])]
                try store.data(split).write(to: sb.store)
                try expectEqual(wallpaper.selectionState(), .partly(.init(displays: 1, missing: 1)))
                try expectEqual(try sb.document().selection(of: wallpaper.module).displaysWithLivePaper, [])
                // A store in an unknown format: the scan can't tell displays apart — never "every display".
                let config = StoreFixture.moduleConfiguration(StoreFixture.livePaperPath)
                try PlistValue.dictionary(["Displays": .dictionary(["X": .dictionary(["Idle": .dictionary(["Choice": .data(config)])])])])
                    .binaryData().write(to: sb.store)
                try expectEqual(wallpaper.selectionState(), .unknown)
                try expect(wallpaper.isSelected(), "uninstall still finds it")
                try PlistValue.dictionary(["Displays": .dictionary(["X": .dictionary(["Idle": .dictionary(["Choice": .data(StoreFixture.moduleConfiguration(StoreFixture.otherSaverPath))])])])])
                    .binaryData().write(to: sb.store)
                try expectEqual(wallpaper.selectionState(), .none)
                try FileManager.default.removeItem(at: sb.store)
                try expectEqual(wallpaper.selectionState(), .none)
            }
            // InstallStatus: `saverSelected` means every display; the old initialiser still reads right.
            try expectEqual(InstallStatus(saverSelected: true).saverSelection, .everyDisplay)
            try expectEqual(InstallStatus().saverSelection, .none)
            let unknown = InstallStatus(saverSelection: .unknown)
            try expect(!unknown.saverSelected && !unknown.saverPartlySelected && unknown.saverSelectionUnknown)
            var partly = InstallStatus(saverSelection: .partly(.init(displays: 6, missing: 4)))
            try expect(!partly.saverSelected && partly.saverPartlySelected)
            partly.saverSelected = true
            try expect(partly.saverSelection == .everyDisplay && !partly.saverPartlySelected)
        },
        TestCase(name: "wallpaper.every-display.plan") {
            let module = StoreFixture.livePaper, store = RealShapedStore.self
            let date = Date(timeIntervalSinceReferenceDate: 800_000_000.5)
            let doc = try store.document(store.reverted(livePaper: StoreFixture.livePaperPath))
            let plan = try doc.planSelect(module, at: date)
            // SystemDefault and the 11 placeholders; a and b already choose LivePaper at this location.
            try expectEqual(plan.paths, ([.systemDefault] + store.placeholderDisplayPaths).sorted())
            try expect(plan.changes.allSatisfy { $0.recordsOriginal && WallpaperSlot.isInherit($0.before) })
            let edited = try doc.applying(plan)
            try WallpaperStoreVerifier.verify(edited: edited.data(), original: doc, plan: plan)
            try expectEqual(desktopSlots(edited), desktopSlots(doc))
            for space in ["", store.s1, store.s2, store.s3] {
                try expectEqual(edited.idleSlot(at: .spaceDefault(space)), doc.idleSlot(at: .spaceDefault(space)))
            }
            try expect(edited.selection(of: module).isSelectedEverywhere)
            try check(try edited.planSelect(module, at: date).isEmpty, "idempotent")
            // The quiet re-apply plans the same but for s3's record of b: it falls back to b's own
            // record, which is LivePaper's already.
            try expectEqual(try doc.planSelect(module, at: date, scope: .placeholdersOnly).paths, plan.paths.filter { $0 != store.s3b })
            // The manifest keeps every placeholder, so uninstall puts exactly it back.
            let manifest = try WallpaperSelectionManifest(module: module.moduleURLString, createdAt: date).recording(plan, module: module, at: date)
            try expectEqual(manifest.slots.map(\.record), plan.paths)
            try expect(manifest.slots.allSatisfy { $0.provider == WallpaperSlot.inheritProvider && $0.configuration == Data() })
            let restore = try edited.planRestore(manifest, module: module, at: date.addingTimeInterval(60), moduleExists: { _ in true })
            let restored = try edited.applying(restore)
            try expect(plan.paths.allSatisfy { restored.idleSlot(at: $0) == doc.idleSlot(at: $0) }, "the placeholders are back byte for byte")
            try expect(restored.selection(of: module).livePaper.isEmpty)

            // The quiet re-apply never touches an explicit choice, nor what inherits one: another saver on
            // c (its first-Space record on the placeholder) and on s2's Default (its display d there on the placeholder).
            var mixed = store.reverted(livePaper: StoreFixture.livePaperPath)
            mixed.displays[store.c] = store.record(store.livePaperSlot(StoreFixture.otherSaverPath))
            mixed.spaces[store.s2]?.default = store.record(store.livePaperSlot(StoreFixture.otherSaverPath))
            let mixedDoc = try store.document(mixed)
            let quiet = try mixedDoc.planSelect(module, at: date, scope: .placeholdersOnly)
            let inheritsOther: Set<WallpaperRecordPath> = [.display(store.c), .spaceDisplay(space: "", display: store.c),
                                                           .spaceDisplay(space: store.s2, display: store.d)]
            try expectEqual(quiet.paths, ([.systemDefault] + store.placeholderDisplayPaths.filter { !inheritsOther.contains($0) && $0 != store.s3b }).sorted())
            try expect(quiet.changes.allSatisfy { WallpaperSlot.isInherit($0.before) && $0.recordsOriginal })
            try expectEqual(mixedDoc.resolution(of: .spaceDisplay(space: "", display: store.c), module: module), .other(at: .display(store.c)))
            // The user's own selection replaces them, as System Settings does (originals recorded).
            let full = try mixedDoc.planSelect(module, at: date)
            try expect(full.paths.contains(.display(store.c)) && full.paths.contains(.spaceDefault(store.s2)))
            try expect(full.changes.allSatisfy(\.recordsOriginal))
            // Nothing falls back to macOS's default: no plan, though SystemDefault holds the placeholder
            // (not worth a WallpaperAgent restart on its own).
            let kept = try store.document(store.filledDefaultKept(livePaper: StoreFixture.livePaperPath))
            try check(try kept.planSelect(module, at: date, scope: .placeholdersOnly).isEmpty)
            try expectEqual(try kept.planSelect(module, at: date).paths, [.systemDefault])
            // Already on every display at the installed location, from the displays' own records:
            // nothing for a user's selection to do (InstallService.selectSaver) — the agent kept its
            // placeholder in SystemDefault, or every display record chose it. System Settings' own
            // selection (placeholders inheriting SystemDefault or a Space's Default) gets the display
            // placeholders filled: the agent copies them into SystemDefault at its next launch.
            let systemSettings = try WallpaperStoreDocument(data: StoreFixture.data(saver: StoreFixture.livePaperPath))
            try expect(kept.isCurrentChoiceOnEveryDisplay(module) && !systemSettings.isCurrentChoiceOnEveryDisplay(module))
            try expectEqual(try systemSettings.planSelect(module, at: date).paths, StoreFixture.placeholderDisplayPaths.sorted())
            try check(try WallpaperStoreDocument(data: WallpaperStoreSchema.encode(StoreFixture.allDisplaysExplicit(saver: StoreFixture.livePaperPath)))
                .isCurrentChoiceOnEveryDisplay(module))
            let byHand = try store.document(store.systemSettings(livePaper: StoreFixture.livePaperPath))
            try expect(!byHand.isCurrentChoiceOnEveryDisplay(module))
            try expectEqual(try byHand.planSelect(module, at: date).paths, store.placeholderDisplayPaths.sorted())
            // The quiet re-apply fills them too (not s3's record of b, which inherits b's own record).
            try expectEqual(try byHand.planSelect(module, at: date, scope: .placeholdersOnly).paths,
                            store.placeholderDisplayPaths.filter { $0 != store.s3b }.sorted())
            // …but nothing while LivePaper isn't chosen anywhere: the user switched away, or every slot was reset.
            try check(try store.document(store.fresh()).planSelect(module, at: date, scope: .placeholdersOnly).isEmpty)
            try check(try store.document(store.afterFill(livePaper: StoreFixture.otherSaverPath)).planSelect(module, at: date, scope: .placeholdersOnly).isEmpty)
            try expect(!doc.isCurrentChoiceOnEveryDisplay(module), "four displays fall back to macOS's default")
            let elsewhere = WallpaperSaverModule(url: URL(fileURLWithPath: "/Library/Screen Savers/LivePaper.saver"))
            try expect(!systemSettings.isCurrentChoiceOnEveryDisplay(elsewhere), "LivePaper.saver at another location gets rewritten")
            try check(try store.document(.init(systemDefault: store.record(store.livePaperSlot(StoreFixture.livePaperPath))))
                .isCurrentChoiceOnEveryDisplay(module), "no display record yet: SystemDefault")
            // A display connected since gets LivePaper, SystemDefault with it — its record in the first
            // Space too: that falls back to the Space's Default, which the agent derives from the
            // displays it shows.
            let connected = try store.document(store.connect(store.display("9"), to: store.filledDefaultKept(livePaper: StoreFixture.livePaperPath)))
            try expectEqual(try connected.planSelect(module, at: date, scope: .placeholdersOnly).paths,
                            [.systemDefault, .display(store.display("9")), .spaceDisplay(space: "", display: store.display("9"))])
            var noSpaceDefault = store.connect(store.display("9"), to: store.filledDefaultKept(livePaper: StoreFixture.livePaperPath))
            noSpaceDefault.spaces[""]?.default = store.record(store.placeholder)
            try expectEqual(try store.document(noSpaceDefault).planSelect(module, at: date, scope: .placeholdersOnly).paths,
                            [.systemDefault, .display(store.display("9")), .spaceDisplay(space: "", display: store.display("9"))])
        },
        TestCase(name: "wallpaper.every-display.confirm") {
            let module = StoreFixture.livePaper, store = RealShapedStore.self
            let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
            let doc = try store.document(store.reverted(livePaper: StoreFixture.livePaperPath))
            let plan = try doc.planSelect(module, at: date)
            let written = try doc.applying(plan)
            try expectEqual(WallpaperStoreVerifier.confirm(current: written, original: doc, plan: plan, acceptingRewrittenDefaults: true), .confirmed)
            // The agent put its own placeholder back into SystemDefault (and a Space Default): every
            // display shows what was asked for, so that counts — for select and restore, not a rollback.
            let kept = try written.replacingIdleSlots([.systemDefault: doc.idleSlot(at: .systemDefault)!])
            try expectEqual(WallpaperStoreVerifier.confirm(current: kept, original: doc, plan: plan, acceptingRewrittenDefaults: true),
                            .confirmedDefaultsRewritten([.systemDefault]))
            try expectEqual(WallpaperStoreVerifier.confirm(current: kept, original: doc, plan: plan), .changeLost([.systemDefault]))
            // A display slot lost too: not what was asked for.
            let display = WallpaperRecordPath.display(store.c)
            let lost = try kept.replacingIdleSlots([display: doc.idleSlot(at: display)!])
            try expectEqual(WallpaperStoreVerifier.confirm(current: lost, original: doc, plan: plan, acceptingRewrittenDefaults: true),
                            .changeLost([.systemDefault, display]))
            // SystemDefault alone, while the displays fall back to it: lost.
            let rootOnly = WallpaperStorePlan(changes: [WallpaperSlotChange(path: .systemDefault, before: doc.idleSlot(at: .systemDefault)!,
                                                                            after: try module.slot(at: date), recordsOriginal: true)])
            try expectEqual(WallpaperStoreVerifier.confirm(current: doc, original: doc, plan: rootOnly, acceptingRewrittenDefaults: true),
                            .changeLost([.systemDefault]))
            // A restore of another saver into SystemDefault that the agent replaced with a display's
            // placeholder: what the displays show isn't that saver — lost, not "rewritten".
            let other = try WallpaperSaverModule(url: URL(fileURLWithPath: StoreFixture.otherSaverPath)).slot(at: date)
            let restoreRoot = WallpaperStorePlan(changes: [WallpaperSlotChange(path: .systemDefault, before: try module.slot(at: date),
                                                                               after: other, recordsOriginal: false)])
            try expectEqual(WallpaperStoreVerifier.confirm(current: doc, original: doc, plan: restoreRoot, acceptingRewrittenDefaults: true),
                            .changeLost([.systemDefault]))
            // With the displays holding it themselves, the same rewrite is fine.
            let pinned = WallpaperStorePlan(changes: restoreRoot.changes + store.placeholderDisplayPaths.sorted().map {
                WallpaperSlotChange(path: $0, before: doc.idleSlot(at: $0)!, after: other, recordsOriginal: false)
            })
            let pinnedKept = try doc.applying(pinned).replacingIdleSlots([.systemDefault: doc.idleSlot(at: .systemDefault)!])
            try expectEqual(WallpaperStoreVerifier.confirm(current: pinnedKept, original: doc, plan: pinned, acceptingRewrittenDefaults: true),
                            .confirmedDefaultsRewritten([.systemDefault]))
        },
    ] }
}

// MARK: - Applier (with the agent as it was seen)

extension SelfTests {
    fileprivate static var everyDisplayApplier: [TestCase] { [
        TestCase(name: "wallpaper.every-display.agent") {
            let store = RealShapedStore.self
            // SystemDefault alone (what LivePaper did before): the agent writes the placeholder back each time.
            try StoreSandbox.with("every-display-old") { sb in
                try store.data(store.reverted(livePaper: sb.saver.path)).write(to: sb.store)
                let system = FakeWallpaperSystem(store: sb.store), clock = FakeClock()
                system.onRestart = { _ in try store.deriveDefaults(at: sb.store) }
                var reason = ""
                do {
                    _ = try applier(sb, system, clock).apply(checkModulePolicy: true, acceptingRewrittenDefaults: true, plan: { doc in
                        WallpaperStorePlan(changes: [WallpaperSlotChange(path: .systemDefault, before: doc.idleSlot(at: .systemDefault)!,
                                                                         after: try sb.module.slot(at: clock.now()), recordsOriginal: true)])
                    })
                } catch WallpaperStoreError.notConfirmed(let why) { reason = why }
                try expect(reason.hasPrefix("WallpaperAgent overwrote SystemDefault"), reason)
                try expectEqual(system.restarts, 3)
                try expectEqual(WallpaperStore(url: sb.store, saver: sb.saver).selectionState(), .partly(.init(displays: 6, missing: 4)))
            }
            // The selection fills the displays' placeholders: kept, and the agent puts LivePaper into
            // SystemDefault and the Defaults of the Spaces in use itself. One restart.
            try StoreSandbox.with("every-display-fill") { sb in
                try store.data(store.reverted(livePaper: sb.saver.path)).write(to: sb.store)
                let before = try sb.document()
                let system = FakeWallpaperSystem(store: sb.store), clock = FakeClock()
                system.onRestart = { _ in try store.deriveDefaults(at: sb.store) }
                let report = try applier(sb, system, clock).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup)
                try expectEqual(report, WallpaperApplyReport(outcome: .applied, changed: ([.systemDefault] + store.placeholderDisplayPaths).sorted(),
                                                             attempts: 1, agentRestarts: 1))
                let after = try sb.document()
                // The store has the shape seen on the Mac afterwards.
                let seen = try store.document(store.afterFill(livePaper: sb.saver.path))
                for record in seen.records {
                    try expect(after.idleSlot(at: record.path).map { WallpaperSlot.sameChoices($0, record.idle!) } == true, "\(record.path)")
                }
                try expectEqual(desktopSlots(after), desktopSlots(before))
                try expectEqual(WallpaperStore(url: sb.store, saver: sb.saver).selectionState(), .everyDisplay)
                // Every placeholder is in the manifest: the restore puts exactly those back; a and b,
                // LivePaper's before this selection without a recorded original, get the placeholder.
                try expectEqual(try WallpaperSelectionManifest.load(from: sb.manifest)?.slots.map(\.record), report.changed)
                let restored = try applier(sb, system, clock).restore(sb.module, manifestURL: sb.manifest)
                try expectEqual(restored.outcome, .applied)
                let undone = try sb.document()
                try expect(report.changed.allSatisfy { undone.idleSlot(at: $0) == before.idleSlot(at: $0) }, "the placeholders are back exactly")
                try expect(undone.records.allSatisfy { $0.idle.map(WallpaperSlot.isInherit) == true }, "nothing names LivePaper")
                try expectEqual(desktopSlots(undone), desktopSlots(before))
                try expectEqual(system.restarts, 2)
            }
            // A Mac whose screen saver was never chosen: select, then restore, gives back the very same bytes.
            try StoreSandbox.with("every-display-fresh") { sb in
                try store.data(store.fresh()).write(to: sb.store)
                let original = try sb.bytes()
                let system = FakeWallpaperSystem(store: sb.store), clock = FakeClock()
                system.onRestart = { _ in try store.deriveDefaults(at: sb.store) }
                let report = try applier(sb, system, clock).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup)
                try expectEqual(report.changed.count, 16)   // SystemDefault and all 15 display slots
                try check(try sb.document().selection(of: sb.module).isSelectedOnEveryDisplay)
                _ = try applier(sb, system, clock).restore(sb.module, manifestURL: sb.manifest)
                try expectEqual(try sb.bytes(), original)
            }
        },
        TestCase(name: "wallpaper.every-display.agent-keeps-default") {
            // The restarted agent keeps the placeholder it had in SystemDefault but every display slot:
            // every display shows LivePaper, so the selection stands — after one restart, not three.
            let store = RealShapedStore.self
            try StoreSandbox.with("every-display-kept") { sb in
                try store.data(store.reverted(livePaper: sb.saver.path)).write(to: sb.store)
                let system = FakeWallpaperSystem(store: sb.store), clock = FakeClock()
                system.onRestart = { _ in try store.keepPlaceholderInSystemDefault(at: sb.store) }
                let report = try applier(sb, system, clock).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup)
                try expectEqual(report, WallpaperApplyReport(outcome: .applied, changed: ([.systemDefault] + store.placeholderDisplayPaths).sorted(),
                                                             attempts: 1, agentRestarts: 1, rewrittenByAgent: [.systemDefault]))
                let after = try sb.document().selection(of: sb.module)
                try expect(after.isSelectedOnEveryDisplay && !after.isSelectedEverywhere)
                let entry = try WallpaperSelectionManifest.load(from: sb.manifest)?.entry(for: .systemDefault)
                try expectEqual(entry?.provider, WallpaperSlot.inheritProvider)
                // What the agent wrote in LivePaper's place is noted: uninstall restores it too.
                let current = try sb.document().idleSlot(at: .systemDefault)!
                try expect(entry?.agentSlot != nil && entry?.agentReplaced(current) == true)
            }
            // Through the installer: selected, and the app has nothing to re-apply.
            try StoreSandbox.with("every-display-kept-install") { sb in
                try store.data(store.reverted(livePaper: sb.saver.path)).write(to: sb.store)
                let fx = InstallFixture(sb)
                fx.system.onRestart = { _ in try store.keepPlaceholderInSystemDefault(at: sb.store) }
                let service = fx.service()
                try check(try service.selectSaver())
                try expectEqual(service.transcript.last, InstallStep(title: selectTitle, outcome: .done))
                try expectEqual(fx.system.restarts, 1)
                let status = service.status()
                try expect(status.saverSelected && !status.saverPartlySelected && !status.selectionReapplyNeeded, "\(status)")
                // Selecting again finds every display on LivePaper: no second restart for a SystemDefault
                // the agent would keep the same way.
                try check(try service.selectSaver())
                try expectEqual(service.transcript.last, InstallStep(title: selectTitle, outcome: .skipped("already selected")))
                try expectEqual(fx.system.restarts, 1)
            }
        },
    ] }
}

// MARK: - InstallService

extension SelfTests {
    fileprivate static var everyDisplayInstall: [TestCase] { [
        TestCase(name: "wallpaper.every-display.reapply") {
            let store = RealShapedStore.self
            let g = store.display("9"), h = store.display("8")
            try StoreSandbox.with("reapply") { sb in
                // After a selection the agent kept the placeholder in SystemDefault; then a display was connected.
                try store.data(store.connect(g, to: store.filledDefaultKept(livePaper: sb.saver.path))).write(to: sb.store)
                let fx = InstallFixture(sb)
                fx.system.onRestart = { _ in try store.deriveDefaults(at: sb.store) }
                var status = fx.service().status()
                try expectEqual(status.saverSelection, .partly(.init(displays: 7, missing: 1)))
                // LivePaper doesn't own the selection (no manifest): left alone.
                try expect(!status.selectionReapplyNeeded)
                try expectEqual(try fx.service().reapplySelectionIfNeeded(), .notNeeded("LivePaper didn't make the selection"))
                // It does (its selection's manifest, or the stub it leaves when it finds itself selected).
                try FileManager.default.createDirectory(at: fx.paths.backups, withIntermediateDirectories: true)
                try WallpaperSelectionManifest(module: sb.module.moduleURLString, createdAt: Date()).write(to: fx.paths.wallpaperSelectionBackup)
                try expect(fx.service().status().selectionReapplyNeeded)
                let before = try sb.document()
                let service = fx.service()
                try expectEqual(try service.reapplySelectionIfNeeded(), .reapplied(displays: 1))
                try expectEqual(service.transcript.last, InstallStep(title: InstallService.reapplySelectionTitle, outcome: .done))
                try expectEqual(fx.system.restarts, 1)
                // Only the new display's placeholders (and SystemDefault's) were written — its first-Space
                // record too: it inherited LivePaper only from that Space's Default.
                let after = try sb.document()
                let written: [WallpaperRecordPath] = [.systemDefault, .display(g), .spaceDisplay(space: "", display: g)]
                try expectEqual(changedIdlePaths(before, after).filter { $0.displayID != nil || $0 == .systemDefault }, written)
                try expectEqual(desktopSlots(after), desktopSlots(before))
                status = fx.service().status()
                try expect(status.saverSelected && !status.selectionReapplyNeeded, "\(status)")
                let manifest = try WallpaperSelectionManifest.load(from: fx.paths.wallpaperSelectionBackup)
                try expectEqual(manifest?.slots.map(\.record), written)
                try expect(manifest?.slots.allSatisfy { $0.provider == WallpaperSlot.inheritProvider } == true)
                // Again: nothing to do, no restart.
                try expectEqual(try fx.service().reapplySelectionIfNeeded(), .notNeeded("no display falls back to macOS\u{2019}s default screen saver"))
                try expectEqual(fx.system.restarts, 1)
                // Locked: refused, nothing written.
                var next = try WallpaperStoreSchema.decode(sb.bytes())
                next.systemDefault = store.record(store.placeholder)
                try store.data(store.connect(h, to: next)).write(to: sb.store)
                let locked = try sb.bytes()
                fx.system.session = .locked
                try expectEqual(try fx.service().reapplySelectionIfNeeded(), .refused(WallpaperStoreError.sessionLocked.localizedDescription))
                try expectEqual(try sb.bytes(), locked)
                try expectEqual(fx.system.restarts, 1)
                fx.system.session = .unlocked
                // Never after an uninstall, nor without the saver.
                try Data().write(to: fx.paths.uninstallMarker)
                try expectEqual(try fx.service().reapplySelectionIfNeeded(), .notNeeded("LivePaper was uninstalled"))
                try expect(!fx.service().status().selectionReapplyNeeded)
                try FileManager.default.removeItem(at: fx.paths.uninstallMarker)
                try FileManager.default.removeItem(at: sb.saver)
                try expectEqual(try fx.service().reapplySelectionIfNeeded(), .notNeeded("the screen saver isn't installed"))
                try expectEqual(try sb.bytes(), locked)
                // A dry run only plans.
            }
            // Never over a screen saver the user chose: they picked another one in System Settings
            // (SystemDefault and every explicit slot), and a display connected since copied SystemDefault.
            try StoreSandbox.with("reapply-other") { sb in
                try store.data(store.connect(g, to: store.afterFill(livePaper: sb.otherSaver.path))).write(to: sb.store)
                let fx = InstallFixture(sb)
                try FileManager.default.createDirectory(at: fx.paths.backups, withIntermediateDirectories: true)
                try WallpaperSelectionManifest(module: sb.module.moduleURLString, createdAt: Date()).write(to: fx.paths.wallpaperSelectionBackup)
                let original = try sb.bytes()
                let status = fx.service().status()
                try expect(status.saverSelection == .none && !status.selectionReapplyNeeded, "\(status)")
                try expectEqual(try fx.service().reapplySelectionIfNeeded(), .notNeeded(notChosen))
                try expectEqual(try sb.bytes(), original)
                try expectEqual(fx.system.restarts, 0)
            }
            // The manifest outlives a switch away from LivePaper: a store that names LivePaper nowhere
            // any more (every slot reset, or another saver picked) is left to the user — even with every
            // display on macOS's default.
            try StoreSandbox.with("reapply-not-chosen") { sb in
                try store.data(store.fresh()).write(to: sb.store)
                let fx = InstallFixture(sb)
                try FileManager.default.createDirectory(at: fx.paths.backups, withIntermediateDirectories: true)
                try WallpaperSelectionManifest(module: sb.module.moduleURLString, createdAt: Date()).write(to: fx.paths.wallpaperSelectionBackup)
                let original = try sb.bytes()
                let status = fx.service().status()
                try expect(status.saverSelection == .none && !status.selectionReapplyNeeded, "\(status)")
                try expectEqual(try fx.service().reapplySelectionIfNeeded(), .notNeeded(notChosen))
                try expectEqual(try sb.bytes(), original)
                try expectEqual(fx.system.restarts, 0)
            }
            // Another saver chosen for one display's own record (c), and for a Space's Default whose
            // record of e holds the placeholder (it inherits that choice); a third display fell back to
            // the default: only the one that fell back.
            try StoreSandbox.with("reapply-mixed") { sb in
                var index = store.connect(g, to: store.filledDefaultKept(livePaper: sb.saver.path))
                let other = store.record(store.livePaperSlot(sb.otherSaver.path))
                index.displays[store.c] = other
                index.spaces[store.s1]?.default = other
                index.spaces[store.s1]?.displays[store.e] = store.record(store.placeholder)
                try store.data(index).write(to: sb.store)
                let fx = InstallFixture(sb)
                try FileManager.default.createDirectory(at: fx.paths.backups, withIntermediateDirectories: true)
                try WallpaperSelectionManifest(module: sb.module.moduleURLString, createdAt: Date()).write(to: fx.paths.wallpaperSelectionBackup)
                try expectEqual(fx.service().status().saverSelection, .partly(.init(displays: 7, missing: 3)))
                let before = try sb.document()
                try expectEqual(before.resolution(of: .spaceDisplay(space: store.s1, display: store.e), module: sb.module), .other(at: .spaceDefault(store.s1)))
                try expectEqual(try fx.service().reapplySelectionIfNeeded(), .reapplied(displays: 1))
                let after = try sb.document()
                try expectEqual(changedIdlePaths(before, after), [.systemDefault, .display(g), .spaceDisplay(space: "", display: g)])
                try expectEqual(fx.service().status().saverSelection, .partly(.init(displays: 7, missing: 2)))
                try expect(!fx.service().status().selectionReapplyNeeded, "what the user chose stays theirs")
            }
            // A dry run plans and changes nothing.
            try StoreSandbox.with("reapply-dry") { sb in
                try store.data(store.connect(g, to: store.filledDefaultKept(livePaper: sb.saver.path))).write(to: sb.store)
                let fx = InstallFixture(sb)
                try FileManager.default.createDirectory(at: fx.paths.backups, withIntermediateDirectories: true)
                try WallpaperSelectionManifest(module: sb.module.moduleURLString, createdAt: Date()).write(to: fx.paths.wallpaperSelectionBackup)
                let original = try sb.bytes()
                let dry = fx.service(dryRun: true)
                try expectEqual(try dry.reapplySelectionIfNeeded(), .notNeeded("dry run"))
                try expectEqual(dry.transcript, [InstallStep(title: InstallService.reapplySelectionTitle, outcome: .planned)])
                try expectEqual(try sb.bytes(), original)
            }
        },
        TestCase(name: "wallpaper.every-display.uninstall") {
            // Select on the store the Mac had, then uninstall: the 12 slots LivePaper filled get their
            // placeholders back exactly, nothing names LivePaper, and the saver goes.
            let store = RealShapedStore.self
            try StoreSandbox.with("every-display-uninstall") { sb in
                try store.data(store.reverted(livePaper: sb.saver.path)).write(to: sb.store)
                let before = try sb.document()
                let fx = InstallFixture(sb)
                fx.system.onRestart = { _ in try store.deriveDefaults(at: sb.store) }
                try check(try fx.service().selectSaver())
                try expectEqual(fx.service().status().saverSelection, .everyDisplay)
                let steps = fx.service().performUninstall(removeLibrary: false)
                try expectEqual(steps.first { $0.title == restoreTitle }?.outcome, .done)
                try expect(steps.allSatisfy { !$0.isFailure } && !sb.exists(sb.saver), "\(steps)")
                let after = try sb.document()
                try expect((([.systemDefault] + store.placeholderDisplayPaths) as [WallpaperRecordPath]).allSatisfy {
                    after.idleSlot(at: $0) == before.idleSlot(at: $0)
                }, "placeholders back exactly")
                try expect(after.selection(of: sb.module).livePaper.isEmpty)
                try expectEqual(desktopSlots(after), desktopSlots(before))
                try expectEqual(fx.system.restarts, 2)
            }
        },
    ] }
}

// MARK: - Uninstall with a previous screen saver; the re-apply's bookkeeping

extension SelfTests {
    fileprivate static var everyDisplayRestore: [TestCase] { [
        TestCase(name: "wallpaper.every-display.uninstall-previous-saver") {
            // The most common store of someone who once picked a saver in System Settings: that saver in
            // SystemDefault, every display record on the placeholder. Select, then uninstall — with the
            // agent re-encoding as it read, deriving the defaults from the displays it shows (§5.5), and
            // keeping its placeholder in SystemDefault: every display shows the previous saver again,
            // from its own record, and keeps showing it after another agent launch.
            let store = RealShapedStore.self
            let agents: [(String, (StoreSandbox) -> ((Int) throws -> Void)?)] = [
                ("plain", { _ in nil }),
                ("derives", { sb in { _ in try store.deriveDefaults(at: sb.store) } }),
                ("keeps-default", { sb in { _ in try store.keepPlaceholderInSystemDefault(at: sb.store) } }),
            ]
            for (name, agent) in agents {
                try StoreSandbox.with("previous-\(name)") { sb in
                    try store.data(store.freshWithDefault(sb.otherSaver.path)).write(to: sb.store)
                    let before = try sb.document()
                    try expect(Set(store.shown(before).values) == ["Example.saver"], "\(name): every display shows the previous saver")
                    let fx = InstallFixture(sb)
                    fx.system.onRestart = agent(sb)
                    try check(try fx.service().selectSaver())
                    try expectEqual(fx.service().status().saverSelection, .everyDisplay)
                    let manifest = try WallpaperSelectionManifest.load(from: fx.paths.wallpaperSelectionBackup)
                    try expectEqual(manifest?.entry(for: .systemDefault)?.configuration, StoreFixture.moduleConfiguration(sb.otherSaver.path))
                    try expect((manifest?.entry(for: .systemDefault)?.agentSlot != nil) == (name == "keeps-default"), "\(name): \(String(describing: manifest))")
                    let steps = fx.service().performUninstall(removeLibrary: false)
                    try expectEqual(steps.first { $0.title == restoreTitle }?.outcome, .done)
                    try expect(steps.allSatisfy { !$0.isFailure } && !sb.exists(sb.saver) && !sb.exists(fx.paths.backups), "\(name): \(steps)")
                    let after = try sb.document()
                    try expectEqual(store.shown(after), store.shown(before))
                    try expect(after.records.filter { $0.path.displayID != nil }.allSatisfy { after.resolvedSlot(of: $0.path)?.at.displayID != nil },
                               "\(name): the displays hold it themselves")
                    try expect(after.selection(of: sb.module).livePaper.isEmpty)
                    try expectEqual(desktopSlots(after), desktopSlots(before))
                    if name != "keeps-default" {
                        try expect(after.idleSlot(at: .systemDefault).map { WallpaperSlot.sameChoices($0, before.idleSlot(at: .systemDefault)!) } == true)
                    }
                    try fx.system.restartWallpaperAgent()   // the next login
                    try expectEqual(store.shown(try sb.document()), store.shown(before))
                }
            }
            // The owner's store (SystemDefault on the placeholder) still comes back byte for byte: no
            // display inherits an explicit choice there.
            try StoreSandbox.with("previous-placeholder") { sb in
                try store.data(store.reverted(livePaper: sb.saver.path)).write(to: sb.store)
                let before = try sb.document()
                let fx = InstallFixture(sb)
                try check(try fx.service().selectSaver())
                _ = fx.service().performUninstall(removeLibrary: false)
                let after = try sb.document()
                try expect((([.systemDefault] + store.placeholderDisplayPaths) as [WallpaperRecordPath]).allSatisfy {
                    after.idleSlot(at: $0) == before.idleSlot(at: $0)
                }, "placeholders back exactly")
            }
        },
        TestCase(name: "wallpaper.every-display.uninstall-not-kept") {
            // The restarted agent keeps nothing the restore put back (here: it writes the placeholder over
            // every slot that doesn't name LivePaper). Nothing names LivePaper afterwards, so the re-plan
            // is empty — but the displays don't show the previous saver: the step fails, names it, and
            // the saver, the manifest and every backup stay.
            let store = RealShapedStore.self
            try StoreSandbox.with("not-kept") { sb in
                try store.data(store.freshWithDefault(sb.otherSaver.path)).write(to: sb.store)
                let fx = InstallFixture(sb)
                try check(try fx.service().selectSaver())
                fx.system.onRestart = { _ in try store.resetIdle(at: sb.store, keeping: sb.module) }
                let steps = fx.service().performUninstall(removeLibrary: false)
                guard case .failed(let why)? = steps.first(where: { $0.title == restoreTitle })?.outcome else {
                    throw TestFailure(description: "\(steps)")
                }
                try expect(why.contains("couldn't confirm that your previous screen saver is back") && why.contains("\u{201C}Example\u{201D}")
                           && why.contains("run uninstall again"), why)
                try expect(why.contains(" and 13 more"), "names a few slots, not all 16: \(why)")
                try expectEqual(steps.first { $0.title == "Remove \(fx.paths.installedSaver.path)" }?.outcome,
                                .skipped("kept while it is still the selected screen saver; run uninstall again"))
                try expect(sb.exists(sb.saver) && sb.exists(fx.paths.wallpaperSelectionBackup) && sb.exists(fx.paths.wallpaperStoreBackup), "\(steps)")
                try expectEqual(fx.system.restarts, 2)   // select, and one restore round (the second had nothing to write)
                // The user picks it again (or another one) and runs uninstall again: it finishes.
                fx.system.onRestart = nil
                let again = fx.service().performUninstall(removeLibrary: false)
                try expectEqual(again.first { $0.title == restoreTitle }?.outcome, .skipped("the screen saver was changed since"))
                try expect(!sb.exists(sb.saver) && again.allSatisfy { !$0.isFailure }, "\(again)")
            }
        },
        TestCase(name: "wallpaper.every-display.reapply-keeps-originals") {
            // Another tool's uninstaller puts its old store back after LivePaper's selection (SystemDefault
            // and c–f on the placeholder, a and b still LivePaper's): the quiet re-apply fills them again
            // but keeps every original recorded before — the user's own saver in SystemDefault above all.
            let store = RealShapedStore.self
            try StoreSandbox.with("reapply-originals") { sb in
                try store.data(store.freshWithDefault(sb.otherSaver.path)).write(to: sb.store)
                let fx = InstallFixture(sb)
                try check(try fx.service().selectSaver())
                let recorded = try WallpaperSelectionManifest.load(from: fx.paths.wallpaperSelectionBackup)
                try store.data(store.reverted(livePaper: sb.saver.path)).write(to: sb.store)
                try expect(fx.service().status().selectionReapplyNeeded)
                try expectEqual(try fx.service().reapplySelectionIfNeeded(), .reapplied(displays: 4))
                let manifest = try WallpaperSelectionManifest.load(from: fx.paths.wallpaperSelectionBackup)
                try expectEqual(manifest?.slots, recorded?.slots)
                try expectEqual(manifest?.entry(for: .systemDefault)?.configuration, StoreFixture.moduleConfiguration(sb.otherSaver.path))
                // The user's own selection after the same reset records nothing over them either.
                try store.data(store.reverted(livePaper: sb.saver.path)).write(to: sb.store)
                try check(try fx.service().selectSaver())
                try expectEqual(try WallpaperSelectionManifest.load(from: fx.paths.wallpaperSelectionBackup)?.slots, recorded?.slots)
                // Uninstall: the previous saver on every display.
                let steps = fx.service().performUninstall(removeLibrary: false)
                try expect(steps.allSatisfy { !$0.isFailure }, "\(steps)")
                let shown = store.shown(try sb.document())
                try expect(Set(shown.values) == ["Example.saver"], "\(shown)")
            }
            // The manifest rule itself: a placeholder never replaces a recorded original; an explicit
            // choice (the user's newer one) does.
            let module = StoreFixture.livePaper, t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
            let doc = try store.document(store.freshWithDefault(StoreFixture.otherSaverPath))
            let first = try WallpaperSelectionManifest(module: module.moduleURLString, createdAt: t0).recording(doc.planSelect(module, at: t0), module: module, at: t0)
            let reset = try store.document(store.reverted(livePaper: StoreFixture.livePaperPath))
            let later = try first.recording(reset.planSelect(module, at: t0.addingTimeInterval(60)), module: module, at: t0.addingTimeInterval(60))
            try expectEqual(later.slots, first.slots)
            let chosen = try WallpaperSaverModule(url: URL(fileURLWithPath: "/Users/user/Library/Screen Savers/Chosen.saver")).slot(at: t0)
            let switched = try reset.replacingIdleSlots([.systemDefault: chosen])
            let newer = try first.recording(switched.planSelect(module, at: t0), module: module, at: t0)
            try expectEqual(try newer.entry(for: .systemDefault)?.originalSlot(), chosen)
        },
        TestCase(name: "wallpaper.every-display.reapply-under-lock") {
            // `livepaper uninstall` starts in Terminal right after the app's check passed: the re-apply
            // looks again once it holds the store lock (here: while it waits for a quiet store) and
            // writes nothing — no manifest made again, no agent restart.
            let store = RealShapedStore.self
            try StoreSandbox.with("reapply-lock") { sb in
                try store.data(store.connect(store.display("9"), to: store.filledDefaultKept(livePaper: sb.saver.path))).write(to: sb.store)
                let fx = InstallFixture(sb)
                try FileManager.default.createDirectory(at: fx.paths.backups, withIntermediateDirectories: true)
                try WallpaperSelectionManifest(module: sb.module.moduleURLString, createdAt: Date()).write(to: fx.paths.wallpaperSelectionBackup)
                let original = try sb.bytes(), manifest = try Data(contentsOf: fx.paths.wallpaperSelectionBackup)
                try expect(fx.service().status().selectionReapplyNeeded)
                fx.clock.schedule(after: 0.1) { try? Data().write(to: fx.paths.uninstallMarker) }
                try expectEqual(try fx.service().reapplySelectionIfNeeded(), .notNeeded("LivePaper was uninstalled"))
                try expectEqual(try sb.bytes(), original)
                try expectEqual(try Data(contentsOf: fx.paths.wallpaperSelectionBackup), manifest)
                // The uninstall's restore already ran and deleted the manifest: not made again.
                try FileManager.default.removeItem(at: fx.paths.uninstallMarker)
                fx.clock.schedule(after: 0.1) { try? FileManager.default.removeItem(at: fx.paths.wallpaperSelectionBackup) }
                try expectEqual(try fx.service().reapplySelectionIfNeeded(), .notNeeded("LivePaper didn't make the selection"))
                try expect(!sb.exists(fx.paths.wallpaperSelectionBackup))
                try expectEqual(try sb.bytes(), original)
                // …and removed the saver: the store must never point at a deleted module.
                try manifest.write(to: fx.paths.wallpaperSelectionBackup)
                fx.clock.schedule(after: 0.1) { try? FileManager.default.removeItem(at: sb.saver) }
                guard case .refused(let why) = try fx.service().reapplySelectionIfNeeded() else { throw TestFailure(description: "not refused") }
                try expect(why.contains("isn't installed"), why)
                try expectEqual(try sb.bytes(), original)
                try expectEqual(fx.system.restarts, 0)
            }
            // A restore reads the manifest once it holds the lock: one written meanwhile counts.
            try StoreSandbox.with("restore-lock") { sb in
                try store.data(store.freshWithDefault(sb.otherSaver.path)).write(to: sb.store)
                let system = FakeWallpaperSystem(store: sb.store), clock = FakeClock()
                _ = try applier(sb, system, clock).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup)
                let manifest = try Data(contentsOf: sb.manifest)
                try FileManager.default.removeItem(at: sb.manifest)
                clock.schedule(after: 0.1) { try? manifest.write(to: sb.manifest) }
                let report = try applier(sb, system, clock).restore(sb.module, manifestURL: sb.manifest)
                try expect(report.builtinSaverPaths.isEmpty && !sb.exists(sb.manifest), "\(report)")
                let shown = store.shown(try sb.document())
                try expect(Set(shown.values) == ["Example.saver"], "\(shown)")
            }
        },
        TestCase(name: "wallpaper.every-display.system-settings") {
            // LivePaper picked in System Settings (the guided step): SystemDefault and a, b chose it, c–f
            // inherit it. Every display shows it — until the agent's next launch copies a display's
            // placeholder into SystemDefault (the reported bug, reproduced first).
            let store = RealShapedStore.self
            try StoreSandbox.with("by-hand-unfilled") { sb in
                try store.data(store.systemSettings(livePaper: sb.saver.path)).write(to: sb.store)
                let wallpaper = WallpaperStore(url: sb.store, saver: sb.saver)
                try expectEqual(wallpaper.selectionState(), .everyDisplay)
                try store.deriveDefaults(at: sb.store)
                try expectEqual(wallpaper.selectionState(), .partly(.init(displays: 6, missing: 4)))
            }
            // "Make LivePaper My Screen Saver" / `livepaper select` doesn't stop at "already selected":
            // it fills the placeholders, and the next launch keeps every display on LivePaper.
            try StoreSandbox.with("by-hand-select") { sb in
                try store.data(store.systemSettings(livePaper: sb.saver.path)).write(to: sb.store)
                let fx = InstallFixture(sb)
                fx.system.onRestart = { _ in try store.deriveDefaults(at: sb.store) }
                let service = fx.service()
                try check(try service.selectSaver())
                try expectEqual(service.transcript.last, InstallStep(title: selectTitle, outcome: .done))
                try expectEqual(fx.system.restarts, 1)
                let recorded = try WallpaperSelectionManifest.load(from: fx.paths.wallpaperSelectionBackup)?.slots ?? []
                try expectEqual(recorded.map(\.record), store.placeholderDisplayPaths.sorted())
                try fx.system.restartWallpaperAgent()   // the next login
                try expectEqual(fx.service().status().saverSelection, .everyDisplay)
                try check(try sb.document().isCurrentChoiceOnEveryDisplay(sb.module))
                try check(try service.selectSaver())
                try expectEqual(service.transcript.last, InstallStep(title: selectTitle, outcome: .skipped("already selected")))
                try expectEqual(fx.system.restarts, 2)
            }
            // While LivePaper owns the selection, the app's quiet re-apply makes it last by itself.
            try StoreSandbox.with("by-hand-reapply") { sb in
                try store.data(store.systemSettings(livePaper: sb.saver.path)).write(to: sb.store)
                let fx = InstallFixture(sb)
                fx.system.onRestart = { _ in try store.deriveDefaults(at: sb.store) }
                try FileManager.default.createDirectory(at: fx.paths.backups, withIntermediateDirectories: true)
                try WallpaperSelectionManifest(module: sb.module.moduleURLString, createdAt: Date()).write(to: fx.paths.wallpaperSelectionBackup)
                let status = fx.service().status()
                try expect(status.saverSelected && status.selectionReapplyNeeded, "\(status)")
                try expectEqual(try fx.service().reapplySelectionIfNeeded(), .reapplied(displays: 4))
                try fx.system.restartWallpaperAgent()
                try expect(fx.service().status().saverSelected && !fx.service().status().selectionReapplyNeeded)
            }
        },
        TestCase(name: "wallpaper.every-display.connected") {
            // The status counts the displays connected now (WallpaperSystem.connectedDisplayIDs, the
            // store's display keys): on the reverted store with c and d connected, neither shows LivePaper.
            let store = RealShapedStore.self
            try StoreSandbox.with("connected") { sb in
                try store.data(store.reverted(livePaper: sb.saver.path)).write(to: sb.store)
                let fx = InstallFixture(sb)
                fx.system.connectedDisplayIDs = [store.c, store.d]
                try expectEqual(fx.service().status().saverSelection, .partly(.init(displays: 6, missing: 4, connected: 2, connectedMissing: 2)))
                fx.system.connectedDisplayIDs = nil
                try expectEqual(fx.service().status().saverSelection, .partly(.init(displays: 6, missing: 4)))
            }
            // The live system lists them read-only (whatever this Mac has; nil without a window server).
            if let live = LiveWallpaperSystem(storeURL: LiveWallpaperSystem.agentStoreURL, runner: RecordingCommandRunner()).connectedDisplayIDs {
                try expect(!live.isEmpty && live.allSatisfy { UUID(uuidString: $0) != nil }, "display UUIDs")
            }
        },
    ] }
}

// MARK: - App

extension SelfTests {
    fileprivate static var everyDisplayApp: [TestCase] { [
        TestCase(name: "app.model.selection-reapply-launch") {
            // At launch: a display fell back to macOS's default while LivePaper owns the selection —
            // re-applied quietly, once.
            let fellBack = InstallStatus(saverInstalled: true, saverUpToDate: true, saverSelection: .partly(.init(displays: 3, missing: 1)),
                                         selectionReapplyNeeded: true)
            try withInstallModel("reapply-launch", status: fellBack, locked: false) { model, install, _ in
                try expectEqual(install.reapplyCalls, 1)
                try expectEqual(model.selectionReapplyCount, 1)
                try expect(model.installStatus.saverSelected && !model.isInstallBusy, "\(model.installStatus)")
                try expect(model.banners.banners.isEmpty, "quiet")
            }
            // Nothing to re-apply (another saver chosen, LivePaper not owning it, …): never asked.
            let partlyOther = InstallStatus(saverInstalled: true, saverUpToDate: true, saverSelection: .partly(.init(displays: 3, missing: 1)))
            try withInstallModel("reapply-not-needed", status: partlyOther, locked: false) { model, install, _ in
                try expectEqual(install.reapplyCalls, 0)
                try expect(model.installStatus.saverPartlySelected)
            }
            // Locked at launch: not now — after the unlock.
            let unlock = UnlockSource()
            try withInstallModel("reapply-locked", status: fellBack, locked: true,
                                 configure: { env in env.observeUnlock = { unlock.observe($0) } }) { model, install, lock in
                try expectEqual(install.reapplyCalls, 0)
                try expect(model.isReapplyWaitingForUnlock && unlock.isObserving)
                lock.isLocked = false
                unlock.fire()
                try awaitMain(until: { install.reapplyCalls == 1 && !model.isInstallBusy })
                try expect(model.installStatus.saverSelected && !model.isReapplyWaitingForUnlock && !unlock.isObserving)
            }
            // Refused (System Settings open): the status keeps offering the button; nothing else happens.
            try withInstallModel("reapply-refused", status: fellBack, locked: false,
                                 prepare: { $0.reapplyRefusal = "System Settings is open" }) { model, install, _ in
                try expectEqual(install.reapplyCalls, 1)
                try expect(model.installStatus.saverPartlySelected && model.banners.banners.isEmpty)
            }
        },
        TestCase(name: "app.model.selection-reapply-screens") {
            // Display changes come in bursts: one re-apply once the burst is over, not one per change.
            try withInstallModel("reapply-screens", status: InstallStatus(saverInstalled: true, saverUpToDate: true, saverSelected: true),
                                 locked: false, configure: { env in env.screenChangeSettleDelay = 0.2 }) { model, install, _ in
                try expectEqual(install.reapplyCalls, 0)
                install.simulateDisplaysOnDefault(missing: 1, of: 3)
                for _ in 0..<5 { model.screenParametersDidChange(); pumpMain(0.03) }
                try expect(model.isSettlingScreenChange)
                try awaitMain(until: { !model.isSettlingScreenChange && install.reapplyCalls == 1 && !model.isInstallBusy })
                try expect(model.installStatus.saverSelected)
                pumpMain(0.4)
                try expectEqual(install.reapplyCalls, 1)
                // A burst that changes nothing that matters: the status is read, nothing re-applied.
                model.screenParametersDidChange()
                try awaitMain(until: { !model.isSettlingScreenChange && !model.isInstallBusy })
                pumpMain(0.1)
                try expectEqual(install.reapplyCalls, 1)
            }
        },
        TestCase(name: "app.model.selection-reapply-after-install-work") {
            // Displays change while other install work runs (here the launch-time saver update): the
            // re-apply waits for it, then runs once.
            try withScratchPaths("reapply-after-update") { root in
                let mocks = try MockServices.make(root: root.appendingPathComponent("Mock"), pace: 0)
                let base = MockInstallService(status: InstallStatus(saverInstalled: true, saverUpToDate: false, saverSelected: true))
                let gated = GatedInstall(base: base)
                let services = LivePaperServices(library: mocks.library, publish: mocks.publish, ai: mocks.ai, install: gated,
                                                 render: mocks.render, checker: mocks.checker, compiler: mocks.compiler)
                defer { gated.release() }   // never leave an update thread waiting
                try MainActor.assumeIsolated {
                    var env = testEnvironment(root: root, saved: SavedStates())
                    env.screenChangeSettleDelay = 0
                    let model = AppModel(services: services, environment: env)
                    let started = WatchLog<Bool>()
                    Task { @MainActor in await model.start(); started.append(true) }
                    try awaitMain(until: { gated.isHolding })
                    base.simulateDisplaysOnDefault(missing: 1, of: 2)
                    model.screenParametersDidChange()
                    try awaitMain(until: { !model.isSettlingScreenChange })
                    pumpMain(0.2)
                    try expect(base.reapplyCalls == 0 && model.installStatus.selectionReapplyNeeded, "held back while the update runs")
                    gated.release()
                    try awaitMain(until: { !started.values.isEmpty && base.reapplyCalls == 1 && !model.isInstallBusy })
                    try expectEqual(gated.events, ["update", "updated", "reapply", "reapplied"])
                    pumpMain(0.2)
                    try expectEqual(base.reapplyCalls, 1)
                    try expect(model.installStatus.saverSelected, "\(model.installStatus)")
                }
            }
        },
        TestCase(name: "app.setup.selected-on-every-display") {
            // The connected displays first (the owner's case: two connected, both on macOS's default).
            let partly = SetupState(install: InstallStatus(saverInstalled: true, saverUpToDate: true,
                                                           saverSelection: .partly(.init(displays: 6, missing: 4, connected: 2, connectedMissing: 2))))
            let row = SetupChecklist.checks(for: .screenSaver, state: partly).first { $0.id == .saverSelected }
            try expectEqual(row?.state, .needed)
            try expectEqual(row?.title, "Selected on every display")
            try expect(row?.detail.contains("2 of your 2 connected displays still show another screen saver") == true, row?.detail ?? "")
            try expect(row?.detail.contains(SetupState.everyDisplayActionTitle) == true)
            try expectEqual(SetupChecklist.saverSummary(partly.install), "Not on 2 of 2 connected displays")
            try expectEqual(partly.selectActionTitle(otherwise: "Select LivePaper"), "Use LivePaper on Every Display")
            try expect(!SetupChecklist.isComplete(.screenSaver, state: partly))
            // Without a display list: the store's display records, by what is missing (never "0 of N").
            let records = SaverSelection.partly(.init(displays: 6, missing: 4))
            try expect(SetupChecklist.selectionDetail(records).hasPrefix("4 of the 6 displays in your wallpaper settings still show"))
            try expectEqual(SetupChecklist.saverSummary(InstallStatus(saverInstalled: true, saverSelection: records)), "Not on 4 of 6 displays")
            let one = SetupChecklist.selectionDetail(.partly(.init(displays: 1, missing: 1)))
            try expect(one.hasPrefix("1 of the 1 displays in your wallpaper settings still shows"), one)
            // Every connected display shows it; one that isn't connected wouldn't.
            let away = SaverSelection.partly(.init(displays: 3, missing: 1, connected: 2, connectedMissing: 0))
            try expect(SetupChecklist.selectionDetail(away).hasPrefix("1 display that isn\u{2019}t connected now would still show"),
                       SetupChecklist.selectionDetail(away))
            try expectEqual(SetupChecklist.saverSummary(InstallStatus(saverInstalled: true, saverSelection: away)), "Not on every display")
            // A store LivePaper can't read: no claim either way, and setup isn't blocked.
            let unknown = SetupState(install: InstallStatus(saverInstalled: true, saverUpToDate: true, saverSelection: .unknown))
            let unknownRow = SetupChecklist.checks(for: .screenSaver, state: unknown).first { $0.id == .saverSelected }
            try expect(unknownRow?.state == .optional && unknownRow?.detail.contains("can\u{2019}t tell which displays") == true, "\(String(describing: unknownRow))")
            try expect(SetupChecklist.isComplete(.screenSaver, state: unknown))
            try expectEqual(SetupChecklist.saverSummary(unknown.install), "Installed \u{2014} can\u{2019}t tell which displays use it")
            // Every display: done; none: the usual setup.
            let all = SetupState(install: InstallStatus(saverInstalled: true, saverUpToDate: true, saverSelected: true))
            try expectEqual(SetupChecklist.checks(for: .screenSaver, state: all).first { $0.id == .saverSelected }?.state, .done)
            try expectEqual(SetupChecklist.saverSummary(all.install), "Active")
            let none = SetupState(install: InstallStatus(saverInstalled: true, saverUpToDate: true))
            try expectEqual(none.selectActionTitle(otherwise: "Select LivePaper"), "Select LivePaper")
            try expectEqual(SetupChecklist.saverSummary(none.install), "Installed, not selected")
            // An outdated saver still says what the full setup does.
            let outdated = SetupState(install: InstallStatus(saverInstalled: true, saverUpToDate: false, saverSelection: .partly(.init(displays: 2, missing: 1))))
            try expectEqual(outdated.selectActionTitle(otherwise: "Install & Select"), "Install & Select")
            // Use LivePaper on Every Display works at once in the mock (no guided step).
            try withInstallModel("every-display-button", status: partly.install, locked: false) { model, _, _ in
                var selected = false
                try awaitMain { selected = await model.makeLivePaperScreenSaver() }
                try expect(selected && model.installStatus.saverSelected)
            }
        },
    ] }
}
