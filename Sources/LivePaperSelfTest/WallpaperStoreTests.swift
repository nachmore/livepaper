// Self tests owned by WS3-autoselect: the wallpaper store (selecting LivePaper as the screen saver
// and undoing it on uninstall).
//
// Nothing here touches the real store or WallpaperAgent. Stores are generated in code with the
// store's Codable mirror (exactly as WallpaperAgent writes them) and scrubbed of personal data:
// the user is "user", display and Space ids are made up, the other saver is "Example.saver".
// The applier runs against temp files with a FakeWallpaperSystem (whose "agent restart" re-encodes
// the store with the mirror, like the real agent does at launch) and a FakeClock (waits are
// instant). `wallpaper.real-store-copy` additionally READS this Mac's real store, if there is one,
// and runs the same checks on a temp copy; it never writes the original.
import Darwin
import Foundation
import LivePaperCore

extension SelfTests {
    static var wallpaper: [TestCase] {
        wallpaperModel + wallpaperApplier + wallpaperInstall + wallpaperEveryDisplay + [realStoreCopy]
    }
}

// MARK: - Fixtures

/// Generated stand-ins for a real macOS 26 wallpaper store.
enum StoreFixture {
    static let livePaperPath = "/Users/user/Library/Screen Savers/LivePaper.saver"
    static let otherSaverPath = "/Users/user/Library/Screen Savers/Example.saver"
    static let displays = (1...6).map { String(format: "0000000%d-0000-4000-8000-00000000000%d", $0, $0) }
    static let spaces = ["", "AAAAAAAA-0000-4000-8000-000000000001", "AAAAAAAA-0000-4000-8000-000000000002", "AAAAAAAA-0000-4000-8000-000000000003"]
    static let setDesktop = Date(timeIntervalSinceReferenceDate: 784_759_658.814_400)
    static let usedDesktop = Date(timeIntervalSinceReferenceDate: 784_764_806.093_742)
    static let setSaver = Date(timeIntervalSinceReferenceDate: 784_680_434.282_752)
    static let setPlaceholder = Date(timeIntervalSinceReferenceDate: 784_680_023.741_172)

    static var livePaper: WallpaperSaverModule { WallpaperSaverModule(url: URL(fileURLWithPath: livePaperPath)) }

    static func moduleConfiguration(_ path: String) -> Data {
        plist(.dictionary(["module": .dictionary(["relative": .string(URL(fileURLWithPath: path, isDirectory: false).absoluteString)])]))
    }
    static let imageFolder = plist(.dictionary(["type": .string("imageFolder"),
                                                "url": .dictionary(["relative": .string("file:///Users/user/Pictures/Wallpapers/")])]))
    /// Desktop colour and placement options, with the colour space as a further nested plist.
    static let desktopOptions = plist(.dictionary(["values": .dictionary([
        "color": .dictionary(["color": .dictionary(["_0": .dictionary(["color": .dictionary([
            "components": .array([.real(0.2549019607843137), .real(0.4117647058823529), .real(0.6666666666666666), .real(1.0)]),
            "colorSpace": .data(plist(.string("kCGColorSpaceGenericRGB"))),
        ])])])]),
        "placement": .dictionary(["picker": .dictionary(["_0": .dictionary(["id": .string("Crop")])])]),
    ])]))

    typealias Schema = WallpaperStoreSchema
    enum Idle { case saver(String), inherit }

    static func desktop(_ set: Date = setDesktop, _ use: Date = usedDesktop) -> Schema.Slot {
        Schema.Slot(lastSet: set, lastUse: use, content: Schema.Content(
            choices: [Schema.Choice(provider: "com.apple.wallpaper.choice.image", configuration: imageFolder)], encodedOptionValues: desktopOptions))
    }

    static func idle(_ idle: Idle, used: Date = usedDesktop) -> Schema.Slot {
        switch idle {
        case .saver(let path):
            // System Settings copies the Desktop options into the saver slot.
            return Schema.Slot(lastSet: setSaver, lastUse: used, content: Schema.Content(
                choices: [Schema.Choice(provider: WallpaperSlot.screenSaverProvider, configuration: moduleConfiguration(path))],
                encodedOptionValues: desktopOptions))
        case .inherit:
            return Schema.Slot(lastSet: setPlaceholder, lastUse: setPlaceholder, content: Schema.Content(
                choices: [Schema.Choice(provider: WallpaperSlot.inheritProvider, configuration: Data())],
                encodedOptionValues: WallpaperChoicePayload.emptyOptionValues))
        }
    }

    static func record(_ choice: Idle) -> Schema.Record { .individual(desktop: desktop(), idle: idle(choice)) }

    /// The shape of the store the research decoded: SystemDefault, 6 displays, 4 Spaces (19 Idle
    /// slots). `saver` is chosen in SystemDefault, displays 1 and 6, the first Space's Default and
    /// its displays 1 and 6 (6 explicit slots); the other 13 are placeholders.
    static func index(saver: String = otherSaverPath) -> Schema.Index {
        let explicit = record(.saver(saver)), inherit = record(.inherit)
        var displayRecords: [String: Schema.Record] = [:]
        for (i, id) in displays.enumerated() { displayRecords[id] = (i == 0 || i == 5) ? explicit : inherit }
        var first: [String: Schema.Record] = [:]
        for i in [0, 1, 3, 4, 5] { first[displays[i]] = (i == 0 || i == 5) ? explicit : inherit }
        var spaceRecords = [spaces[0]: Schema.SpaceRecord(default: explicit, displays: first)]
        for (n, space) in spaces.dropFirst().enumerated() {
            spaceRecords[space] = Schema.SpaceRecord(default: inherit, displays: [displays[n + 1]: inherit])
        }
        return Schema.Index(allSpacesAndDisplays: nil, systemDefault: explicit, spaces: spaceRecords, displays: displayRecords)
    }

    /// The fixture as WallpaperAgent would write it.
    static func data(saver: String = otherSaverPath) throws -> Data { try Schema.encode(index(saver: saver)) }

    /// Paths of the 6 explicit Idle slots (the other 13 are placeholders).
    static var explicitPaths: [WallpaperRecordPath] {
        [.systemDefault, .display(displays[0]), .display(displays[5]), .spaceDefault(""),
         .spaceDisplay(space: "", display: displays[0]), .spaceDisplay(space: "", display: displays[5])]
    }

    /// The 10 display records whose Idle slot is the placeholder (the 3 other placeholders are
    /// Space Defaults).
    static var placeholderDisplayPaths: [WallpaperRecordPath] {
        [2, 3, 4, 5].map { .display(displays[$0 - 1]) } + [2, 4, 5].map { .spaceDisplay(space: "", display: displays[$0 - 1]) }
            + [(1, 2), (2, 3), (3, 4)].map { .spaceDisplay(space: spaces[$0.0], display: displays[$0.1 - 1]) }
    }

    /// What a selection writes: the explicit slots and every display's placeholder (16), in
    /// document order.
    static var selectPaths: [WallpaperRecordPath] { (explicitPaths + placeholderDisplayPaths).sorted() }

    /// Every display record chooses `saver` explicitly too (no placeholder below SystemDefault but
    /// the 3 Space Defaults): a selection has nothing to add when `saver` is LivePaper.
    static func allDisplaysExplicit(saver: String) -> Schema.Index {
        var index = self.index(saver: saver)
        let explicit = record(.saver(saver))
        for id in index.displays.keys { index.displays[id] = explicit }
        for (space, var record) in index.spaces {
            for id in record.displays.keys { record.displays[id] = explicit }
            index.spaces[space] = record
        }
        return index
    }

    static func plist(_ value: PlistValue) -> Data {
        guard let data = try? value.binaryData() else { fatalError("fixture plist") }
        return data
    }
}

/// A temp folder with a store and an installed LivePaper.saver.
struct StoreSandbox {
    let root: URL
    var store: URL { root.appendingPathComponent("com.apple.wallpaper/Store/Index.plist") }
    var saver: URL { root.appendingPathComponent("Screen Savers/LivePaper.saver") }
    /// The saver the generated store chooses before LivePaper (it exists, so restore puts it back).
    var otherSaver: URL { root.appendingPathComponent("Screen Savers/Example.saver") }
    /// Stands in for macOS's own Message saver (WallpaperRestoreFallback.systemSaverURL).
    var builtinSaver: URL { root.appendingPathComponent("System Screen Savers/FloatingMessage.saver") }
    var snapshot: URL { backups.appendingPathComponent("wallpaper-store-before-last-change.plist") }
    var backups: URL { root.appendingPathComponent("support/backups") }
    var manifest: URL { backups.appendingPathComponent("wallpaper-selection.json") }
    var rawBackup: URL { backups.appendingPathComponent("wallpaper-store-Index.plist") }
    var lock: URL { root.appendingPathComponent("support/wallpaper-store.lock") }
    var module: WallpaperSaverModule { WallpaperSaverModule(url: saver) }

    init(_ name: String, store data: Data? = nil) throws {
        root = try tempDir("wallpaper-\(name)").resolvingSymlinksInPath()
        for (bundle, id) in [(saver, LPPaths.saverBundleID), (otherSaver, "com.example.saver"), (builtinSaver, "com.example.builtin")] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
                .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data ?? StoreFixture.data(saver: otherSaver.path)).write(to: store)
    }

    func bytes() throws -> Data { try Data(contentsOf: store) }
    func document() throws -> WallpaperStoreDocument { try WallpaperStoreDocument(data: bytes()) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }

    static func with(_ name: String, store data: Data? = nil, _ body: (StoreSandbox) throws -> Void) throws {
        let sandbox = try StoreSandbox(name, store: data)
        defer { sandbox.cleanup() }
        try body(sandbox)
    }
}

/// Virtual time: `sleep` advances it and runs the events that became due.
final class FakeClock: WallpaperClock, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var current = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var events: [(at: Date, run: () -> Void)] = []
    private(set) var slept: TimeInterval = 0

    func now() -> Date { lock.withLock { current } }

    func sleep(_ seconds: TimeInterval) {
        lock.withLock {
            current = current.addingTimeInterval(seconds)
            slept += seconds
            while let index = events.indices.filter({ events[$0].at <= current }).min(by: { events[$0].at < events[$1].at }) {
                events.remove(at: index).run()
            }
        }
    }

    func schedule(after seconds: TimeInterval, _ run: @escaping () -> Void) {
        lock.withLock { events.append((current.addingTimeInterval(seconds), run)) }
    }
}

/// The running Mac, faked. `restartWallpaperAgent()` runs `onRestart` (default: the respawned
/// agent decodes the store with the mirror and writes it back, as the real one does at launch).
final class FakeWallpaperSystem: WallpaperSystem, @unchecked Sendable {
    let store: URL
    var unavailable: String?
    var session = WallpaperSessionState.unlocked
    var conflicts: [String] = []
    var forced = false
    var disabled = false
    var version: Int? = WallpaperApplyOptions.supportedStoreVersion
    var restartError: Error?
    var onRestart: ((_ restart: Int) throws -> Void)?
    private(set) var restarts = 0
    /// The session state at each restart (the agent must never be restarted while locked).
    private(set) var sessionAtRestart: [WallpaperSessionState] = []

    init(store: URL) { self.store = store }

    func unavailability(forStoreAt url: URL) -> String? { unavailable }
    var sessionState: WallpaperSessionState { session }
    func conflictingProcesses() -> [String] { conflicts }
    var screenSaverModuleForced: Bool { forced }
    var wallpaperChangesDisabled: Bool { disabled }
    var storeMigrationVersion: Int? { version }

    func restartWallpaperAgent() throws {
        restarts += 1
        sessionAtRestart.append(session)
        if let restartError { throw restartError }
        if let onRestart { try onRestart(restarts) } else { try agentRewrite() }
    }

