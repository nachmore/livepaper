// Self tests for the saver's multiple-display logic (Saver/SaverLogic.swift): the deck with a spread
// ("Different on each display"), per-display history, the display plan of every mode, spanning
// geometry, display-only scenes, the web config's span keys and the Options summary.
import Foundation
import LivePaperCore

/// SaverDeck exactly as it was before display modes: the spread-1 deck must stay byte-for-byte this.
private struct LegacyDeck {
    let ids: [String]
    let mode: LPPlaylistMode
    let seed: UInt64
    let avoid: String?
    var recent: [String] = []

    var startAvoidSet: Set<String> {
        guard ids.count > 1 else { return [] }
        var list = recent
        if let avoid, !list.contains(avoid) { list.insert(avoid, at: 0) }
        return Set(list.filter { ids.contains($0) }.prefix(max(1, ids.count / 2)))
    }

    func entryIndex(atStep step: Int) -> Int {
        let n = ids.count, s = max(0, step)
        guard n > 1 else { return 0 }
        switch mode {
        case .single:
            return 0
        case .sequence:
            let start = avoid.flatMap { ids.firstIndex(of: $0) }.map { ($0 + 1) % n } ?? 0
            return (start + s) % n
        case .shuffle:
            return shuffledRound(s / n)[s % n]
        }
    }

    func shuffledRound(_ round: Int) -> [Int] {
        let n = ids.count
        guard n > 1 else { return Array(0..<n) }
        var previous = avoid.flatMap { ids.firstIndex(of: $0) }
        var order: [Int] = []
        for r in 0...max(0, round) {
            var rng = SaverRandom(seed: seed &+ UInt64(r) &* 0xD1B5_4A32_D192_ED03)
            order = Array(0..<n)
            for i in stride(from: n - 1, to: 0, by: -1) { order.swapAt(i, rng.next(below: i + 1)) }
            if r == 0 {
                let avoidSet = startAvoidSet
                if let k = order.firstIndex(where: { !avoidSet.contains(ids[$0]) }), k > 0 { order.swapAt(0, k) }
            } else if let previous, order[0] == previous {
                order.swapAt(0, 1)
            }
            previous = order[n - 1]
        }
        return order
    }
}

private func ids(_ n: Int) -> [String] { (0..<n).map { "s\($0)" } }

/// A deterministic reordering of `list` (tests must not depend on the system RNG).
private func scrambled(_ list: [String], _ seed: Int) -> [String] {
    var rng = SaverRandom(seed: UInt64(seed) &+ 99), out = list
    for i in stride(from: out.count - 1, to: 0, by: -1) { out.swapAt(i, rng.next(below: i + 1)) }
    return out
}

private func webEntry(_ id: String, span: Bool? = nil) -> LPPlaylistEntry {
    LPPlaylistEntry(id: id, name: id, kind: .web, file: "\(id).html", clock: .top, span: span)
}

private func content(_ entries: [LPPlaylistEntry], extra: [LPPlaylistEntry] = [], displays: LPDisplaySettings = .standard,
                     mode: LPPlaylistMode = .shuffle) -> SaverContent {
    SaverContent(playlist: LPPlaylist(generation: 1, mode: mode, scenes: entries, displays: displays, displayScenes: extra),
                 entries: entries, problems: [], directory: URL(fileURLWithPath: "/nonexistent"), displayEntries: extra)
}

private let keyA = "00000000-0000-4000-8000-0000000000A1"
private let keyB = "00000000-0000-4000-8000-0000000000A2"
private let keyC = "00000000-0000-4000-8000-0000000000A3"
private let keyD = "00000000-0000-4000-8000-0000000000A4"
private let keys = [keyA, keyB, keyC, keyD]

/// `d` displays side by side (keys A…D left to right); the first is the built-in one with the menu bar
/// unless `mainIndex` says otherwise.
private func row(_ d: Int, mainIndex: Int = 0) -> LPDisplayLayout {
    LPDisplayLayout((0..<d).map { i in
        LPDisplay(id: keys[i], name: "Display \(i + 1)", frame: LPRect(x: Double(i) * 1600, y: 0, width: 1600, height: 1000),
                  scale: 2, isBuiltin: i == mainIndex, isMenuBar: i == mainIndex)
    })
}

private let ac = SaverPowerState(onBattery: false, lowPowerMode: false)
private let battery = SaverPowerState(onBattery: true, lowPowerMode: false)
private let lowPower = SaverPowerState(onBattery: false, lowPowerMode: true)

/// One display of a simulated run against a shared store, doing what LivePaperSaverView does: plan
/// (joining another display's session), build the display plan and deck, show steps and record them.
private struct SimDisplayView {
    let key: String
    let planned: (session: SaverSession, record: SaverSessionRecord, joined: Bool)
    let displayPlan: SaverDisplayPlan
    let deck: SaverDeck
    let schedule: SaverSchedule
    let content: SaverContent
    private(set) var record: SaverSessionRecord
    private(set) var shown: [String] = []

