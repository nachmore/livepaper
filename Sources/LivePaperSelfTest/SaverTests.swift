// Self tests owned by WS-saver.
//
// The saver is not a SwiftPM target (it is a swiftc-built MH_BUNDLE), so its pure logic lives in
// Saver/SaverLogic.swift and is compiled into this target through the symlink
// Sources/LivePaperSelfTest/SaverLogic.swift. Everything AppKit/WebKit-bound is exercised by the
// off-screen dev host instead (scripts/dev/saverhost-lp.swift, see Saver/README.md).
import Foundation
import LivePaperCore

private func entry(_ id: String, _ kind: LPPlaylistEntry.Kind = .web, file: String? = nil) -> LPPlaylistEntry {
    LPPlaylistEntry(id: id, name: id.capitalized, kind: kind, file: file ?? (kind == .web ? "\(id).html" : "\(id).mov"), clock: .top)
}

/// A Playlist directory with the given entries' files present (plus anything in `extraFiles`).
private func playlistDir(_ playlist: LPPlaylist, extraFiles: [String] = [], skipFiles: Set<String> = []) throws -> URL {
    let dir = try tempDir("saver-playlist")
    try playlist.write(to: dir)
    for e in playlist.scenes where !skipFiles.contains(e.file) && SaverPlaylistLoader.isPlainFileName(e.file) {
        try Data("x".utf8).write(to: dir.appendingPathComponent(e.file))
    }
    for f in extraFiles { try Data("x".utf8).write(to: dir.appendingPathComponent(f)) }
    return dir
}

private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

/// One display's view reduced to the bookkeeping LivePaperSaverView does against the shared session
/// store, with the same SaverLogic calls: begin() plans and builds the deck, then shows step 0;
/// show() → rememberShown() (at the given time); willstop → recordEnded. Tests run several of these
/// against one store.
private struct SimDisplay {
    let ids: [String]
    let planned: (session: SaverSession, record: SaverSessionRecord, joined: Bool)
    let deck: SaverDeck
    private(set) var record: SaverSessionRecord

    init(ids: [String], mode: LPPlaylistMode = .shuffle, at now: Date, store: SaverSessionStore) {
        self.ids = ids
        planned = SaverSessionPlanner.plan(now: now, stored: store.load())
        deck = SaverDeck(ids: ids, mode: mode, session: planned.session)
        record = planned.record
        show(step: 0, at: now, store: store)
    }

    var joined: Bool { planned.joined }
    func scene(atStep step: Int) -> String { ids[deck.entryIndex(atStep: step)] }

    mutating func show(step: Int, at now: Date, store: SaverSessionStore) { show(id: scene(atStep: step), at: now, store: store) }
    mutating func show(id: String, at now: Date, store: SaverSessionStore) {
        let update = SaverSessionPlanner.recordShown(id, own: record, stored: store.load(), now: now)
        record.noteShown(id)
        if let update { store.save(update) }
    }

    func stop(at date: Date, store: SaverSessionStore) {
        if let ended = SaverSessionPlanner.recordEnded(at: date.timeIntervalSince1970, own: record, stored: store.load()) {
            store.save(ended)
        }
    }
}

private var repoRoot: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