    /// What a freshly launched WallpaperAgent does: decode the store (a default store if it can't)
    /// and write its model back atomically.
    func agentRewrite() throws {
        let data = try Data(contentsOf: store)
        let model = (try? WallpaperStoreSchema.decode(data)) ?? StoreFixture.Schema.Index(systemDefault: .individual(
            desktop: StoreFixture.Schema.Slot(lastSet: Date(), lastUse: Date(), content: .init(
                choices: [.init(provider: "com.apple.wallpaper.choice.aerials", configuration: Data())], encodedOptionValues: nil)),
            idle: StoreFixture.idle(.inherit)))
        try WallpaperStoreSchema.encode(model).write(to: store, options: .atomic)
    }

    /// The agent wrote `bytes` from memory (losing LivePaper's edit) and then restarted.
    func overwrite(with bytes: Data) throws {
        try bytes.write(to: store, options: .atomic)
        try agentRewrite()
    }
}

/// `expect` for a condition that can throw.
func check(_ cond: @autoclosure () throws -> Bool, _ msg: @autoclosure () -> String = "", file: String = #fileID, line: Int = #line) throws {
    if try !cond() { throw TestFailure(description: "\(file):\(line) expectation failed \(msg())") }
}

func expectStoreError(_ expected: WallpaperStoreError, file: String = #fileID, line: Int = #line, _ body: () throws -> Void) throws {
    do { try body() } catch let error as WallpaperStoreError {
        guard error == expected else { throw TestFailure(description: "\(file):\(line) threw \(error), expected \(expected)") }
        return
    }
    throw TestFailure(description: "\(file):\(line) didn't throw \(expected)")
}

func applier(_ sb: StoreSandbox, _ system: FakeWallpaperSystem, _ clock: FakeClock, snapshot: Bool = false) -> WallpaperStoreApplier {
    WallpaperStoreApplier(storeURL: sb.store, system: system, clock: clock, lockURL: sb.lock, snapshotURL: snapshot ? sb.snapshot : nil)
}

/// A store as WallpaperAgent writes it when it can't use the file: defaults, every Desktop choice gone.
private func defaultStore() throws -> Data { try WallpaperStoreSchema.encode(.init(systemDefault: StoreFixture.record(.inherit))) }

/// The Idle slots of every record, by path.
func idleSlots(_ doc: WallpaperStoreDocument) -> [WallpaperRecordPath: PlistValue] {
    Dictionary(uniqueKeysWithValues: doc.records.compactMap { r in r.idle.map { (r.path, $0) } })
}

func desktopSlots(_ doc: WallpaperStoreDocument) -> [WallpaperRecordPath: PlistValue] {
    Dictionary(uniqueKeysWithValues: doc.records.compactMap { r in r.desktop.map { (r.path, $0) } })
}

// MARK: - Model