    init(key: String, layout: LPDisplayLayout, settings: LPDisplaySettings, content: SaverContent, mode: LPPlaylistMode,
         power: SaverPowerState = ac, at now: Date, store: SaverSessionStore, inProcess: SaverSimJoin? = nil) {
        self.key = key
        self.content = content
        if let join = inProcess?.session { planned = (join.session, join.record, true) } else {
            planned = SaverSessionPlanner.plan(now: now, stored: store.load())
        }
        displayPlan = SaverDisplayPlan.make(settings: settings, layout: layout, key: key, content: content, power: power, preview: false)
        deck = SaverDeck(ids: content.entries.map(\.id), mode: mode, session: planned.session, spread: displayPlan.spread,
                         previous: displayPlan.previous(for: planned.session))
        schedule = SaverSchedule(startedAt: planned.session.startedAt, cycleMinutes: 5, deckCount: deck.count, mode: mode, cycles: true)
        record = planned.record
        inProcess?.session = (planned.session, record)
    }

    var joined: Bool { planned.joined }

    func scene(atStep step: Int) -> String? {
        displayPlan.resolve(step: step, skipOffset: 0, deck: deck, content: content, session: planned.session, schedule: schedule)?.entry.id
    }

    mutating func show(step: Int, at now: Date, store: SaverSessionStore) {
        guard let id = scene(atStep: step) else { return }
        shown.append(id)
        guard displayPlan.recordsHistory else { return }
        let update = SaverSessionPlanner.recordShown(id, own: record, stored: store.load(), now: now, display: key,
                                                     updatesLastShown: displayPlan.isLead)
        record.noteShown(id, display: key, updatesLastShown: displayPlan.isLead)
        if let update { store.save(update) }
    }

    func stop(at date: Date, store: SaverSessionStore) {
        if let ended = SaverSessionPlanner.recordEnded(at: date.timeIntervalSince1970, own: record, stored: store.load()) { store.save(ended) }
    }
}

/// The in-process join: the session of the view that started first in this host process.
private final class SaverSimJoin {
    var session: (session: SaverSession, record: SaverSessionRecord)?
}

/// Runs `sessions` locks of `d` displays in "Different", each `steps(i)` cycle steps long, and returns
/// what every display showed per session (session → display → scenes).
private func simulateDifferent(n: Int, d: Int, mode: LPPlaylistMode, sessions: Int, seed: UInt64,
                               steps: (Int) -> Int) -> [[[String]]] {
    let store = SaverMemorySessionStore()
    let layout = row(d)
    let c = content(ids(n).map { webEntry($0) }, mode: mode)
    let settings = LPDisplaySettings(mode: .different)
    var t = 1_800_000_000.0 + Double(seed % 1000) * 37
    var out: [[[String]]] = []
    for i in 0..<sessions {
        let join = SaverSimJoin()
        var views = (0..<d).map { k in
            SimDisplayView(key: keys[k], layout: layout, settings: settings, content: c, mode: mode, at: Date(timeIntervalSince1970: t),
                           store: store, inProcess: join)
        }
        let count = max(1, steps(i))
        for step in 0..<count {
            for k in views.indices { views[k].show(step: step, at: Date(timeIntervalSince1970: t + Double(step) * 300), store: store) }
        }
        let end = t + Double(count) * 300
        views.first?.stop(at: Date(timeIntervalSince1970: end), store: store)
        out.append(views.map(\.shown))
        // The next lock comes between 10 s and an hour later.
        t = end + 10 + Double((seed &* UInt64(i + 7)) % 3600)
    }
    return out
}