extension SelfTests {
    static var saver: [TestCase] { [
        // MARK: playlist
        TestCase(name: "saver.playlist.load") {
            let p = LPPlaylist(generation: 7, mode: .sequence, cycleMinutes: 2, scenes: [entry("aurora"), entry("beach", .video)])
            let dir = try playlistDir(p)
            defer { remove(dir) }
            let content = SaverPlaylistLoader.load(from: dir)
            try expectEqual(content.entries.map(\.id), ["aurora", "beach"])
            try expectEqual(content.playlist?.generation, 7)
            try expect(content.problems.isEmpty, "\(content.problems)")
        },
        TestCase(name: "saver.playlist.missing-or-corrupt") {
            let empty = try tempDir("saver-empty")
            defer { remove(empty) }
            let missing = SaverPlaylistLoader.load(from: empty)
            try expect(missing.isEmpty && missing.playlist == nil && missing.problems.count == 1)
            try Data("{not json".utf8).write(to: empty.appendingPathComponent(LPPlaylist.fileName))
            let corrupt = SaverPlaylistLoader.load(from: empty)
            try expect(corrupt.isEmpty && corrupt.problems.first?.contains("unreadable") == true, "\(corrupt.problems)")
        },
        TestCase(name: "saver.playlist.filters-unsafe-and-missing") {
            let p = LPPlaylist(scenes: [entry("ok"), entry("escape", file: "../../etc/passwd.html"), entry("hidden", file: ".x.html"),
                                        entry("wrong-ext", file: "wrong.mov"), entry("gone"), entry("ok", file: "dup.html"),
                                        entry("clip", .video, file: "clip.mp4")])
            let dir = try playlistDir(p, skipFiles: ["gone.html"])
            defer { remove(dir) }
            let content = SaverPlaylistLoader.load(from: dir)
            try expectEqual(content.entries.map(\.id), ["ok", "clip"])
            try expectEqual(content.problems.count, 5)
        },
        TestCase(name: "saver.playlist.newer-schema-still-plays") {
            let p = LPPlaylist(schema: LPPlaylist.currentSchema + 1, scenes: [entry("a")])
            let dir = try playlistDir(p)
            defer { remove(dir) }
            let content = SaverPlaylistLoader.load(from: dir)
            try expectEqual(content.entries.count, 1)
            try expect(content.problems.first?.contains("newer") == true)
        },

        // MARK: deck
        TestCase(name: "saver.deck.shuffle-deterministic-permutation") {
            let ids = (0..<7).map { "s\($0)" }
            let a = SaverDeck(ids: ids, mode: .shuffle, seed: 42, avoid: nil), b = SaverDeck(ids: ids, mode: .shuffle, seed: 42, avoid: nil)
            for round in 0..<4 {
                try expectEqual(a.shuffledRound(round), b.shuffledRound(round))
                try expectEqual(Set(a.shuffledRound(round)), Set(0..<7))
            }
            let c = SaverDeck(ids: ids, mode: .shuffle, seed: 43, avoid: nil)
            try expect((0..<4).contains { a.shuffledRound($0) != c.shuffledRound($0) }, "different seeds should differ")
        },
        TestCase(name: "saver.deck.shuffle-never-repeats") {
            for n in 2...6 {
                let ids = (0..<n).map { "s\($0)" }
                for seed in UInt64(0)..<200 {
                    let avoid = ids[Int(seed) % n]
                    let deck = SaverDeck(ids: ids, mode: .shuffle, seed: seed, avoid: avoid)
                    try expect(ids[deck.entryIndex(atStep: 0)] != avoid, "n=\(n) seed=\(seed) repeated the previous session's scene")
                    for step in 1..<(n * 4) {
                        try expect(deck.entryIndex(atStep: step) != deck.entryIndex(atStep: step - 1), "n=\(n) seed=\(seed) step=\(step)")
                    }
                }
            }
        },
        TestCase(name: "saver.deck.sequence-and-single") {
            let ids = ["a", "b", "c"]
            let seq = SaverDeck(ids: ids, mode: .sequence, seed: 1, avoid: "b")
            try expectEqual((0..<4).map { ids[seq.entryIndex(atStep: $0)] }, ["c", "a", "b", "c"])
            try expectEqual(SaverDeck(ids: ids, mode: .sequence, seed: 1, avoid: "gone").entryIndex(atStep: 0), 0)
            let single = SaverDeck(ids: ids, mode: .single, seed: 9, avoid: "a")
            try expect((0..<5).allSatisfy { single.entryIndex(atStep: $0) == 0 })
            try expectEqual(SaverDeck(ids: ["only"], mode: .shuffle, seed: 3, avoid: "only").entryIndex(atStep: 5), 0)
        },

        // MARK: sessions
        TestCase(name: "saver.session.displays-agree-and-next-session-avoids") {
            let store = SaverMemorySessionStore()
            let ids = ["aurora", "beach", "city"]
            let t0 = Date(timeIntervalSince1970: 1_800_000_010)
            let first = SimDisplay(ids: ids, at: t0, store: store)
            try expect(!first.joined)
            // A second display a few seconds later joins the same session and plays the same scenes.
            let second = SimDisplay(ids: ids, at: t0.addingTimeInterval(3), store: store)
            try expect(second.joined)
            try expectEqual(second.planned.session, first.planned.session)
            try expectEqual(second.deck, first.deck)
            // The next lock, minutes later, is a new session that avoids what was shown last.
            first.stop(at: t0.addingTimeInterval(300), store: store)
            second.stop(at: t0.addingTimeInterval(300), store: store)
            let next = SaverSessionPlanner.plan(now: t0.addingTimeInterval(600), stored: store.load())
            try expect(!next.joined)
            try expectEqual(next.session.avoid, first.scene(atStep: 0))
            try expect(next.session.epoch != first.planned.session.epoch)
        },
        TestCase(name: "saver.session.joined-display-builds-same-deck") {
            // The first display's begin() already recorded its scene before the second display plans;
            // the second must still build the same deck (it used to avoid that very scene).
            for mode in [LPPlaylistMode.shuffle, .sequence] {
                for n in [2, 3, 6, 13] {
                    let ids = (0..<n).map { "s\($0)" }
                    for k in 0..<50 {
                        let store = SaverMemorySessionStore()
                        var prior = SaverSessionRecord(epoch: 1, startedAt: 30, avoid: nil, lastShown: nil)
                        for i in 0..<(k % 4) { prior.noteShown(ids[(k + i) % n]) }
                        prior.endedAt = 40
                        store.save(prior)
                        let t0 = Date(timeIntervalSince1970: 1_800_000_000 + Double(k * 97))
                        let first = SimDisplay(ids: ids, mode: mode, at: t0, store: store)
                        let afterFirst = store.load()
                        let second = SimDisplay(ids: ids, mode: mode, at: t0.addingTimeInterval([0.2, 3, 8, 14][(k / 4) % 4]), store: store)
                        let label = "\(mode) n=\(n) k=\(k)"
                        try expect(second.joined, label)
                        try expect(second.planned.session == first.planned.session, label)
                        for step in 0..<(2 * n) {
                            try expect(second.scene(atStep: step) == first.scene(atStep: step), "\(label) step=\(step)")
                        }
                        try expect(store.load() == afterFirst, "\(label): joining display rewrote the record")
                    }
                }
            }
            // Only the session-start fields define the session: history and the end never change it.
            var record = SaverSessionPlanner.plan(now: Date(timeIntervalSince1970: 1_800_000_000),
                                                  stored: SaverSessionRecord(epoch: 1, startedAt: 30, avoid: nil, lastShown: "a")).record
            let session = record.session
            record.noteShown("b"); record.noteShown("c"); record.endedAt = 1_800_000_100
            try expectEqual(record.session, session)
        },
        TestCase(name: "saver.session.displays-keep-each-others-history") {
            let ids = (0..<8).map { "s\($0)" }
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            for stopOrder in [false, true] {
                // One session; display 2 skipped a failing scene, so the two showed different scenes.
                let store = SaverMemorySessionStore()
                var a = SimDisplay(ids: ids, at: t0, store: store)
                var b = SimDisplay(ids: ids, at: t0.addingTimeInterval(1), store: store)
                let x = a.scene(atStep: 1), w = ids.first { $0 != x && $0 != a.scene(atStep: 0) }!
                a.show(step: 1, at: t0.addingTimeInterval(60), store: store)
                b.show(id: w, at: t0.addingTimeInterval(61), store: store)
                if stopOrder { a.stop(at: t0.addingTimeInterval(200), store: store); b.stop(at: t0.addingTimeInterval(200), store: store) }
                else { b.stop(at: t0.addingTimeInterval(200), store: store); a.stop(at: t0.addingTimeInterval(200), store: store) }
                let ended = try unwrap(store.load())
                try expect(ended.endedAt != nil)
                try expect(ended.recent?.contains(x) == true && ended.recent?.contains(w) == true, "\(ended.recent ?? [])")

                // A display that starts late (60 s, or days later: a locked Mac whose displays slept
                // over a weekend, then docked) begins its own session. The first display changing scene
                // afterwards (waking, catching up) must not replace that newer session in the store —
                // however long after the first session it began — and whichever display handles
                // willstop last, the next lock still knows what both showed.
                let lead = SaverSessionPlanner.epochLength * Double(SaverSessionPlanner.maxEpochLead)
                for gap in [60, 3600, lead - 400, lead, lead + 3600, 3 * lead] {
                    let label = "stopOrder=\(stopOrder) late by \(gap) s"
                    let late = SaverMemorySessionStore()
                    let lateStart = t0.addingTimeInterval(gap)
                    var first = SimDisplay(ids: ids, at: t0, store: late)
                    let second = SimDisplay(ids: ids, at: lateStart, store: late)
                    try expect(!second.joined, label)
                    first.show(step: 1, at: lateStart.addingTimeInterval(5), store: late)
                    try expect(late.load()?.session == second.planned.session, "\(label): the first display replaced the newer session")
                    let third = SimDisplay(ids: ids, at: lateStart.addingTimeInterval(10), store: late)
                    try expect(third.joined && third.planned.session == second.planned.session && third.deck == second.deck,
                               "\(label): a display joins the newest session")
                    for display in stopOrder ? [first, second, third] : [third, second, first] {
                        display.stop(at: lateStart.addingTimeInterval(60), store: late)
                    }
                    let record = try unwrap(late.load())
                    let all = [first.scene(atStep: 0), first.scene(atStep: 1), second.scene(atStep: 0)]
                    try expect(record.endedAt != nil && record.session == second.planned.session
                               && all.allSatisfy { record.recent?.contains($0) == true }, "\(label): \(record)")
                    let next = SaverSessionPlanner.plan(now: lateStart.addingTimeInterval(70), stored: record)
                    try expect(!next.joined, label)
                    let avoided = SaverDeck(ids: ids, mode: .shuffle, session: next.session).startAvoidSet
                    try expect(Set(all).isSubset(of: avoided), "\(label): next lock avoids \(avoided), shown \(all)")
                }
            }
            // No stored record (the store lost it): willstop still saves this display's, ended.
            let own = SaverSessionPlanner.plan(now: t0, stored: nil).record
            try expect(SaverSessionPlanner.recordEnded(at: 5, own: own, stored: nil)?.endedAt == 5)
        },
        TestCase(name: "saver.session.epoch-boundary") {
            // Display 1 starts 1 s before an epoch boundary, display 2 starts 2 s after it.
            let boundary = 1_800_000_000.0 + SaverSessionPlanner.epochLength * 3
            let first = SaverSessionPlanner.plan(now: Date(timeIntervalSince1970: boundary - 1), stored: nil)
            let second = SaverSessionPlanner.plan(now: Date(timeIntervalSince1970: boundary + 2), stored: first.record)
            try expect(second.joined, "displays straddling an epoch boundary must still agree")
            try expectEqual(second.session.shuffleSeed, first.session.shuffleSeed)
            // Without the record (separate processes racing) they still agree within one epoch.
            let a = SaverSessionPlanner.plan(now: Date(timeIntervalSince1970: boundary + 1), stored: nil)
            let b = SaverSessionPlanner.plan(now: Date(timeIntervalSince1970: boundary + 20), stored: nil)
            try expectEqual(a.session, b.session)
            try expect(first.session.sceneSeed >= 1 && first.session.sceneSeed <= 100_000)
        },
        TestCase(name: "saver.session.ended-session-not-replayed") {
            // Lock, unlock after 10 s, lock again 15 s later: a NEW session with a different shuffle.
            let t0 = Date(timeIntervalSince1970: 1_800_000_015)
            var first = SaverSessionPlanner.plan(now: t0, stored: nil).record
            first.noteShown("a")
            first.endedAt = t0.addingTimeInterval(10).timeIntervalSince1970
            let again = SaverSessionPlanner.plan(now: t0.addingTimeInterval(15), stored: first)
            try expect(!again.joined, "an ended session must not be joined")
            try expect(again.session.epoch != first.epoch, "new shuffle seed")
            try expectEqual(again.session.recent, ["a"])
            // A second display starting while the session runs still joins it (and plays the same deck).
            let store = SaverMemorySessionStore()
            let ids = ["a", "b", "c", "d"]
            let running = SimDisplay(ids: ids, at: t0, store: store)
            let joining = SimDisplay(ids: ids, at: t0.addingTimeInterval(1), store: store)
            try expect(joining.joined && joining.deck == running.deck)
        },
        TestCase(name: "saver.session.implausible-stored-epoch-ignored") {
            // A damaged record (or a clock moved back by days) must not pin or overflow the epoch: this
            // used to trap on `stored.epoch + 1` at every start.
            let t = Date(timeIntervalSince1970: 1_800_000_000)
            let clockEpoch = Int(1_800_000_000 / SaverSessionPlanner.epochLength)
            for bad in [Int.max, Int.max - 1, clockEpoch + SaverSessionPlanner.maxEpochLead] {
                let stored = SaverSessionRecord(epoch: bad, startedAt: 0, avoid: nil, lastShown: "a", endedAt: 1)
                let planned = SaverSessionPlanner.plan(now: t, stored: stored)
                try expect(!planned.joined && planned.session.epoch == clockEpoch, "epoch \(bad) → \(planned.session.epoch)")
                try expectEqual(planned.record.startedAt, TimeInterval(clockEpoch) * SaverSessionPlanner.epochLength)
                try expectEqual(planned.session.avoid, "a")
            }
            // The new session replaces the damaged record, so a second display joins it.
            let store = SaverMemorySessionStore()
            store.save(SaverSessionRecord(epoch: .max, startedAt: 0, avoid: nil, lastShown: "a", endedAt: 1))
            let ids = ["a", "b", "c"]
            let a = SimDisplay(ids: ids, at: t, store: store)
            let b = SimDisplay(ids: ids, at: t.addingTimeInterval(2), store: store)
            try expect(b.joined && b.deck == a.deck)
            let damaged = SaverSessionRecord(epoch: .max, startedAt: 0, avoid: nil, lastShown: nil)
            let ancient = SaverSessionRecord(epoch: .min, startedAt: 0, avoid: nil, lastShown: nil)
            try expect(!SaverSessionPlanner.isSession(damaged, newerThan: ancient, at: t)
                       && !SaverSessionPlanner.isSession(ancient, newerThan: damaged, at: t))
            // Newer is bounded by the clock, not by the gap to the other session: any later epoch
            // short of `maxEpochLead` ahead of the clock is a newer session, one at or past it is not.
            let old = SaverSessionRecord(epoch: clockEpoch - 3 * SaverSessionPlanner.maxEpochLead, startedAt: 0, avoid: nil, lastShown: nil)
            for (epoch, newer) in [(clockEpoch, true), (clockEpoch + SaverSessionPlanner.maxEpochLead - 1, true),
                                   (clockEpoch + SaverSessionPlanner.maxEpochLead, false), (old.epoch, false)] {
                let record = SaverSessionRecord(epoch: epoch, startedAt: 0, avoid: nil, lastShown: nil)
                try expect(SaverSessionPlanner.isSession(record, newerThan: old, at: t) == newer, "epoch \(epoch)")
            }
            // A running session stored ahead of the clock (written before the clock was moved back a
            // day or more) is replaced by the new session's first scene, so the next display joins it.
            for bad in [clockEpoch + SaverSessionPlanner.maxEpochLead, clockEpoch + 2 * SaverSessionPlanner.maxEpochLead] {
                let ahead = SaverMemorySessionStore()
                ahead.save(SaverSessionRecord(epoch: bad, startedAt: TimeInterval(bad) * SaverSessionPlanner.epochLength,
                                              avoid: nil, lastShown: "a"))
                let a = SimDisplay(ids: ids, at: t, store: ahead)
                try expect(!a.joined && a.planned.session.epoch == clockEpoch, "epoch \(bad) → \(a.planned.session.epoch)")
                try expect(ahead.load()?.session == a.planned.session, "epoch \(bad) kept in the store")
                let b = SimDisplay(ids: ids, at: t.addingTimeInterval(2), store: ahead)
                try expect(b.joined && b.deck == a.deck, "epoch \(bad)")
            }
            // An epoch a little ahead (quick re-locks ran it past the clock) is still bumped past.
            let ahead = SaverSessionRecord(epoch: clockEpoch + 20, startedAt: 1_799_999_990, avoid: nil, lastShown: "a", endedAt: 1_799_999_995)
            let planned = SaverSessionPlanner.plan(now: t, stored: ahead)
            try expect(planned.session.epoch == clockEpoch + 21 && planned.record.startedAt == t.timeIntervalSince1970, "\(planned.record)")
        },
        TestCase(name: "saver.deck.avoids-recent-half") {
            let ids = (0..<13).map { "s\($0)" }
            let recent = ["s3", "s7", "s1", "s9", "s0", "s5", "s11"]   // newest first
            for seed in UInt64(1)...500 {
                let deck = SaverDeck(ids: ids, mode: .shuffle, seed: seed, avoid: "s3", recent: recent)
                let first = ids[deck.entryIndex(atStep: 0)]
                try expect(!recent.prefix(6).contains(first), "seed \(seed) started with recent \(first)")
            }
        },
        TestCase(name: "saver.deck.relock-walk-no-repeats") {
            // Simulate 40 quick lock/unlock cycles: no scene repeats within the newest half.
            let ids = (0..<13).map { "s\($0)" }
            let store = SaverMemorySessionStore()
            var shown: [String] = []
            var t = Date(timeIntervalSince1970: 1_800_000_000)
            for _ in 0..<40 {
                let display = SimDisplay(ids: ids, at: t, store: store)
                try expect(!display.joined)
                display.stop(at: t.addingTimeInterval(5), store: store)
                let id = display.scene(atStep: 0)
                if let last = shown.suffix(6).firstIndex(of: id) { throw TestFailure(description: "\(id) repeated after \(shown.count - last) locks: \(shown)") }
                shown.append(id)
                t = t.addingTimeInterval(12)
            }
        },
        TestCase(name: "saver.session.record-recent-cap") {
            var r = SaverSessionRecord(epoch: 1, startedAt: 30, avoid: nil, lastShown: nil)
            for i in 0..<20 { r.noteShown("s\(i % 15)") }
            try expectEqual(r.recent?.count, SaverSessionRecord.recentCapacity)
            try expectEqual(r.recent?.first, "s4"); try expectEqual(r.lastShown, "s4")
            let decoded = try JSONDecoder().decode(SaverSessionRecord.self, from: Data(#"{"epoch":5,"startedAt":150,"avoid":"a","lastShown":"b"}"#.utf8))
            try expect(decoded.recent == nil && decoded.startRecent == nil && decoded.endedAt == nil, "old records still decode")
            // A running session recorded by an older build is joined with what it avoided (`avoid`).
            let joined = SaverSessionPlanner.plan(now: Date(timeIntervalSince1970: 160), stored: decoded)
            try expect(joined.joined && joined.session.avoid == "a" && joined.session.recent.isEmpty)
            try expectEqual(SaverDeck(ids: ["a", "b"], mode: .shuffle, session: joined.session).startAvoidSet, ["a"])
        },
        TestCase(name: "saver.session.file-store") {
            let dir = try tempDir("saver-store")
            defer { remove(dir) }
            let url = dir.appendingPathComponent("state.json")
            let store = SaverFileSessionStore(url: url)
            try expect(store.load() == nil)
            let r = SaverSessionRecord(epoch: 5, startedAt: 150, avoid: "a", lastShown: "b", recent: ["b", "a"], startRecent: ["a"],
                                       endedAt: 170)
            store.save(r)
            try expectEqual(SaverFileSessionStore(url: url).load(), r)
        },

        // MARK: schedule
        TestCase(name: "saver.schedule.steps") {
            let start = Date(timeIntervalSince1970: 1_000_000)
            let s = SaverSchedule(startedAt: start, cycleMinutes: 5, deckCount: 3, mode: .shuffle, cycles: true)
            try expectEqual(s.step(at: start.addingTimeInterval(10)), 0)
            try expectEqual(s.step(at: start.addingTimeInterval(301)), 1)
            try expectEqual(s.step(at: start.addingTimeInterval(-50)), 0)
            try expectEqual(s.nextChange(after: start.addingTimeInterval(301)), start.addingTimeInterval(600))
            for never in [SaverSchedule(startedAt: start, cycleMinutes: 0, deckCount: 3, mode: .shuffle, cycles: true),
                          SaverSchedule(startedAt: start, cycleMinutes: 5, deckCount: 1, mode: .shuffle, cycles: true),
                          SaverSchedule(startedAt: start, cycleMinutes: 5, deckCount: 3, mode: .single, cycles: true),
                          SaverSchedule(startedAt: start, cycleMinutes: 5, deckCount: 3, mode: .shuffle, cycles: false)] {
                try expect(never.nextChange(after: start) == nil && never.step(at: start.addingTimeInterval(9999)) == 0)
            }
        },

        // MARK: recovery
        TestCase(name: "saver.recovery.backoff") {
            var policy = SaverRecoveryPolicy()
            let t = Date(timeIntervalSince1970: 0)
            try expectEqual(policy.recordFailure(at: t), .retry(after: 1, skipScene: false))
            try expectEqual(policy.recordFailure(at: t.addingTimeInterval(1)), .retry(after: 2, skipScene: true))
            try expectEqual(policy.recordFailure(at: t.addingTimeInterval(3)), .retry(after: 4, skipScene: true))
            try expectEqual(policy.recordFailure(at: t.addingTimeInterval(7)), .giveUp)
            // Old failures age out of the window.
            var later = SaverRecoveryPolicy()
            _ = later.recordFailure(at: t)
            try expectEqual(later.recordFailure(at: t.addingTimeInterval(SaverRecoveryPolicy.window + 1)), .retry(after: 1, skipScene: false))
        },

        // MARK: lock UI hand-off
        TestCase(name: "saver.lockui.events") {
            try expectEqual(SaverSystemEvent(notificationName: LPNotification.lockUIShowing), .lockUIShown)
            try expectEqual(SaverSystemEvent(notificationName: LPNotification.lockUIShown), .lockUIShown)
            try expectEqual(SaverSystemEvent(notificationName: LPNotification.lockUIHidden), .lockUIHidden)
            try expectEqual(SaverSystemEvent.distributedNames.count, Set(SaverSystemEvent.distributedNames).count)
            try expectEqual(SaverSystemEvent(notificationName: LPNotification.saverWillStop), .willStop)
            try expectEqual(SaverSystemEvent(notificationName: LPNotification.screenLocked), .screenLocked)
            try expectEqual(SaverSystemEvent(notificationName: LPNotification.screenUnlocked), .screenUnlocked)
            try expectEqual(SaverSystemEvent(notificationName: "NSWorkspaceScreensDidSleepNotification"), .screensDidSleep)
            try expect(SaverSystemEvent(notificationName: "com.example.other") == nil)
            for name in SaverSystemEvent.distributedNames { try expect(SaverSystemEvent(notificationName: name) != nil, name) }
            var state = SaverLockUIState()
            try expect(state.apply(.lockUIShown) && state.isShowing)
            try expect(!state.apply(.lockUIShown) && state.isShowing, "a repeated Shown is not a change")
            try expect(!state.apply(.screensDidSleep) && state.isShowing)
            try expect(state.apply(.lockUIHidden) && !state.isShowing)
            state.apply(.lockUIShown)
            try expect(state.apply(.screenUnlocked) && !state.isShowing, "unlock clears a missed IsHidden")
        },

        // MARK: prewarm / run gate
        TestCase(name: "saver.gate.prewarmed-instance-waits-for-lock") {
            // WallpaperAgent's hidden prewarm instance: started, session unlocked → nothing loads.
            var gate = SaverRunGate(preview: false, sessionLocked: false)
            gate.animating = true
            try expect(!gate.mayLoad && !gate.shouldRun, "a non-preview instance must not load before a saver is up")
            gate.apply(.screenLocked)
            try expect(gate.mayLoad && gate.shouldRun && gate.openedBy == "locked")
            gate.apply(.screensDidSleep)
            try expect(gate.active && !gate.shouldRun && !gate.mayLoad && !gate.shouldRelease,
                       "kept but paused while the displays sleep; nothing new loads in the dark")
            gate.apply(.screensDidWake)
            try expect(gate.shouldRun)
            gate.apply(.screenUnlocked)
            try expect(!gate.shouldRun && gate.shouldRelease, "pause as soon as the user is back at the desktop, then release")
            gate.apply(.lockUIShown)
            try expect(!gate.sessionLocked, "lock UI events don't change the lock state")
        },
        TestCase(name: "saver.gate.explicit-start-renders-while-unlocked") {
            // A saver started while the session stays unlocked (password delay or "Never", hot
            // corner, System Settings' full-screen preview) used to stay black until a lock.
            try expect(SaverSystemEvent.distributedNames.contains(LPNotification.saverDidStart), "observes didstart")
            try expect(SaverSystemEvent.distributedNames.contains(LPNotification.saverDidStop), "observes didstop")
            var gate = SaverRunGate(preview: false, sessionLocked: false)
            gate.animating = true
            if let start = SaverSystemEvent(notificationName: LPNotification.saverDidStart) { gate.apply(start) }
            try expect(gate.mayLoad && gate.shouldRun, "loginwindow's didstart opens the gate while unlocked")
            // The password delay passes: still running, now also locked.
            gate.apply(.screenLocked)
            try expect(gate.shouldRun)
            gate.apply(.screenUnlocked)
            try expect(!gate.shouldRun && !gate.saverStarted, "an unlock ends the run")
            // didstop and willstop end it too; a later didstart opens it again.
            gate.apply(.saverDidStart)
            try expect(gate.shouldRun)
            gate.apply(.saverDidStop)
            try expect(!gate.shouldRun)
            gate.apply(.saverDidStart)
            gate.apply(.willStop)
            try expect(!gate.shouldRun)
            // didstart may arrive before startAnimation (presented prewarm): remembered.
            var early = SaverRunGate(preview: false, sessionLocked: false)
            early.apply(.saverDidStart)
            try expect(!early.shouldRun, "nothing before startAnimation")
            early.animating = true
            try expect(early.shouldRun && early.openedBy == "didstart")
            // A running ScreenSaverEngine (LivePaper's lock) opens it as well.
            var engine = SaverRunGate(preview: false, sessionLocked: false)
            engine.animating = true
            engine.apply(.engineLaunched)
            try expect(engine.shouldRun && engine.openedBy == "engine")
            engine.apply(.engineTerminated)
            try expect(!engine.shouldRun)
            // Names the relay forwards for NSWorkspace's app notifications.
            try expectEqual(SaverSystemEvent(notificationName: SaverSystemEvent.engineLaunchedName), .engineLaunched)
            try expectEqual(SaverSystemEvent(notificationName: SaverSystemEvent.previewHostDeactivatedName), .previewHostDeactivated)
            try expectEqual(SaverSystemEvent(notificationName: SaverSystemEvent.windowChangedName), .windowChanged)
        },
        TestCase(name: "saver.gate.no-load-while-displays-asleep") {
            // Lid-close and display-sleep locks happen with the displays off: a prewarmed instance
            // must not load its scene in the dark (it waits for wake).
            var gate = SaverRunGate(preview: false, sessionLocked: false)
            gate.animating = true
            gate.apply(.screensDidSleep)
            gate.apply(.screenLocked)
            try expect(!gate.mayLoad && !gate.shouldRun, "nothing loads while the displays sleep")
            gate.apply(.screensDidWake)
            try expect(gate.mayLoad && gate.shouldRun)
        },
        TestCase(name: "saver.gate.release") {
            var gate = SaverRunGate(preview: false, sessionLocked: true)
            try expect(gate.shouldRelease, "not started: nothing may stay loaded")
            gate.animating = true
            try expect(!gate.shouldRelease)
            gate.animating = false
            try expect(gate.shouldRelease, "stopAnimation releases")
            gate.animating = true
            gate.exiting = true
            try expect(!gate.shouldRelease, "about to exit: keep the last frame for the fade-out")
            var preview = SaverRunGate(preview: true, sessionLocked: true)
            try expect(!preview.shouldRelease, "previews only pause")
            preview.animating = true
            try expect(!preview.shouldRelease)
        },
        TestCase(name: "saver.gate.policy") {
            // sessionLockOpens off: a direct lock (no saver started) keeps the prewarm dark.
            var strict = SaverRunGate(preview: false, sessionLocked: false, policy: SaverGatePolicy(sessionLockOpens: false))
            strict.animating = true
            strict.apply(.screenLocked)
            try expect(!strict.shouldRun && strict.waitingFor?.contains("didstart") == true, strict.summary)
            strict.apply(.saverDidStart)
            try expect(strict.shouldRun)
            var noDidStart = SaverRunGate(preview: false, sessionLocked: false, policy: SaverGatePolicy(didStartOpens: false))
            noDidStart.animating = true
            noDidStart.apply(.saverDidStart)
            try expect(!noDidStart.shouldRun)
            var noEngine = SaverRunGate(preview: false, sessionLocked: false, policy: SaverGatePolicy(engineOpens: false))
            noEngine.animating = true
            noEngine.apply(.engineLaunched)
            try expect(!noEngine.shouldRun)
            // The shipped policy: any of the three opens the gate.
            try expectEqual(SaverGatePolicy.standard, SaverGatePolicy(sessionLockOpens: true, didStartOpens: true, engineOpens: true, previewFPS: 15))
            try expect(SaverRunGate(preview: false, sessionLocked: false).summary.contains("wait for"))
        },
        TestCase(name: "saver.gate.start-latch") {
            // A view created after didstart in the same host process still knows a run is on.
            var latch = SaverStartLatch()
            latch.apply(.saverDidStart)
            try expect(latch.started)
            latch.apply(.screenLocked)
            try expect(latch.started)
            for end in [SaverSystemEvent.saverDidStop, .willStop, .screenUnlocked] {
                latch.apply(.saverDidStart)
                latch.apply(end)
                try expect(!latch.started, end.rawValue)
            }
        },
        TestCase(name: "saver.gate.previews-pause") {
            // System Settings previews: render at once, but not while locked, asleep, hidden or
            // while System Settings isn't in front.
            var preview = SaverRunGate(preview: true, sessionLocked: false)
            preview.animating = true
            try expect(preview.shouldRun)
            preview.apply(.screenLocked)
            try expect(!preview.shouldRun, "a preview pauses while the Mac is locked")
            preview.apply(.screenUnlocked)
            try expect(preview.shouldRun)
            preview.apply(.screensDidSleep)
            try expect(!preview.shouldRun)
            preview.apply(.screensDidWake)
            preview.apply(.previewHostDeactivated)
            try expect(!preview.shouldRun && preview.waitingFor?.contains("System Settings") == true, preview.summary)
            preview.apply(.previewHostActivated)
            try expect(preview.shouldRun)
            preview.windowVisible = false
            try expect(!preview.shouldRun)
            preview.windowVisible = true
            // didstart / willstop / the engine don't concern previews.
            preview.apply(.saverDidStart)
            preview.apply(.willStop)
            try expect(preview.shouldRun)
            // Which app counts as the preview host.
            try expect(SaverPreviewHost.isActive(frontmostBundleIdentifier: "com.apple.systempreferences"))
            try expect(!SaverPreviewHost.isActive(frontmostBundleIdentifier: "com.apple.Terminal"))
            try expect(SaverPreviewHost.isActive(frontmostBundleIdentifier: nil), "unknown: don't pause on a guess")
        },
        TestCase(name: "saver.gate.window-visibility") {
            var v = SaverWindowVisibility()
            // A host that always reports "occluded" (macOS 26's saver host) or "not ordered in".
            try expect(v.isVisible(orderedIn: false, miniaturized: false, occlusionVisible: false), "never trusted, never paused")
            try expect(!v.isVisible(orderedIn: true, miniaturized: true, occlusionVisible: false), "miniaturised")
            try expect(v.isVisible(orderedIn: true, miniaturized: false, occlusionVisible: false))
            try expect(!v.isVisible(orderedIn: false, miniaturized: false, occlusionVisible: false), "ordered out after being in")
            try expect(v.isVisible(orderedIn: true, miniaturized: false, occlusionVisible: true))
            try expect(!v.isVisible(orderedIn: true, miniaturized: false, occlusionVisible: false), "occluded after being visible")
        },
        TestCase(name: "saver.gate.preview-and-stop") {
            var preview = SaverRunGate(preview: true, sessionLocked: false)
            try expect(!preview.mayLoad, "nothing before startAnimation")
            preview.animating = true
            try expect(preview.mayLoad && preview.shouldRun, "previews render immediately")
            var locked = SaverRunGate(preview: false, sessionLocked: true)
            locked.animating = true
            try expect(locked.shouldRun, "already locked at start")
            locked.exiting = true
            try expect(!locked.mayLoad && !locked.shouldRun, "nothing new after willstop")
            locked.exiting = false
            locked.animating = false
            try expect(!locked.shouldRun, "stopAnimation pauses")
        },

        // MARK: clock
        TestCase(name: "saver.clock.layout-matches-runtime") {
            // Runtime: time = clamp(min(w*.11, h*.15), 40, 210); date = max(13, time*.2); top rect at y = h*.07.
            guard let top = SaverClockLayout.make(width: 1512, height: 982, position: .top) else { throw TestFailure(description: "nil layout") }
            try expect(abs(top.timeSize - 147.3) < 0.01, "\(top.timeSize)")
            try expect(abs(top.dateSize - 29.46) < 0.01, "\(top.dateSize)")
            try expect(abs(top.rect.minY - 68.74) < 0.01 && top.alignment == .center && top.anchorX == 756)
            try expect(abs(top.dateBaseline - (68.74 + 29.46 * 1.1)) < 0.01)
            try expect(abs(top.timeBaseline - (top.dateBaseline + 147.3 * 0.98)) < 0.01)
            try expectEqual(SaverClockLayout.make(width: 300, height: 188, position: .top)?.timeSize, 40)
            try expectEqual(SaverClockLayout.make(width: 5120, height: 1440, position: .top)?.timeSize, 210)
            let bl = SaverClockLayout.make(width: 1512, height: 982, position: .bottomLeft)
            try expect(bl?.alignment == .left && abs((bl?.anchorX ?? 0) - 58.92) < 0.01)
            let br = SaverClockLayout.make(width: 1512, height: 982, position: .bottomRight)
            try expect(br?.alignment == .right && abs((br?.anchorX ?? 0) - (1512 - 58.92)) < 0.01)
            try expect(SaverClockLayout.make(width: 1512, height: 982, position: .none) == nil)
        },
        TestCase(name: "saver.clock.format") {
            try expectEqual(SaverClockFormat.removingDayPeriod(from: "h:mm\u{202F}a"), "h:mm")
            try expectEqual(SaverClockFormat.removingDayPeriod(from: "a h:mm"), "h:mm")
            try expectEqual(SaverClockFormat.removingDayPeriod(from: "h:mm 'at' B"), "h:mm 'at'")
            try expectEqual(SaverClockFormat.timePattern(locale: Locale(identifier: "en_US")), "h:mm")
            try expectEqual(SaverClockFormat.timePattern(locale: Locale(identifier: "en_GB")), "HH:mm")
            for id in ["ko_KR", "zh_CN", "ja_JP", "de_DE", "ar_EG"] {
                let p = SaverClockFormat.timePattern(locale: Locale(identifier: id))
                try expect(!p.contains("a") && p.contains("mm"), "\(id): \(p)")
            }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US"); f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = SaverClockFormat.datePattern(locale: f.locale)
            try expectEqual(f.string(from: Date(timeIntervalSince1970: 1_794_528_000)), "Friday, November 13")
            try expectEqual(SaverClockFormat.nextMinuteBoundary(after: Date(timeIntervalSince1970: 120)).timeIntervalSince1970, 180)
            try expectEqual(SaverClockFormat.nextMinuteBoundary(after: Date(timeIntervalSince1970: 179.9)).timeIntervalSince1970, 180)
        },

        // MARK: web bridge & power
        TestCase(name: "saver.web.config-and-js") {
            let cfg = SaverWebConfig(showClock: true, clockPosition: .bottomLeft, profile: .init(fps: 30, scale: 0.75), seed: 12,
                                     power: SaverPowerState(onBattery: true, lowPowerMode: false))
            try expect(cfg.userScript.hasPrefix("window.LIVEPAPER_CONFIG = {") && cfg.userScript.hasSuffix("};"))
            let decoded = try JSONSerialization.jsonObject(with: Data(cfg.json.utf8)) as? [String: Any]
            try expectEqual(decoded?["clockPosition"] as? String, "bottom-left")
            try expectEqual(decoded?["power"] as? String, "battery")
            try expectEqual(decoded?["fps"] as? Int, 30)
            try expectEqual(decoded?["seed"] as? Int, 12)
            // Only keys the runtime understands (runtime.js TYPES).
            try expectEqual(Set(decoded?.keys.map { $0 } ?? []), ["clock", "clockPosition", "fps", "scale", "seed", "power", "lowPower"])
            try expectEqual(SaverJS.lockUI(true),
                            "(function(h){if(h&&typeof h.lockUI==='function'){h.lockUI(true);}})(window.LivePaper&&window.LivePaper.host);")
            try expect(SaverJS.pause.contains("h.pause()") && SaverJS.resume.contains("h.resume()"))
            let update = SaverPowerUpdate(power: SaverPowerState(onBattery: false, lowPowerMode: true), profile: .init(fps: 30, scale: 0.75))
            try expect(SaverJS.power(update).contains("h.power({\"fps\":30,\"lowPower\":true,\"power\":\"ac\",\"scale\":0.75})"),
                       SaverJS.power(update))
        },
        TestCase(name: "saver.performance.resolve") {
            let battery = SaverPowerState(onBattery: true, lowPowerMode: false), ac = SaverPowerState(onBattery: false, lowPowerMode: false)
            try expectEqual(SaverPerformance.resolve(.automatic, power: battery, preview: false), .init(fps: 30, scale: 0.75))
            try expectEqual(SaverPerformance.resolve(.automatic, power: ac, preview: false), .init(fps: 60, scale: 1))
            try expectEqual(SaverPerformance.resolve(.automatic, power: SaverPowerState(onBattery: false, lowPowerMode: true), preview: false),
                            .init(fps: 30, scale: 0.75))
            try expectEqual(SaverPerformance.resolve(.best, power: battery, preview: true), .init(fps: 15, scale: 1))
            try expectEqual(SaverPerformance.resolve(.automatic, power: ac, preview: true), .init(fps: 15, scale: 1))
        },

        // MARK: options sheet
        TestCase(name: "saver.summary") {
            // Only the URL is used; nothing is read or written.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("livepaper-selftest-saver-summary")
            let none = SaverSummary.make(content: .empty(directory: dir), version: "0.1.0")
            try expect(none.scenes == nil && none.playlist.contains("No scenes"))
            let scenes = (1...6).map { entry("scene-\($0)") }
            let content = SaverContent(playlist: LPPlaylist(generation: 3, mode: .shuffle, cycleMinutes: 5, showClock: false, scenes: scenes),
                                       entries: scenes, problems: [], directory: dir)
            let s = SaverSummary.make(content: content, version: "0.1.0")
            try expectEqual(s.playlist, "6 scenes · shuffled · new scene every 5 minutes")
            try expectEqual(s.clock, "Hidden")
            try expect(s.scenes?.hasSuffix("and 2 more") == true, s.scenes ?? "")
            try expect(s.footnote.contains("publish 3"))
        },

        // MARK: bundle contract
        TestCase(name: "saver.bundle.info-plist") {
            let url = repoRoot.appendingPathComponent("Saver/Info.plist")
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
            try expectEqual(plist?["CFBundleIdentifier"] as? String, LPPaths.saverBundleID)
            try expectEqual(plist?["NSPrincipalClass"] as? String, "LivePaperSaverView")
            try expectEqual(plist?["CFBundleName"] as? String, "LivePaper")
            try expectEqual(plist?["CFBundlePackageType"] as? String, "BNDL")
            try expectEqual(plist?["LSMinimumSystemVersion"] as? String, "14.0")
            // The principal class must keep its @objc name (module-independent lookup).
            let view = try String(contentsOf: repoRoot.appendingPathComponent("Saver/LivePaperSaverView.swift"), encoding: .utf8)
            try expect(view.contains("@objc(LivePaperSaverView)"))
            for png in ["thumbnail.png", "thumbnail@2x.png"] {
                try expect(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Saver/Resources/\(png)").path), png)
            }
        },
    ] }
}