extension SelfTests {
    fileprivate static var wallpaperModel: [TestCase] { [
        TestCase(name: "wallpaper.payload") {
            // The research's verified 132-byte Configuration (what System Settings writes for this
            // path), with the 8-letter user name scrubbed to "username": same length, same bytes.
            let research132 = "YnBsaXN0MDDRAQJWbW9kdWxl0QMEWHJlbGF0aXZlXxA+ZmlsZTovLy9Vc2Vycy91c2VybmFtZS9MaWJyYXJ5L1NjcmVlbiUyMFNhdmVycy9MaXZlUGFwZXIuc2F2ZXIICxIVHgAAAAAAAAEBAAAAAAAAAAUAAAAAAAAAAAAAAAAAAABf"
            let scrubbed = WallpaperSaverModule(url: URL(fileURLWithPath: "/Users/username/Library/Screen Savers/LivePaper.saver"))
            try expectEqual(try scrubbed.configuration().count, 132)
            try expectEqual(try scrubbed.configuration().base64EncodedString(), research132)
            // The same layout for /Users/user (cross-checked with Python's plistlib FMT_BINARY).
            let user128 = "YnBsaXN0MDDRAQJWbW9kdWxl0QMEWHJlbGF0aXZlXxA6ZmlsZTovLy9Vc2Vycy91c2VyL0xpYnJhcnkvU2NyZWVuJTIwU2F2ZXJzL0xpdmVQYXBlci5zYXZlcggLEhUeAAAAAAAAAQEAAAAAAAAABQAAAAAAAAAAAAAAAAAAAFs="
            let module = StoreFixture.livePaper
            try expectEqual(module.moduleURLString, "file:///Users/user/Library/Screen%20Savers/LivePaper.saver")
            try expectEqual(try module.configuration().base64EncodedString(), user128)
            try expectEqual(try PlistValue.parse(module.configuration()),
                            .dictionary(["module": .dictionary(["relative": .string(module.moduleURLString)])]))
            // EncodedOptionValues: {values = {}}, 54 bytes, as the agent writes it.
            try expectEqual(WallpaperChoicePayload.emptyOptionValues.base64EncodedString(),
                            "YnBsaXN0MDDRAQJWdmFsdWVz0AgLEgAAAAAAAAEBAAAAAAAAAAMAAAAAAAAAAAAAAAAAAAAT")
            // An existing bundle directory still gets no trailing slash.
            try StoreSandbox.with("payload") { sb in
                try expect(!sb.module.moduleURLString.hasSuffix("/"), sb.module.moduleURLString)
                try expect(sb.module.moduleURLString.hasSuffix("/Screen%20Savers/LivePaper.saver"))
            }
            // The whole slot.
            let date = Date(timeIntervalSinceReferenceDate: 1)
            let slot = try module.slot(at: date)
            try expectEqual(slot["LastSet"], .date(date))
            try expectEqual(slot.value(at: ["Content", "Shuffle"]), .string("$null"))
            try expectEqual(slot.value(at: ["Content", "Choices"]), .array([.dictionary([
                "Provider": .string("com.apple.wallpaper.choice.screen-saver"), "Files": .array([]),
                "Configuration": .data(try module.configuration())])]))
            try expect(module.isCurrentChoice(in: slot) && module.isChosen(in: slot))
            try expect(!WallpaperSlot.isInherit(slot) && WallpaperSlot.isInherit(WallpaperChoicePayload.inheritSlot(at: date)))
            // Recognition: by bundle name anywhere; "current" only at the exact location.
            let elsewhere = try WallpaperSaverModule(url: URL(fileURLWithPath: "/Library/Screen Savers/LivePaper.saver")).slot(at: date)
            try expect(module.isChosen(in: elsewhere) && !module.isCurrentChoice(in: elsewhere))
            let otherSlot = try PlistValue.parse(StoreFixture.data()).value(at: ["SystemDefault", "Idle"])
            try expect(otherSlot != nil && !module.isChosen(in: otherSlot!))
            // A module URL with a trailing slash or a base still resolves.
            let slashed = FakePayload.configuration(relative: "file:///Users/user/Library/Screen%20Savers/LivePaper.saver/")
            try expectEqual(WallpaperSlot.moduleURL(fromConfiguration: slashed)?.lastPathComponent, "LivePaper.saver")
            let based = FakePayload.configuration(relative: "LivePaper.saver", base: "file:///Users/user/Library/Screen%20Savers/")
            try expectEqual(WallpaperSlot.moduleURL(fromConfiguration: based)?.path, StoreFixture.livePaperPath)
        },
        TestCase(name: "wallpaper.plist-value") {
            let date = Date(timeIntervalSinceReferenceDate: 784_680_434.282_752)
            let tree = PlistValue.dictionary([
                "bool": .bool(true), "one": .integer(1), "negative": .integer(-5), "big": .integer(Int64.max),
                "real": .real(0.1), "whole": .real(1.0), "date": .date(date), "data": .data(Data([0, 1, 2, 255])),
                "empty": .data(Data()), "string": .string("Screen%20Savers é"), "null": .string("$null"),
                "nested": .array([.dictionary(["k": .array([])]), .dictionary([:])]),
            ])
            let parsed = try PlistValue.parse(tree.binaryData())
            try expectEqual(parsed, tree)
            try expect(parsed["bool"] == .bool(true) && parsed["bool"] != .integer(1), "a bool stays a bool")
            try expect(parsed["whole"] == .real(1.0) && parsed["whole"] != .integer(1), "a real stays a real")
            try expect(PlistValue.real(0.1) != .real(0.1000000000000001), "reals compare bit for bit")
            // XML input converts the same way.
            let xml = try PropertyListSerialization.data(fromPropertyList: tree.foundationObject, format: .xml, options: 0)
            // (XML dates only keep whole seconds.)
            try expectEqual(try PlistValue.parse(xml).removing(["date"]), tree.removing(["date"]))
        },
        TestCase(name: "wallpaper.plist-value.paths") {
            let tree = PlistValue.dictionary(["a": .dictionary(["b": .integer(1), "c": .string("x")]), "d": .array([.integer(1)])])
            try expectEqual(tree.value(at: ["a", "b"]), .integer(1))
            try expect(tree.value(at: ["a", "zz"]) == nil && tree.value(at: ["d", "0"]) == nil)
            let edited = try tree.setting(.integer(2), at: ["a", "b"])
            try expectEqual(edited.differences(from: tree), [["a", "b"]])
            try expectEqual(try tree.setting(.integer(3), at: ["a", "new"]).differences(from: tree), [["a", "new"]])
            try expectEqual(try tree.setting(.array([]), at: ["d"]).differences(from: tree), [["d"]])
            try expect(tree.differences(from: tree).isEmpty)
            var threw = false
            do { _ = try tree.setting(.integer(1), at: ["missing", "x"]) } catch { threw = true }
            try expect(threw, "setting below a missing dictionary throws")
        },
        TestCase(name: "wallpaper.schema") {
            // The fixture decodes, and encoding is deterministic and byte-exact (like the agent's).
            let data = try StoreFixture.data()
            let index = try WallpaperStoreSchema.decode(data)
            try expectEqual(index, StoreFixture.index())
            try expectEqual(try WallpaperStoreSchema.encode(index), data)
            // nil optionals are the string "$null" on disk.
            let root = try PlistValue.parse(data)
            try expectEqual(root["AllSpacesAndDisplays"], .string("$null"))
            try expectEqual(root.value(at: ["SystemDefault", "Idle", "Content", "Shuffle"]), .string("$null"))
            try expectEqual(root.value(at: ["SystemDefault", "Type"]), .string("individual"))
            // Strict where LivePaper writes, so a store the agent can't decode is caught.
            let reject = { (path: [String], value: PlistValue?) throws in
                let tampered = try value.map { try root.setting($0, at: path) } ?? root.removing(path)
                var failed = false
                do { _ = try WallpaperStoreSchema.decode(tampered.binaryData()) } catch { failed = true }
                try expect(failed, "accepted a store with \(path.joined(separator: "/")) = \(value.map(\.description) ?? "removed")")
                var refused = false
                do { _ = try WallpaperStoreDocument(data: tampered.binaryData()) } catch WallpaperStoreError.undecodable { refused = true }
                try expect(refused, "the document refuses it too")
            }
            let choice = ["SystemDefault", "Idle", "Content", "Choices"]
            try reject(["SystemDefault", "Type"], .string("bogus"))
            try reject(["SystemDefault", "Type"], .string("desktop"))           // SystemDefault: individual | linked only
            try reject(choice, .array([.dictionary(["Files": .array([]), "Configuration": .data(Data())])]))   // no Provider
            try reject(choice, .array([.dictionary(["Provider": .string("x"), "Files": .array([])])]))         // no Configuration
            try reject(choice, .array([.dictionary(["Provider": .string("x"), "Files": .array([]), "Configuration": .string("x")])]))
            try reject(["SystemDefault", "Idle", "LastSet"], .string("yesterday"))
            try reject(["SystemDefault", "Idle", "Content", "EncodedOptionValues"], .integer(1))
            try reject(["SystemDefault", "Idle"], nil)
            try reject(["Spaces", "", "Displays"], nil)
            try reject(["Displays"], nil)
            // Permissive only where LivePaper never writes: Files entries, Shuffle values.
            let files = try root.setting(.array([.dictionary(["Provider": .string("x"), "Files": .array([.string("a"), .dictionary(["k": .integer(1)])]),
                                                               "Configuration": .data(Data())])]), at: choice)
            _ = try WallpaperStoreSchema.decode(files.binaryData())
            _ = try WallpaperStoreSchema.decode(root.setting(.dictionary(["afterDuration": .dictionary(["duration": .real(60)])]),
                                                             at: ["SystemDefault", "Idle", "Content", "Shuffle"]).binaryData())
            // Other record types decode.
            let idleOnly = PlistValue.dictionary(["Type": .string("idle"), "Idle": root.value(at: ["SystemDefault", "Idle"])!])
            _ = try WallpaperStoreSchema.decode(root.setting(idleOnly, at: ["Displays", StoreFixture.displays[0]]).binaryData())
        },
        TestCase(name: "wallpaper.round-trip") {
            let data = try StoreFixture.data()
            let doc = try WallpaperStoreDocument(data: data)
            try expectEqual(doc.records.count, 19)
            try expectEqual(try PlistValue.parse(doc.data()), doc.root)
            try expectEqual(try WallpaperStoreDocument(data: doc.data()), doc)
            // Re-serialising and decoding with the agent's model gives the identical model and bytes.
            try expectEqual(try WallpaperStoreSchema.encode(WallpaperStoreSchema.decode(doc.data())), data)
            // Keys LivePaper doesn't know survive parsing, editing and writing.
            let future = try doc.root.setting(.string("kept"), at: ["FutureTopLevel"])
                .setting(.integer(7), at: ["SystemDefault", "FutureRecordKey"])
                .setting(.data(Data([9, 9])), at: ["SystemDefault", "Desktop", "FutureSlotKey"])
                .setting(.bool(false), at: ["Spaces", StoreFixture.spaces[1], "Default", "Idle", "Content", "FutureContentKey"])
            let futureDoc = try WallpaperStoreDocument(data: future.binaryData())
            let plan = try futureDoc.planSelect(StoreFixture.livePaper, at: Date(timeIntervalSinceReferenceDate: 5))
            let edited = try PlistValue.parse(futureDoc.applying(plan).data())
            try expectEqual(edited["FutureTopLevel"], .string("kept"))
            try expectEqual(edited.value(at: ["SystemDefault", "FutureRecordKey"]), .integer(7))
            try expectEqual(edited.value(at: ["SystemDefault", "Desktop", "FutureSlotKey"]), .data(Data([9, 9])))
            try expectEqual(edited.value(at: ["Spaces", StoreFixture.spaces[1], "Default", "Idle", "Content", "FutureContentKey"]), .bool(false))
            // Every difference is inside a planned Idle slot.
            let allowed = Set(plan.paths.map { $0.keyPath + ["Idle"] })
            try expect(future.differences(from: edited).allSatisfy { d in allowed.contains { d.starts(with: $0) } })
            // Record paths encode as key arrays and back.
            for path in doc.records.map(\.path) + [.allSpacesAndDisplays] {
                try expectEqual(try JSONDecoder().decode(WallpaperRecordPath.self, from: JSONEncoder().encode(path)), path)
                try expectEqual(WallpaperRecordPath(keyPath: path.keyPath), path)
            }
            try expectEqual(WallpaperRecordPath.spaceDisplay(space: "", display: "D").description, "Spaces/\"\"/Displays/D")
        },
        TestCase(name: "wallpaper.detection") {
            let module = StoreFixture.livePaper
            let other = try WallpaperStoreDocument(data: StoreFixture.data()).selection(of: module)
            try expect(!other.isSelected && !other.isSelectedEverywhere)
            try expectEqual(other.other, StoreFixture.explicitPaths)
            try expectEqual(other.inheriting.count, 13)
            // Selected the way System Settings does it.
            let selected = try WallpaperStoreDocument(data: StoreFixture.data(saver: StoreFixture.livePaperPath)).selection(of: module)
            try expect(selected.isSelected && selected.isSelectedEverywhere)
            try expectEqual(selected.livePaper, StoreFixture.explicitPaths)
            // LivePaper on one display only.
            var partial = StoreFixture.index()
            partial.displays[StoreFixture.displays[0]] = StoreFixture.record(.saver(StoreFixture.livePaperPath))
            let some = try WallpaperStoreDocument(data: WallpaperStoreSchema.encode(partial)).selection(of: module)
            try expect(some.isSelected && !some.isSelectedEverywhere)
            try expectEqual(some.livePaper, [.display(StoreFixture.displays[0])])
            // …and everywhere but one display.
            var almost = StoreFixture.index(saver: StoreFixture.livePaperPath)
            almost.spaces[""]?.displays[StoreFixture.displays[5]] = StoreFixture.record(.saver(StoreFixture.otherSaverPath))
            let most = try WallpaperStoreDocument(data: WallpaperStoreSchema.encode(almost)).selection(of: module)
            try expect(most.isSelected && !most.isSelectedEverywhere)
            try expectEqual(most.other, [.spaceDisplay(space: "", display: StoreFixture.displays[5])])

            // WallpaperStore on files.
            try StoreSandbox.with("detect") { sb in
                let store = WallpaperStore(url: sb.store, saver: sb.saver)
                try expect(!store.isSelected() && !store.isSelectedEverywhere())
                try expectEqual(store.selection(), other)
                try StoreFixture.data(saver: StoreFixture.livePaperPath).write(to: sb.store)
                try expect(store.isSelected() && store.isSelectedEverywhere(), "by bundle name, whatever the folder")
                try expect(!WallpaperStore(url: sb.root.appendingPathComponent("missing.plist"), saver: sb.saver).isSelected())
                try Data("not a plist".utf8).write(to: sb.store)
                try expect(store.selection() == nil && !store.isSelected())
                // A store in an unknown format falls back to scanning the Idle subtrees.
                let config = StoreFixture.moduleConfiguration(StoreFixture.livePaperPath)
                let future = PlistValue.dictionary(["Displays": .dictionary(["X": .dictionary(["Idle": .dictionary(["Choice": .data(config)])])]),
                                                    "Desktop": .dictionary(["Choice": .data(config)])])
                try future.binaryData().write(to: sb.store)
                try expect(store.selection() == nil && store.isSelected() && !store.isSelectedEverywhere())
                try PlistValue.dictionary(["Desktop": .dictionary(["Choice": .data(config)])]).binaryData().write(to: sb.store)
                try expect(!store.isSelected(), "a mention outside Idle doesn't count")
            }
        },
        TestCase(name: "wallpaper.plan-select") {
            let module = StoreFixture.livePaper
            let date = Date(timeIntervalSinceReferenceDate: 800_000_000.5)
            let doc = try WallpaperStoreDocument(data: StoreFixture.data())
            let plan = try doc.planSelect(module, at: date)
            // The explicit slots (as System Settings does) and every display's placeholder; the
            // placeholders' originals are recorded too, so uninstall puts exactly them back.
            try expectEqual(plan.paths, StoreFixture.selectPaths)
            try expect(plan.changes.allSatisfy { $0.recordsOriginal && $0.after == (try? module.slot(at: date)) })
            try expect(StoreFixture.placeholderDisplayPaths.allSatisfy { path in
                plan.changes.first { $0.path == path }.map { WallpaperSlot.isInherit($0.before) } == true
            })
            let edited = try doc.applying(plan)
            try WallpaperStoreVerifier.verify(edited: edited.data(), original: doc, plan: plan)
            try expectEqual(desktopSlots(edited), desktopSlots(doc))
            let before = idleSlots(doc), after = idleSlots(edited)
            for (path, slot) in before where !plan.paths.contains(path) { try expectEqual(after[path], slot) }
            try expect(edited.selection(of: module).isSelectedEverywhere)
            try check(try edited.planSelect(module, at: date).isEmpty, "idempotent")
            // A placeholder SystemDefault is still set (nothing to inherit from); the placeholders of
            // Space Defaults aren't (every display of theirs gets LivePaper itself).
            var inheritRoot = StoreFixture.index()
            inheritRoot.systemDefault = StoreFixture.record(.inherit)
            let rootPlan = try WallpaperStoreDocument(data: WallpaperStoreSchema.encode(inheritRoot)).planSelect(module, at: date)
            try expect(rootPlan.paths.contains(.systemDefault) && rootPlan.paths.count == 16)
            try expect(!rootPlan.paths.contains { if case .spaceDefault(let s) = $0 { return !s.isEmpty }; return false })
            // LivePaper at an old location (gone) is rewritten but never recorded as an original…
            var moved = StoreFixture.index()
            let oldCopy = "/Users/old/Library/Screen Savers/LivePaper.saver"
            moved.displays[StoreFixture.displays[0]] = StoreFixture.record(.saver(oldCopy))
            let movedDoc = try WallpaperStoreDocument(data: WallpaperStoreSchema.encode(moved))
            let movedPlan = try movedDoc.planSelect(module, at: date)
            try expectEqual(movedPlan.changes.first { $0.path == .display(StoreFixture.displays[0]) }?.recordsOriginal, false)
            // …but a copy at another location that exists (say /Library/Screen Savers) is the user's own
            // choice: recorded, so uninstall can put that location back.
            let otherCopyPlan = try movedDoc.planSelect(module, at: date, moduleExists: { $0.path == oldCopy })
            try expectEqual(otherCopyPlan.changes.first { $0.path == .display(StoreFixture.displays[0]) }?.recordsOriginal, true)
            try expect(module.isOtherExistingCopy(URL(fileURLWithPath: oldCopy), moduleExists: { _ in true }))
            try expect(!module.isOtherExistingCopy(module.url, moduleExists: { _ in true }), "the module itself isn't another copy")
            // An explicit AllSpacesAndDisplays override is set too; a Desktop-only record is left alone.
            var override = StoreFixture.index()
            override.allSpacesAndDisplays = StoreFixture.record(.saver(StoreFixture.otherSaverPath))
            override.displays[StoreFixture.displays[2]] = .desktop(StoreFixture.desktop())
            let overridePlan = try WallpaperStoreDocument(data: WallpaperStoreSchema.encode(override)).planSelect(module, at: date)
            try expect(overridePlan.paths.contains(.allSpacesAndDisplays) && overridePlan.paths.count == 16, "\(overridePlan.paths.count)")
            // Layouts LivePaper doesn't edit.
            var linked = StoreFixture.index()
            linked.displays[StoreFixture.displays[3]] = .linked(StoreFixture.desktop())
            try expectStoreError(.unsupportedShape("Displays/\(StoreFixture.displays[3]) is a linked record")) {
                _ = try WallpaperStoreDocument(data: WallpaperStoreSchema.encode(linked)).planSelect(module, at: date)
            }
            var desktopOverride = StoreFixture.index()
            desktopOverride.allSpacesAndDisplays = .desktop(StoreFixture.desktop())
            try expectStoreError(.unsupportedShape("AllSpacesAndDisplays has no Idle slot")) {
                _ = try WallpaperStoreDocument(data: WallpaperStoreSchema.encode(desktopOverride)).planSelect(module, at: date)
            }
        },
        TestCase(name: "wallpaper.verify") {
            let module = StoreFixture.livePaper
            let doc = try WallpaperStoreDocument(data: StoreFixture.data())
            let plan = try doc.planSelect(module, at: Date(timeIntervalSinceReferenceDate: 9))
            let good = try doc.applying(plan).root
            try WallpaperStoreVerifier.verify(edited: good.binaryData(), original: doc, plan: plan)
            let fails = { (tampered: PlistValue, why: String) throws in
                var failed: String?
                do { try WallpaperStoreVerifier.verify(edited: tampered.binaryData(), original: doc, plan: plan) }
                catch WallpaperStoreError.verificationFailed(let reason) { failed = reason }
                try expect(failed?.contains(why) == true, "expected '\(why)', got \(failed ?? "success")")
            }
            try fails(good.setting(.date(Date()), at: ["SystemDefault", "Desktop", "LastSet"]), "unexpected change at SystemDefault/Desktop/LastSet")
            try fails(good.setting(.string("x"), at: ["Spaces", StoreFixture.spaces[1], "Default", "Idle", "Content", "Shuffle"]),
                      "unexpected change at Spaces/\(StoreFixture.spaces[1])/Default/Idle")
            try fails(good.setting(.string("x"), at: ["NewTopLevel"]), "unexpected change at NewTopLevel")
            try fails(good.setting(.string("idle"), at: ["Displays", StoreFixture.displays[0], "Type"]), "unexpected change")
            try fails(good.setting(.array([.dictionary(["Files": .array([])])]), at: ["SystemDefault", "Idle", "Content", "Choices"]),
                      "WallpaperAgent couldn't decode it")
            try fails(good.setting(.date(Date()), at: ["SystemDefault", "Idle", "LastSet"]), "isn't the planned value")
            var notPlist = false
            do { try WallpaperStoreVerifier.verify(edited: Data("x".utf8), original: doc, plan: plan) } catch WallpaperStoreError.verificationFailed { notPlist = true }
            try expect(notPlist)
            // Confirmation after a restart ignores LastUse but nothing else.
            let restarted = try good.setting(.date(Date()), at: ["SystemDefault", "Idle", "LastUse"])
                .setting(.date(Date()), at: ["SystemDefault", "Desktop", "LastUse"])
            try expectEqual(WallpaperStoreVerifier.confirm(current: WallpaperStoreDocument(root: restarted), original: doc, plan: plan), .confirmed)
            try expectEqual(WallpaperStoreVerifier.confirm(current: doc, original: doc, plan: plan), .changeLost(plan.paths))
            let desktop = try good.setting(.data(Data()), at: ["Displays", StoreFixture.displays[2], "Desktop", "Content", "EncodedOptionValues"])
            try expectEqual(WallpaperStoreVerifier.confirm(current: WallpaperStoreDocument(root: desktop), original: doc, plan: plan),
                            .desktopChanged([.display(StoreFixture.displays[2])]))
            let reset = try WallpaperStoreDocument(data: WallpaperStoreSchema.encode(StoreFixture.Schema.Index(systemDefault: StoreFixture.record(.inherit))))
            if case .desktopChanged(let paths) = WallpaperStoreVerifier.confirm(current: reset, original: doc, plan: plan) {
                try expectEqual(paths.count, 18)   // a default store lost every display and Space record
            } else { throw TestFailure(description: "a reset store must count as a Desktop change") }
        },
        TestCase(name: "wallpaper.plan-restore") {
            let module = StoreFixture.livePaper
            let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000), t1 = t0.addingTimeInterval(60)
            let original = try WallpaperStoreDocument(data: StoreFixture.data())
            let plan = try original.planSelect(module, at: t0)
            let manifest = try WallpaperSelectionManifest(module: module.moduleURLString, createdAt: t0).recording(plan, module: module, at: t0)
            try expectEqual(manifest.slots.map(\.record), StoreFixture.selectPaths)
            try expectEqual(manifest.entry(for: .systemDefault)?.provider, WallpaperSlot.screenSaverProvider)
            try expectEqual(manifest.entry(for: .systemDefault)?.configuration, StoreFixture.moduleConfiguration(StoreFixture.otherSaverPath))
            try expectEqual(try manifest.entry(for: .systemDefault)?.originalSlot(), original.idleSlot(at: .systemDefault))
            let selected = try original.applying(plan)
            // Select then restore = the original store, exactly.
            let restore = try selected.planRestore(manifest, module: module, at: t1, moduleExists: { _ in true })
            try expectEqual(restore.paths, StoreFixture.selectPaths)
            try expectEqual(try selected.applying(restore), original)
            try WallpaperStoreVerifier.verify(edited: selected.applying(restore).data(), original: selected, plan: restore)
            // The manifest survives JSON (whole-second dates).
            try StoreSandbox.with("manifest") { sb in
                try manifest.write(to: sb.manifest)
                try expectEqual(try WallpaperSelectionManifest.load(from: sb.manifest), manifest)
                let json = try String(contentsOf: sb.manifest, encoding: .utf8)
                try expect(json.contains("\"slot\"") && json.contains("\"provider\"") && json.contains("\"configuration\""), json)
                try check(try WallpaperSelectionManifest.load(from: sb.root.appendingPathComponent("none.json")) == nil)
            }
            // The user changed one slot since; a display appeared (copied from SystemDefault); a
            // recorded original's module was deleted (a sub-slot and SystemDefault).
            let userChoice = try WallpaperSaverModule(url: URL(fileURLWithPath: "/Users/user/Library/Screen Savers/Chosen.saver")).slot(at: t1)
            let newDisplay = "0000000F-0000-4000-8000-00000000000F"
            var tree = try selected.replacingIdleSlots([.display(StoreFixture.displays[0]): userChoice]).root
            tree = try tree.setting(selected.root.value(at: ["SystemDefault"])!, at: ["Displays", newDisplay])
            let later = WallpaperStoreDocument(root: tree)
            let deleted = { (url: URL) in url.lastPathComponent != "Example.saver" }
            let partial = try later.planRestore(manifest, module: module, at: t1, moduleExists: deleted)
            try expectEqual(Set(partial.paths), Set(StoreFixture.selectPaths.filter { $0 != .display(StoreFixture.displays[0]) } + [.display(newDisplay)]))
            let after = try later.applying(partial)
            try expectEqual(after.idleSlot(at: .display(StoreFixture.displays[0])), userChoice)
            try expectEqual(after.idleSlot(at: .display(newDisplay)), WallpaperChoicePayload.inheritSlot(at: t1))
            try expectEqual(after.idleSlot(at: .spaceDefault("")), WallpaperChoicePayload.inheritSlot(at: t1))
            try expectEqual(after.idleSlot(at: .systemDefault), original.idleSlot(at: .systemDefault))
            try expect(StoreFixture.placeholderDisplayPaths.allSatisfy { after.idleSlot(at: $0) == original.idleSlot(at: $0) },
                       "the placeholders are back exactly")
            try expect(after.selection(of: module).livePaper.isEmpty)
            // Without a recorded original (LivePaper picked by hand in System Settings) no slot may keep
            // pointing at LivePaper: the placeholder below the root; SystemDefault, which can't inherit,
            // gets the pre-LivePaper store's choice, else the built-in saver — or nothing can be done.
            let empty = WallpaperSelectionManifest(module: module.moduleURLString, createdAt: t0)
            try expectStoreError(.noPreviousChoice("SystemDefault")) {
                _ = try selected.planRestore(empty, module: module, at: t1, moduleExists: { _ in true })
            }
            let builtin = WallpaperSaverModule(url: WallpaperRestoreFallback.systemSaverURL)
            let unrecorded = try selected.planRestore(empty, module: module, at: t1, fallback: WallpaperRestoreFallback(builtinSaver: builtin),
                                                      moduleExists: { _ in true })
            try expectEqual(unrecorded.paths, StoreFixture.selectPaths)
            try expectEqual(unrecorded.builtinSaverPaths, [.systemDefault])
            try expectEqual(unrecorded.changes.first?.after, try builtin.slot(at: t1))
            try expect(unrecorded.changes.dropFirst().allSatisfy { $0.after == WallpaperChoicePayload.inheritSlot(at: t1) })
            try check(try selected.applying(unrecorded).selection(of: module).livePaper.isEmpty)
            try WallpaperStoreVerifier.verify(edited: selected.applying(unrecorded).data(), original: selected, plan: unrecorded)
            try expectStoreError(.noPreviousChoice("SystemDefault")) {   // a built-in saver that isn't there doesn't count
                _ = try selected.planRestore(empty, module: module, at: t1, fallback: WallpaperRestoreFallback(builtinSaver: builtin),
                                             moduleExists: { $0 != builtin.url })
            }
            // The pre-LivePaper store's choice comes first…
            let fromBackup = try selected.planRestore(empty, module: module, at: t1,
                                                      fallback: WallpaperRestoreFallback(previousStore: original, builtinSaver: builtin),
                                                      moduleExists: { _ in true })
            try expectEqual(fromBackup.changes.first?.after, original.idleSlot(at: .systemDefault))
            try expect(fromBackup.builtinSaverPaths.isEmpty)
            // …unless it chose LivePaper too.
            let previousLivePaper = try WallpaperStoreDocument(data: StoreFixture.data(saver: StoreFixture.livePaperPath))
            let notFromBackup = try selected.planRestore(empty, module: module, at: t1,
                                                         fallback: WallpaperRestoreFallback(previousStore: previousLivePaper, builtinSaver: builtin),
                                                         moduleExists: { _ in true })
            try expectEqual(notFromBackup.builtinSaverPaths, [.systemDefault])
            // A recorded original that is LivePaper at another location goes back while that copy
            // exists; when it's gone it counts as no original.
            let elsewhere = try WallpaperSaverModule(url: URL(fileURLWithPath: "/Library/Screen Savers/LivePaper.saver")).slot(at: t0)
            let elsewhereStore = try original.replacingIdleSlots([.systemDefault: elsewhere])
            let elsewherePlan = try elsewhereStore.planSelect(module, at: t0, moduleExists: { _ in true })
            let elsewhereManifest = try empty.recording(elsewherePlan, module: module, at: t0)
            try expectEqual(try elsewhereManifest.entry(for: .systemDefault)?.originalSlot(), elsewhere)
            let elsewhereSelected = try elsewhereStore.applying(elsewherePlan)
            let back = try elsewhereSelected.planRestore(elsewhereManifest, module: module, at: t1, moduleExists: { _ in true })
            try expectEqual(try elsewhereSelected.applying(back).idleSlot(at: .systemDefault), elsewhere)
            let gone = try elsewhereSelected.planRestore(elsewhereManifest, module: module, at: t1,
                                                         fallback: WallpaperRestoreFallback(builtinSaver: builtin),
                                                         moduleExists: { $0.path != "/Library/Screen Savers/LivePaper.saver" })
            try expectEqual(gone.builtinSaverPaths, [.systemDefault])
            // Selecting again after the user switched away records their newer choice; LivePaper
            // itself is never recorded as an original.
            let switched = try selected.replacingIdleSlots([.systemDefault: userChoice])
            let again = try switched.planSelect(module, at: t1)
            try expectEqual(again.paths, [.systemDefault])
            let updated = try manifest.recording(again, module: module, at: t1)
            try expectEqual(try updated.entry(for: .systemDefault)?.originalSlot(), userChoice)
            try expectEqual(updated.slots.count, 16)
            try expectEqual(try manifest.recording(try selected.planSelect(module, at: t1), module: module, at: t1).slots, manifest.slots)
        },
    ] }
}