extension SelfTests {
    static var saverDisplays: [TestCase] { [
        // MARK: deck
        TestCase(name: "saver.deck.spread1MatchesLegacy") {
            for n in 1...8 {
                let list = ids(n)
                let avoids: [String?] = [nil, list.first, list.last, "gone"]
                let recents: [[String]] = [[], Array(list.reversed()), ["gone"] + list.prefix(2), Array(scrambled(list, n).prefix(n / 2 + 1))]
                for seed in 0..<200 {
                    let s = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(n)
                    for mode in LPPlaylistMode.allCases {
                        for avoid in avoids {
                            let recent = recents[seed % recents.count]
                            let legacy = LegacyDeck(ids: list, mode: mode, seed: s, avoid: avoid, recent: recent)
                            let deck = SaverDeck(ids: list, mode: mode, seed: s, avoid: avoid, recent: recent)
                            let spread1 = SaverDeck(ids: list, mode: mode, seed: s, avoid: avoid, recent: recent, spread: 1, previous: [list.first])
                            try expectEqual(deck.startAvoidSet, legacy.startAvoidSet)
                            for step in 0...(3 * n) {
                                let want = legacy.entryIndex(atStep: step)
                                if deck.entryIndex(atStep: step) != want || spread1.entryIndex(atStep: step) != want {
                                    throw TestFailure(description: "n=\(n) seed=\(seed) mode=\(mode) avoid=\(avoid ?? "-") step=\(step): " +
                                                      "\(deck.entryIndex(atStep: step)) != \(want)")
                                }
                            }
                        }
                    }
                }
            }
            // The session initialiser is unchanged too.
            let session = SaverSession(epoch: 59_999_123, startedAt: Date(), avoid: "s2", recent: ["s2", "s0"])
            let legacy = LegacyDeck(ids: ids(5), mode: .shuffle, seed: session.shuffleSeed, avoid: "s2", recent: ["s2", "s0"])
            let deck = SaverDeck(ids: ids(5), mode: .shuffle, session: session)
            try expectEqual((0..<15).map(deck.entryIndex(atStep:)), (0..<15).map(legacy.entryIndex(atStep:)))
        },
        TestCase(name: "saver.deck.differentDisplaysDiffer") {
            for d in 1...4 {
                for n in 1...8 {
                    let list = ids(n)
                    for seed in 0..<60 {
                        for mode in [LPPlaylistMode.shuffle, .sequence] {
                            let avoid = seed % 3 == 0 ? nil : list[seed % n]
                            let recent = Array(scrambled(list, seed).prefix(seed % (n + 1)))
                            let previous: [String?] = (0..<d).map { k in (seed + k) % 4 == 0 ? nil : list[(seed * 7 + k) % n] }
                            let deck = SaverDeck(ids: list, mode: mode, seed: UInt64(seed) &* 0x2545_F491_4F6C_DD1D, avoid: avoid,
                                                 recent: recent, spread: d, previous: previous)
                            for s in 0...(4 * n) {
                                let shown = (0..<d).map { deck.entryIndex(atStep: s + $0) }
                                if n >= d {
                                    try expect(Set(shown).count == d, "n=\(n) d=\(d) \(mode) seed=\(seed) step \(s): \(shown)")
                                } else {
                                    for k in 0..<(d - n) {
                                        try expect(shown[k] == shown[k + n], "n=\(n) d=\(d) \(mode) seed=\(seed) step \(s): \(shown)")
                                    }
                                }
                                // Each pass still plays every scene (shuffle) / in order (sequence).
                                if mode == .shuffle, s % n == 0 {
                                    try expectEqual(Set(deck.shuffledRound(s / n)), Set(0..<n))
                                }
                            }
                            // The first `d` positions avoid the start set.
                            if mode == .shuffle {
                                let avoidSet = deck.startAvoidSet
                                for k in 0..<min(d, n) {
                                    try expect(!avoidSet.contains(list[deck.entryIndex(atStep: k)]),
                                               "n=\(n) d=\(d) seed=\(seed): position \(k) in \(avoidSet)")
                                }
                            }
                        }
                    }
                }
            }
        },
        TestCase(name: "saver.deck.differentNoRepeatPerDisplay") {
            for d in 1...4 {
                for n in 2...8 {
                    for mode in [LPPlaylistMode.shuffle, .sequence] {
                        for seed: UInt64 in [1, 77, 4242] {
                            let runs = simulateDifferent(n: n, d: d, mode: mode, sessions: 30, seed: seed) { i in 1 + Int((seed &+ UInt64(i * 13)) % UInt64(2 * n)) }
                            for i in 1..<runs.count {
                                let before = runs[i - 1], now = runs[i]
                                let onScreenAtEnd = Set(before.compactMap(\.last))
                                for k in 0..<d {
                                    guard let first = now[k].first, let last = before[k].last else {
                                        throw TestFailure(description: "display \(k) showed nothing")
                                    }
                                    try expect(first != last, "n=\(n) d=\(d) \(mode) seed=\(seed) session \(i): display \(k) repeats \(first)")
                                    if n >= 2 * d {
                                        try expect(!onScreenAtEnd.contains(first),
                                                   "n=\(n) d=\(d) \(mode) seed=\(seed) session \(i): display \(k) starts with \(first), on screen at the end (\(onScreenAtEnd))")
                                    }
                                }
                                if n >= d {
                                    try expectEqual(Set(now.compactMap(\.first)).count, d)
                                }
                            }
                        }
                    }
                }
            }
        },

        // MARK: sessions
        TestCase(name: "saver.session.joinedDisplayBuildsSameDifferentDeck") {
            let store = SaverMemorySessionStore()
            let layout = row(3)
            let c = content(ids(6).map { webEntry($0) })
            let settings = LPDisplaySettings(mode: .different)
            // A previous session left per-display history behind.
            var old = SaverSessionPlanner.plan(now: Date(timeIntervalSince1970: 1_800_000_000), stored: nil).record
            for (k, id) in ["s0", "s1", "s2"].enumerated() { old.noteShown(id, display: keys[k], updatesLastShown: k == 2) }
            old.endedAt = 1_800_000_100
            store.save(old)
            let t0 = Date(timeIntervalSince1970: 1_800_000_500)
            var a = SimDisplayView(key: keyA, layout: layout, settings: settings, content: c, mode: .shuffle, at: t0, store: store)
            a.show(step: 0, at: t0, store: store)
            // Through the store (another host process) and in-process.
            let b = SimDisplayView(key: keyB, layout: layout, settings: settings, content: c, mode: .shuffle,
                                   at: t0.addingTimeInterval(0.1), store: store)
            try expect(b.joined && !a.joined)
            try expectEqual(b.deck, a.deck)
            try expectEqual(a.deck.previous, ["s0", "s1", "s2"])
            try expectEqual(b.deck.previous, a.deck.previous)
            try expectEqual(b.planned.session, a.planned.session)
            let join = SaverSimJoin()
            join.session = (a.planned.session, a.record)
            let c3 = SimDisplayView(key: keyC, layout: layout, settings: settings, content: c, mode: .shuffle,
                                    at: t0.addingTimeInterval(400), store: store, inProcess: join)
            try expectEqual(c3.deck, a.deck)
            for step in 0..<12 {
                let shown = [a, b, c3].map { $0.scene(atStep: step) }
                try expectEqual(Set(shown).count, 3)
                try expectEqual(shown[1], a.deck.ids[a.deck.entryIndex(atStep: step + 1)])
            }
        },
        TestCase(name: "saver.session.shownOnRecordedAndFrozen") {
            var r = SaverSessionPlanner.plan(now: Date(timeIntervalSince1970: 1_800_000_000), stored: nil).record
            try expectEqual(r.shownOn, nil)
            r.noteShown("x", display: keyA)
            r.noteShown("y", display: keyB, updatesLastShown: false)
            try expectEqual(r.shownOn, [keyA: "x", keyB: "y"])
            try expectEqual(r.lastShown, "x")
            try expectEqual(r.recent, ["y", "x"])
            try expectEqual(r.session.shownOn, [:])   // frozen at the start: history doesn't change the session
            // The next session starts from it and freezes it.
            r.endedAt = 1_800_000_100
            let next = SaverSessionPlanner.plan(now: Date(timeIntervalSince1970: 1_800_000_500), stored: r)
            try expect(!next.joined)
            try expectEqual(next.record.startShownOn, [keyA: "x", keyB: "y"])
            try expectEqual(next.session.shownOn, [keyA: "x", keyB: "y"])
            var during = next.record
            during.noteShown("z", display: keyA)
            try expectEqual(during.session, next.session)
            try expectEqual(during.shownOn?[keyA], "z")
            // Capped at 16 displays; the display being recorded always stays.
            var many = r
            for i in 0..<20 { many.noteShown("s\(i)", display: String(format: "K%02d", i)) }
            try expectEqual(many.shownOn?.count, SaverSessionRecord.shownOnCapacity)
            try expectEqual(many.shownOn?["K19"], "s19")
            try expectEqual(many.shownOn?["K00"], nil)
            many.noteShown("t", display: "A0")
            try expectEqual(many.shownOn?["A0"], "t")
            try expectEqual(many.shownOn?.count, SaverSessionRecord.shownOnCapacity)
            // A record from an older build decodes; an old reader ignores the new fields.
            let oldJSON = #"{"epoch": 60000000, "startedAt": 1800000000, "lastShown": "a", "recent": ["a"], "startRecent": []}"#
            let decoded = try JSONDecoder().decode(SaverSessionRecord.self, from: Data(oldJSON.utf8))
            try expectEqual(decoded.shownOn, nil); try expectEqual(decoded.session.shownOn, [:])
            struct OldRecord: Codable { var epoch: Int; var startedAt: TimeInterval; var lastShown: String?; var recent: [String]? }
            let old = try JSONDecoder().decode(OldRecord.self, from: JSONEncoder().encode(during))
            try expectEqual(old.lastShown, during.lastShown)
            // Recording with a display reports changes to shownOn even when lastShown is the same.
            let own = next.record
            let first = SaverSessionPlanner.recordShown("q", own: own, stored: own, now: Date(timeIntervalSince1970: 1_800_000_501), display: keyA)
            try expectEqual(first?.shownOn?[keyA], "q")
            let again = SaverSessionPlanner.recordShown("q", own: first!, stored: first, now: Date(timeIntervalSince1970: 1_800_000_502), display: keyA)
            try expect(again == nil, "unchanged record → nothing to save")
            let other = SaverSessionPlanner.recordShown("q", own: first!, stored: first, now: Date(timeIntervalSince1970: 1_800_000_502), display: keyB)
            try expectEqual(other?.shownOn?[keyB], "q")
            // Without a display: today's guard.
            try expect(SaverSessionPlanner.recordShown("q", own: first!, stored: first, now: Date(timeIntervalSince1970: 1_800_000_503)) == nil)
        },
        TestCase(name: "saver.session.leadWritesLastShown") {
            // Different, sequence: the next session continues after the LAST display's scene.
            let runs = simulateDifferent(n: 8, d: 3, mode: .sequence, sessions: 4, seed: 5) { _ in 2 }
            for i in 1..<runs.count {
                let leadLast = runs[i - 1][2].last!
                let next = runs[i][0].first!
                try expectEqual(Int(next.dropFirst())!, (Int(leadLast.dropFirst())! + 1) % 8)
            }
            // Battery + off: only the main display shows anything, so it is the lead.
            let layout = row(3, mainIndex: 1)
            let settings = LPDisplaySettings(mode: .different, onBattery: .off)
            let c = content(ids(5).map { webEntry($0) })
            let plans = keys.prefix(3).map { SaverDisplayPlan.make(settings: settings, layout: layout, key: $0, content: c, power: battery, preview: false) }
            try expectEqual(plans.map(\.isLead), [false, true, false])
            try expectEqual(plans.map(\.liveness), [.off, .live, .off])
            try expectEqual(plans.map(\.recordsHistory), [false, true, false])
            let onAC = keys.prefix(3).map { SaverDisplayPlan.make(settings: settings, layout: layout, key: $0, content: c, power: ac, preview: false) }
            try expectEqual(onAC.map(\.isLead), [false, false, true])
            // Same: every display writes lastShown (they show the same scene).
            let same = keys.prefix(3).map { SaverDisplayPlan.make(settings: .standard, layout: layout, key: $0, content: c, power: ac, preview: false) }
            try expectEqual(same.map(\.isLead), [true, true, true])
        },

        // MARK: display plan
        TestCase(name: "saver.displays.plan.modes") {
            let c = content(ids(4).map { webEntry($0, span: true) })
            for d in 1...4 {
                let layout = row(d, mainIndex: d - 1)
                for mode in LPDisplayMode.allCases {
                    for battery in LPBatteryDisplays.allCases {
                        for power in [ac, SaverPowerState(onBattery: true, lowPowerMode: false), lowPower] {
                            let settings = LPDisplaySettings(mode: mode, assignments: [keyA: "s3"], onBattery: battery)
                            let saving = power.prefersBatterySaver
                            let effective: LPDisplayMode = d < 2 && (mode == .different || mode == .span) ? .same : mode
                            var lead = -1
                            for k in 0..<d {
                                let p = SaverDisplayPlan.make(settings: settings, layout: layout, key: keys[k], content: c, power: power, preview: false)
                                let label = "d=\(d) \(mode) \(battery) battery=\(saving) k=\(k)"
                                try expect(p.mode == effective, label)
                                try expect(p.index == k, label)
                                try expect(p.isMain == (k == d - 1), label)
                                let live: SaverDisplayLiveness = k != d - 1 && saving ? SaverDisplayLiveness(battery) : .live
                                try expect(p.liveness == live, "\(label): \(p.liveness)")
                                try expect(p.spread == (effective == .different ? d : 1), label)
                                switch effective {
                                case .different: try expect(p.source == .deck(offset: k), label)
                                case .choose: try expect(p.source == (k == 0 ? .assigned("s3") : .deck(offset: 0)), label)
                                case .same, .span: try expect(p.source == .deck(offset: 0), label)
                                }
                                try expect(p.spanAllowed == (effective == .span && !(saving && battery == .off)), label)
                                if p.isLead { lead = k }
                                if effective != .different { try expect(p.isLead, label) }
                            }
                            if effective == .different {
                                let expected = saving && battery == .off ? d - 1 : d - 1
                                try expect(lead == expected, "lead \(lead)")
                            }
                        }
                    }
                }
            }
            // The lead with the main display on the left and the others black: the main one.
            let leftMain = row(3, mainIndex: 0)
            let off = LPDisplaySettings(mode: .different, onBattery: .off)
            try expectEqual(keys.prefix(3).map { SaverDisplayPlan.make(settings: off, layout: leftMain, key: $0, content: c, power: battery, preview: false).isLead },
                            [true, false, false])
            // Previews, unknown displays and a missing key play as before: same, live.
            let layout = row(3)
            let settings = LPDisplaySettings(mode: .different, onBattery: .off)
            for p in [SaverDisplayPlan.make(settings: settings, layout: layout, key: keyB, content: c, power: battery, preview: true),
                      SaverDisplayPlan.make(settings: settings, layout: layout, key: "FFFFFFFF-0000-4000-8000-000000000000", content: c, power: battery, preview: false),
                      SaverDisplayPlan.make(settings: settings, layout: layout, key: nil, content: c, power: battery, preview: false),
                      SaverDisplayPlan.make(settings: settings, layout: LPDisplayLayout([]), key: keyA, content: c, power: battery, preview: false)] {
                try expectEqual(p.mode, .same); try expectEqual(p.liveness, .live); try expectEqual(p.source, .deck(offset: 0))
                try expect(p.isLead && p.isMain && !p.spanAllowed && p.spread == 1)
            }
            // The key's case doesn't matter.
            try expectEqual(SaverDisplayPlan.make(settings: settings, layout: layout, key: keyC.lowercased(), content: c, power: ac, preview: false).index, 2)
            try expectEqual(SaverDisplayPlan.make(settings: settings, layout: layout, key: keyC, content: c, power: ac, preview: false).previous(
                for: SaverSession(epoch: 1, startedAt: Date(), avoid: nil, shownOn: [keyA: "s1", keyC: "s0"])), ["s1", nil, "s0"])
            try expect(SaverDisplayPlan.make(settings: .standard, layout: layout, key: keyC, content: c, power: ac, preview: false).previous(
                for: SaverSession(epoch: 1, startedAt: Date(), avoid: nil, shownOn: [keyA: "s1"])).isEmpty)
        },
        TestCase(name: "saver.displays.plan.chooseAssignments") {
            let deck = ids(3).map { webEntry($0) }
            let extra = [webEntry("extra")]
            let c = content(deck, extra: extra)
            let layout = row(4)
            let settings = LPDisplaySettings(mode: .choose, assignments: [keyA: "s2", keyB.lowercased(): "extra", keyC: "missing"])
            let session = SaverSession(epoch: 7, startedAt: Date(timeIntervalSince1970: 1_800_000_000), avoid: nil)
            let d = SaverDeck(ids: deck.map(\.id), mode: .shuffle, session: session)
            let schedule = SaverSchedule(startedAt: session.startedAt, cycleMinutes: 5, deckCount: 3, mode: .shuffle, cycles: true)
            func plan(_ key: String) -> SaverDisplayPlan {
                SaverDisplayPlan.make(settings: settings, layout: layout, key: key, content: c, power: ac, preview: false)
            }
            try expectEqual(plan(keyA).source, .assigned("s2"))          // a deck scene
            try expectEqual(plan(keyB).source, .assigned("extra"))       // a display-only scene (key case ignored)
            try expectEqual(plan(keyC).source, .deck(offset: 0))         // missing scene → the playlist
            try expectEqual(plan(keyD).source, .deck(offset: 0))         // no assignment → the playlist
            try expect(!plan(keyA).recordsHistory && !plan(keyB).recordsHistory, "assigned displays write no history")
            try expect(plan(keyC).recordsHistory && plan(keyD).recordsHistory)
            for step in 0..<9 {
                try expectEqual(plan(keyA).resolve(step: step, skipOffset: 0, deck: d, content: c, session: session, schedule: schedule)?.entry.id, "s2")
                try expectEqual(plan(keyB).resolve(step: step, skipOffset: 0, deck: d, content: c, session: session, schedule: schedule)?.entry.id, "extra")
                let playlist = deck[d.entryIndex(atStep: step)].id
                try expectEqual(plan(keyD).resolve(step: step, skipOffset: 0, deck: d, content: c, session: session, schedule: schedule)?.entry.id, playlist)
                // After failures an assigned display falls back to the playlist (skip 1 → step + 0).
                try expectEqual(plan(keyB).resolve(step: step, skipOffset: 1, deck: d, content: c, session: session, schedule: schedule)?.entry.id, playlist)
                try expectEqual(plan(keyB).resolve(step: step, skipOffset: 2, deck: d, content: c, session: session, schedule: schedule)?.entry.id,
                                deck[d.entryIndex(atStep: step + 1)].id)
            }
            // An assigned scene that isn't playable (dropped by the loader) → the playlist.
            let unplayable = content(deck, extra: [])
            try expectEqual(SaverDisplayPlan.make(settings: settings, layout: layout, key: keyB, content: unplayable, power: ac, preview: false).source,
                            .deck(offset: 0))
            // Choose works with a single display too.
            try expectEqual(SaverDisplayPlan.make(settings: settings, layout: row(1), key: keyA, content: c, power: ac, preview: false).source,
                            .assigned("s2"))
            // Assigned displays still follow the battery setting.
            let batteryPlan = SaverDisplayPlan.make(settings: LPDisplaySettings(mode: .choose, assignments: [keyB: "extra"], onBattery: .still),
                                                    layout: layout, key: keyB, content: c, power: battery, preview: false)
            try expectEqual(batteryPlan.liveness, .still)
            try expectEqual(batteryPlan.source, .assigned("extra"))
        },
        TestCase(name: "saver.displays.plan.spanPerScene") {
            let entries = [webEntry("pure", span: true), webEntry("stateful", span: false), webEntry("old", span: nil),
                           LPPlaylistEntry(id: "clip", name: "Clip", kind: .video, file: "clip.mov", clock: .bottomLeft, span: true)]
            let c = content(entries, mode: .sequence)
            // Arrangement B of the span check: a laptop (main) bottom-aligned left of a bigger display.
            let layout = LPDisplayLayout([LPDisplay(id: keyA, frame: LPRect(x: 0, y: 458, width: 1512, height: 982), isBuiltin: true),
                                          LPDisplay(id: keyB, frame: LPRect(x: 1512, y: 0, width: 2560, height: 1440), scale: 1, isMenuBar: true)])
            let session = SaverSession(epoch: 7, startedAt: Date(timeIntervalSince1970: 1_800_000_000), avoid: nil)
            let deck = SaverDeck(ids: entries.map(\.id), mode: .sequence, session: session)
            let schedule = SaverSchedule(startedAt: session.startedAt, cycleMinutes: 5, deckCount: 4, mode: .sequence, cycles: true)
            func resolved(_ key: String, _ step: Int, onBattery: LPBatteryDisplays = .live, power: SaverPowerState = ac) -> SaverResolvedScene? {
                SaverDisplayPlan.make(settings: LPDisplaySettings(mode: .span, onBattery: onBattery), layout: layout, key: key, content: c,
                                      power: power, preview: false)
                    .resolve(step: step, skipOffset: 0, deck: deck, content: c, session: session, schedule: schedule)
            }
            let a0 = resolved(keyA, 0), b0 = resolved(keyB, 0)
            try expectEqual(a0?.entry.id, "pure"); try expectEqual(b0?.entry.id, "pure")
            try expectEqual(a0?.span, SaverSpan(canvasWidth: 4072, canvasHeight: 1440, viewport: LPRect(x: 0, y: 458, width: 1512, height: 982),
                                                clockViewport: LPRect(x: 0, y: 458, width: 1512, height: 982), timeOrigin: session.startedAt, isMain: true))
            try expectEqual(b0?.span?.viewport, LPRect(x: 1512, y: 0, width: 2560, height: 1440))
            try expectEqual(b0?.span?.clockViewport, LPRect(x: 0, y: 458, width: 1512, height: 982))
            try expectEqual(b0?.span?.isMain, false)
            // Scenes that can't span play on every display, like Same.
            try expectEqual(resolved(keyB, 1)?.entry.id, "stateful"); try expect(resolved(keyB, 1)?.span == nil)
            try expectEqual(resolved(keyB, 2)?.entry.id, "old"); try expect(resolved(keyB, 2)?.span == nil)
            // Every display shares the step's time origin.
            try expectEqual(resolved(keyB, 3)?.span?.timeOrigin, session.startedAt.addingTimeInterval(900))
            try expectEqual(resolved(keyA, 3)?.span?.timeOrigin, resolved(keyB, 3)?.span?.timeOrigin)
            // On battery with the others black: the main display shows the whole scene.
            try expect(resolved(keyA, 0, onBattery: .off, power: battery)?.span == nil)
            try expect(resolved(keyA, 0, onBattery: .still, power: battery)?.span != nil)
            try expect(resolved(keyA, 0, onBattery: .off, power: ac)?.span != nil)
            // Span clock rect: placed in the main display's viewport, in this display's coordinates.
            let clockA = SaverSpanGeometry.clockRect(span: a0!.span!, position: .top)
            let plain = SaverClockLayout.make(width: 1512, height: 982, position: .top)!.rect
            try expectEqual(clockA, plain)
            let clockB = SaverSpanGeometry.clockRect(span: b0!.span!, position: .top)
            try expectEqual(clockB, SaverRect(x: plain.x - 1512, y: plain.y + 458, width: plain.width, height: plain.height))
            try expect(SaverSpanGeometry.clockRect(span: a0!.span!, position: .none) == nil)
        },
        TestCase(name: "saver.span.videoLayerFrame") {
            let span = SaverSpan(canvasWidth: 4072, canvasHeight: 1440, viewport: LPRect(x: 0, y: 458, width: 1512, height: 982),
                                 clockViewport: LPRect(x: 0, y: 458, width: 1512, height: 982), timeOrigin: Date(), isMain: true)
            // Bottom-left origin: the canvas's bottom edge lines up with the laptop's (bottom-aligned).
            try expectEqual(SaverSpanGeometry.layerFrame(span: span, viewHeight: 982), SaverRect(x: 0, y: 0, width: 4072, height: 1440))
            var right = span
            right.viewport = LPRect(x: 1512, y: 0, width: 2560, height: 1440)
            try expectEqual(SaverSpanGeometry.layerFrame(span: right, viewHeight: 1440), SaverRect(x: -1512, y: 0, width: 4072, height: 1440))
            // Stacked: the lower display sees the canvas's bottom part (the layer extends above it).
            let stacked = SaverSpan(canvasWidth: 1920, canvasHeight: 2062, viewport: LPRect(x: 204, y: 1080, width: 1512, height: 982),
                                    clockViewport: LPRect(x: 0, y: 0, width: 1920, height: 1080), timeOrigin: Date(), isMain: false)
            try expectEqual(SaverSpanGeometry.layerFrame(span: stacked, viewHeight: 982), SaverRect(x: -204, y: 0, width: 1920, height: 2062))
            var upper = stacked
            upper.viewport = LPRect(x: 0, y: 0, width: 1920, height: 1080)
            try expectEqual(SaverSpanGeometry.layerFrame(span: upper, viewHeight: 1080), SaverRect(x: 0, y: -982, width: 1920, height: 2062))
        },

        // MARK: playlist
        TestCase(name: "saver.playlist.displayScenesValidated") {
            let dir = try tempDir("saver-display-scenes")
            defer { try? FileManager.default.removeItem(at: dir) }
            let p = LPPlaylist(generation: 2, scenes: [webEntry("a"), webEntry("b")], displays: LPDisplaySettings(mode: .choose, assignments: [keyA: "x"]),
                               displayScenes: [webEntry("x"), webEntry("a"), webEntry("missing"),
                                               LPPlaylistEntry(id: "bad", name: "Bad", kind: .web, file: "../escape.html", clock: .top),
                                               webEntry("x")])
            try p.write(to: dir)
            for f in ["a.html", "b.html", "x.html", "escape.html"] { try Data("x".utf8).write(to: dir.appendingPathComponent(f)) }
            let loaded = SaverPlaylistLoader.load(from: dir)
            try expectEqual(loaded.entries.map(\.id), ["a", "b"])
            try expectEqual(loaded.displayEntries.map(\.id), ["x"])
            try expectEqual(loaded.entry(id: "x")?.file, "x.html")
            try expectEqual(loaded.entry(id: "a")?.id, "a")
            try expect(loaded.entry(id: "missing") == nil)
            try expectEqual(loaded.problems.filter { $0.hasPrefix("display scene") }.count, 4)
            try expectEqual(loaded.playlist?.displays.assignments, [keyA: "x"])
        },

        // MARK: web bridge, events, summary
        TestCase(name: "saver.web.configSpanKeys") {
            let base = SaverWebConfig(showClock: true, clockPosition: .top, profile: .init(fps: 60, scale: 1), seed: 3, power: ac)
            try expectEqual(base.json, #"{"clock":true,"clockPosition":"top","fps":60,"lowPower":false,"power":"ac","scale":1,"seed":3}"#)
            try expectEqual(SaverWebConfig(showClock: true, clockPosition: .top, profile: .init(fps: 60, scale: 1), seed: 3, power: ac, span: nil, paused: false).json,
                            base.json)
            let span = SaverSpan(canvasWidth: 4072, canvasHeight: 1440, viewport: LPRect(x: 1512, y: 0, width: 2560, height: 1440),
                                 clockViewport: LPRect(x: 0, y: 458, width: 1512, height: 982),
                                 timeOrigin: Date(timeIntervalSince1970: 1_800_000_000.25), isMain: false)
            let cfg = SaverWebConfig(showClock: true, clockPosition: .top, profile: .init(fps: 30, scale: 0.75), seed: 3, power: battery,
                                     span: span, paused: true)
            let obj = try JSONSerialization.jsonObject(with: Data(cfg.json.utf8)) as? [String: Any] ?? [:]
            try expectEqual(obj["spanW"] as? Double, 4072); try expectEqual(obj["spanH"] as? Double, 1440)
            try expectEqual(obj["spanX"] as? Double, 1512); try expectEqual(obj["spanY"] as? Double, 0)
            try expectEqual(obj["spanClockX"] as? Double, 0); try expectEqual(obj["spanClockY"] as? Double, 458)
            try expectEqual(obj["spanClockW"] as? Double, 1512); try expectEqual(obj["spanClockH"] as? Double, 982)
            try expectEqual(obj["timeOrigin"] as? Double, 1_800_000_000_250)
            try expectEqual(obj["paused"] as? Bool, true)
            // Every key is one the runtime understands (runtime.js TYPES).
            let runtime = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Runtime/runtime.js"), encoding: .utf8)
            let typesBlock = runtime.components(separatedBy: "var TYPES = {").dropFirst().first?.components(separatedBy: "};").first ?? ""
            for key in obj.keys { try expect(typesBlock.contains("\(key): '"), "runtime.js TYPES lacks \(key)") }
        },
        TestCase(name: "saver.events.screensChanged") {
            try expectEqual(SaverSystemEvent(notificationName: SaverSystemEvent.screensChangedName), .screensChanged)
            try expectEqual(SaverSystemEvent.screensChangedName, "LivePaperScreensChanged")
            var gate = SaverRunGate(preview: false, sessionLocked: true)
            gate.animating = true
            let before = gate
            gate.apply(.screensChanged)
            try expectEqual(gate, before)
            var latch = SaverStartLatch()
            latch.apply(.saverDidStart); latch.apply(.screensChanged)
            try expect(latch.started)
            try expect(!SaverSystemEvent.distributedNames.contains(SaverSystemEvent.screensChangedName))
        },
        TestCase(name: "saver.summary.displays") {
            let dir = URL(fileURLWithPath: "/nonexistent")
            let scenes = [webEntry("a"), webEntry("b")]
            func summary(_ d: LPDisplaySettings) -> SaverSummary {
                SaverSummary.make(content: SaverContent(playlist: LPPlaylist(generation: 1, scenes: scenes, displays: d), entries: scenes,
                                                        problems: [], directory: dir), version: "1")
            }
            try expect(summary(.standard).displays == nil)
            try expectEqual(summary(LPDisplaySettings(mode: .different, onBattery: .still)).displays,
                            "Different on each display · on battery, other displays show a still")
            try expectEqual(summary(LPDisplaySettings(mode: .span)).displays, "Spans all displays")
            try expectEqual(summary(LPDisplaySettings(mode: .choose, assignments: [keyA: "a", keyB: "b"])).displays, "Chosen per display (2 displays assigned)")
            try expectEqual(summary(LPDisplaySettings(onBattery: .off)).displays, "Same on every display · on battery, other displays are black")
            // Everything else is as before.
            try expectEqual(summary(LPDisplaySettings(mode: .span)).playlist, summary(.standard).playlist)
        },
    ] }
}

