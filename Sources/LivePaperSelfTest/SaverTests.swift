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

private var repoRoot: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

extension SelfTests {
    static var saver: [TestCase] { [
        // MARK: playlist
        TestCase(name: "saver.playlist.load") {
            let p = LPPlaylist(generation: 7, mode: .sequence, cycleMinutes: 2, scenes: [entry("aurora"), entry("beach", .video)])
            let content = SaverPlaylistLoader.load(from: try playlistDir(p))
            try expectEqual(content.entries.map(\.id), ["aurora", "beach"])
            try expectEqual(content.playlist?.generation, 7)
            try expect(content.problems.isEmpty, "\(content.problems)")
        },
        TestCase(name: "saver.playlist.missing-or-corrupt") {
            let empty = try tempDir("saver-empty")
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
            let content = SaverPlaylistLoader.load(from: try playlistDir(p, skipFiles: ["gone.html"]))
            try expectEqual(content.entries.map(\.id), ["ok", "clip"])
            try expectEqual(content.problems.count, 5)
        },
        TestCase(name: "saver.playlist.newer-schema-still-plays") {
            let p = LPPlaylist(schema: LPPlaylist.currentSchema + 1, scenes: [entry("a")])
            let content = SaverPlaylistLoader.load(from: try playlistDir(p))
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
            let t0 = Date(timeIntervalSince1970: 1_800_000_010)
            let first = SaverSessionPlanner.plan(now: t0, stored: store.load())
            try expect(!first.joined)
            var record = first.record
            record.lastShown = "aurora"
            store.save(record)
            // A second display a few seconds later joins the same session.
            let second = SaverSessionPlanner.plan(now: t0.addingTimeInterval(3), stored: store.load())
            try expect(second.joined)
            try expectEqual(second.session, first.session)
            // The next lock, minutes later, is a new session that avoids what was shown last.
            let next = SaverSessionPlanner.plan(now: t0.addingTimeInterval(600), stored: store.load())
            try expect(!next.joined)
            try expectEqual(next.session.avoid, "aurora")
            try expect(next.session.epoch != first.session.epoch)
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
        TestCase(name: "saver.session.file-store") {
            let url = try tempDir("saver-store").appendingPathComponent("state.json")
            let store = SaverFileSessionStore(url: url)
            try expect(store.load() == nil)
            let r = SaverSessionRecord(epoch: 5, startedAt: 150, avoid: "a", lastShown: "b")
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
            try expectEqual(SaverSystemEvent(notificationName: LPNotification.lockUIShowing), .lockUIShowing)
            try expectEqual(SaverSystemEvent(notificationName: LPNotification.saverWillStop), .willStop)
            try expectEqual(SaverSystemEvent(notificationName: LPNotification.screenLocked), .screenLocked)
            try expectEqual(SaverSystemEvent(notificationName: LPNotification.screenUnlocked), .screenUnlocked)
            try expectEqual(SaverSystemEvent(notificationName: "NSWorkspaceScreensDidSleepNotification"), .screensDidSleep)
            try expect(SaverSystemEvent(notificationName: "com.example.other") == nil)
            for name in SaverSystemEvent.distributedNames { try expect(SaverSystemEvent(notificationName: name) != nil, name) }
            var state = SaverLockUIState()
            try expect(state.apply(.lockUIShowing) && state.isShowing)
            try expect(!state.apply(.lockUIShown) && state.isShowing, "Shown after Showing is not a change")
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
            try expect(!gate.mayLoad && !gate.shouldRun, "a non-preview instance must not load before the session locks")
            gate.apply(.screenLocked)
            try expect(gate.mayLoad && gate.shouldRun)
            gate.apply(.screensDidSleep)
            try expect(gate.mayLoad && !gate.shouldRun, "loaded but paused while the displays sleep")
            gate.apply(.screensDidWake)
            try expect(gate.shouldRun)
            gate.apply(.screenUnlocked)
            try expect(!gate.shouldRun, "pause as soon as the user is back at the desktop")
            gate.apply(.lockUIShowing)
            try expect(!gate.sessionLocked, "lock UI events don't change the lock state")
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
            try expectEqual(SaverPerformance.resolve(.best, power: battery, preview: true), .init(fps: 30, scale: 1))
        },

        // MARK: options sheet
        TestCase(name: "saver.summary") {
            let dir = try tempDir("saver-summary")
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