/// Builders for unusual configurations.
private enum FakePayload {
    static func configuration(relative: String, base: String? = nil) -> Data {
        var module: [String: PlistValue] = ["relative": .string(relative)]
        if let base { module["base"] = .dictionary(["relative": .string(base)]) }
        return StoreFixture.plist(.dictionary(["module": .dictionary(module)]))
    }
}

extension PlistValue {
    /// A copy without the value at `path` (test helper).
    func removing(_ path: [String]) -> PlistValue {
        guard let key = path.first, var dict = dictionaryValue else { return self }
        if path.count == 1 { dict.removeValue(forKey: key) } else if let child = dict[key] { dict[key] = child.removing(Array(path.dropFirst())) }
        return .dictionary(dict)
    }
}

// MARK: - Applier

extension SelfTests {
    fileprivate static var wallpaperApplier: [TestCase] { [
        TestCase(name: "wallpaper.applier.select-restore") {
            try StoreSandbox.with("apply") { sb in
                let original = try sb.bytes()
                let clock = FakeClock(), system = FakeWallpaperSystem(store: sb.store)
                let report = try applier(sb, system, clock).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup)
                try expectEqual(report, WallpaperApplyReport(outcome: .applied, changed: StoreFixture.selectPaths, attempts: 1, agentRestarts: 1))
                try expect(clock.slept > 1.99, "waited for a quiet store before and after the restart (\(clock.slept) s)")
                let selected = try sb.document()
                try expect(selected.selection(of: sb.module).isSelectedEverywhere)
                try expectEqual(desktopSlots(selected), desktopSlots(try WallpaperStoreDocument(data: original)))
                try expectEqual(try Data(contentsOf: sb.rawBackup), original)
                try expectEqual(try WallpaperSelectionManifest.load(from: sb.manifest)?.slots.map(\.record), StoreFixture.selectPaths)
                try expect(!FileManager.default.fileExists(atPath: sb.store.path + ".tmp"))
                try expectEqual(try FileManager.default.contentsOfDirectory(atPath: sb.store.deletingLastPathComponent().path), ["Index.plist"])
                // Again: nothing to do, the agent isn't restarted.
                try expectEqual(try applier(sb, system, clock).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup).outcome, .unchanged)
                try expectEqual(system.restarts, 1)
                // Restore: the agent's file is byte-identical to before LivePaper.
                let restored = try applier(sb, system, clock).restore(sb.module, manifestURL: sb.manifest)
                try expectEqual(restored.outcome, .applied)
                try expectEqual(restored.changed, StoreFixture.selectPaths)
                try expectEqual(try sb.bytes(), original)
                try expect(!sb.exists(sb.manifest), "manifest removed after a restore")
                try expectEqual(try applier(sb, system, clock).restore(sb.module, manifestURL: sb.manifest).outcome, .unchanged)
                try expectEqual(system.restarts, 2)
            }
        },
        TestCase(name: "wallpaper.applier.refusals") {
            let refusal = { (name: String, expected: WallpaperStoreError, setup: (StoreSandbox, FakeWallpaperSystem) throws -> Void) throws in
                try StoreSandbox.with("refuse-\(name)") { sb in
                    let system = FakeWallpaperSystem(store: sb.store)
                    try setup(sb, system)
                    let before = FileManager.default.contents(atPath: sb.store.path)
                    try expectStoreError(expected) {
                        _ = try applier(sb, system, FakeClock()).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup)
                    }
                    try expect(!expected.wroteStore)
                    try expectEqual(FileManager.default.contents(atPath: sb.store.path), before)
                    try expectEqual(system.restarts, 0)
                    try expect(!sb.exists(sb.manifest) && !sb.exists(sb.rawBackup), "\(name): no backups")
                }
            }
            try refusal("unavailable", .unavailable("redirected")) { $1.unavailable = "redirected" }
            try refusal("locked", .sessionLocked) { $1.session = .locked }
            try refusal("no-session", .sessionUnknown) { $1.session = .unknown }
            try refusal("settings", .conflictingProcess("System Settings")) { $1.conflicts = ["System Settings"] }
            try refusal("forced", .moduleForcedByMDM) { $1.forced = true }
            try refusal("disabled", .wallpaperChangesDisabledByMDM) { $1.disabled = true }
            try refusal("version", .unsupportedStoreVersion(11)) { $1.version = 11 }
            try refusal("no-version", .unsupportedStoreVersion(nil)) { $1.version = nil }
        },
        TestCase(name: "wallpaper.applier.refusals.store") {
            let module = { (sb: StoreSandbox) in sb.module }
            let check = { (name: String, data: Data?, matches: (WallpaperStoreError) -> Bool) throws in
                try StoreSandbox.with("refuse-\(name)") { sb in
                    if let data { try data.write(to: sb.store) } else { try FileManager.default.removeItem(at: sb.store) }
                    let system = FakeWallpaperSystem(store: sb.store)
                    var thrown: WallpaperStoreError?
                    do { _ = try applier(sb, system, FakeClock()).select(module(sb), manifestURL: sb.manifest, rawBackupURL: sb.rawBackup) }
                    catch let error as WallpaperStoreError { thrown = error }
                    try expect(thrown.map(matches) == true, "\(name): \(thrown.map { "\($0)" } ?? "no error")")
                    try expectEqual(FileManager.default.contents(atPath: sb.store.path), data)
                    try expect(system.restarts == 0 && !sb.exists(sb.manifest) && !sb.exists(sb.rawBackup))
                }
            }
            try check("missing", nil) { if case .storeMissing = $0 { return true }; return false }
            try check("garbage", Data("garbage".utf8)) { if case .undecodable = $0 { return true }; return false }
            try check("shape", try PlistValue.dictionary(["SystemDefault": .string("x")]).binaryData()) { if case .undecodable = $0 { return true }; return false }
            var linked = StoreFixture.index()
            linked.spaces[""]?.default = .linked(StoreFixture.desktop())
            try check("linked", try WallpaperStoreSchema.encode(linked)) { if case .unsupportedShape = $0 { return true }; return false }
            // The saver must exist before the store points at it.
            try StoreSandbox.with("refuse-saver") { sb in
                try FileManager.default.removeItem(at: sb.saver)
                try expectStoreError(.saverMissing(sb.saver.path)) {
                    _ = try applier(sb, FakeWallpaperSystem(store: sb.store), FakeClock()).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup)
                }
            }
            // A plan that would produce a store the agent can't decode is refused before writing.
            try StoreSandbox.with("refuse-plan") { sb in
                let before = try sb.bytes()
                let system = FakeWallpaperSystem(store: sb.store)
                var refused = false
                do {
                    _ = try applier(sb, system, FakeClock()).apply(checkModulePolicy: true, plan: { doc in
                        let broken = PlistValue.dictionary(["Content": .dictionary(["Choices": .array([.dictionary(["Files": .array([])])])])])
                        return WallpaperStorePlan(changes: [WallpaperSlotChange(path: .systemDefault, before: doc.idleSlot(at: .systemDefault)!,
                                                                                after: broken, recordsOriginal: true)])
                    })
                } catch WallpaperStoreError.verificationFailed { refused = true }
                try expect(refused)
                try expectEqual(try sb.bytes(), before)
                try expectEqual(system.restarts, 0)
            }
            // Undoing LivePaper's own change is allowed even when MDM forces the module.
            try StoreSandbox.with("restore-mdm") { sb in
                let system = FakeWallpaperSystem(store: sb.store), clock = FakeClock()
                _ = try applier(sb, system, clock).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup)
                system.forced = true
                system.disabled = true
                try expectEqual(try applier(sb, system, clock).restore(sb.module, manifestURL: sb.manifest).outcome, .applied)
                system.conflicts = ["System Settings"]
                try StoreFixture.data(saver: sb.saver.path).write(to: sb.store)
                try WallpaperSelectionManifest(module: "", createdAt: Date()).write(to: sb.manifest)
                try expectStoreError(.conflictingProcess("System Settings")) {
                    _ = try applier(sb, system, clock).restore(sb.module, manifestURL: sb.manifest)
                }
                try expect(sb.exists(sb.manifest), "a refused restore keeps the manifest")
            }
        },
        TestCase(name: "wallpaper.applier.retry") {
            // The old agent wrote from memory between LivePaper's rename and the restart: retried once.
            try StoreSandbox.with("lost-once") { sb in
                let original = try sb.bytes()
                let system = FakeWallpaperSystem(store: sb.store), clock = FakeClock()
                system.onRestart = { n in if n == 1 { try system.overwrite(with: original) } else { try system.agentRewrite() } }
                let report = try applier(sb, system, clock).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup)
                try expectEqual(report, WallpaperApplyReport(outcome: .applied, changed: StoreFixture.selectPaths, attempts: 2, agentRestarts: 2))
                try expect(clock.slept > 3.99, "retried at least 2 s later")
                try check(try sb.document().selection(of: sb.module).isSelectedEverywhere)
                try expectEqual(try Data(contentsOf: sb.rawBackup), original)
                try expectEqual(try WallpaperSelectionManifest.load(from: sb.manifest)?.slots.count, 16)
            }
            // Lost every time: three attempts (1 + 2 retries), then an error.
            try StoreSandbox.with("lost-always") { sb in
                let original = try sb.bytes()
                let system = FakeWallpaperSystem(store: sb.store)
                system.onRestart = { _ in try system.overwrite(with: original) }
                var reason = ""
                do { _ = try applier(sb, system, FakeClock()).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup) }
                catch WallpaperStoreError.notConfirmed(let why) { reason = why }
                try expect(reason.hasPrefix("WallpaperAgent overwrote SystemDefault"), reason)
                try expectEqual(system.restarts, 3)
                try expect(WallpaperStoreError.notConfirmed("").wroteStore && WallpaperStoreError.notConfirmed("").isTransient)
            }
            // The agent never rewrites the file: restarted again on each retry, then an error.
            try StoreSandbox.with("no-rewrite") { sb in
                let system = FakeWallpaperSystem(store: sb.store), clock = FakeClock()
                system.onRestart = { _ in }
                var reason = ""
                do { _ = try applier(sb, system, clock).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup) }
                catch WallpaperStoreError.notConfirmed(let why) { reason = why }
                try expectEqual(reason, "WallpaperAgent didn't rewrite the store after restarting")
                try expectEqual(system.restarts, 3)
                try expect(clock.slept > 33.99, "waited for each rewrite (\(clock.slept) s)")
                try check(try sb.document().selection(of: sb.module).isSelectedEverywhere, "the written store stays (it is valid)")
            }
            // The restart itself fails.
            try StoreSandbox.with("restart-fails") { sb in
                let system = FakeWallpaperSystem(store: sb.store)
                system.restartError = WallpaperStoreError.agentRestartFailed("No matching processes belonging to you were found")
                try expectStoreError(.agentRestartFailed("No matching processes belonging to you were found")) {
                    _ = try applier(sb, system, FakeClock()).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup)
                }
            }
            // The store changed between reading and writing: re-read on the next attempt.
            try StoreSandbox.with("changed-while-editing") { sb in
                let system = FakeWallpaperSystem(store: sb.store), clock = FakeClock()
                var touched = false
                let report = try applier(sb, system, clock).apply(checkModulePolicy: true, plan: { try $0.planSelect(sb.module, at: clock.now()) },
                                                                  beforeWrite: { bytes, _ in
                    if !touched { touched = true; try bytes.write(to: sb.store, options: .atomic) }
                })
                try expectEqual(report.attempts, 2)
                try expectEqual(system.restarts, 1)
            }
            // Something refuses during a retry after LivePaper wrote: reported as unconfirmed.
            try StoreSandbox.with("refused-on-retry") { sb in
                let original = try sb.bytes()
                let system = FakeWallpaperSystem(store: sb.store)
                system.onRestart = { _ in try system.overwrite(with: original); system.conflicts = ["System Settings"] }
                var reason = ""
                do { _ = try applier(sb, system, FakeClock()).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup) }
                catch WallpaperStoreError.notConfirmed(let why) { reason = why }
                try expectEqual(reason, WallpaperStoreError.conflictingProcess("System Settings").localizedDescription)
                try expectEqual(system.restarts, 1)
            }
        },
        TestCase(name: "wallpaper.applier.quiet") {
            // WallpaperAgent is busy writing for 3 s: LivePaper reads only after 1 s of quiet.
            try StoreSandbox.with("busy") { sb in
                let original = try sb.bytes()
                let system = FakeWallpaperSystem(store: sb.store), clock = FakeClock()
                let start = clock.now()
                var readAt: Date?
                for i in 1...6 { clock.schedule(after: Double(i) * 0.5) { try? original.write(to: sb.store, options: .atomic) } }
                _ = try applier(sb, system, clock).apply(checkModulePolicy: true, plan: { doc in
                    if readAt == nil { readAt = clock.now() }
                    return try doc.planSelect(sb.module, at: clock.now())
                })
                try expect((readAt?.timeIntervalSince(start) ?? 0) >= 4, "read after the last write + 1 s: \(readAt.map { $0.timeIntervalSince(start) } ?? -1)")
                try check(try sb.document().selection(of: sb.module).isSelectedEverywhere)
            }
            // It never stops: give up without writing anything.
            try StoreSandbox.with("never-quiet") { sb in
                let original = try sb.bytes()
                let system = FakeWallpaperSystem(store: sb.store), clock = FakeClock()
                func keepWriting() { clock.schedule(after: 0.3) { try? original.write(to: sb.store, options: .atomic); keepWriting() } }
                keepWriting()
                try expectStoreError(.storeBusy) {
                    _ = try applier(sb, system, clock).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup)
                }
                try expectEqual(try sb.bytes(), original)
                try expect(system.restarts == 0 && !sb.exists(sb.manifest) && !sb.exists(sb.rawBackup))
                try expect(clock.slept > 14.9 && clock.slept < 16, "gave up after the quiet timeout (\(clock.slept) s)")
            }
        },
        TestCase(name: "wallpaper.applier.rollback") {
            // The restarted agent couldn't use the edit and fell back to a default store (Desktop lost):
            // the previous store goes back and the agent is restarted once more.
            try StoreSandbox.with("reset") { sb in
                let original = try sb.bytes()
                let system = FakeWallpaperSystem(store: sb.store)
                system.onRestart = { n in
                    if n == 1 { try WallpaperStoreSchema.encode(.init(systemDefault: StoreFixture.record(.inherit))).write(to: sb.store, options: .atomic) }
                    else { try system.agentRewrite() }
                }
                var reason = ""
                do { _ = try applier(sb, system, FakeClock()).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup) }
                catch WallpaperStoreError.rolledBack(let why) { reason = why }
                try expect(reason.hasPrefix("Desktop of Displays/"), reason)
                try expectEqual(system.restarts, 2)
                try expectEqual(try sb.bytes(), original)
            }
            // The restarted agent wrote something unreadable.
            try StoreSandbox.with("unreadable") { sb in
                let original = try sb.bytes()
                let system = FakeWallpaperSystem(store: sb.store)
                system.onRestart = { n in if n == 1 { try Data("??".utf8).write(to: sb.store, options: .atomic) } else { try system.agentRewrite() } }
                try expectStoreError(.rolledBack("the restarted WallpaperAgent wrote a store LivePaper can't read")) {
                    _ = try applier(sb, system, FakeClock()).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup)
                }
                try expectEqual(try sb.bytes(), original)
                try expectEqual(system.restarts, 2)
            }
        },
        TestCase(name: "wallpaper.applier.recheck") {
            // The Mac locks while LivePaper waits for a quiet store (click "Make LivePaper my screen
            // saver", then ⌃⌘Q to see it): the agent's lock-time writes only stretch the wait, and
            // LivePaper must not then replace the store and kill the agent that draws the lock screen.
            for (name, event, expected) in [
                ("locked", { (s: FakeWallpaperSystem) in s.session = .locked }, WallpaperStoreError.sessionLocked),
                ("settings", { (s: FakeWallpaperSystem) in s.conflicts = ["System Settings"] }, .conflictingProcess("System Settings")),
            ] {
                try StoreSandbox.with("recheck-\(name)") { sb in
                    let original = try sb.bytes()
                    let system = FakeWallpaperSystem(store: sb.store), clock = FakeClock()
                    clock.schedule(after: 0.5) { event(system); try? original.write(to: sb.store, options: .atomic) }
                    clock.schedule(after: 0.9) { try? original.write(to: sb.store, options: .atomic) }
                    try expectStoreError(expected) {
                        _ = try applier(sb, system, clock).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup)
                    }
                    try expect(system.restarts == 0 && system.sessionAtRestart.isEmpty, "\(name): restarted \(system.sessionAtRestart)")
                    try expectEqual(try sb.bytes(), original)
                    try expect(!sb.exists(sb.manifest) && !sb.exists(sb.rawBackup), "\(name): nothing written")
                }
            }
            // Locked while waiting for a restarted agent's rewrite that never came: the retry doesn't
            // restart it again.
            try StoreSandbox.with("recheck-retry") { sb in
                let system = FakeWallpaperSystem(store: sb.store), clock = FakeClock()
                system.onRestart = { _ in clock.schedule(after: 1) { system.session = .locked } }
                try expectStoreError(.notConfirmed(WallpaperStoreError.sessionLocked.localizedDescription)) {
                    _ = try applier(sb, system, clock).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup)
                }
                try expectEqual(system.sessionAtRestart, [.unlocked])
            }
        },
        TestCase(name: "wallpaper.applier.retry-normalised") {
            // The restarted agent spells LivePaper's slots its own way — the Desktop's option values
            // (as System Settings writes saver slots), its own LastSet. What is chosen is what counts:
            // confirmed at once, the agent restarted once.
            try StoreSandbox.with("normalised") { sb in
                let system = FakeWallpaperSystem(store: sb.store), clock = FakeClock()
                system.onRestart = { _ in
                    var tree = try PlistValue.parse(Data(contentsOf: sb.store))
                    for record in WallpaperStoreDocument(root: tree).records {
                        guard let idle = record.idle, sb.module.isChosen(in: idle),
                              let options = record.desktop?.value(at: ["Content", "EncodedOptionValues"]) else { continue }
                        tree = try tree.setting(options, at: record.path.keyPath + ["Idle", "Content", "EncodedOptionValues"])
                            .setting(.date(clock.now()), at: record.path.keyPath + ["Idle", "LastSet"])
                    }
                    try tree.binaryData().write(to: sb.store, options: .atomic)
                }
                let report = try applier(sb, system, clock).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup)
                try expectEqual(report, WallpaperApplyReport(outcome: .applied, changed: StoreFixture.selectPaths, attempts: 1, agentRestarts: 1))
            }
            // It lets a planned Space Default inherit instead (every display still shows LivePaper):
            // the agent derives those defaults from the displays it shows — confirmed at once.
            try StoreSandbox.with("normalised-inherit") { sb in
                let system = FakeWallpaperSystem(store: sb.store), clock = FakeClock()
                let space = WallpaperRecordPath.spaceDefault("")
                system.onRestart = { n in
                    guard n == 1 else { try system.agentRewrite(); return }
                    let doc = try WallpaperStoreDocument(data: Data(contentsOf: sb.store))
                    try doc.replacingIdleSlots([space: WallpaperChoicePayload.inheritSlot(at: clock.now())]).data().write(to: sb.store, options: .atomic)
                }
                let report = try applier(sb, system, clock).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup)
                try expectEqual(report, WallpaperApplyReport(outcome: .applied, changed: StoreFixture.selectPaths, attempts: 1, agentRestarts: 1,
                                                             rewrittenByAgent: [space]))
                try check(try sb.document().selection(of: sb.module).isSelectedOnEveryDisplay)
            }
            // A display slot left on the placeholder isn't kept, though (that is what fell back to
            // macOS's default): planned again, and the next restart keeps it.
            try StoreSandbox.with("normalised-inherit-display") { sb in
                let system = FakeWallpaperSystem(store: sb.store), clock = FakeClock()
                let display = WallpaperRecordPath.display(StoreFixture.displays[0])
                system.onRestart = { n in
                    guard n == 1 else { try system.agentRewrite(); return }
                    let doc = try WallpaperStoreDocument(data: Data(contentsOf: sb.store))
                    try doc.replacingIdleSlots([display: WallpaperChoicePayload.inheritSlot(at: clock.now())]).data().write(to: sb.store, options: .atomic)
                }
                let report = try applier(sb, system, clock).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup)
                try expectEqual(report.outcome, .applied)
                try expect(report.attempts == 2 && system.restarts == 2 && report.changed == [display], "\(report), \(system.restarts) restarts")
                try check(try sb.document().selection(of: sb.module).isSelectedEverywhere)
            }
        },
        TestCase(name: "wallpaper.applier.rollback-verified") {
            let reset = try defaultStore()
            // The rollback races the old agent too (it writes its in-memory default store between the
            // rename and the restart): retried until the previous store is confirmed back.
            try StoreSandbox.with("rollback-race") { sb in
                let original = try sb.bytes()
                let system = FakeWallpaperSystem(store: sb.store)
                system.onRestart = { n in
                    switch n {
                    case 1: try reset.write(to: sb.store, options: .atomic)   // the agent couldn't use LivePaper's edit
                    case 2: try system.overwrite(with: reset)                  // …and wrote that model while dying
                    default: try system.agentRewrite()
                    }
                }
                var reason = ""
                do { _ = try applier(sb, system, FakeClock()).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup) }
                catch WallpaperStoreError.rolledBack(let why) { reason = why }
                try expect(reason.hasPrefix("Desktop of "), reason)
                try expectEqual(system.restarts, 3)
                try expectEqual(try sb.bytes(), original)
            }
            // It never sticks, or the rollback's restart fails: not reported as "put back" — reported
            // as failed, naming the saved copy of the previous store.
            for name in ["lost", "restart-fails"] {
                try StoreSandbox.with("rollback-\(name)") { sb in
                    let original = try sb.bytes()
                    let system = FakeWallpaperSystem(store: sb.store)
                    system.onRestart = { n in
                        if n == 1 {
                            try reset.write(to: sb.store, options: .atomic)
                            if name == "restart-fails" { system.restartError = WallpaperStoreError.agentRestartFailed("no such process") }
                        } else { try system.overwrite(with: reset) }
                    }
                    var reason = ""
                    do { _ = try applier(sb, system, FakeClock(), snapshot: true).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup) }
                    catch WallpaperStoreError.rollbackFailed(let why) { reason = why }
                    try expect(reason.contains(sb.snapshot.path), "\(name): \(reason)")
                    try expectEqual(try Data(contentsOf: sb.snapshot), original)
                    try expectEqual(system.restarts, 4)
                    try expect(WallpaperStoreError.rollbackFailed("").wroteStore && !WallpaperStoreError.rollbackFailed("").isTransient)
                }
            }
            // The Mac locks before the rollback: it waits for the unlock before restarting the agent…
            try StoreSandbox.with("rollback-locked") { sb in
                let original = try sb.bytes()
                let system = FakeWallpaperSystem(store: sb.store), clock = FakeClock()
                system.onRestart = { n in
                    guard n == 1 else { try system.agentRewrite(); return }
                    try reset.write(to: sb.store, options: .atomic)
                    system.session = .locked
                    clock.schedule(after: 20) { system.session = .unlocked }
                }
                do { _ = try applier(sb, system, clock).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup) }
                catch WallpaperStoreError.rolledBack {}
                try expectEqual(system.sessionAtRestart, [.unlocked, .unlocked])
                try expectEqual(try sb.bytes(), original)
            }
            // …but not forever.
            try StoreSandbox.with("rollback-stays-locked") { sb in
                let system = FakeWallpaperSystem(store: sb.store)
                system.onRestart = { _ in try reset.write(to: sb.store, options: .atomic); system.session = .locked }
                var reason = ""
                do { _ = try applier(sb, system, FakeClock(), snapshot: true).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup) }
                catch WallpaperStoreError.rollbackFailed(let why) { reason = why }
                try expect(reason.contains("the Mac is locked") && reason.contains(sb.snapshot.path), reason)
                try expectEqual(system.sessionAtRestart, [.unlocked])
            }
        },
        TestCase(name: "wallpaper.live-system-guard") {
            // The live killer refuses any store but the agent's own: tests can never restart it.
            try StoreSandbox.with("guard") { sb in
                let runner = RecordingCommandRunner()
                let live = LiveWallpaperSystem(storeURL: sb.store, runner: runner)
                try expect(live.unavailability(forStoreAt: sb.store) != nil)
                try expect(live.unavailability(forStoreAt: LiveWallpaperSystem.agentStoreURL) != nil, "configured for a different store")
                var refused = false
                do { try live.restartWallpaperAgent() } catch WallpaperStoreError.unavailable { refused = true }
                try expect(refused && runner.commands.isEmpty, "no command was run: \(runner.commands)")
                try expect(LiveWallpaperSystem.agentStoreURL.path.hasSuffix("/Library/Application Support/com.apple.wallpaper/Store/Index.plist"))
                // The applier stops at the first check, before probing anything else.
                let before = try sb.bytes()
                var unavailable = false
                do { _ = try WallpaperStoreApplier(storeURL: sb.store, system: live, clock: FakeClock()).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup) }
                catch WallpaperStoreError.unavailable { unavailable = true }
                try expect(unavailable && runner.commands.isEmpty)
                try expectEqual(try sb.bytes(), before)
                let unavailableSystem = UnavailableWallpaperSystem(reason: "recorded")
                try expectEqual(unavailableSystem.unavailability(forStoreAt: sb.store), "recorded")
            }
        },
    ] }
}

// MARK: - InstallService

/// Preferences in memory.
final class MemoryPreferences: PreferencesAccessing, @unchecked Sendable {
    var values: [String: Any] = [:]
    func value(domain: String, key: String, currentHost: Bool) -> Any? { values["\(domain)|\(key)|\(currentHost)"] }
    func set(_ value: Any?, domain: String, key: String, currentHost: Bool) -> Bool { values["\(domain)|\(key)|\(currentHost)"] = value; return true }
}

private struct NoLoginItem: LoginItemRegistering {
    var isAvailable: Bool { false }
    var status: LoginItemStatus { .notFound }
    func register() throws -> LoginItemStatus { .notFound }
    func unregister() throws {}
}

/// An InstallService over a StoreSandbox, with every system interaction faked.
struct InstallFixture {
    let sb: StoreSandbox
    let system: FakeWallpaperSystem
    let clock = FakeClock()
    let runner = RecordingCommandRunner { exe, args in
        exe == "/bin/launchctl" && args.first == "print" ? CommandResult(status: 113, stderr: "Could not find service") : nil
    }
    let preferences = MemoryPreferences()

    init(_ sb: StoreSandbox) {
        self.sb = sb
        system = FakeWallpaperSystem(store: sb.store)
    }

    var paths: InstallPaths {
        InstallPaths(saverTemplate: sb.root.appendingPathComponent("app/LivePaper.saver"), screenSaversDir: sb.saver.deletingLastPathComponent(),
                     launchAgentsDir: sb.root.appendingPathComponent("agents"), wallpaperStore: sb.store,
                     supportRoot: sb.root.appendingPathComponent("support"), helperExecutable: sb.root.appendingPathComponent("app/Helper"),
                     managedPreferences: [], builtinScreenSaver: sb.builtinSaver)
    }

    func service(dryRun: Bool = false, system override: WallpaperSystem? = nil) -> InstallService {
        InstallService(paths: paths, publisher: nil, runner: runner, loginItem: NoLoginItem(), preferences: preferences, dryRun: dryRun,
                       uid: 501, wallpaperSystem: override ?? system, wallpaperClock: clock)
    }

    /// Commands other than read-only probes (there must never be a killall: the agent is faked).
    var mutatingCommands: [[String]] { runner.commands.filter { $0.first != "/bin/launchctl" && $0.first != "/usr/sbin/sysadminctl" } }
}

let selectTitle = "Select LivePaper as the screen saver"
let restoreTitle = "Restore the previous screen saver choice"

extension SelfTests {
    fileprivate static var wallpaperInstall: [TestCase] { [
        TestCase(name: "wallpaper.install.select") {
            try StoreSandbox.with("install-select") { sb in
                let fx = InstallFixture(sb)
                let original = try sb.bytes()
                try expect(!fx.service().status().saverSelected)
                // A dry run changes nothing.
                let dry = fx.service(dryRun: true)
                try check(!(try dry.selectSaver()))
                try expectEqual(dry.transcript, [InstallStep(title: selectTitle, outcome: .planned)])
                try expectEqual(try sb.bytes(), original)

                let service = fx.service()
                try check(try service.selectSaver())
                try expectEqual(service.transcript.last, InstallStep(title: selectTitle, outcome: .done))
                try expect(service.status().saverSelected)
                try expectEqual(fx.system.restarts, 1)
                try expectEqual(try Data(contentsOf: fx.paths.wallpaperStoreBackup), original)
                try expectEqual(try WallpaperSelectionManifest.load(from: fx.paths.wallpaperSelectionBackup)?.slots.count, 16)
                try check(try service.selectSaver())
                try expectEqual(service.transcript.last, InstallStep(title: selectTitle, outcome: .skipped("already selected")))
                try expectEqual(fx.system.restarts, 1)
                try expect(fx.mutatingCommands.isEmpty, "\(fx.mutatingCommands)")
            }
        },
        TestCase(name: "wallpaper.install.select-moved") {
            // Picked by hand in System Settings at an old location that is gone: rewritten, and that
            // location is never recorded as the choice to restore.
            try StoreSandbox.with("install-moved", store: try StoreFixture.data(saver: StoreFixture.livePaperPath)) { sb in
                let fx = InstallFixture(sb)
                let service = fx.service()
                try check(try service.selectSaver())
                try expectEqual(service.transcript.last, InstallStep(title: selectTitle, outcome: .done))
                try expectEqual(fx.system.restarts, 1)
                let moved = try sb.document()
                try expectEqual(moved.selection(of: sb.module).livePaper, StoreFixture.selectPaths)
                try expect(StoreFixture.selectPaths.allSatisfy { moved.idleSlot(at: $0).map(sb.module.isCurrentChoice) == true })
                // Only the displays' placeholders are recorded (never the old location).
                let recorded = try WallpaperSelectionManifest.load(from: fx.paths.wallpaperSelectionBackup)?.slots ?? []
                try expectEqual(recorded.map(\.record), StoreFixture.placeholderDisplayPaths.sorted())
                try expect(recorded.allSatisfy { $0.provider == WallpaperSlot.inheritProvider }, "\(recorded)")
                try check(try service.selectSaver())
                try expectEqual(service.transcript.last, InstallStep(title: selectTitle, outcome: .skipped("already selected")))
                // Uninstall has no original for SystemDefault, and the store from before LivePaper's
                // first change chose LivePaper too: it gets macOS's own saver (the store must never
                // point at the LivePaper.saver uninstall deletes); the other slots inherit it.
                let steps = fx.service().performUninstall(removeLibrary: false)
                try expectEqual(steps.first { $0.title == restoreTitle }?.outcome, .done)
                try expect(steps.contains(InstallStep(title: InstallService.builtinSaverTitle, outcome: .done)), "\(steps)")
                let after = try sb.document()
                try expect(after.selection(of: sb.module).livePaper.isEmpty, "\(after.selection(of: sb.module))")
                try expect(WallpaperSaverModule(url: sb.builtinSaver).isCurrentChoice(in: after.idleSlot(at: .systemDefault)!))
                try expect(StoreFixture.selectPaths.dropFirst().allSatisfy { after.idleSlot(at: $0).map(WallpaperSlot.isInherit) == true })
                try expect(!sb.exists(sb.saver) && steps.allSatisfy { !$0.isFailure }, "\(steps)")
            }
        },
        TestCase(name: "wallpaper.install.uninstall-unmanifested") {
            // LivePaper picked by hand in System Settings (the guided step): LivePaper never wrote the
            // store, so there are no recorded originals — uninstall must still switch every slot away
            // from LivePaper.saver before deleting it.
            try StoreSandbox.with("install-by-hand") { sb in
                try StoreFixture.data(saver: sb.saver.path).write(to: sb.store)
                let fx = InstallFixture(sb)
                // "Make LivePaper my screen saver" finds it already selected: no restart, but the
                // backups now say LivePaper owns those slots.
                let select = fx.service()
                try check(try select.selectSaver())
                try expectEqual(select.transcript.last, InstallStep(title: selectTitle, outcome: .skipped("already selected")))
                try expectEqual(try WallpaperSelectionManifest.load(from: fx.paths.wallpaperSelectionBackup)?.slots, [])
                try expectEqual(fx.system.restarts, 0)
                let plan = fx.service(dryRun: true).performUninstall(removeLibrary: false)
                try expectEqual(plan.first { $0.title == restoreTitle }?.outcome, .planned)

                let steps = fx.service().performUninstall(removeLibrary: false)
                try expectEqual(steps.first { $0.title == restoreTitle }?.outcome, .done)
                try expect(steps.contains(InstallStep(title: InstallService.builtinSaverTitle, outcome: .done)), "\(steps)")
                let after = try sb.document()
                try expect(after.selection(of: sb.module).livePaper.isEmpty)
                try expect(WallpaperSaverModule(url: sb.builtinSaver).isCurrentChoice(in: after.idleSlot(at: .systemDefault)!))
                try expect(!sb.exists(sb.saver) && steps.allSatisfy { !$0.isFailure }, "\(steps)")
                try expectEqual(fx.system.restarts, 1)
            }
            // With the store from before LivePaper's first change, SystemDefault gets that choice back.
            try StoreSandbox.with("install-by-hand-backup") { sb in
                let before = try sb.bytes()
                try StoreFixture.data(saver: sb.saver.path).write(to: sb.store)
                let fx = InstallFixture(sb)
                try FileManager.default.createDirectory(at: fx.paths.backups, withIntermediateDirectories: true)
                try before.write(to: fx.paths.wallpaperStoreBackup)
                let steps = fx.service().performUninstall(removeLibrary: false)
                try expectEqual(steps.first { $0.title == restoreTitle }?.outcome, .done)
                try expect(!steps.contains { $0.title == InstallService.builtinSaverTitle })
                try expectEqual(try sb.document().idleSlot(at: .systemDefault), try WallpaperStoreDocument(data: before).idleSlot(at: .systemDefault))
                try expect(!sb.exists(sb.saver))
            }
            // Nothing LivePaper may put there (no backup, no built-in saver): the step fails with what
            // to do, and the saver and backups stay — the store still points at it.
            try StoreSandbox.with("install-by-hand-stuck") { sb in
                try StoreFixture.data(saver: sb.saver.path).write(to: sb.store)
                try FileManager.default.removeItem(at: sb.builtinSaver)
                let fx = InstallFixture(sb)
                let original = try sb.bytes()
                try check(try fx.service().selectSaver())   // leaves the manifest stub
                for removeLibrary in [false, true] {
                    let steps = fx.service().performUninstall(removeLibrary: removeLibrary)
                    guard case .failed(let why)? = steps.first(where: { $0.title == restoreTitle })?.outcome else { throw TestFailure(description: "\(steps)") }
                    try expect(why.contains("System Settings › Wallpaper › Screen Saver") && why.contains("run uninstall again"), why)
                    try expectEqual(steps.first { $0.title == "Remove \(fx.paths.installedSaver.path)" }?.outcome,
                                    .skipped("kept while it is still the selected screen saver; run uninstall again"))
                    try expect(sb.exists(sb.saver) && sb.exists(fx.paths.wallpaperSelectionBackup), "saver and backups kept: \(steps)")
                    try expectEqual(try sb.bytes(), original)
                    try expectEqual(fx.system.restarts, 0)
                }
                // The user picks another saver themselves, then runs uninstall again: it finishes.
                try StoreFixture.data(saver: sb.otherSaver.path).write(to: sb.store)
                let steps = fx.service().performUninstall(removeLibrary: false)
                try expectEqual(steps.first { $0.title == restoreTitle }?.outcome, .skipped("the screen saver was changed since"))
                try expect(!sb.exists(sb.saver) && !sb.exists(fx.paths.backups) && steps.allSatisfy { !$0.isFailure }, "\(steps)")
            }
        },
        TestCase(name: "wallpaper.install.select-refused") {
            try StoreSandbox.with("install-refused") { sb in
                let fx = InstallFixture(sb)
                let original = try sb.bytes()
                fx.system.conflicts = ["System Settings"]
                let service = fx.service()
                try check(!(try service.selectSaver()))
                try expectEqual(service.transcript.last, InstallStep(title: selectTitle, outcome: .skipped(
                    "needs the guided step in System Settings: System Settings is open — quit it and try again")))
                try expectEqual(try sb.bytes(), original)
                // Without an injected system, a recording runner means "never touch the live system".
                let recorded = InstallService(paths: fx.paths, publisher: nil, runner: fx.runner, loginItem: NoLoginItem(), preferences: fx.preferences)
                try check(!(try recorded.selectSaver()))
                try expectEqual(recorded.transcript.last, InstallStep(title: selectTitle, outcome: .skipped(
                    "needs the guided step in System Settings: the wallpaper settings can't be changed here (system commands are only recorded)")))
                try expectEqual(try sb.bytes(), original)
                try expect(fx.mutatingCommands.isEmpty)
                // Written but not confirmed: an error (the UI shows it, then the guided step).
                fx.system.conflicts = []
                fx.system.onRestart = { _ in try fx.system.overwrite(with: original) }
                var threw = false
                do { _ = try service.selectSaver() } catch WallpaperStoreError.notConfirmed { threw = true }
                try expect(threw)
                if case .failed(let why)? = service.transcript.last?.outcome { try expect(why.hasPrefix("macOS didn't keep the change"), why) }
                else { throw TestFailure(description: "expected a failed step: \(service.transcript)") }
            }
        },
        TestCase(name: "wallpaper.install.uninstall") {
            try StoreSandbox.with("install-uninstall") { sb in
                let fx = InstallFixture(sb)
                let original = try sb.bytes()
                try check(try fx.service().selectSaver())
                let plan = fx.service(dryRun: true).performUninstall(removeLibrary: false)
                try expectEqual(plan.first { $0.title == restoreTitle }?.outcome, .planned)
                try expectEqual(fx.system.restarts, 1)

                // System Settings is open: the restore fails, so the saver stays (the store points at it).
                fx.system.conflicts = ["System Settings"]
                var steps = fx.service().performUninstall(removeLibrary: false)
                try expectEqual(steps.first { $0.title == restoreTitle }?.outcome,
                                .failed(WallpaperStoreError.conflictingProcess("System Settings").localizedDescription))
                try expectEqual(steps.first { $0.title == "Remove \(fx.paths.installedSaver.path)" }?.outcome,
                                .skipped("kept while it is still the selected screen saver; run uninstall again"))
                try expect(sb.exists(sb.saver) && sb.exists(fx.paths.wallpaperSelectionBackup), "saver and backups kept for the retry")

                // Retry once it's closed: everything goes, and the store is exactly as before LivePaper.
                fx.system.conflicts = []
                steps = fx.service().performUninstall(removeLibrary: false)
                try expectEqual(steps.first { $0.title == restoreTitle }?.outcome, .done)
                try expect(!sb.exists(sb.saver) && !sb.exists(fx.paths.backups), "\(steps)")
                try expectEqual(try sb.bytes(), original)
                try expectEqual(fx.system.restarts, 2)
                steps = fx.service().performUninstall(removeLibrary: false)
                try expectEqual(steps.first { $0.title == restoreTitle }?.outcome, .skipped("LivePaper isn't the selected screen saver"))
                try expect(fx.mutatingCommands.isEmpty)
            }
        },
        TestCase(name: "wallpaper.install.uninstall-permanent") {
            // The user changed every slot since: nothing to restore, the manifest goes.
            try StoreSandbox.with("install-changed") { sb in
                let fx = InstallFixture(sb)
                try check(try fx.service().selectSaver())
                try StoreFixture.data().write(to: sb.store)
                let steps = fx.service().performUninstall(removeLibrary: false)
                try expectEqual(steps.first { $0.title == restoreTitle }?.outcome, .skipped("the screen saver was changed since"))
                try expect(!sb.exists(sb.saver))
            }
            // A store LivePaper can't edit any more (a new macOS: another format version, a shape it
            // doesn't know) that still selects LivePaper: the restore can't run, so the step fails with
            // what to do, and the saver and every backup stay — both for a full uninstall and when the
            // scenes are kept. Once the user has picked another saver, running it again finishes.
            let config = StoreFixture.moduleConfiguration(StoreFixture.livePaperPath)
            let futureLivePaper = try PlistValue.dictionary(["Displays": .dictionary(["X": .dictionary(["Idle": .dictionary(["Choice": .data(config)])])])]).binaryData()
            let futureOther = try PlistValue.dictionary(["Displays": .dictionary(["X": .dictionary(["Idle": .dictionary(["Choice": .data(StoreFixture.moduleConfiguration(StoreFixture.otherSaverPath))])])])]).binaryData()
            for (name, breakStore) in [("version", { (sb: StoreSandbox, fx: InstallFixture) throws in fx.system.version = 11 }),
                                       ("format", { (sb: StoreSandbox, fx: InstallFixture) throws in try futureLivePaper.write(to: sb.store) })] {
                for removeLibrary in [false, true] {
                    try StoreSandbox.with("install-\(name)") { sb in
                        let fx = InstallFixture(sb)
                        try check(try fx.service().selectSaver())
                        try breakStore(sb, fx)
                        let broken = try sb.bytes()
                        let steps = fx.service().performUninstall(removeLibrary: removeLibrary)
                        guard case .failed(let why)? = steps.first(where: { $0.title == restoreTitle })?.outcome else {
                            throw TestFailure(description: "\(name): \(steps)")
                        }
                        try expect(why.hasPrefix("LivePaper is still your screen saver (LivePaper couldn't change it back automatically: "), why)
                        try expect(why.contains(name == "version" ? "version 11" : "isn't in the expected format"), why)
                        try expect(why.contains("Choose another screen saver in System Settings › Wallpaper › Screen Saver, then run uninstall again"), why)
                        try expect(why.contains("before LivePaper it was \u{201C}Example\u{201D}"), why)
                        try expectEqual(steps.first { $0.title == "Remove \(fx.paths.installedSaver.path)" }?.outcome,
                                        .skipped("kept while it is still the selected screen saver; run uninstall again"))
                        try expect(sb.exists(sb.saver), "\(name): the store still points at the saver")
                        try expect(sb.exists(fx.paths.wallpaperSelectionBackup) && sb.exists(fx.paths.wallpaperStoreBackup),
                                   "\(name): the record of the previous saver is kept")
                        try expectEqual(try sb.bytes(), broken)
                        try expectEqual(fx.system.restarts, 1)
                        // The user chose another saver in System Settings (the format is still the new one).
                        if name == "version" { try StoreFixture.data().write(to: sb.store) } else { try futureOther.write(to: sb.store) }
                        let again = fx.service().performUninstall(removeLibrary: removeLibrary)
                        try expectEqual(again.first { $0.title == restoreTitle }?.outcome, .skipped("the screen saver was changed since"))
                        try expect(!sb.exists(sb.saver) && again.allSatisfy { !$0.isFailure }, "\(name): \(again)")
                    }
                }
            }
            // Not even a property list: nothing in it can point at the saver, so the uninstall finishes.
            try StoreSandbox.with("install-unreadable") { sb in
                let fx = InstallFixture(sb)
                try check(try fx.service().selectSaver())
                try Data("garbage".utf8).write(to: sb.store)
                let steps = fx.service().performUninstall(removeLibrary: false)
                try expectEqual(steps.first { $0.title == restoreTitle }?.outcome, .skipped("the screen saver was changed since"))
                try expect(!sb.exists(sb.saver) && steps.allSatisfy { !$0.isFailure }, "\(steps)")
            }
        },
    ] }
}

// MARK: - The real store (read-only)

extension SelfTests {
    /// Runs the model and the applier on a temp copy of this Mac's wallpaper store. The original is
    /// only read. Nothing about its contents is printed.
    fileprivate static var realStoreCopy: TestCase {
        TestCase(name: "wallpaper.real-store-copy") {
            guard let bytes = FileManager.default.contents(atPath: LiveWallpaperSystem.agentStoreURL.path) else {
                print("  (no wallpaper store on this Mac: covered by the generated fixtures only)")
                return
            }
            // The agent's model mirror decodes it and re-encodes it byte for byte.
            let index = try WallpaperStoreSchema.decode(bytes)
            try check(try WallpaperStoreSchema.encode(index) == bytes, "the schema mirror doesn't reproduce the real store's bytes")
            // Lossless through the document.
            let document = try WallpaperStoreDocument(data: bytes)
            try check(try PlistValue.parse(document.data()) == document.root, "document round trip lost something")
            try check(try WallpaperStoreSchema.encode(WallpaperStoreSchema.decode(document.data())) == bytes, "re-serialised store decodes differently")
            // LivePaper refuses to edit some layouts (a linked record, a missing Idle slot) and guides
            // the user instead (covered by the fixtures). A Mac whose wallpaper was never customised —
            // a CI runner — can have one. (The reason isn't printed: it can name display UUIDs.)
            do { try document.checkEditable() } catch WallpaperStoreError.unsupportedShape {
                print("  (skipped select/restore: this Mac's store has a layout LivePaper doesn't edit; decoding and the byte round trip were checked)")
                return
            }
            // Select, then restore, on a copy (with a fake agent that re-encodes like the real one).
            try StoreSandbox.with("real", store: bytes) { sb in
                let system = FakeWallpaperSystem(store: sb.store), clock = FakeClock()
                let before = try sb.document().selection(of: sb.module)
                let selected = try applier(sb, system, clock).select(sb.module, manifestURL: sb.manifest, rawBackupURL: sb.rawBackup)
                try expect(selected.outcome == .applied || before.isSelectedEverywhere)
                let during = try sb.document()
                try expect(during.selection(of: sb.module).isSelectedEverywhere, "not selected everywhere")
                try expect(desktopSlots(during) == desktopSlots(document), "a Desktop slot changed")
                let unchanged = idleSlots(document).filter { !selected.changed.contains($0.key) }
                try expect(unchanged.allSatisfy { idleSlots(during)[$0.key] == $0.value }, "an unplanned Idle slot changed")
                _ = try applier(sb, system, clock).restore(sb.module, manifestURL: sb.manifest)
                let after = try sb.document()
                try expect(idleSlots(after) == idleSlots(document), "Idle slots aren't back to their originals")
                try expect(after.root == document.root, "the store isn't otherwise identical")
                try check(try sb.bytes() == bytes, "the agent's re-encoded store differs from the original bytes")
            }
            try expect(FileManager.default.contents(atPath: LiveWallpaperSystem.agentStoreURL.path) != nil)
        }
    }
}
