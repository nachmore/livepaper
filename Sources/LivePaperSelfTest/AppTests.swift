// Self tests owned by WS-app.
//
// The app's testable logic is compiled into this target through the symlinks in
// Sources/LivePaperSelfTest/AppLogic/ (they point at Foundation/Observation-only files in
// Sources/LivePaperApp/{Logic,Model,Mocks}); the SwiftUI views are not part of it. AppModel tests
// run against the mock services with zero delays, in temporary directories, and drive the main run
// loop so MainActor tasks (event streams, banners) make progress. Nothing here touches the user's
// real state or launches a GUI process.
import CoreGraphics
import Foundation
import LivePaperCore
import os

extension SelfTests {
    static var app: [TestCase] { appLogic + appModel + appWatch }

    // MARK: - Pure logic

    static var appLogic: [TestCase] { [
        TestCase(name: "app.banners.keep-pending-decisions") {
            try MainActor.assumeIsolated {
                // Opening many packages at once: the warning that needs a decision outlives the
                // "Imported" banners that follow it; the newest banner is always shown.
                let center = BannerCenter()
                center.post(.warning, "\u{201C}Lake\u{201D} is already in your library", message: "lake.lpscene is a different version of it.",
                            actions: [.init(title: "Replace with This Version") {}, .init(title: "Import as a Copy") {}])
                for n in 1...6 { center.post(.success, "Imported \u{201C}Scene \(n)\u{201D}") }
                try expectEqual(center.banners.count, BannerCenter.maxVisible)
                try expectEqual(center.banners.first?.style, .warning)
                try expectEqual(center.banners.last?.title, "Imported \u{201C}Scene 6\u{201D}")
                // Then plain warnings go before ones with actions, and only then the oldest.
                center.post(.warning, "Plain warning")
                center.post(.error, "Failed 1", message: "x", actions: [.init(title: "Try Again") {}])
                center.post(.error, "Failed 2", message: "x", actions: [.init(title: "Try Again") {}])
                try expectEqual(center.banners.map(\.title), ["\u{201C}Lake\u{201D} is already in your library", "Plain warning", "Failed 1", "Failed 2"])
                center.post(.error, "Failed 3", message: "x", actions: [.init(title: "Try Again") {}])
                try expectEqual(center.banners.map(\.title), ["\u{201C}Lake\u{201D} is already in your library", "Failed 1", "Failed 2", "Failed 3"])
                center.post(.info, "Newest")
                try expectEqual(center.banners.map(\.title), ["Failed 1", "Failed 2", "Failed 3", "Newest"])
            }
        },
        TestCase(name: "app.hotkey.accepts-combos") {
            let ctrlCmd = HotkeyRecorder.FlagBit.control | HotkeyRecorder.FlagBit.command
            try expectEqual(HotkeyRecorder.evaluate(keyCode: 37, rawFlags: ctrlCmd), .accepted(.controlCommandL))
            try expectEqual(HotkeyRecorder.evaluate(keyCode: 37, rawFlags: ctrlCmd | HotkeyRecorder.FlagBit.capsLock),
                            .accepted(.controlCommandL))
            try expectEqual(HotkeyRecorder.evaluate(keyCode: 105, rawFlags: 0), .accepted(LPHotkey(keyCode: 105, modifiers: [])))
            let opt = HotkeyRecorder.FlagBit.option | HotkeyRecorder.FlagBit.command
            try expectEqual(HotkeyRecorder.evaluate(keyCode: 37, rawFlags: opt), .accepted(LPHotkey(keyCode: 37, modifiers: [.option, .command])))
        },
        TestCase(name: "app.hotkey.special-keys") {
            try expectEqual(HotkeyRecorder.evaluate(keyCode: 53, rawFlags: 0), .cancelled)
            try expectEqual(HotkeyRecorder.evaluate(keyCode: 51, rawFlags: 0), .cleared)
            try expectEqual(HotkeyRecorder.evaluate(keyCode: 117, rawFlags: 0), .cleared)
            try expectEqual(HotkeyRecorder.evaluate(keyCode: 59, rawFlags: HotkeyRecorder.FlagBit.control), .ignored)
        },
        TestCase(name: "app.hotkey.rejects-unsafe") {
            func rejected(_ code: UInt16, _ flags: UInt) -> Bool {
                if case .rejected = HotkeyRecorder.evaluate(keyCode: code, rawFlags: flags) { return true }
                return false
            }
            let cmd = HotkeyRecorder.FlagBit.command, ctrl = HotkeyRecorder.FlagBit.control, shift = HotkeyRecorder.FlagBit.shift
            try expect(rejected(37, 0), "bare letter")
            try expect(rejected(37, shift), "shift only")
            try expect(rejected(37, cmd), "⌘L collides with apps")
            try expect(rejected(37, cmd | shift), "⌘⇧L collides with apps")
            try expect(rejected(12, ctrl | cmd), "⌃⌘Q is the system lock")
            try expect(rejected(49, cmd), "⌘Space is Spotlight")
            try expect(rejected(48, cmd), "⌘Tab switches apps")
            try expect(rejected(21, cmd | shift), "⌘⇧4 takes screenshots")
            if case .rejected(let why) = HotkeyRecorder.evaluate(keyCode: 12, rawFlags: ctrl | cmd) {
                try expect(why.contains("Use \u{2303}\u{2318}Q and the lock key for LivePaper lock"), why)
            }
        },
        TestCase(name: "app.hotkey.display") {
            try expectEqual(HotkeyRecorder.display(.controlCommandL), "\u{2303}\u{2318}L")
            try expectEqual(HotkeyRecorder.display(LPHotkey(keyCode: 122, modifiers: [.command, .option, .shift, .control])),
                            "\u{2303}\u{2325}\u{21E7}\u{2318}F1")
            try expectEqual(HotkeyRecorder.accessibilityLabel(.controlCommandL), "Control Command L")
            try expectEqual(HotkeyRecorder.accessibilityLabel(nil), "No shortcut")
            try expectEqual(HotkeyRecorder.modifiers(fromRawFlags: HotkeyRecorder.FlagBit.command | HotkeyRecorder.FlagBit.shift),
                            [.shift, .command])
        },
        TestCase(name: "app.library.query") {
            let entries = sampleEntries()
            var q = LibraryQuery()
            try expect(!q.isActive)
            try expectEqual(q.apply(entries).count, entries.count)
            q.text = "night"
            try expectEqual(Set(q.apply(entries).map(\.id)), ["aurora-lake", "neon-rain", "paper-lanterns"])
            q.text = "NIGHT  rain"
            try expectEqual(q.apply(entries).map(\.id), ["neon-rain"])
            q = LibraryQuery(text: "", kind: .video)
            try expectEqual(Set(q.apply(entries).map(\.id)), ["coastline-at-dusk", "morning-fog"])
            q.kind = .ai
            try expectEqual(Set(q.apply(entries).map(\.id)), ["neon-rain", "paper-lanterns", "tidal-glass"])
            q = LibraryQuery(text: "Dünes", kind: .all)
            try expectEqual(q.apply(entries).map(\.id), ["drifting-dunes"])
        },
        TestCase(name: "app.naming") {
            try expectEqual(SceneNaming.uniqueCopyName(for: "Aurora Lake", existing: ["Aurora Lake"]), "Aurora Lake copy")
            try expectEqual(SceneNaming.uniqueCopyName(for: "Aurora Lake", existing: ["aurora lake copy", "Aurora Lake copy 2"]),
                            "Aurora Lake copy 3")
            try expectEqual(SceneNaming.suggestedName(forFile: URL(fileURLWithPath: "/x/coastline_at-dusk.mov")), "Coastline at dusk")
            try expectEqual(SceneNaming.suggestedName(forFile: URL(fileURLWithPath: "/x/NYC Skyline.mp4")), "NYC Skyline")
            try expectEqual(SceneNaming.validated("  Name  "), "Name")
            try expectEqual(SceneNaming.validated("   "), nil)
            try expectEqual(SceneNaming.validated(String(repeating: "x", count: 81)), nil)
        },
        TestCase(name: "app.playlist.membership") {
            let all = ["a", "b", "c"]
            var d = PlaylistDraft(PlaylistSettings())
            try expect(d.includesAllScenes)
            try expectEqual(d.effectiveSceneIDs(available: all), all)
            d.setIncluded("b", false, available: all)
            try expectEqual(d.settings.sceneIDs, ["a", "c"])
            d.setIncluded("b", true, available: all)
            try expectEqual(d.settings.sceneIDs, ["a", "c", "b"])
            // Deleted scenes drop out; if none remain the saver falls back to everything.
            try expectEqual(PlaylistDraft(PlaylistSettings(sceneIDs: ["gone", "c"])).effectiveSceneIDs(available: all), ["c"])
            try expectEqual(PlaylistDraft(PlaylistSettings(sceneIDs: ["gone"])).effectiveSceneIDs(available: all), all)
            d.setIncludesAllScenes(true, available: all)
            try expectEqual(d.settings.sceneIDs, [])
        },
        TestCase(name: "app.playlist.move") {
            var d = PlaylistDraft(PlaylistSettings(sceneIDs: ["a", "b", "c", "d"]))
            d.move(fromOffsets: [0], toOffset: 3)
            try expectEqual(d.settings.sceneIDs, ["b", "c", "a", "d"])
            d.move(fromOffsets: [3], toOffset: 0)
            try expectEqual(d.settings.sceneIDs, ["d", "b", "c", "a"])
            d.move(fromOffsets: [1, 2], toOffset: 4)
            try expectEqual(d.settings.sceneIDs, ["d", "a", "b", "c"])
            d.move(fromOffsets: [2], toOffset: 1) // "Move Up" on index 2
            try expectEqual(d.settings.sceneIDs, ["d", "b", "a", "c"])
        },
        TestCase(name: "app.playlist.use-add-advance") {
            var d = PlaylistDraft(PlaylistSettings())
            d.useOnly("b")
            try expectEqual(d.settings.mode, .single)
            try expectEqual(d.settings.sceneIDs, ["b"])
            try expect(!d.add("b"), "already the single scene")
            try expect(d.add("c"))
            try expectEqual(d.settings.mode, .sequence)
            try expectEqual(d.settings.sceneIDs, ["b", "c"])
            let all = ["a", "b", "c"]
            try expectEqual(PlaylistDraft.advanced(PlaylistSettings(mode: .single, sceneIDs: ["c"]), available: all)?.sceneIDs, ["a"])
            try expectEqual(PlaylistDraft.advanced(PlaylistSettings(mode: .sequence, sceneIDs: ["a", "b"]), available: all)?.sceneIDs,
                            ["b", "a"])
            try expect(PlaylistDraft.advanced(PlaylistSettings(mode: .shuffle), available: all) == nil)
            try expect(PlaylistDraft.advanced(PlaylistSettings(mode: .single), available: []) == nil)
        },
        TestCase(name: "app.playlist.summary") {
            let names = ["a": "Aurora", "b": "Beach"]
            try expectEqual(PlaylistDraft.summary(PlaylistSettings(), available: ["a", "b"], names: names),
                            "Shuffle \u{00B7} all 2 scenes \u{00B7} every 5 minutes")
            try expectEqual(PlaylistDraft.summary(PlaylistSettings(mode: .single, sceneIDs: ["b"]), available: ["a", "b"], names: names),
                            "Beach")
            try expectEqual(PlaylistDraft.summary(PlaylistSettings(mode: .sequence, cycleMinutes: 0, sceneIDs: ["a", "b"]),
                                                  available: ["a", "b"], names: names),
                            "In order \u{00B7} 2 scenes \u{00B7} one per session")
            try expectEqual(PlaylistDraft.summary(PlaylistSettings(), available: [], names: [:]), "No scenes yet")
        },
        TestCase(name: "app.energy-class") {
            func m(_ kind: SceneManifest.Kind, ms: Double?, mw: Double?) -> SceneManifest {
                SceneManifest(id: "x", name: "X", kind: kind, performance: .init(benchMs: ms, energyMw: mw))
            }
            try expectEqual(EnergyClass(manifest: m(.web, ms: 1.2, mw: nil)), .low)
            try expectEqual(EnergyClass(manifest: m(.web, ms: 3.9, mw: nil)), .medium)
            try expectEqual(EnergyClass(manifest: m(.web, ms: 4.5, mw: nil)), .high)
            try expectEqual(EnergyClass(manifest: m(.web, ms: 0.5, mw: 300)), .high) // energy wins over bench
            try expectEqual(EnergyClass(manifest: m(.web, ms: nil, mw: 90)), .low)
            try expectEqual(EnergyClass(manifest: m(.web, ms: .nan, mw: nil)), .unmeasured)
            try expectEqual(EnergyClass(manifest: SceneManifest(id: "v", name: "V", kind: .video)), .low)
            try expectEqual(EnergyClass(manifest: SceneManifest(id: "w", name: "W", kind: .web)), .unmeasured)
            try expectEqual(SceneBadge(kind: .web, hasAIHistory: true), .ai)
            try expectEqual(SceneBadge(kind: .video, hasAIHistory: true), .video)
        },
        TestCase(name: "app.format") {
            try expectEqual(LPFormat.milliseconds(1.44), "1.4 ms")
            try expectEqual(LPFormat.milliseconds(12.4), "12 ms")
            try expectEqual(LPFormat.power(milliwatts: 61), "61 mW")
            try expectEqual(LPFormat.power(milliwatts: 1250), "1.2 W")
            try expectEqual(LPFormat.elapsed(7.9), "0:07")
            try expectEqual(LPFormat.elapsed(245), "4:05")
            try expectEqual(LPFormat.elapsed(3723), "1:02:03")
            try expectEqual(LPFormat.elapsed(-5), "0:00")
            try expectEqual(LPFormat.cycle(minutes: 0), "Never changes")
            try expectEqual(LPFormat.cycle(minutes: 1), "Every minute")
            try expectEqual(LPFormat.cycle(minutes: 15), "Every 15 minutes")
            try expectEqual(LPFormat.abbreviatingHome("/Users/a/Library/x", home: "/Users/a"), "~/Library/x")
            try expectEqual(LPFormat.abbreviatingHome("/Users/ab/x", home: "/Users/a/"), "/Users/ab/x")
            try expectEqual(LPFormat.abbreviatingHome("/Users/a", home: "/Users/a"), "~")
            try expectEqual(BenchLabel.title("1512x982@2 t=14"), "1512\u{00D7}982 @2x")
            try expectEqual(BenchLabel.title("5120x1440"), "5120\u{00D7}1440")
            try expectEqual(BenchLabel.title("heaviest"), "heaviest")
        },
        TestCase(name: "app.format.check-summary") {
            let ok = CheckReport(passed: true, benchMs: ["5120x1440@1 t=14": 2.9, "1512x982@2 t=14": 1.4, "1512x982@2 t=600": 1.1], energyMw: 61)
            try expectEqual(LPFormat.checkSummary(ok), "Passed \u{00B7} 1.4 ms \u{00B7} 61 mW")
            try expectEqual(CheckReportFile.sortedBench(ok).map(\.key), ["1512x982@2 t=14", "1512x982@2 t=600", "5120x1440@1 t=14"])
            try expectEqual(LPFormat.checkSummary(CheckReport(passed: false, problems: ["a"], jsErrors: ["b"])), "2 problems")
            try expectEqual(LPFormat.checkSummary(CheckReport(passed: false)), "1 problem")
        },
        TestCase(name: "app.records.provenance") {
            let text = """
            {"date":"2026-11-10T08:00:00Z","action":"create","harness":"Claude Code","prompt":"Rain","summary":"Made it"}
            not json
            {"date":"2026-11-11T08:00:00.250Z","action":"clone","summary":"From aurora-lake"}

            {"date":"bad","prompt":"  ","model":"gpt"}
            """
            let entries = ProvenanceLog.parse(Data(text.utf8))
            try expectEqual(entries.count, 3)
            try expect(entries[0].isAI && entries[0].date != nil)
            try expect(!entries[1].isAI, "clone is not AI")
            try expect(entries[1].date != nil, "fractional seconds")
            try expectEqual(entries[2].prompt, nil)
            try expectEqual(entries[2].date, nil)
            try expectEqual(entries[1].title, "Cloned")
            let dir = try tempDir("provenance")
            defer { try? FileManager.default.removeItem(at: dir) }
            try Data(#"{"action":"clone"}"#.utf8).write(to: dir.appendingPathComponent(ProvenanceLog.fileName))
            try expect(!ProvenanceLog.hasAIHistory(package: dir))
            try Data(text.utf8).write(to: dir.appendingPathComponent(ProvenanceLog.fileName))
            try expect(ProvenanceLog.hasAIHistory(package: dir))
        },
        TestCase(name: "app.records.check-report") {
            let json = #"{"passed":false,"problems":["Too slow"],"warnings":[],"jsErrors":[],"stills":[],"benchMs":{"1512x982@2 t=14":5.1},"checkedAt":"2026-11-12T10:00:00.250Z"}"#
            let r = try unwrap(CheckReportFile.decode(Data(json.utf8)))
            try expectEqual(r.problems, ["Too slow"])
            try expectEqual(CheckReportFile.primaryBenchMs(r), 5.1)
            try expect(CheckReportFile.decode(Data("{}".utf8)) == nil)
        },
        TestCase(name: "app.ai.preferences") {
            try expect(AIPreferences.customCommandProblem("") == nil, "no custom command is fine")
            try expectEqual(AIPreferences.customCommandProblem("mytool --prompt {prompt_file} --dir {workspace}"), nil)
            try expect(AIPreferences.customCommandProblem("x {prompt_file} {bogus}")?.contains("{bogus}") == true)
            try expectEqual(AIPreferences.placeholders, CustomAdapter.placeholders)
            try expectEqual(AIPreferences.timeoutChoices(including: 20), AIPreferences.timeoutChoices)
            try expectEqual(AIPreferences.timeoutChoices(including: 25), [5, 10, 20, 25, 30, 45, 60])
            var settings = AISettings(customTemplate: "mytool --prompt {prompt_file}")
            try expectEqual(AIPreferences.customHarness(settings)?.executable, "mytool")
            settings.customTemplate = "mytool {nope}"
            try expect(AIPreferences.customHarness(settings) == nil, "an unusable template offers no harness")
            // Detection's own custom entry is replaced by the one from the (current) settings.
            let hs = [AIHarness(kind: .claude, name: "C", executable: "/c"), AIHarness(kind: .codex, name: "X", executable: "/x"),
                      AIHarness.custom(template: "stale {prompt_file}")]
            settings.customTemplate = "fresh {prompt_file}"
            try expectEqual(AIPreferences.availableHarnesses(detected: hs, settings: settings).map(\.executable), ["/c", "/x", "fresh"])
            settings.customTemplate = nil
            try expectEqual(AIPreferences.availableHarnesses(detected: hs, settings: settings).count, 2)
            try expectEqual(AIPreferences.preferredHarness(in: hs, preferredID: "codex:/x")?.kind, .codex)
            try expectEqual(AIPreferences.preferredHarness(in: hs, preferredID: "gone")?.kind, .claude)
        },
        TestCase(name: "app.ai.prompts") {
            try expect(!PromptComposer.isUsable("  short "))
            try expect(PromptComposer.isUsable("A calm aurora"))
            try expectEqual(PromptComposer.retry(original: "Rain ", feedback: " "), "Rain")
            try expect(PromptComposer.retry(original: "Rain", feedback: "slower").hasSuffix("(please address it): slower"))
            try expectEqual(PromptComposer.title(for: "one  two\nthree"), "one two three")
            try expectEqual(PromptComposer.title(for: "alpha beta gamma delta", limit: 12), "alpha beta\u{2026}")
            try expectEqual(PromptComposer.title(for: "   "), "Untitled")
        },
        TestCase(name: "app.ai.session-reducer") {
            var s = AISessionState()
            let t = Date(timeIntervalSince1970: 0)
            s.apply(.status("Preparing workspace\u{2026}"), at: t)
            try expectEqual(s.phase, .running)
            s.apply(.assistantText("Hel"), at: t)
            s.apply(.assistantText("lo."), at: t)
            s.apply(.assistantText("Next part"), at: t)
            s.apply(.assistantText("   "), at: t)
            try expectEqual(s.entries.count, 2)
            try expectEqual(s.entries[1].kind, .text("Hello.\n\nNext part"))
            s.apply(.toolUse(name: "Read", detail: "a"), at: t)
            s.apply(.toolUse(name: "Read", detail: "b"), at: t)
            s.apply(.toolUse(name: "Write", detail: "c"), at: t)
            try expectEqual(s.entries.count, 3)
            try expectEqual(s.toolCallCount, 3)
            if case .tools(let calls) = s.entries[2].kind { try expectEqual(ToolSummary.title(calls), "Used 3 tools \u{00B7} Read \u{00D7}2, Write") }
            let png = URL(fileURLWithPath: "/tmp/a.png")
            s.apply(.stillRendered(png), at: t)
            s.apply(.stillRendered(png), at: t)   // rewritten: one tile, a new revision
            s.apply(.stillRendered(URL(fileURLWithPath: "/tmp/b.png")), at: t)
            s.apply(.stillRendered(URL(fileURLWithPath: "/tmp/motion-1512x982@2.png")), at: t)   // a heat map: shown, not counted
            try expectEqual(s.stills.count, 3)
            try expectEqual(s.stillRevision(png), 1)
            try expectEqual(s.entries.last?.kind, .stills(3))
            s.apply(.status("Validating with livepaper check\u{2026}"), at: t)
            try expectEqual(s.phase, .validating)
            s.apply(.checkResult(CheckReport(passed: true, benchMs: ["1512x982@2 t=14": 1.6])), at: t)
            try expectEqual(s.report?.passed, true)
            let pkg = URL(fileURLWithPath: "/tmp/scene")
            s.apply(.finished(package: pkg), at: t)
            try expectEqual(s.package, pkg)
            let count = s.entries.count
            s.apply(.assistantText("late output"), at: t)
            s.markCancelled(at: t)
            try expectEqual(s.entries.count, count)
            try expectEqual(s.phase, .succeeded(package: pkg))
        },
        TestCase(name: "app.ai.session-reducer.bounds") {
            var s = AISessionState()
            for i in 0..<(AISessionState.maxEntries + 50) {
                s.apply(i.isMultiple(of: 2) ? .status("s\(i)") : .stillRendered(URL(fileURLWithPath: "/tmp/\(i).png")))
            }
            try expectEqual(s.entries.count, AISessionState.maxEntries)
            try expectEqual(s.droppedEntries, 50)
            try expect(s.entries.map(\.id) == s.entries.map(\.id).sorted(), "ids stay ordered")
            let long = String(repeating: "x", count: AISessionState.maxTextLength + 10)
            try expectEqual(AISessionState.clamp(long).count, AISessionState.maxTextLength + 1)
            var ended = AISessionState()
            ended.apply(.status("Running\u{2026}"))
            ended.streamEnded()
            if case .failed = ended.phase {} else { throw TestFailure(description: "stream end without result must fail") }
            var cancelled = AISessionState()
            cancelled.markCancelled()
            try expectEqual(cancelled.phase, .cancelled)
        },
        TestCase(name: "app.ai.session-reducer.rerendered-stills") {
            // Every `livepaper check` run (the agent's, then LivePaper's own) rewrites the same file
            // names; AISession re-reports a still whenever its file changes. Each report is a new
            // picture: the filmstrip keeps one tile per file, newest render last (the hero shows
            // the last one), and the tile's revision changes so its image is reloaded.
            var s = AISessionState()
            let t = Date(timeIntervalSince1970: 0)
            let a = URL(fileURLWithPath: "/tmp/ws/scene/.check/1512x982@2-t4.png")
            let b = URL(fileURLWithPath: "/tmp/ws/scene/.check/1512x982@2-t12.png")
            s.apply(.stillRendered(a), at: t)
            s.apply(.stillRendered(b), at: t)
            try expectEqual(s.stills, [a, b])
            try expectEqual([s.stillRevision(a), s.stillRevision(b)], [0, 0])
            s.apply(.toolUse(name: "Edit", detail: "scene/scene.js"), at: t)
            s.apply(.stillRendered(a), at: t)   // the second check run
            try expectEqual(s.stills, [b, a])
            try expectEqual([s.stillRevision(a), s.stillRevision(b)], [1, 0])
            try expectEqual(s.entries.last?.kind, .stills(1))
            s.apply(.stillRendered(b), at: t)
            try expectEqual(s.stills, [a, b])
            try expectEqual([s.stillRevision(a), s.stillRevision(b)], [1, 1])
            try expectEqual(s.entries.last?.kind, .stills(2))
            // The image a tile shows is keyed on the revision, so it can't be the first run's.
            try expect(ThumbnailCache.key(a, revision: s.stillRevision(a), maxPixel: 240)
                       != ThumbnailCache.key(a, revision: 0, maxPixel: 240))
        },
        TestCase(name: "app.thumbnails.revisions") {
            // A file rewritten under the same name is decoded again for a new revision, and the
            // superseded image is dropped (re-rendered stills don't pile up in memory).
            let dir = try tempDir("thumbs")
            defer { try? FileManager.default.removeItem(at: dir) }
            let png = dir.appendingPathComponent("1512x982@2-t4.png")
            func pixels(_ image: CGImage?) -> Data? { image?.dataProvider?.data as Data? }
            try expect(MockArtwork.writeImage(style: .aurora, seed: 1, width: 64, height: 40, to: png))
            let cache = ThumbnailCache()
            var first: CGImage?, stale: CGImage?, second: CGImage?, late: CGImage?
            try awaitMain { first = await cache.load(png, revision: 0, maxPixel: 64) }
            try expect(MockArtwork.writeImage(style: .dunes, seed: 2, width: 64, height: 40, to: png))
            try awaitMain { stale = await cache.load(png, revision: 0, maxPixel: 64) }
            try expect(stale === first, "same revision: served from the cache")
            try awaitMain { second = await cache.load(png, revision: 1, maxPixel: 64) }
            try expect(pixels(first) != nil && pixels(second) != nil)
            try expect(pixels(second) != pixels(first), "the new revision shows the new picture")
            try expect(cache.cached(ThumbnailCache.key(png, revision: 0, maxPixel: 64)) == nil, "superseded image dropped")
            try expect(cache.cached(ThumbnailCache.key(png, revision: 1, maxPixel: 64)) === second)
            // A slow load of an older revision finishing late doesn't evict or shadow the newer one.
            try awaitMain { late = await cache.load(png, revision: 0, maxPixel: 64) }
            try expect(late != nil)
            try expect(cache.cached(ThumbnailCache.key(png, revision: 0, maxPixel: 64)) == nil)
            try expect(cache.cached(ThumbnailCache.key(png, revision: 1, maxPixel: 64)) === second)
            // Other sizes of the same file are separate entries.
            try awaitMain { _ = await cache.load(png, revision: 1, maxPixel: 32) }
            try expect(cache.cached(ThumbnailCache.key(png, revision: 1, maxPixel: 64)) === second)
        },
        TestCase(name: "app.setup.checklist") {
            var st = SetupState()
            try expectEqual(SetupChecklist.firstIncompleteStep(state: st), .screenSaver)
            try expectEqual(SetupChecklist.saverSummary(st.install), "Not installed")
            st.install.saverInstalled = true; st.install.saverUpToDate = true
            try expectEqual(SetupChecklist.checks(for: .screenSaver, state: st).map(\.state), [.done, .needed])
            try expectEqual(SetupChecklist.saverSummary(st.install), "Installed, not selected")
            st.install.saverSelected = true
            try expectEqual(SetupChecklist.firstIncompleteStep(state: st), .lock)
            try expectEqual(SetupChecklist.checks(for: .lock, state: st).map(\.id), [.lockKeys, .password, .helper])
            // A profile that manages only other screen-saver keys (idle time …) leaves the password
            // delay to the user: still "needed", with the fix, never "managed".
            st.install.helperRunning = true; st.install.managedByMDM = true
            try expectEqual(SetupChecklist.checks(for: .lock, state: st).map(\.state), [.needed, .needed, .done])
            let fixable = try unwrap(SetupChecklist.checks(for: .lock, state: st).first { $0.id == .password })
            try expect(fixable.detail.contains("Immediately") && !fixable.detail.contains("organisation"), fixable.detail)
            // Only a profile that forces the password off or a delay makes it "managed".
            st.install.passwordManagedByMDM = true
            try expectEqual(SetupChecklist.checks(for: .lock, state: st).map(\.state), [.needed, .managed, .done])
            let managed = try unwrap(SetupChecklist.checks(for: .lock, state: st).first { $0.id == .password })
            try expect(managed.detail.contains("organisation") && !managed.detail.contains("Locking still works"), managed.detail)
            try expect(!SetupChecklist.isComplete(.lock, state: st), "lock keys still off")
            st.install.lockKeysShowScene = true
            try expect(SetupChecklist.isComplete(.lock, state: st), "managed never blocks")
            try expectEqual(SetupChecklist.firstIncompleteStep(state: st), .firstScene)
            try expect(SetupChecklist.checks(for: .welcome, state: st).isEmpty)
            st.install.saverUpToDate = false
            try expectEqual(SetupChecklist.saverSummary(st.install), "Selected \u{2014} update available")
            try expect(SetupChecklist.checks(for: .screenSaver, state: st)[0].detail.contains("update is available"))
            // A newer build from another copy of LivePaper isn't an "update".
            st.install.saverNewerInstalled = true
            try expectEqual(SetupChecklist.saverSummary(st.install), "Selected \u{2014} a newer build is installed")
            try expect(SetupChecklist.checks(for: .screenSaver, state: st)[0].detail.contains("newer build"))
            st.install.saverNewerInstalled = false
            // A login item waiting for approval says where to allow it.
            st.install.helperRunning = false
            st.install.helperLoginItem = .requiresApproval
            try expect(st.helperNeedsApproval)
            let helper = try unwrap(SetupChecklist.checks(for: .lock, state: st).first { $0.id == .helper })
            try expectEqual(helper.state, .needed)
            try expect(helper.detail.contains("Login Items"), helper.detail)
            st.install.helperLoginItem = .enabled
            try expect(!st.helperNeedsApproval)
            // launchd can't start the enabled login item (after an update): its own wording, and
            // the button registers it again.
            try expectEqual(st.helperActionTitle, "Start Helper")
            st.install.helperProblem = .cannotStart("spawn failed, last exit code 78: EX_CONFIG")
            try expect(st.helperCannotStart)
            try expectEqual(st.helperActionTitle, "Repair Helper")
            let broken = try unwrap(SetupChecklist.checks(for: .lock, state: st).first { $0.id == .helper })
            try expectEqual(broken.title, "LivePaper helper can\u{2019}t start")
            try expect(broken.state == .needed && broken.detail.contains("Repair Helper"), broken.detail)
            st.install.helperLoginItem = .requiresApproval
            try expect(!st.helperCannotStart && st.helperNeedsApproval, "approval comes first: only the user can give it")
            st.install.helperLoginItem = .enabled; st.install.helperRunning = true
            try expect(!st.helperCannotStart && st.helperActionTitle == "Start Helper")
            try expectEqual(st.helperOtherCopy, nil)
            // Another copy's helper runs: done, and Settings › Lock offers to use this copy's instead.
            st.install.helperProblem = .otherCopy("/Users/me/Downloads/LivePaper.app")
            try expectEqual(st.helperOtherCopy, "/Users/me/Downloads/LivePaper.app")
            let other = try unwrap(SetupChecklist.checks(for: .lock, state: st).first { $0.id == .helper })
            try expect(other.state == .done && other.detail.contains("/Users/me/Downloads/LivePaper.app") &&
                       other.detail.contains(SetupState.useThisCopysHelperTitle), other.detail)
            st.install.helperRunning = false
            try expectEqual(st.helperOtherCopy, nil)
        },
        TestCase(name: "app.setup.uninstall-report") {
            let home = "/Users/someone"
            let report = UninstallReport.make([
                InstallStep(title: "Unregister the helper login item", outcome: .done),
                InstallStep(title: "Restore the previous screen saver choice", outcome: .skipped("LivePaper didn't change it")),
                InstallStep(title: "Remove /Users/someone/Library/Screen Savers/LivePaper.saver", outcome: .failed("Permission denied")),
            ], home: home)
            try expectEqual(report.rows.map(\.state), [.done, .skipped, .failed])
            try expectEqual(report.rows[2].title, "Remove ~/Library/Screen Savers/LivePaper.saver")
            try expectEqual(report.rows[1].detail, "Nothing to do: LivePaper didn't change it.")
            try expectEqual(report.rows[2].detail, "Permission denied")
            try expect(!report.succeeded && report.summary.hasPrefix("1 step"), report.summary)
            let ok = UninstallReport.make([InstallStep(title: "x", outcome: .done)], home: home)
            try expect(ok.succeeded && ok.failures.isEmpty)
        },
        TestCase(name: "app.lock.distributed-channel") {
            // The real channel on private names (nobody else listens), with this test as the helper.
            let tag = "com.nachmore.livepaper.selftest.\(UUID().uuidString.prefix(8))"
            try MainActor.assumeIsolated {
                let channel = DistributedHelperLockChannel(requestName: tag + ".lockNow", acceptedName: tag + ".lockNowAccepted")
                let center = DistributedNotificationCenter.default()
                var received: [String] = []
                let helper = center.addObserver(forName: .init(tag + ".lockNow"), object: nil, queue: .main) { note in
                    let id = note.userInfo?[LPNotification.requestIDKey] as? String ?? ""
                    received.append(id)
                    center.postNotificationName(.init(tag + ".lockNowAccepted"), object: nil,
                                                userInfo: [LPNotification.requestIDKey: id], deliverImmediately: true)
                }
                var answered = false
                try awaitMain { answered = await channel.requestLock(timeout: 5) }
                try expect(answered, "the helper's answer arrives")
                try expectEqual(received.count, 1)
                try expect(!(received.first ?? "").isEmpty, "requests carry an id")
                center.removeObserver(helper)
                let started = Date()
                try awaitMain { answered = await channel.requestLock(timeout: 0.3) }
                try expect(!answered, "no helper: no answer")
                try expect(Date().timeIntervalSince(started) < 3, "gives up after the timeout")
            }
        },
        TestCase(name: "app.session-unlock.observer") {
            // On a private name (nobody else posts it): an unlock of this session (the uid as the
            // object, or no object) counts; another session's doesn't; nothing after invalidate().
            try expect(SessionUnlockObserver.isOwnSession(nil, uid: "501") && SessionUnlockObserver.isOwnSession("501", uid: "501"))
            try expect(!SessionUnlockObserver.isOwnSession("502", uid: "501") && !SessionUnlockObserver.isOwnSession(501, uid: "501"))
            let name = Notification.Name("com.nachmore.livepaper.selftest.\(UUID().uuidString.prefix(8)).unlocked")
            try MainActor.assumeIsolated {
                var calls = 0
                let observer = SessionUnlockObserver(name: name.rawValue, uid: 501) { calls += 1 }
                let center = DistributedNotificationCenter.default()
                center.postNotificationName(name, object: "502", userInfo: nil, deliverImmediately: true)
                center.postNotificationName(name, object: "501", userInfo: nil, deliverImmediately: true)
                try awaitMain(until: { calls == 1 })
                pumpMain(0.3)
                try expectEqual(calls, 1)
                observer.invalidate()
                center.postNotificationName(name, object: "501", userInfo: nil, deliverImmediately: true)
                pumpMain(0.3)
                try expectEqual(calls, 1)
            }
        },
        TestCase(name: "app.setup.uninstall-plan") {
            try withScratchPaths("plan") { root in
                let home = root.path
                let keep = UninstallPlan.make(keepScenes: true, userSceneCount: 1, restoresLockKeys: true,
                                              appBundlePath: home + "/Applications/LivePaper.app", home: home)
                try expectEqual(keep.items.map(\.id), ["helper", "saver", "restore", "lock-keys", "library", "app"])
                try expectEqual(keep.items.first { $0.id == "library" }?.action, .keep)
                try expect(keep.items.first { $0.id == "library" }?.title.contains("1 scene)") == true)
                try expectEqual(keep.items.last?.detail, "~/Applications/LivePaper.app")
                let wipe = UninstallPlan.make(keepScenes: false, userSceneCount: 3, restoresLockKeys: false, appBundlePath: nil, home: home)
                try expect(!wipe.items.contains { $0.id == "lock-keys" }, "nothing to restore")
                try expectEqual(wipe.items.first { $0.id == "library" }?.action, .remove)
                try expect(!wipe.items.contains { $0.id == "app" }, "no app bundle when not running from one")
                try expect(wipe.items.allSatisfy { !$0.detail.contains(home + "/") }, "paths are ~-abbreviated")
            }
        },
    ] + fullScreenPreview }

    // MARK: - Full-screen preview (pure logic)

    static var fullScreenPreview: [TestCase] { [
        TestCase(name: "app.fullscreen.sequence-steps-and-wraps") {
            var seq = try unwrap(FullScreenPreviewSequence(ids: ["a", "b", "c"], start: "b", source: .library))
            try expectEqual(seq.current, "b")
            try expectEqual(seq.positionText, "2 of 3")
            try expect(seq.step(1)); try expectEqual(seq.current, "c")
            try expect(seq.step(1)); try expectEqual(seq.current, "a")   // wraps forward
            try expect(seq.step(-1)); try expectEqual(seq.current, "c")  // wraps backward
            try expect(seq.step(-4)); try expectEqual(seq.current, "b")  // any distance
            try expectEqual(seq.positionText, "2 of 3")
            var single = try unwrap(FullScreenPreviewSequence(ids: ["solo"], source: .playlist))
            try expect(!single.canStep && !single.step(1), "one scene: nowhere to go")
            try expectEqual(single.current, "solo")
            try expectEqual(single.positionText, nil)
            try expect(FullScreenPreviewSequence(ids: [], source: .library) == nil, "nothing to show")
            let unknown = try unwrap(FullScreenPreviewSequence(ids: ["a", "b"], start: "zz", source: .library))
            try expectEqual(unknown.current, "a")
            let dupes = try unwrap(FullScreenPreviewSequence(ids: ["a", "b", "a", "c", "b"], start: "c", source: .playlist))
            try expectEqual(dupes.ids, ["a", "b", "c"])
            try expectEqual(dupes.current, "c")
        },
        TestCase(name: "app.fullscreen.sequence-drops-deleted-scenes") {
            var seq = try unwrap(FullScreenPreviewSequence(ids: ["a", "b", "c", "d"], start: "b", source: .library))
            try expect(seq.retain(available: ["a", "b", "c", "d", "extra"]))
            try expectEqual(seq.ids, ["a", "b", "c", "d"])
            try expect(seq.retain(available: ["a", "b", "d"]), "the current scene survives")
            try expectEqual(seq.current, "b")
            try expectEqual(seq.ids, ["a", "b", "d"])
            try expect(seq.retain(available: ["a", "d"]), "current deleted → the next one")
            try expectEqual(seq.current, "d")
            try expect(seq.retain(available: ["a"]), "the last one deleted → wraps to the first")
            try expectEqual(seq.current, "a")
            try expect(!seq.retain(available: []), "nothing left")
        },
        TestCase(name: "app.fullscreen.step-after-deletion") {
            // The scene on screen was deleted: retain already moved to the next one, which is the step.
            var seq = try unwrap(FullScreenPreviewSequence(ids: ["a", "b", "c", "d"], start: "b", source: .library))
            try expect(seq.advance(1, available: ["a", "c", "d"]))
            try expectEqual(seq.current, "c")   // not d: c isn't skipped
            try expectEqual(seq.ids, ["a", "c", "d"])
            seq = try unwrap(FullScreenPreviewSequence(ids: ["a", "b", "c", "d"], start: "b", source: .library))
            try expect(seq.advance(-1, available: ["a", "c", "d"]))
            try expectEqual(seq.current, "a")   // the one before the deleted scene
            seq = try unwrap(FullScreenPreviewSequence(ids: ["a", "b", "c", "d"], start: "d", source: .playlist))
            try expect(seq.advance(1, available: ["a", "b", "c"]))
            try expectEqual(seq.current, "a")   // wraps, like a step from d would
            seq = try unwrap(FullScreenPreviewSequence(ids: ["a", "b", "c", "d"], start: "d", source: .playlist))
            try expect(seq.advance(-1, available: ["a", "b", "c"]))
            try expectEqual(seq.current, "c")
            // One scene left: either key shows it (the deleted one doesn't stay on screen).
            for delta in [1, -1] {
                var two = try unwrap(FullScreenPreviewSequence(ids: ["a", "b"], start: "b", source: .playlist))
                try expect(two.advance(delta, available: ["a"]))
                try expectEqual(two.current, "a")
                try expect(!two.canStep)
                try expectEqual(two.positionText, nil)
            }
            // The AI compare sequence keeps the candidate when the library scene goes.
            var compare = try unwrap(FullScreenPreviewSequence(ids: ["ai-candidate:s1", "aurora"], start: "aurora", source: .candidate))
            try expect(compare.advance(1, available: ["ai-candidate:s1"]))
            try expectEqual(compare.current, "ai-candidate:s1")
            // Nothing deleted: a plain step; other scenes deleted: the same scene stays, the count follows.
            seq = try unwrap(FullScreenPreviewSequence(ids: ["a", "b", "c"], start: "a", source: .library))
            try expect(seq.advance(1, available: ["a", "b", "c"]))
            try expectEqual(seq.current, "b")
            seq = try unwrap(FullScreenPreviewSequence(ids: ["a", "b", "c"], start: "a", source: .library))
            try expect(seq.advance(1, available: ["a"]))
            try expectEqual(seq.current, "a")
            try expectEqual(seq.ids, ["a"])
            try expect(!seq.advance(1, available: []), "nothing left")
        },
        TestCase(name: "app.fullscreen.keys") {
            func down(_ keyCode: UInt16, _ key: String = "", command: Bool = false, shift: Bool = false, control: Bool = false,
                      option: Bool = false, repeating: Bool = false) -> FullScreenKeyAction {
                FullScreenKeys.keyDown(FullScreenKeyPress(keyCode: keyCode, key: key, command: command, shift: shift, control: control,
                                                          option: option, isRepeat: repeating))
            }
            try expectEqual(down(FullScreenKeys.escape), .close)
            try expectEqual(down(FullScreenKeys.space, " "), .close)
            try expectEqual(down(FullScreenKeys.left), .step(-1))
            try expectEqual(down(FullScreenKeys.right), .step(1))
            try expectEqual(down(8, "c"), .toggleClock)
            try expectEqual(down(8, "c", shift: true), .toggleClock)
            try expectEqual(down(37, "l"), .toggleLockUI)
            try expectEqual(down(8, "c", option: true), .pass)
            try expectEqual(down(0, "a"), .pass)
            // A held key acts once: its repeats are taken without doing anything.
            for keyCode in [FullScreenKeys.escape, FullScreenKeys.space, FullScreenKeys.left, FullScreenKeys.right] {
                try expectEqual(down(keyCode, repeating: true), .swallow)
            }
            try expectEqual(down(8, "c", repeating: true), .swallow)    // the clock doesn't flicker
            try expectEqual(down(37, "l", repeating: true), .swallow)
            func equivalent(_ key: String, shift: Bool = false, option: Bool = false, control: Bool = false,
                            command: Bool = true, repeating: Bool = false) -> FullScreenKeyAction {
                FullScreenKeys.keyEquivalent(FullScreenKeyPress(keyCode: 0, key: key, command: command, shift: shift, control: control,
                                                                option: option, isRepeat: repeating))
            }
            try expectEqual(equivalent("."), .close)
            try expectEqual(equivalent("w"), .close)
            try expectEqual(equivalent("f", shift: true), .close)
            try expectEqual(equivalent("f", shift: true, repeating: true), .swallow)
            try expectEqual(equivalent("w", repeating: true), .swallow)
            try expectEqual(equivalent("q"), .pass)
            try expectEqual(equivalent("h"), .pass)
            try expectEqual(equivalent("h", option: true), .pass)
            try expectEqual(equivalent("f"), .swallow)              // nothing acts on the window behind
            try expectEqual(equivalent("n"), .swallow)
            try expectEqual(equivalent("c", command: false), .pass) // not a ⌘ shortcut: keyDown decides
        },
        TestCase(name: "app.fullscreen.closing-key-swallowed-until-released") {
            let space = FullScreenClosingKey(keyCode: FullScreenKeys.space)
            // Held past the fade: its repeats never reach the library card, the menu or the previous app.
            try expectEqual(space.verdict(keyUp: false, keyCode: FullScreenKeys.space, isRepeat: true), .drop)
            try expectEqual(space.verdict(keyUp: true, keyCode: FullScreenKeys.space, isRepeat: false), .released)
            // Other keys are delivered; a new press (any key) means the repeating is over.
            try expectEqual(space.verdict(keyUp: true, keyCode: 0, isRepeat: false), .deliver)
            try expectEqual(space.verdict(keyUp: false, keyCode: 0, isRepeat: true), .deliver)
            try expectEqual(space.verdict(keyUp: false, keyCode: 0, isRepeat: false), .released)
            try expectEqual(space.verdict(keyUp: false, keyCode: FullScreenKeys.space, isRepeat: false), .released)
            // ⇧⌘F: the F key, whatever the modifiers do meanwhile.
            let f = FullScreenClosingKey(keyCode: 3)
            try expectEqual(f.verdict(keyUp: false, keyCode: 3, isRepeat: true), .drop)
        },
        TestCase(name: "app.fullscreen.library-order") {
            let all = ["mine-1", "mine-2", "builtin-1", "builtin-2"]
            try expectEqual(FullScreenPreviewSequence.libraryOrder(visible: ["mine-2", "builtin-1"], all: all, start: "builtin-1"),
                            ["mine-2", "builtin-1"])
            // A scene the grid doesn't show (filtered out) steps through the whole library.
            try expectEqual(FullScreenPreviewSequence.libraryOrder(visible: ["mine-2"], all: all, start: "builtin-2"), all)
            var settings = PlaylistSettings()
            settings.showClock = false
            settings.performance = .battery
            let request = try unwrap(FullScreenPreviewRequest.library(start: "mine-2", visible: all, all: all, playlist: settings))
            try expectEqual(request.sequence.source, .library)
            try expectEqual(request.sequence.current, "mine-2")
            try expectEqual(request.showClock, false)
            try expectEqual(request.performance, .battery)
            // The sample library's grid order (user scenes first) is what ← → follow.
            let entries = sampleEntries()
            let visible = LibraryQuery().apply(entries).map(\.id)
            let start = try unwrap(visible.last)
            var fromGrid = try unwrap(FullScreenPreviewRequest.library(start: start, visible: visible, all: entries.map(\.id),
                                                                       playlist: PlaylistSettings())).sequence
            fromGrid.step(1)
            try expectEqual(fromGrid.current, visible[0])
        },
        TestCase(name: "app.fullscreen.playlist-order") {
            let available = ["a", "b", "c", "d"]
            var settings = PlaylistSettings()
            settings.mode = .sequence
            settings.sceneIDs = ["c", "gone", "a"]
            settings.showClock = false
            settings.performance = .balanced
            let request = try unwrap(FullScreenPreviewRequest.playlist(settings, available: available))
            try expectEqual(request.sequence.source, .playlist)
            try expectEqual(request.sequence.ids, ["c", "a"])   // the playlist's order, deleted scenes left out
            try expectEqual(request.sequence.current, "c")
            try expectEqual(request.showClock, false)
            try expectEqual(request.performance, .balanced)
            settings.sceneIDs = []
            try expectEqual(try unwrap(FullScreenPreviewRequest.playlist(settings, available: available, start: "b")).sequence.ids,
                            available)   // "all scenes"
            try expectEqual(try unwrap(FullScreenPreviewRequest.playlist(settings, available: available, start: "b")).sequence.current, "b")
            settings.mode = .single
            settings.sceneIDs = ["d"]
            try expectEqual(try unwrap(FullScreenPreviewRequest.playlist(settings, available: available)).sequence.ids, ["d"])
            try expect(FullScreenPreviewRequest.playlist(settings, available: []) == nil, "nothing to preview")
            // It changes scene on the playlist's cadence, like the saver; never for one scene or the library.
            try expectEqual(try unwrap(FullScreenPreviewRequest.playlist(settings, available: available)).autoAdvanceInterval, nil)
            settings.mode = .shuffle
            settings.sceneIDs = []
            settings.cycleMinutes = 2
            try expectEqual(try unwrap(FullScreenPreviewRequest.playlist(settings, available: available)).autoAdvanceInterval, 120)
            settings.cycleMinutes = 0
            try expectEqual(try unwrap(FullScreenPreviewRequest.playlist(settings, available: available)).autoAdvanceInterval, nil)
            settings.cycleMinutes = 5
            try expectEqual(try unwrap(FullScreenPreviewRequest.playlist(settings, available: ["a"])).autoAdvanceInterval, nil)
            try expectEqual(try unwrap(FullScreenPreviewRequest.library(start: "a", visible: available, all: available,
                                                                        playlist: settings)).autoAdvanceInterval, nil)
        },
        TestCase(name: "app.fullscreen.hint-visibility") {
            let t0 = Date(timeIntervalSince1970: 1_000)
            func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
            var hint = IdleVisibility(timeout: 3)
            try expect(!hint.isVisible)
            try expectEqual(hint.noteActivity(at: t0), .init(visible: true, armTimer: at(3)))       // opened: shows, one timer
            try expectEqual(hint.noteActivity(at: at(1)), .init())                                   // moving: no new timer
            try expectEqual(hint.noteActivity(at: at(1.5)), .init())
            try expectEqual(hint.timerFired(at: at(3)), .init(armTimer: at(4.5)))                   // too early: re-armed for the rest
            try expect(hint.isVisible)
            try expectEqual(hint.timerFired(at: at(4.5)), .init(visible: false))                    // 3 s without movement: hides
            try expect(!hint.isVisible && hint.timerDate == nil, "hidden, nothing scheduled")
            try expectEqual(hint.timerFired(at: at(9)), .init())                                     // a stale timer does nothing
            try expectEqual(hint.noteActivity(at: at(10)), .init(visible: true, armTimer: at(13)))  // moving again: back
            try expectEqual(hint.timerFired(at: at(12.99)), .init(visible: false))                  // a hair early counts
            hint.reset()
            try expect(!hint.isVisible && hint.timerDate == nil && hint.lastActivity == nil)
            var cursor = IdleVisibility(timeout: 2)
            _ = cursor.noteActivity(at: t0)
            try expectEqual(cursor.timerFired(at: at(2)), .init(visible: false))
        },
        TestCase(name: "app.fullscreen.hint-text") {
            try expectEqual(FullScreenHint.text(FullScreenHint.items(canStep: true, clockOn: true, lockPreview: false)),
                            "\u{2190} \u{2192} scenes \u{00B7} C clock \u{00B7} L lock-screen preview \u{00B7} Esc close")
            try expectEqual(FullScreenHint.text(FullScreenHint.items(canStep: false, clockOn: true, lockPreview: false)),
                            "C clock \u{00B7} L lock-screen preview \u{00B7} Esc close")
            let toggled = FullScreenHint.items(canStep: true, clockOn: false, lockPreview: true)
            try expectEqual(FullScreenHint.text(toggled),
                            "\u{2190} \u{2192} scenes \u{00B7} C clock off \u{00B7} L lock-screen preview on \u{00B7} Esc close")
            try expectEqual(toggled.filter(\.isActive).map(\.id), ["L"])
            try expectEqual(Set(toggled.map(\.id)).count, toggled.count)   // stable, unique ids for ForEach
        },
        TestCase(name: "app.feedback.return-sends") {
            try expectEqual(ReturnKeyRule.action(shift: false, option: false, composing: false, canSend: true), .send)
            try expectEqual(ReturnKeyRule.action(shift: true, option: false, composing: false, canSend: true), .asUsual)
            try expectEqual(ReturnKeyRule.action(shift: false, option: true, composing: false, canSend: true), .asUsual)
            try expectEqual(ReturnKeyRule.action(shift: false, option: false, composing: true, canSend: true), .asUsual)   // IME
            try expectEqual(ReturnKeyRule.action(shift: false, option: false, composing: false, canSend: false), .nothing)
        },
        TestCase(name: "app.about.version-with-build") {
            try expectEqual(AppVersion.display(short: "0.1.0", build: "195"), "0.1.0.195")
            try expectEqual(AppVersion.display(short: "0.1.0-beta.2", build: "201"), "0.1.0-beta.2.201")
            try expectEqual(AppVersion.display(short: "0.1.0", build: nil), "0.1.0")
            try expectEqual(AppVersion.display(short: "0.1.0", build: "abc"), "0.1.0")
            try expectEqual(AppVersion.display(short: "0.1.0.195", build: "195"), "0.1.0.195")   // not twice
            try expectEqual(AppVersion.display(short: nil, build: nil), "dev")
        },
        TestCase(name: "app.fullscreen.ai-candidate") {
            var settings = PlaylistSettings()
            settings.showClock = false
            settings.performance = .balanced
            let candidate = SceneItem(manifest: SceneManifest(id: "aurora", name: "Aurora", kind: .web),
                                      packageURL: URL(fileURLWithPath: "/tmp/ws/aurora.lpscene"), isBuiltin: false)
            let key = FullScreenPreviewRequest.candidateKey(session: "s1")
            try expect(key.contains(":"), "never a scene id (slugs have no colon)")
            // Create: the new scene alone, labelled as not in the library, with the playlist's settings.
            let create = try unwrap(FullScreenPreviewRequest.candidate(candidate, session: "s1", replacing: nil,
                                                                       available: ["a", "aurora"], playlist: settings))
            try expectEqual(create.sequence.source, .candidate)
            try expectEqual(create.sequence.ids, [key])
            try expectEqual(create.candidate(for: key)?.item, candidate)
            try expect(create.candidate(for: "aurora") == nil, "a library scene with the same id stays a library scene")
            try expectEqual(create.caption(for: key, in: create.sequence), "Not in your library yet")
            try expectEqual(create.showClock, false)
            try expectEqual(create.performance, .balanced)
            try expectEqual(create.autoAdvanceInterval, nil)
            try expectEqual(create.available(library: ["a"]), ["a", key])
            // Modify: the new version first, then the current one; ← → compare them.
            var modify = try unwrap(FullScreenPreviewRequest.candidate(candidate, session: "s1", replacing: "aurora",
                                                                       available: ["a", "aurora"], playlist: settings))
            try expectEqual(modify.sequence.ids, [key, "aurora"])
            try expectEqual(modify.sequence.current, key)
            try expectEqual(modify.caption(for: key, in: modify.sequence), "New version \u{00B7} 1 of 2")
            var stepped = modify.sequence
            stepped.step(1)
            try expectEqual(modify.caption(for: stepped.current, in: stepped), "Current version \u{00B7} 2 of 2")
            try expectEqual(FullScreenHint.text(FullScreenHint.items(canStep: true, clockOn: true, lockPreview: false, source: .candidate)),
                            "\u{2190} \u{2192} compare \u{00B7} C clock \u{00B7} L lock-screen preview \u{00B7} Esc close")
            // The scene being modified was deleted meanwhile: the candidate alone, as for create.
            modify = try unwrap(FullScreenPreviewRequest.candidate(candidate, session: "s1", replacing: "aurora",
                                                                   available: ["a"], playlist: settings))
            try expectEqual(modify.sequence.ids, [key])
            try expectEqual(modify.caption(for: key, in: modify.sequence), "Not in your library yet")
            // Deleting the current version while comparing leaves the candidate.
            var sequence = try unwrap(FullScreenPreviewRequest.candidate(candidate, session: "s1", replacing: "aurora",
                                                                         available: ["aurora"], playlist: settings)).sequence
            sequence.step(1)
            try expect(sequence.retain(available: create.available(library: [])), "the candidate is still there")
            try expectEqual(sequence.current, key)
        },
        TestCase(name: "app.fullscreen.ai-result-after-accept") {
            let playlist = PlaylistSettings()
            let result = SceneItem(manifest: SceneManifest(id: "new-scene", name: "New Scene", kind: .web),
                                   packageURL: URL(fileURLWithPath: "/tmp/ws/new-scene.lpscene"), isBuiltin: false)
            let library = ["neon-rain", "aurora"]
            let key = FullScreenPreviewRequest.candidateKey(session: "s1")
            // A scene that isn't in the library never opens the preview on another one.
            try expect(FullScreenPreviewRequest.library(start: "new-scene", visible: library, all: library, playlist: playlist) == nil)
            // Accepted, but the library hasn't reloaded yet (or the scene was deleted since): the result itself.
            let reloading = try unwrap(FullScreenPreviewRequest.aiResult(result, session: "s1", accepted: "new-scene", replacing: nil,
                                                                         visible: library, available: library, playlist: playlist))
            try expectEqual(reloading.sequence.source, .candidate)
            try expectEqual(reloading.sequence.current, key)
            try expectEqual(reloading.candidate(for: key)?.item, result)
            // Accepted and in the library: a library scene, stepping through the library.
            let added = library + ["new-scene"]
            let accepted = try unwrap(FullScreenPreviewRequest.aiResult(result, session: "s1", accepted: "new-scene", replacing: nil,
                                                                        visible: added, available: added, playlist: playlist))
            try expectEqual(accepted.sequence.source, .library)
            try expectEqual(accepted.sequence.current, "new-scene")
            try expectEqual(accepted.candidates, [])
            // Not accepted: the candidate, compared with the current version when modifying.
            let modify = try unwrap(FullScreenPreviewRequest.aiResult(result, session: "s1", accepted: nil, replacing: "aurora",
                                                                      visible: library, available: library, playlist: playlist))
            try expectEqual(modify.sequence.ids, [key, "aurora"])
        },
        TestCase(name: "app.fullscreen.follows-power-changes") {
            // The running page gets the saver's power call with the profile resolved for the new state.
            let battery = SaverPowerState(onBattery: true, lowPowerMode: false)
            let ac = SaverPowerState(onBattery: false, lowPowerMode: false)
            let onBattery = FullScreenSceneConfig.stateScript(showClock: true, lockUI: false, performance: .automatic, power: battery)
            try expect(onBattery.contains(SaverJS.power(SaverPowerUpdate(power: battery,
                                                                         profile: SaverPerformance.resolve(.automatic, power: battery, preview: false)))),
                       onBattery)
            try expect(onBattery.contains("\"fps\":30") && onBattery.contains("\"power\":\"battery\""), onBattery)
            let onAC = FullScreenSceneConfig.stateScript(showClock: true, lockUI: false, performance: .automatic, power: ac)
            try expect(onAC.contains("\"fps\":60") && onAC.contains("\"power\":\"ac\""), onAC)
            let lowPower = FullScreenSceneConfig.stateScript(showClock: true, lockUI: false, performance: .automatic,
                                                             power: SaverPowerState(onBattery: false, lowPowerMode: true))
            try expect(lowPower.contains("\"fps\":30") && lowPower.contains("\"lowPower\":true"), lowPower)
            // A fixed profile keeps its numbers; the page still learns the power state (lp.env.power).
            let best = FullScreenSceneConfig.stateScript(showClock: true, lockUI: false, performance: .best, power: battery)
            try expect(best.contains("\"fps\":60") && best.contains("\"power\":\"battery\""), best)
        },
        TestCase(name: "app.fullscreen.video-file-like-publish") {
            let package = URL(fileURLWithPath: "/tmp/lib/clip.lpscene")
            let exists: (URL) -> Bool = { _ in true }
            try expectEqual(FullScreenSceneConfig.videoFile("clip.mov", in: package, isRegularFile: exists),
                            package.appendingPathComponent("clip.mov"))
            try expectEqual(FullScreenSceneConfig.videoFile("Clip.MP4", in: package, isRegularFile: exists)?.lastPathComponent, "Clip.MP4")
            try expectEqual(FullScreenSceneConfig.videoFile("clip", in: package, isRegularFile: exists)?.lastPathComponent, "clip")
            // Untrusted scene.json: nothing outside the package, nothing hidden, nothing the saver can't play.
            for bad in [nil, "", "../../Movies/private.mov", "sub/clip.mov", "/Users/x/clip.mov", ".clip.mov", "..", "clip.avi"] {
                try expect(FullScreenSceneConfig.videoFile(bad, in: package, isRegularFile: exists) == nil, bad ?? "nil")
            }
            try expect(FullScreenSceneConfig.videoFile("clip.mov", in: package, isRegularFile: { _ in false }) == nil, "missing")
            // On disk: a regular file counts, a symlink to one doesn't.
            let dir = try tempDir("fullscreen-video")
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("clip.mov")
            try Data("x".utf8).write(to: file)
            let link = dir.appendingPathComponent("link.mov")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            try expect(FullScreenSceneConfig.videoFile("clip.mov", in: dir) != nil)
            try expect(FullScreenSceneConfig.videoFile("link.mov", in: dir) == nil, "a symlink")
            try expect(FullScreenSceneConfig.videoFile("gone.mov", in: dir) == nil, "missing")
        },
        TestCase(name: "app.fullscreen.screen-choice") {
            // Primary 1512×982 at the origin, a 2560×1440 display to its right, one above-left.
            let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
            let right = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
            let above = CGRect(x: -400, y: 982, width: 1920, height: 1080)
            let screens = [primary, right, above]
            let mouseOnPrimary = CGPoint(x: 700, y: 400)
            // The window's screen: the one it overlaps most, wherever the pointer is.
            try expectEqual(FullScreenScreenChoice.index(screens: screens, origin: .window(CGRect(x: 1300, y: 100, width: 1100, height: 700)),
                                                         pointer: mouseOnPrimary), 1)
            try expectEqual(FullScreenScreenChoice.index(screens: screens, origin: .window(CGRect(x: 100, y: 100, width: 900, height: 600)),
                                                         pointer: CGPoint(x: 2000, y: 300)), 0)
            // No window frame, or a window off every screen: the pointer decides.
            try expectEqual(FullScreenScreenChoice.index(screens: screens, origin: .window(nil), pointer: CGPoint(x: 0, y: 1500)), 2)
            try expectEqual(FullScreenScreenChoice.index(screens: screens, origin: .window(CGRect(x: 9000, y: 9000, width: 10, height: 10)),
                                                         pointer: CGPoint(x: 2000, y: 0)), 1)
            // Menu bar: the screen under the pointer, its top edge (menu bar) included; edges between screens go to one.
            try expectEqual(FullScreenScreenChoice.index(screens: screens, origin: .pointer, pointer: CGPoint(x: 3000, y: 1240)), 1)
            try expectEqual(FullScreenScreenChoice.index(screens: [primary, right], origin: .pointer, pointer: CGPoint(x: 700, y: 982)), 0)
            try expectEqual(FullScreenScreenChoice.index(screens: screens, origin: .pointer, pointer: CGPoint(x: 1512, y: 500)), 1)
            // Off every screen: the nearest; no screens at all: nothing.
            try expectEqual(FullScreenScreenChoice.index(screens: screens, origin: .pointer, pointer: CGPoint(x: 5000, y: 0)), 1)
            try expectEqual(FullScreenScreenChoice.index(screens: [], origin: .pointer, pointer: .zero), nil)
            try expectEqual(FullScreenScreenChoice.index(screens: [primary], origin: .window(nil), pointer: CGPoint(x: -50, y: -50)), 0)
        },
        TestCase(name: "app.fullscreen.renders-like-the-saver") {
            let battery = SaverPowerState(onBattery: true, lowPowerMode: false)
            let ac = SaverPowerState(onBattery: false, lowPowerMode: false)
            // Byte for byte what WebSceneHost injects: SaverWebConfig + the lock-UI line.
            let profile = SaverPerformance.resolve(.automatic, power: battery, preview: false)
            let saver = SaverWebConfig(showClock: true, clockPosition: .bottomLeft, profile: profile, seed: 42, power: battery)
            try expectEqual(FullScreenSceneConfig.webConfigScript(showClock: true, clockPosition: .bottomLeft, performance: .automatic,
                                                                  power: battery, seed: 42, lockUI: false),
                            saver.userScript + "window.LIVEPAPER_CONFIG.lockUI = false;")
            func config(_ script: String) throws -> [String: Any] {
                let json = try unwrap(script.split(separator: ";").first?.split(separator: "=", maxSplits: 1).last)
                return try unwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            }
            let onBattery = try config(FullScreenSceneConfig.webConfigScript(showClock: false, clockPosition: .top, performance: .automatic,
                                                                             power: battery, seed: 7, lockUI: true))
            try expectEqual(onBattery["fps"] as? Int, 30)
            try expectEqual(onBattery["scale"] as? Double, 0.75)
            try expectEqual(onBattery["clock"] as? Bool, false)
            try expectEqual(onBattery["clockPosition"] as? String, "top")
            try expectEqual(onBattery["power"] as? String, "battery")
            try expect(onBattery["preview"] == nil, "full screen is not a small preview (lp.env.preview stays false)")
            let best = try config(FullScreenSceneConfig.webConfigScript(showClock: true, clockPosition: .none, performance: .best,
                                                                        power: battery, seed: 7, lockUI: false))
            try expectEqual(best["fps"] as? Int, 60)
            try expectEqual(best["scale"] as? Double, 1)
            try expectEqual(best["clockPosition"] as? String, "none")
            let balanced = try config(FullScreenSceneConfig.webConfigScript(showClock: true, clockPosition: .top, performance: .balanced,
                                                                            power: ac, seed: 7, lockUI: false))
            try expectEqual(balanced["fps"] as? Int, 60)
            try expectEqual(balanced["scale"] as? Double, 0.75)
            // C and L reach a running page through guarded host calls.
            let state = FullScreenSceneConfig.stateScript(showClock: false, lockUI: true, performance: .automatic, power: ac)
            try expect(state.contains("h.config({\"clock\":false})"), state)
            try expect(state.contains(SaverJS.lockUI(true)), state)
            try expect(FullScreenSceneConfig.nativeClockVisible(showClock: true, lockUI: false))
            try expect(!FullScreenSceneConfig.nativeClockVisible(showClock: true, lockUI: true), "the lock UI hides the video clock")
            try expect(!FullScreenSceneConfig.nativeClockVisible(showClock: false, lockUI: false))
            for _ in 0..<50 { try expect((1...100_000).contains(FullScreenSceneConfig.randomSeed())) }
        },
    ] }

    // MARK: - AppModel with mock services

    static var appModel: [TestCase] { [
        TestCase(name: "app.model.start") {
            try withModel("start") { model, _ in
                try expectEqual(model.entries.count, MockSampleData.samples().count)
                try expect(!model.entries[0].item.isBuiltin, "user scenes first")
                try expectEqual(model.entry(id: "neon-rain")?.badge, .ai)
                try expectEqual(model.entry(id: "aurora-lake")?.badge, .web)
                try expectEqual(model.entry(id: "tidal-glass")?.energy, .high)
                try expectEqual(model.harnesses.count, 3)
                try expectEqual(model.preferredHarness?.kind, .claude)
                try expect(model.showOnboarding, "first launch shows onboarding")
                try expect(model.isInPlaylist("aurora-lake"), "all scenes by default")
            }
        },
        TestCase(name: "app.model.playlist-publish") {
            try withModel("publish") { model, _ in
                try awaitMain { await model.useAsScreenSaver("paper-lanterns") }
                try expectEqual(model.playlist.mode, .single)
                try expectEqual(model.lastPublished?.scenes.map(\.id), ["paper-lanterns"])
                try expect(!model.isInPlaylist("neon-rain"))
                try expectEqual(model.playlistSummary, "Paper Lanterns")
                try awaitMain { await model.addToPlaylist("neon-rain") }
                try expectEqual(model.playlist.mode, .sequence)
                try expectEqual(model.playlist.sceneIDs, ["paper-lanterns", "neon-rain"])
                try expect(model.canAdvanceScene)
                try awaitMain { await model.advanceScene() }
                try expectEqual(model.playlist.sceneIDs, ["neon-rain", "paper-lanterns"])
                try awaitMain { await model.addToPlaylist("neon-rain") }
                try expect(model.banners.banners.contains { $0.style == .info && $0.title.contains("already") })
                try awaitMain { await model.setPerformance(.battery) }
                try expectEqual(model.lastPublished?.performance, .battery)
            }
        },
        TestCase(name: "app.model.playlist-store-only") {
            try withModel("store-only") { model, fx in
                var ok = false
                try awaitMain { ok = await model.savePlaylist(PlaylistSettings(mode: .single, sceneIDs: ["ink-bloom"]),
                                                              announce: false, publishNow: false) }
                try expect(ok)
                try expectEqual(model.playlist.sceneIDs, ["ink-bloom"])
                try expect(model.lastPublished == nil, "nothing published without a saver")
                try expectEqual(fx.services.publish.loadSettings().sceneIDs, ["ink-bloom"])
            }
        },
        TestCase(name: "app.model.publish-failure-banner") {
            try withModel("publish-fail") { model, fx in
                let publish = try unwrap(fx.services.publish as? MockPublishService)
                try fx.services.install.installSaver()
                publish.failNextPublish = true
                var ok = true
                try awaitMain { ok = await model.savePlaylist(PlaylistSettings(mode: .sequence)) }
                try expect(!ok)
                try expect(!model.isPublishing)
                try expectEqual(model.playlist, PlaylistSettings()) // unchanged on failure
                // … and so are the stored settings: the saver still plays the previous playlist, and
                // nothing (the disk watcher, the CLI) may take the failed draft for the current one.
                try expectEqual(fx.services.publish.loadSettings(), PlaylistSettings())
                let banner = try unwrap(model.banners.banners.last)
                try expectEqual(banner.style, .error)
                try expectEqual(banner.actions.map(\.title), ["Try Again"])
                banner.actions[0].perform()
                try awaitMain(until: { model.playlist.mode == .sequence })
                try expectEqual(fx.services.publish.loadSettings().mode, .sequence)
            }
        },
        TestCase(name: "app.model.publish-without-saver") {
            try withModel("publish-nosaver") { model, fx in
                let publish = try unwrap(fx.services.publish as? MockPublishService)
                publish.failNextPublish = true
                try awaitMain { _ = await model.savePlaylist(PlaylistSettings(mode: .sequence)) }
                let banner = try unwrap(model.banners.banners.last)
                try expectEqual(banner.actions.map(\.title), ["Set Up\u{2026}"])
                model.showOnboarding = false
                banner.actions[0].perform()
                try expect(model.showOnboarding)
            }
        },
        TestCase(name: "app.model.clone-delete") {
            try withModel("clone") { model, _ in
                var copy: SceneItem?
                try awaitMain { copy = await model.clone("aurora-lake", name: "Aurora Lake copy") }
                let item = try unwrap(copy)
                try expectEqual(item.manifest.parent, "aurora-lake")
                try expect(model.entry(id: item.id)?.item.isBuiltin == false)
                try awaitMain { await model.useAsScreenSaver(item.id) }
                try awaitMain { await model.addToPlaylist("neon-rain") }
                try awaitMain { await model.delete(item.id) }
                try expect(model.entry(id: item.id) == nil)
                try expectEqual(model.playlist.sceneIDs, ["neon-rain"]) // the deleted scene left the playlist
                try awaitMain { await model.delete("aurora-lake") }
                try expect(model.banners.banners.contains { $0.style == .error }, "built-ins can't be deleted")
            }
        },
        TestCase(name: "app.model.open-package-already-imported") {
            try withModel("open-package") { model, fx in
                var copy: SceneItem?
                try awaitMain { copy = await model.clone("aurora-lake", name: "Lake") }
                let item = try unwrap(copy)
                let exported = fx.root.appendingPathComponent("Downloads/lake.lpscene")
                try FileManager.default.createDirectory(at: exported.deletingLastPathComponent(), withIntermediateDirectories: true)
                try awaitMain { await model.export(item.id, to: exported) }
                let before = model.entries.count
                // Double-clicking the same scene (a copy, or the library's own package) opens it.
                for url in [exported, item.packageURL] {
                    model.libraryPath = []
                    model.section = .playlist
                    try awaitMain { await model.openScenePackage(at: url) }
                    try expectEqual(model.entries.count, before)
                    try expectEqual(model.section, .library)
                    try expectEqual(model.libraryPath, [item.id])
                    try expect(model.banners.banners.last?.title.contains("already in your library") == true)
                }
                // A different version of it: shown, with Replace and Import as a Copy.
                let js = exported.appendingPathComponent("scene.js")
                try Data("// edited elsewhere\n".utf8).write(to: js)
                model.libraryPath = []
                try awaitMain { await model.openScenePackage(at: exported) }
                try expectEqual(model.entries.count, before)
                try expectEqual(model.libraryPath, [item.id])
                let banner = try unwrap(model.banners.banners.last)
                try expectEqual(banner.style, .warning)
                try expectEqual(banner.actions.map(\.title), ["Replace with This Version", "Import as a Copy"])
                // Replace: the scene is in the screen saver's playlist, so the saver gets the new version.
                let install = try unwrap(fx.services.install as? MockInstallService)
                try install.installSaver()
                try awaitMain { await model.refreshInstallStatus() }
                try awaitMain { await model.useAsScreenSaver(item.id) }
                let published = try unwrap(model.lastPublished?.generation)
                try awaitMain { await model.replaceScene(item.id, with: exported) }
                try expectEqual(model.entries.count, before)
                try expectEqual(String(decoding: try Data(contentsOf: item.packageURL.appendingPathComponent("scene.js")), as: UTF8.self),
                                "// edited elsewhere\n")
                try expect((model.lastPublished?.generation ?? 0) > published, "republished after Replace")
                // Now identical again: it just opens.
                try awaitMain { await model.openScenePackage(at: exported) }
                try expectEqual(model.entries.count, before)
                // A new scene still imports.
                try Data("// another scene\n".utf8).write(to: js)
                var m = try SceneManifest.load(package: exported)
                m.id = "brand-new"; m.name = "Brand New"
                try m.write(package: exported)
                try awaitMain { await model.openScenePackage(at: exported) }
                try expectEqual(model.entries.count, before + 1)
                try expect(model.entry(id: "brand-new") != nil, "imported")
                // Another scene that only shares the id (someone else's "Lake") is imported as a copy.
                try Data("// someone else's lake\n".utf8).write(to: js)
                m = try SceneManifest.load(package: exported)
                m.id = item.id; m.name = "Lake"; m.created = Date(timeIntervalSince1970: 1_700_000_000)
                try m.write(package: exported)
                try awaitMain { await model.openScenePackage(at: exported) }
                try expectEqual(model.entries.count, before + 2)
                try expectEqual(model.banners.banners.last?.title, "Imported \u{201C}Lake\u{201D}")
            }
        },
        TestCase(name: "app.model.open-package-twice-at-once") {
            // Two copies of a new scene opened together (or a second double-click while the first
            // import is still copying): imported once, the other open shows it.
            try withModel("open-package-twice") { model, fx in
                let downloads = fx.root.appendingPathComponent("Downloads")
                try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
                let first = downloads.appendingPathComponent("comet.lpscene"), second = downloads.appendingPathComponent("comet 2.lpscene")
                try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
                try SceneManifest(id: "comet", name: "Comet", kind: .web).write(package: first)
                try Data("// comet\n".utf8).write(to: first.appendingPathComponent("scene.js"))
                try FileManager.default.copyItem(at: first, to: second)
                let before = model.entries.count
                try awaitMain {
                    async let a: Void = model.openScenePackage(at: first)
                    async let b: Void = model.openScenePackage(at: second)
                    _ = await (a, b)
                }
                try expectEqual(model.entries.count, before + 1)
                try expect(model.entry(id: "comet") != nil && model.entry(id: "comet-2") == nil, model.entries.map(\.id).joined(separator: ", "))
                try expect(model.banners.banners.contains { $0.title.contains("already in your library") })
            }
        },
        TestCase(name: "app.model.lock-settings") {
            try withModel("lock") { model, fx in
                let saved = fx.saved
                model.updateLock { $0.hotkey = LPHotkey(keyCode: 37, modifiers: [.option, .command]) }
                model.updateLock { $0.hotkey = LPHotkey(keyCode: 37, modifiers: [.option, .command]) } // unchanged: not saved
                try expectEqual(saved.count, 1)
                try expectEqual(model.sharedState.lock.hotkey?.modifiers, [.option, .command])
                // The lock keys go through InstallServicing; state.json mirrors the result.
                try expect(!model.lockKeysShowScene)
                try awaitMain { await model.setLockKeysShowScene(true) }
                try expect(model.lockKeysShowScene)
                try expect(fx.services.install.status().lockKeysShowScene, "changed through the install service")
                try expectEqual(saved.last?.lock.lockKeysShowScene, true)
                try expect(model.uninstallPlan(keepScenes: true).items.contains { $0.id == "lock-keys" })
                var report: UninstallReport?
                try awaitMain { report = await model.uninstall(keepScenes: true) }
                try expect(report?.succeeded == true)
                try expect(report?.rows.contains { $0.title == InstallService.restoreLockKeysTitle && $0.state == .done } == true)
                try expect(!model.lockKeysShowScene, "uninstall restored the lock keys")
                try expectEqual(saved.last?.lock.lockKeysShowScene, false)
                try expect(!model.uninstallPlan(keepScenes: true).items.contains { $0.id == "lock-keys" })
            }
        },
        TestCase(name: "app.model.lock-keys-real-install") {
            // The bug this guards against: the app kept its own backup of the lock-keys preference,
            // which uninstall never restored. Now the app only talks to InstallService.
            try withScratchPaths("lock-real") { root in
                let prefs = ScratchPreferences()
                let paths = InstallPaths(saverTemplate: root.appendingPathComponent("missing.saver"),
                                         screenSaversDir: root.appendingPathComponent("Screen Savers"),
                                         launchAgentsDir: root.appendingPathComponent("LaunchAgents"),
                                         wallpaperStore: root.appendingPathComponent("Wallpaper/Index.plist"),
                                         supportRoot: root.appendingPathComponent("Support"),
                                         helperExecutable: root.appendingPathComponent("Helpers/LivePaperHelper"), managedPreferences: [])
                let runner = RecordingCommandRunner { exe, args in
                    exe == "/bin/launchctl" && args.first == "print" ? CommandResult(status: 113) : nil
                }
                let install = InstallService(paths: paths, publisher: nil, runner: runner, loginItem: NoLoginItem(), preferences: prefs)
                let mock = try MockServices.make(root: root.appendingPathComponent("Mock"), pace: 0)
                let services = LivePaperServices(library: mock.library, publish: mock.publish, ai: mock.ai, install: install,
                                                 render: mock.render, checker: mock.checker, compiler: mock.compiler)
                let key = "com.apple.loginwindow|immediateLockLaunchesScreenSaver"
                try MainActor.assumeIsolated {
                    let model = AppModel(services: services, environment: testEnvironment(root: root, saved: SavedStates()))
                    try awaitMain { await model.start() }
                    try awaitMain { await model.setLockKeysShowScene(true) }
                    try expectEqual(prefs.values[key] as? Bool, true)
                    try expect(model.lockKeysShowScene && model.installStatus.lockKeysChangedByLivePaper)
                    try expect(!FileManager.default.fileExists(atPath: paths.backups.appendingPathComponent("loginwindow-lock.json").path),
                               "no second backup location")
                    var report: UninstallReport?
                    try awaitMain { report = await model.uninstall(keepScenes: true) }
                    try expect(report?.succeeded == true, "\(report?.failures ?? [])")
                    try expect(prefs.values[key] == nil, "restored: the key didn't exist before LivePaper")
                    try expect(!model.lockKeysShowScene)
                    try expect(runner.commands.allSatisfy { $0.first != "/usr/bin/open" }, "nothing opened")
                }
            }
        },
        TestCase(name: "app.model.onboarding-install") {
            try withModel("install") { model, _ in
                var selected = true
                try awaitMain { selected = await model.makeLivePaperScreenSaver() }
                try expect(!selected, "mock asks for the guided step first")
                try expect(model.installStatus.saverInstalled && !model.installStatus.saverSelected)
                model.openScreenSaverSettings()
                try awaitMain { await model.refreshInstallStatus() }
                try expect(model.installStatus.saverSelected)
                try awaitMain { await model.registerHelper() }
                try expect(model.installStatus.helperRunning)
                try expectEqual(SetupChecklist.firstIncompleteStep(state: model.setupState), .lock)
                try awaitMain { await model.setLockKeysShowScene(true) }
                try expectEqual(SetupChecklist.firstIncompleteStep(state: model.setupState), .firstScene)
                model.completeOnboarding()
                try expect(model.hasCompletedOnboarding && !model.showOnboarding)
                var report: UninstallReport?
                try awaitMain { report = await model.uninstall(keepScenes: true) }
                try expectEqual(report?.rows.map(\.state), [.done, .done, .done, .done, .done])
                try expect(!model.hasCompletedOnboarding)
                try expect(!model.installStatus.saverInstalled && !model.installStatus.helperRunning)
            }
        },
        TestCase(name: "app.model.saver-update-on-launch") {
            // Launch replaces only an older installed saver, never while the Mac is locked.
            let outdated = InstallStatus(saverInstalled: true, saverUpToDate: false)
            try withInstallModel("update-locked", status: outdated, locked: true) { model, install, lock in
                try expectEqual(install.installCount, 0)
                try expect(install.updateCalls == 0, "the model itself doesn't start an update while locked")
                try expect(model.installStatus.saverUpdateAvailable, "still to do")
                lock.isLocked = false
                try awaitMain { await model.updateInstalledSaverIfNeeded() }
                try expectEqual(install.installCount, 1)
                try expect(model.installStatus.saverUpToDate && !model.isInstallBusy, "status refreshed afterwards")
                try awaitMain { await model.updateInstalledSaverIfNeeded() }
                try expectEqual(install.installCount, 1)
            }
            try withInstallModel("update-now", status: outdated, locked: false) { model, install, _ in
                try expectEqual(install.installCount, 1)
                try expect(model.installStatus.saverUpToDate)
            }
            // A newer build (another copy of LivePaper installed it) stays; so does no saver at all.
            try withInstallModel("update-newer", status: InstallStatus(saverInstalled: true, saverNewerInstalled: true), locked: false) { model, install, _ in
                try expectEqual(install.installCount, 0)
                try expect(model.installStatus.saverNewerInstalled && !model.installStatus.saverUpdateAvailable)
            }
            try withInstallModel("update-none", status: InstallStatus(), locked: false) { _, install, _ in
                try expectEqual(install.installCount, 0)
            }
        },
        TestCase(name: "app.model.saver-update-after-unlock") {
            // Locked at launch: the update waits for the unlock, runs once then, and stops listening.
            let outdated = InstallStatus(saverInstalled: true, saverUpToDate: false)
            let unlock = UnlockSource()
            try withInstallModel("update-after-unlock", status: outdated, locked: true,
                                 configure: { env in env.observeUnlock = { unlock.observe($0) } }) { model, install, lock in
                try expect(model.isSaverUpdateWaitingForUnlock && unlock.isObserving, "waits for the unlock")
                try expectEqual(install.updateCalls, 0)
                try expectEqual(unlock.observeCount, 1)
                // An unlock that finds the Mac locked again (a quick re-lock) waits for the next one.
                unlock.fire()
                try awaitMain(until: { unlock.observeCount == 2 && model.isSaverUpdateWaitingForUnlock })
                try expectEqual(install.updateCalls, 0)
                lock.isLocked = false
                unlock.fire()
                try awaitMain(until: { install.installCount == 1 && !model.isInstallBusy })
                try expect(!model.isSaverUpdateWaitingForUnlock && !unlock.isObserving, "stopped listening")
                try expect(model.installStatus.saverUpToDate)
                unlock.fire()   // nobody listens any more
                pumpMain(0.2)
                try expectEqual(install.updateCalls, 1)
                try expectEqual(unlock.observeCount, 2)
            }
            // Nothing to update: nothing to wait for.
            try withInstallModel("update-locked-none", status: InstallStatus(saverInstalled: true, saverUpToDate: true), locked: true,
                                 configure: { env in env.observeUnlock = { unlock.observe($0) } }) { model, _, _ in
                try expect(!model.isSaverUpdateWaitingForUnlock)
            }
            // Uninstalling stops the wait (the update would put back what it removes).
            let unlock2 = UnlockSource()
            try withInstallModel("update-locked-uninstall", status: outdated, locked: true,
                                 configure: { env in env.observeUnlock = { unlock2.observe($0) } }) { model, install, lock in
                try expect(unlock2.isObserving)
                try awaitMain { _ = await model.uninstall(keepScenes: true) }
                try expect(!unlock2.isObserving && !model.isSaverUpdateWaitingForUnlock)
                lock.isLocked = false
                unlock2.fire()
                pumpMain(0.2)
                try expectEqual(install.updateCalls, 0)
            }
        },
        TestCase(name: "app.model.helper-repair") {
            // After an update launchd can't start the helper although its login item is enabled: the
            // app registers it again by itself — once per launch, quietly when that works.
            let broken = InstallStatus(helperLoginItem: .enabled, helperProblem: .cannotStart("spawn failed, last exit code 78: EX_CONFIG"))
            try withInstallModel("helper-repair", status: broken, locked: false) { model, install, _ in
                try awaitMain { await model.awaitHelperRepair() }
                try expectEqual(install.recoverCalls, 1)
                try expect(model.installStatus.helperRunning && model.installStatus.helperProblem == nil, "\(model.installStatus)")
                try expect(model.banners.banners.isEmpty, "a repair that worked is quiet")
                try expect(model.helperRepairAttempted && !model.isInstallBusy)
                // It breaks again later: no second automatic attempt; "Repair Helper" is the user's.
                install.simulateHelperCannotStart()
                try awaitMain { await model.refreshInstallStatus() }
                try awaitMain { await model.awaitHelperRepair() }
                try expectEqual(install.recoverCalls, 1)
                try expect(model.setupState.helperCannotStart)
                try awaitMain { await model.registerHelper() }
                try expectEqual(install.registerCalls, 1)
                try expect(model.installStatus.helperRunning)
                try expectEqual(install.recoverCalls, 1)
            }
            // macOS asks for approval after the new registration: the banner says where.
            let opened = OpenCount()
            try withInstallModel("helper-repair-approval", status: broken, locked: false,
                                 prepare: { $0.recoveryBehaviour = .needsApproval },
                                 configure: { env in env.openLoginItemsSettings = { opened.count += 1 } }) { model, _, _ in
                try awaitMain { await model.awaitHelperRepair() }
                try expect(model.setupState.helperNeedsApproval)
                let banner = try unwrap(model.banners.banners.last)
                try expect(banner.style == .warning && banner.title.contains("Allow"), banner.title)
                try expectEqual(banner.actions.map(\.title), ["Open Login Items"])
                banner.actions[0].perform()
                try expectEqual(opened.count, 1)
            }
            // A repair that fails says so, and Try Again is the user's attempt.
            try withInstallModel("helper-repair-fails", status: broken, locked: false,
                                 prepare: { $0.recoveryBehaviour = .fails("spawn failed") }) { model, install, _ in
                try awaitMain { await model.awaitHelperRepair() }
                let banner = try unwrap(model.banners.banners.last)
                try expect(banner.style == .error && banner.message?.contains("spawn failed") == true, banner.message ?? "")
                try expectEqual(banner.actions.map(\.title), ["Try Again"])
                banner.actions[0].perform()
                try awaitMain(until: { install.registerCalls == 1 && !model.isInstallBusy })
                try expect(model.installStatus.helperRunning)
                try expectEqual(install.recoverCalls, 1)
            }
            // Nothing set up, or waiting for approval: nothing to repair, nothing tried.
            for status in [InstallStatus(), InstallStatus(helperLoginItem: .requiresApproval)] {
                try withInstallModel("helper-repair-none", status: status, locked: false) { model, install, _ in
                    try awaitMain { await model.awaitHelperRepair() }
                    try expectEqual(install.recoverCalls, 0)
                    try expect(!model.helperRepairAttempted)
                }
            }
        },
        TestCase(name: "app.model.helper-repair-banners") {
            // The repair's banners go once a status read shows the helper running: the user allowed
            // it in Login Items, or a later attempt worked.
            let broken = InstallStatus(helperLoginItem: .enabled, helperProblem: .cannotStart("spawn failed, last exit code 78: EX_CONFIG"))
            try withInstallModel("helper-banners-approval", status: broken, locked: false,
                                 prepare: { $0.recoveryBehaviour = .needsApproval }) { model, install, _ in
                try awaitMain { await model.awaitHelperRepair() }
                try expect(model.banners.banners.contains { $0.title.contains("Allow") })
                try awaitMain { await model.refreshInstallStatus() }
                try expect(model.banners.banners.contains { $0.title.contains("Allow") }, "still waiting for approval")
                try install.registerHelper()   // the user allowed it; the helper runs
                try awaitMain { await model.refreshInstallStatus() }
                try expect(model.banners.banners.isEmpty, "\(model.banners.banners.map(\.title))")
            }
            try withInstallModel("helper-banners-error", status: broken, locked: false,
                                 prepare: { $0.recoveryBehaviour = .fails("spawn failed") }) { model, install, _ in
                try awaitMain { await model.awaitHelperRepair() }
                try expect(model.banners.banners.contains { $0.style == .error })
                try install.registerHelper()
                try awaitMain { await model.refreshInstallStatus() }
                try expect(model.banners.banners.isEmpty, "\(model.banners.banners.map(\.title))")
            }
            // Another copy's helper runs: reported only; no repair is attempted (and none used up).
            try withInstallModel("helper-other-copy", status: InstallStatus(helperRunning: true, helperLoginItem: .enabled,
                                                                            helperProblem: .otherCopy("/Users/me/Downloads/LivePaper.app")),
                                 locked: false) { model, install, _ in
                try awaitMain { await model.awaitHelperRepair() }
                try expect(install.recoverCalls == 0 && !model.helperRepairAttempted)
            }
        },
        TestCase(name: "app.model.helper-repair-before-uninstall") {
            // Uninstall waits for an automatic repair that is still running (it would register the
            // helper again), and no repair runs after it.
            try withScratchPaths("repair-uninstall") { root in
                let mocks = try MockServices.make(root: root.appendingPathComponent("Mock"), pace: 0)
                let base = MockInstallService(status: InstallStatus(helperLoginItem: .enabled, helperProblem: .cannotStart("spawn failed")))
                let gated = GatedInstall(base: base)
                gated.holdsRepairs = true
                let services = LivePaperServices(library: mocks.library, publish: mocks.publish, ai: mocks.ai, install: gated,
                                                 render: mocks.render, checker: mocks.checker, compiler: mocks.compiler)
                try MainActor.assumeIsolated {
                    let model = AppModel(services: services, environment: testEnvironment(root: root, saved: SavedStates()))
                    Task { @MainActor in await model.start() }
                    try awaitMain(until: { gated.isRepairing })
                    try expect(model.isInstallBusy, "the repair counts as install work")
                    let reports = WatchLog<UninstallReport>()
                    Task { @MainActor in reports.append(await model.uninstall(keepScenes: true)) }
                    pumpMain(0.3)
                    try expectEqual(gated.events, ["recover"])
                    gated.releaseRepair()
                    try awaitMain(until: { !reports.values.isEmpty })
                    try expectEqual(gated.events, ["recover", "recovered", "uninstall"])
                    // A status read that shows a problem after the uninstall starts nothing.
                    base.simulateHelperCannotStart()
                    try awaitMain { await model.refreshInstallStatus() }
                    try awaitMain { await model.awaitHelperRepair() }
                    try expectEqual(gated.events, ["recover", "recovered", "uninstall"])
                    try expectEqual(base.registerCalls, 0)
                    try expect(!model.isInstallBusy)
                }
            }
        },
        TestCase(name: "app.model.helper-repair-after-install-work") {
            // A helper problem that shows while other install work runs (here the launch-time saver
            // update) is repaired as soon as that work ends, not at some later status read.
            try withScratchPaths("repair-after-update") { root in
                let mocks = try MockServices.make(root: root.appendingPathComponent("Mock"), pace: 0)
                let base = MockInstallService(status: InstallStatus(saverInstalled: true, saverUpToDate: false, helperRunning: true,
                                                                    helperLoginItem: .enabled))
                let gated = GatedInstall(base: base)
                let services = LivePaperServices(library: mocks.library, publish: mocks.publish, ai: mocks.ai, install: gated,
                                                 render: mocks.render, checker: mocks.checker, compiler: mocks.compiler)
                try MainActor.assumeIsolated {
                    let model = AppModel(services: services, environment: testEnvironment(root: root, saved: SavedStates()))
                    let started = WatchLog<Bool>()
                    Task { @MainActor in await model.start(); started.append(true) }
                    try awaitMain(until: { gated.isHolding })
                    base.simulateHelperCannotStart()
                    try awaitMain { await model.refreshInstallStatus() }
                    try expect(model.installStatus.helperProblem != nil)
                    try expect(base.recoverCalls == 0 && !model.helperRepairAttempted, "held back while the update runs")
                    gated.release()
                    try awaitMain(until: { !started.values.isEmpty && base.recoverCalls == 1 && !model.isInstallBusy })
                    try expectEqual(gated.events, ["update", "updated", "recover", "recovered"])
                    try expect(model.installStatus.helperRunning && model.installStatus.helperProblem == nil, "\(model.installStatus)")
                }
            }
        },
        TestCase(name: "app.model.saver-update-unlock-uninstall") {
            // Uninstall right after an unlock: the update the unlock sets off (once it has re-read the
            // status, which takes a moment) must neither run alongside the uninstall nor after it.
            try withScratchPaths("unlock-uninstall") { root in
                let mocks = try MockServices.make(root: root.appendingPathComponent("Mock"), pace: 0)
                let base = MockInstallService(status: InstallStatus(saverInstalled: true, saverUpToDate: false))
                let gated = GatedInstall(base: base)
                let services = LivePaperServices(library: mocks.library, publish: mocks.publish, ai: mocks.ai, install: gated,
                                                 render: mocks.render, checker: mocks.checker, compiler: mocks.compiler)
                let unlock = UnlockSource()
                let lock = LockFlag(true)
                defer { for _ in 0..<3 { gated.release() } }   // never leave an update thread waiting
                try MainActor.assumeIsolated {
                    var env = testEnvironment(root: root, saved: SavedStates())
                    env.isSessionLocked = { lock.isLocked }
                    env.observeUnlock = { unlock.observe($0) }
                    let model = AppModel(services: services, environment: env)
                    try awaitMain { await model.start() }
                    try expect(model.isSaverUpdateWaitingForUnlock)
                    lock.isLocked = false
                    gated.holdStatusReads()
                    unlock.fire()
                    try awaitMain(until: { gated.isHoldingStatusRead })
                    let reports = WatchLog<UninstallReport>()
                    Task { @MainActor in reports.append(await model.uninstall(keepScenes: true)) }
                    pumpMain(0.3)
                    try expect(reports.values.isEmpty && !gated.events.contains("uninstall"), "uninstall waits for what the unlock started")
                    gated.releaseStatus()
                    try awaitMain(until: { !reports.values.isEmpty })
                    pumpMain(0.2)
                    try expectEqual(gated.events, ["uninstall"])
                    try expectEqual(base.updateCalls, 0)
                    try expect(!model.isInstallBusy && !model.isSaverUpdateWaitingForUnlock)
                }
            }
        },
        TestCase(name: "app.model.saver-update-before-uninstall") {
            // Uninstall (and setup) wait for a launch-time update that is still running: it would
            // otherwise put back what uninstall removes.
            try withScratchPaths("update-uninstall") { root in
                let mocks = try MockServices.make(root: root.appendingPathComponent("Mock"), pace: 0)
                let gated = GatedInstall(base: MockInstallService(status: InstallStatus(saverInstalled: true, saverUpToDate: false)))
                let services = LivePaperServices(library: mocks.library, publish: mocks.publish, ai: mocks.ai, install: gated,
                                                 render: mocks.render, checker: mocks.checker, compiler: mocks.compiler)
                try MainActor.assumeIsolated {
                    let model = AppModel(services: services, environment: testEnvironment(root: root, saved: SavedStates()))
                    let started = WatchLog<Bool>()
                    Task { @MainActor in await model.start(); started.append(true) }
                    try awaitMain(until: { gated.isHolding })
                    try expect(model.isInstallBusy, "the update counts as install work")
                    let reports = WatchLog<UninstallReport>()
                    Task { @MainActor in reports.append(await model.uninstall(keepScenes: true)) }
                    pumpMain(0.3)
                    try expectEqual(gated.events, ["update"])
                    gated.release()
                    try awaitMain(until: { !reports.values.isEmpty && !started.values.isEmpty })
                    try expectEqual(gated.events, ["update", "updated", "uninstall"])
                    try expect(!model.isInstallBusy)
                }
            }
        },
        TestCase(name: "app.model.saver-update-locked-while-waiting") {
            // The Mac locks after the launch-time update started but before the swap (it waits on
            // publish.lock): the model hands its own lock probe to the service, which checks it again
            // right before the swap, so the bundle under the running lock screen stays.
            try withScratchPaths("update-locks-late") { root in
                let mocks = try MockServices.make(root: root.appendingPathComponent("Mock"), pace: 0)
                let base = MockInstallService(status: InstallStatus(saverInstalled: true, saverUpToDate: false))
                let gated = GatedInstall(base: base)
                let services = LivePaperServices(library: mocks.library, publish: mocks.publish, ai: mocks.ai, install: gated,
                                                 render: mocks.render, checker: mocks.checker, compiler: mocks.compiler)
                let lock = LockFlag(false)
                try MainActor.assumeIsolated {
                    var env = testEnvironment(root: root, saved: SavedStates())
                    env.isSessionLocked = { lock.isLocked }
                    let model = AppModel(services: services, environment: env)
                    let started = WatchLog<Bool>()
                    Task { @MainActor in await model.start(); started.append(true) }
                    try awaitMain(until: { gated.isHolding })
                    lock.isLocked = true
                    gated.release()
                    try awaitMain(until: { !started.values.isEmpty })
                    try expect(gated.lockProbes == [true], "the service sees the model's lock probe: \(gated.lockProbes)")
                    try expectEqual(base.installCount, 0)
                    try expect(!model.installStatus.saverUpToDate && model.installStatus.saverUpdateAvailable, "still to do")
                    try expect(!model.isInstallBusy)
                    try expect(model.isSaverUpdateWaitingForUnlock, "tries again after the unlock")
                    // Unlocked again, the next update goes ahead.
                    lock.isLocked = false
                    gated.release()
                    try awaitMain { await model.updateInstalledSaverIfNeeded() }
                    try expectEqual(gated.lockProbes, [true, false])
                    try expectEqual(base.installCount, 1)
                    try expect(model.installStatus.saverUpToDate)
                }
            }
        },
        TestCase(name: "app.model.saver-update-reports-skipped") {
            // The update republishes from the current settings and library; scenes that can't be
            // published any more are shown like after any publish, not just logged.
            try withScratchPaths("update-report") { root in
                let paths = InstallPaths(saverTemplate: root.appendingPathComponent("App/LivePaper.saver"),
                                         screenSaversDir: root.appendingPathComponent("Screen Savers"),
                                         launchAgentsDir: root.appendingPathComponent("LaunchAgents"),
                                         wallpaperStore: root.appendingPathComponent("Wallpaper/Index.plist"),
                                         supportRoot: root.appendingPathComponent("Support"),
                                         helperExecutable: root.appendingPathComponent("Helpers/LivePaperHelper"), managedPreferences: [])
                func bundle(_ version: String, at url: URL) throws {
                    try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
                    try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": version], format: .xml, options: 0)
                        .write(to: url.appendingPathComponent("Contents/Info.plist"))
                }
                try bundle("2", at: paths.saverTemplate)
                try bundle("1", at: paths.installedSaver)
                let runner = RecordingCommandRunner { exe, args in
                    exe == "/bin/launchctl" && args.first == "print" ? CommandResult(status: 113) : nil
                }
                let mocks = try MockServices.make(root: root.appendingPathComponent("Mock"), pace: 0)
                let publish = try unwrap(mocks.publish as? MockPublishService)
                publish.simulatedSkips = ["neon-rain": "neon-rain has a syntax error on line 3."]
                let install = InstallService(paths: paths, publisher: publish, runner: runner, loginItem: NoLoginItem(), preferences: ScratchPreferences())
                let services = LivePaperServices(library: mocks.library, publish: publish, ai: mocks.ai, install: install,
                                                 render: mocks.render, checker: mocks.checker, compiler: mocks.compiler)
                try MainActor.assumeIsolated {
                    let model = AppModel(services: services, environment: testEnvironment(root: root, saved: SavedStates()))
                    try awaitMain { await model.start() }
                    try expect(model.installStatus.saverUpToDate, "\(model.installStatus)")
                    try expectEqual(model.lastPublishResult?.skippedScenes.map(\.id), ["neon-rain"])
                    let banner = try unwrap(model.banners.banners.last { $0.style == .warning })
                    try expect(banner.title.contains("left out") && banner.message?.contains("Neon Rain") == true, banner.message ?? "")
                    try expect(runner.commands.allSatisfy { $0.first != "/usr/bin/open" && $0.first != "/usr/bin/killall" }, "\(runner.commands)")
                }
            }
        },
        TestCase(name: "app.model.preview-follows-edits") {
            // scene.js edited in an editor (or checked with `livepaper check`, which keeps
            // `updated`): previews compile the new code instead of serving the cached copy.
            try withModel("preview-edits") { model, _ in
                let entry = try unwrap(model.entry(id: "neon-rain"))
                var first: URL?, again: URL?, edited: URL?, withAsset: URL?
                try awaitMain { first = try await model.previewHTML(for: entry.item) }
                try awaitMain { again = try await model.previewHTML(for: entry.item) }
                try expectEqual(again, first)
                let later = Date().addingTimeInterval(5)
                let script = entry.item.packageURL.appendingPathComponent("scene.js")
                try Data("LivePaper.scene({ draw(lp) { lp.ctx.fillRect(0, 0, 1, 1); } });\n".utf8).write(to: script)
                try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: script.path)
                try awaitMain { await model.refreshFromDisk(.library) }
                try expectEqual(model.previewRevision[entry.id], 1)
                let current = try unwrap(model.entry(id: entry.id))
                try expectEqual(current.manifest.updated, entry.manifest.updated)
                try awaitMain { edited = try await model.previewHTML(for: current.item) }
                try expect(edited != first, "recompiled after the edit")
                let editedFile = try unwrap(edited)
                try expect(FileManager.default.fileExists(atPath: editedFile.path))
                // An asset added counts too.
                let assets = entry.item.packageURL.appendingPathComponent("assets")
                try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
                try Data("png".utf8).write(to: assets.appendingPathComponent("dot.png"))
                try awaitMain { await model.refreshFromDisk(.library) }
                try expectEqual(model.previewRevision[entry.id], 2)
                try awaitMain { withAsset = try await model.previewHTML(for: current.item) }
                try expect(withAsset != edited)
                try expectEqual(model.previewRevision["paper-lanterns"], nil)
            }
        },
        TestCase(name: "app.model.preview-unsafe-id") {
            // An AI candidate's scene.json is written by the agent: an id like "../x" must never
            // become part of a path (the file always lands in the preview cache).
            try withModel("preview-unsafe-id") { model, fx in
                let entry = try unwrap(model.entry(id: "neon-rain"))
                var manifest = entry.manifest
                manifest.id = "../escaped-preview"
                let candidate = SceneItem(manifest: manifest, packageURL: entry.item.packageURL, isBuiltin: false)
                var url: URL?
                try awaitMain { url = try await model.previewHTML(for: candidate) }
                let out = try unwrap(url)
                try expectEqual(out.deletingLastPathComponent().standardizedFileURL.path,
                                fx.root.appendingPathComponent("Previews").standardizedFileURL.path)
                try expect(FileManager.default.fileExists(atPath: out.path))
                let outside = ((try? FileManager.default.contentsOfDirectory(atPath: fx.root.path)) ?? []).filter { $0.contains("escaped") }
                try expectEqual(outside, [])
                // Still a different preview from the library copy's.
                var library: URL?
                try awaitMain { library = try await model.previewHTML(for: entry.item) }
                try expect(library != out)
            }
        },
        TestCase(name: "app.model.uninstall-retry") {
            try withModel("uninstall-retry") { model, fx in
                let install = try unwrap(fx.services.install as? MockInstallService)
                try install.installSaver()
                try awaitMain { await model.registerHelper() }
                install.failingUninstallStep = "Remove"
                model.completeOnboarding()
                var report: UninstallReport?
                try awaitMain { report = await model.uninstall(keepScenes: false) }
                let failed = try unwrap(report)
                try expectEqual(failed.failures.map(\.title), ["Remove \(LPPaths.installedSaver.path)".replacingOccurrences(of: NSHomeDirectory() + "/", with: "~/")])
                try expect(model.hasCompletedOnboarding, "an unfinished uninstall keeps the setup state")
                try expect(model.installStatus.saverInstalled && !model.installStatus.helperRunning)
                // LivePaper is still in use: sessions start again.
                let harness = try unwrap(model.preferredHarness)
                try expect(!model.refusesNewSessions)
                try started(model, .create(prompt: "After an unfinished uninstall"), harness: harness, model: nil).cancel()
                install.failingUninstallStep = nil
                try awaitMain { report = await model.uninstall(keepScenes: false) }
                try expect(report?.succeeded == true)
                try expect(report?.rows.first?.state == .skipped, "finished steps are skipped on retry")
                try expect(!model.hasCompletedOnboarding && !model.installStatus.saverInstalled)
                // Uninstalled (the app is about to quit, its support directory is gone): none do.
                var late: AISessionModel?
                try awaitMain { late = await model.startSession(.create(prompt: "After uninstalling"), harness: harness, model: nil) }
                try expect(late == nil && model.refusesNewSessions)
            }
        },
        TestCase(name: "app.model.publish-skipped") {
            try withModel("publish-skipped") { model, fx in
                let publish = try unwrap(fx.services.publish as? MockPublishService)
                publish.simulatedSkips = ["neon-rain": "neon-rain has a syntax error on line 3."]
                try awaitMain { _ = await model.savePlaylist(PlaylistSettings(mode: .sequence, sceneIDs: ["paper-lanterns", "neon-rain"]),
                                                             announce: false) }
                let result = try unwrap(model.lastPublishResult)
                try expectEqual(result.playlist.scenes.map(\.id), ["paper-lanterns"])
                try expectEqual(result.skippedScenes.map(\.id), ["neon-rain"])
                try expectEqual(model.lastPublished?.scenes.count, 1)
                // Even a quiet publish says what was left out.
                let banner = try unwrap(model.banners.banners.last)
                try expectEqual(banner.style, .warning)
                try expect(banner.message?.contains("Neon Rain") == true && banner.message?.contains("syntax error") == true,
                           banner.message ?? "")
                model.section = .library
                banner.actions.first?.perform()
                try expectEqual(model.section, .playlist)
                publish.simulatedSkips = [:]
                try awaitMain { await model.addToPlaylist("aurora-lake") }
                try expect(model.lastPublishResult?.skipped.isEmpty == true)
            }
        },
        TestCase(name: "app.model.ai-settings") {
            try withModel("ai-settings") { model, fx in
                try expectEqual(model.aiSettings, AISettings())
                model.aiSettings.setModel("opus", for: .claude)
                model.aiSettings.timeoutMinutes = 30
                model.aiSettings.customTemplate = "mytool --task {prompt_file}"
                // Saved through AIServicing (ai-settings.json), not the app's own preferences.
                try expectEqual(fx.services.ai.loadSettings().models, ["claude": "opus"])
                try expectEqual(fx.services.ai.loadSettings().timeoutMinutes, 30)
                try expectEqual(model.availableHarnesses.last?.executable, "mytool")
                let claude = try unwrap(model.availableHarnesses.first { $0.kind == .claude })
                try expectEqual(model.defaultModel(for: claude), "opus")
                model.aiSettings.preferredHarness = claude.id
                try expectEqual(model.preferredHarness?.id, claude.id)
                let session = try started(model, .create(prompt: "Ink drops blooming in water"), harness: claude, model: "  ")
                try expect(session.model == "opus", "an empty model field uses the default from Settings")
                let other = try started(model, .create(prompt: "Ink drops blooming in water"), harness: claude, model: "haiku")
                try expectEqual(other.model, "haiku")
                for s in model.runningSessions { s.cancel() }
                // A new model (next launch) reads them back.
                let again = AppModel(services: fx.services, environment: testEnvironment(root: fx.root, saved: SavedStates()))
                try expectEqual(again.aiSettings.models, ["claude": "opus"])
            }
        },
        TestCase(name: "app.model.lock-now") {
            try withModel("lock-now") { model, fx in
                try awaitMain { _ = await model.registerHelper() }
                var route: AppModel.LockRoute?
                // Mock environment: never locks for real.
                try awaitMain { route = await model.lockNow() }
                try expectEqual(route, .sample)
                // Live-like environment: the helper answers…
                let answering = FixedHelperLockChannel(answers: true)
                var started = 0
                let live = AppModel(services: fx.services, environment: testEnvironment(root: fx.root, saved: SavedStates(), mock: false,
                                                                                     helperLock: answering, startScreenSaver: { started += 1 }))
                try awaitMain { await live.refreshInstallStatus() }
                try awaitMain { route = await live.lockNow() }
                try expectEqual(route, .helper)
                try expectEqual(answering.requests, 1)
                try expect(started == 0, "the helper runs the lock flow")
                try expect(live.banners.banners.contains { $0.title.contains("isn't your screen saver") }, "warns when not selected")
                // …or nobody does, and the app starts the screen saver itself.
                let silent = FixedHelperLockChannel(answers: false)
                let fallback = AppModel(services: fx.services, environment: testEnvironment(root: fx.root, saved: SavedStates(), mock: false,
                                                                                         helperLock: silent, startScreenSaver: { started += 1 }))
                try awaitMain { route = await fallback.lockNow() }
                try expectEqual(route, .screenSaverEngine)
                try expectEqual(started, 1)
                struct Refused: Error {}
                let failing = AppModel(services: fx.services, environment: testEnvironment(root: fx.root, saved: SavedStates(), mock: false,
                                                                                        helperLock: silent, startScreenSaver: { throw Refused() }))
                try awaitMain { route = await failing.lockNow() }
                try expectEqual(route, .failed)
                try expect(failing.banners.banners.contains { $0.style == .error })
            }
        },
        TestCase(name: "app.model.lock-now-refuses-without-immediate-password") {
            // Starting the saver only locks with "Require password … Immediately". Without it, Lock
            // Now must not start anything that looks like a lock — neither through the helper nor
            // the fallback — and must say why.
            try withModel("lock-now-refused") { _, fx in
                let install = try unwrap(fx.services.install as? MockInstallService)
                try install.registerHelper()
                install.simulatePasswordDelay()
                let answering = FixedHelperLockChannel(answers: true)
                var started = 0, openedSettings = 0
                var env = testEnvironment(root: fx.root, saved: SavedStates(), mock: false, helperLock: answering,
                                          startScreenSaver: { started += 1 })
                env.openLockScreenSettings = { openedSettings += 1 }
                let live = AppModel(services: fx.services, environment: env)
                try expect(live.lockRefusal == nil, "nothing is known before the first status read")
                var route: AppModel.LockRoute?
                try awaitMain { route = await live.lockNow() }
                try expectEqual(route, .refused)
                try expect(answering.requests == 0 && started == 0, "no lock request, no screen saver")
                let banner = try unwrap(live.banners.banners.first { $0.title == LPLockRefusal.passwordNotImmediate.title })
                try expectEqual(banner.style, .warning)
                try expect(banner.message?.contains("Immediately") == true)
                try expectEqual(banner.actions.map(\.title), ["Open Lock Screen Settings"])
                banner.actions.first?.perform()
                try expectEqual(openedSettings, 1)
                // The menu disables Lock Now and explains, from the status read.
                try expectEqual(live.lockRefusal, .passwordNotImmediate)
                // Fixed in System Settings: Lock Now reads the status again and locks.
                try install.registerHelper()
                try awaitMain { route = await live.lockNow() }
                try expectEqual(route, .helper)
                try expect(live.lockRefusal == nil && answering.requests == 1)
                // The helper's refusal (hotkey path) is shown the same way.
                let other = AppModel(services: fx.services, environment: env)
                other.showLockRefusal(.passwordOff)
                try expect(other.banners.banners.contains { $0.message == LPLockRefusal.passwordOff.message })
            }
        },
        TestCase(name: "app.model.run-check") {
            try withModel("check") { model, _ in
                try awaitMain { await model.runCheck("tidal-glass") }
                try expect(model.checkingSceneIDs.isEmpty)
                try expectEqual(model.entry(id: "tidal-glass")?.manifest.performance?.benchMs, 5.6)
                try expect(model.banners.banners.contains { $0.style == .warning && $0.actions.map(\.title) == ["Modify with AI"] })
                try awaitMain { await model.runCheck("ink-bloom") }
                try expectEqual(model.entry(id: "ink-bloom")?.energy, .low)
                let before = model.banners.banners.count
                try awaitMain { await model.runCheck("aurora-lake") } // built-in: ignored
                try expectEqual(model.banners.banners.count, before)
            }
        },
        TestCase(name: "app.model.ai-create-accept") {
            try withModel("ai-create") { model, _ in
                let harness = try unwrap(model.preferredHarness)
                let session = try started(model, .create(prompt: "Paper lanterns drifting upward at night"), harness: harness, model: "opus")
                try expectEqual(model.section, .session(session.id))
                try awaitMain(until: { !session.isRunning })
                guard case .succeeded = session.state.phase else { throw TestFailure(description: "phase \(session.state.phase)") }
                try expectEqual(session.state.report?.passed, true)
                try expect(session.state.stills.count >= 3)
                var added: SceneItem?
                try awaitMain { added = await model.accept(session) }
                let item = try unwrap(added)
                try expectEqual(session.resolution, .accepted(sceneID: item.id))
                try expectEqual(model.entry(id: item.id)?.badge, .ai)
                var again: SceneItem? = item
                try awaitMain { again = await model.accept(session) }
                try expect(again == nil, "a session is accepted once")
            }
        },
        TestCase(name: "app.model.ai-modify-builtin") {
            try withModel("ai-modify") { model, fx in
                let harness = try unwrap(model.preferredHarness)
                var started: AISessionModel?
                try awaitMain { started = await model.startModify(sceneID: "aurora-lake", prompt: "Make it slower please", harness: harness, model: nil) }
                let session = try unwrap(started)
                try expectEqual(session.clonedFrom, "Aurora Lake")
                let target = try unwrap(session.targetSceneID)
                try expect(target != "aurora-lake", "built-ins are modified as a copy")
                try awaitMain(until: { !session.isRunning })
                // The copy is in the screen saver's playlist: accepting republishes it.
                let install = try unwrap(fx.services.install as? MockInstallService)
                try install.installSaver()
                try awaitMain { await model.refreshInstallStatus() }
                try awaitMain { await model.useAsScreenSaver(target) }
                let published = try unwrap(model.lastPublished?.generation)
                var replaced: SceneItem?
                try awaitMain { replaced = await model.accept(session) }
                try expectEqual(replaced?.id, target)
                try expect((model.lastPublished?.generation ?? 0) > published, "republished after accepting")
                let history = ProvenanceLog.load(package: try unwrap(replaced).packageURL)
                try expect(history.contains { $0.action == "modify" })
            }
        },
        TestCase(name: "app.model.ai-failure-retry-discard") {
            try withModel("ai-fail") { model, _ in
                let harness = try unwrap(model.preferredHarness)
                let session = try started(model, .create(prompt: "This one should fail quickly"), harness: harness, model: nil)
                model.section = .library // away from the session: a banner reports the outcome
                try awaitMain(until: { !session.isRunning })
                guard case .failed(let message) = session.state.phase else { throw TestFailure(description: "expected failure") }
                try expect(message.contains("rate limit"), message)
                try expect(model.banners.banners.contains { $0.style == .warning && $0.actions.map(\.title) == ["Open"] })
                let retry = try retried(model, session, feedback: "and use aurora colours")
                try expect(retry.prompt.contains("aurora colours"))
                try expect(model.session(id: session.id) == nil, "retry replaces the old session")
                model.discard(retry)
                try expect(model.sessions.isEmpty)
                try expectEqual(model.section, .create)
            }
        },
        TestCase(name: "app.model.ai-cancel-and-timeout") {
            try withModel("ai-cancel") { model, fx in
                let ai = try unwrap(fx.services.ai as? MockAIService)
                ai.holdAfterSteps = 4
                let harness = try unwrap(model.preferredHarness)
                let session = try started(model, .create(prompt: "A slow orbit of planets"), harness: harness, model: nil)
                try awaitMain(until: { session.state.toolCallCount >= 1 })
                try expectEqual(model.runningSessions.count, 1)
                session.cancel()
                try expectEqual(session.state.phase, .cancelled)
                try expect(model.runningSessions.isEmpty)
                // The watchdog stops sessions that run past the time limit.
                let handle = try ai.start(.create(prompt: "Endless dunes at dusk"), harness: harness, model: nil)
                let timed = AISessionModel(handle: handle, request: .create(prompt: "Endless dunes at dusk"), harness: harness,
                                           model: nil, timeout: 0.3)
                var finished = 0
                timed.start { _ in finished += 1 }
                try awaitMain(until: { !timed.isRunning })
                guard case .failed(let why) = timed.state.phase else { throw TestFailure(description: "expected timeout") }
                try expect(why.contains("time limit"), why)
                try expectEqual(finished, 1)
            }
        },
        TestCase(name: "app.model.quit-stops-agents") {
            // Quitting (and uninstalling) waits until every agent's process group is gone. These
            // agents — and the tool each started — ignore SIGTERM; once LivePaper has exited,
            // nothing would ever kill them. One is still running, the user stopped the other a
            // moment ago (its SIGKILL was only scheduled).
            try withScratchPaths("quit-agents") { root in
                let (ai, harness) = try scriptedAIService(root: root, agent: """
                trap '' TERM
                echo $$ > .livepaper/agent.pid
                sh -c 'while :; do sleep 1; done' &
                echo $! > .livepaper/grandchild.pid
                echo started
                while :; do sleep 1; done
                """)
                let mock = try MockServices.make(root: root.appendingPathComponent("Mock"), pace: 0)
                let services = LivePaperServices(library: mock.library, publish: mock.publish, ai: ai, install: mock.install,
                                                 render: mock.render, checker: mock.checker, compiler: mock.compiler)
                try MainActor.assumeIsolated {
                    let model = AppModel(services: services, environment: testEnvironment(root: root, saved: SavedStates()))
                    let running = try started(model, .create(prompt: "An agent that ignores SIGTERM"), harness: harness, model: nil)
                    let stopped = try started(model, .create(prompt: "Another one, stopped just now"), harness: harness, model: nil)
                    for s in [running, stopped] { try awaitMain(until: { s.state.entries.contains { $0.kind == .text("started") } }) }
                    stopped.cancel()
                    try expectEqual(model.runningSessions.map(\.id), [running.id])
                    let pids = try [running, stopped].flatMap { s in
                        try ["agent.pid", "grandchild.pid"].map { name in
                            try unwrap(Int32(String(decoding: try Data(contentsOf: AIWorkspace(root: s.workspace).internalDirectory
                                .appendingPathComponent(name)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
                        }
                    }
                    let began = Date()
                    try awaitMain { await model.stopAllAgents() }
                    let took = Date().timeIntervalSince(began)
                    // Checked the moment it returns: the app exits right after.
                    try expectEqual(pids.filter { kill($0, 0) == 0 }, [])
                    try expectEqual([pids[0], pids[2]].filter { killpg($0, 0) == 0 }, [])
                    try expect(took < AgentShutdown.limit, "bounded: \(took)s")
                    try expectEqual(running.state.phase, .cancelled)
                    try expect(model.runningSessions.isEmpty)
                }
            }
        },
        TestCase(name: "app.model.quit-during-start") {
            // Quitting (or uninstalling) while a session is still being started: its harness launches
            // once the workspace is built, so quitting waits for that start and stops its agent too
            // (here one that ignores SIGTERM), and no new session starts from then on.
            try withScratchPaths("quit-starting") { root in
                let (scripted, harness) = try scriptedAIService(root: root, agent: """
                trap '' TERM
                echo $$ > .livepaper/agent.pid
                echo started
                while :; do sleep 1; done
                """)
                let ai = GatedAIService(scripted)
                let mock = try MockServices.make(root: root.appendingPathComponent("Mock"), pace: 0)
                let services = LivePaperServices(library: mock.library, publish: mock.publish, ai: ai, install: mock.install,
                                                 render: mock.render, checker: mock.checker, compiler: mock.compiler)
                try MainActor.assumeIsolated {
                    let model = AppModel(services: services, environment: testEnvironment(root: root, saved: SavedStates()))
                    var returned = false, handedBack: AISessionModel?
                    Task { @MainActor in
                        handedBack = await model.startSession(.create(prompt: "Started as LivePaper quits"), harness: harness, model: nil)
                        returned = true
                    }
                    try awaitMain(until: { ai.starts.withLock { $0 } == 1 })
                    try expect(model.isStartingSession && model.sessions.isEmpty && model.hasAgentsToStop, "quitting has an agent to stop")
                    var stopped = false
                    Task { @MainActor in await model.stopAllAgents(); stopped = true }
                    let soon = Date().addingTimeInterval(0.3)
                    try awaitMain(until: { Date() > soon })
                    try expect(!stopped && !returned, "quitting waits for the start")
                    ai.gate.signal()
                    try awaitMain(until: { stopped })
                    try expect(returned && handedBack == nil, "the start hands back no session to use")
                    try expect(!model.isStartingSession)
                    let session = try unwrap(model.sessions.first)
                    try expectEqual(session.state.phase, .cancelled)
                    // Its agent never ran, or is gone — also a moment later (a launch stopped while
                    // warming up never spawns).
                    let pidFile = AIWorkspace(root: session.workspace).internalDirectory.appendingPathComponent("agent.pid")
                    func agentAlive() -> Bool {
                        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
                              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
                        return kill(pid, 0) == 0
                    }
                    try expect(!agentAlive(), "the agent was stopped before LivePaper would exit")
                    let later = Date().addingTimeInterval(1.5)
                    try awaitMain(until: { Date() > later })
                    try expect(!agentAlive(), "no agent spawned after the stop")
                    // From now on nothing starts.
                    ai.gate.signal()
                    var refused: AISessionModel?
                    try awaitMain { refused = await model.startSession(.create(prompt: "One more"), harness: harness, model: nil) }
                    try expect(refused == nil && ai.starts.withLock { $0 } == 1, "a new session isn't started while quitting")
                }
            }
        },
        TestCase(name: "app.model.quit-wait-is-bounded") {
            // An agent that can't be stopped in time never holds up quitting past the limit.
            try MainActor.assumeIsolated {
                let began = Date()
                try awaitMain { await AgentShutdown.stop([]) }
                try expect(Date().timeIntervalSince(began) < 0.2, "nothing to stop: immediate")
                let stuck = StuckHandle()
                defer { stuck.release.signal() }
                let session = AISessionModel(handle: stuck, request: .create(prompt: "x"),
                                             harness: AIService.customHarness(template: "/usr/bin/true"), model: nil, timeout: 600)
                let start = Date()
                try awaitMain { await AgentShutdown.stop([session], grace: 0.1, limit: 0.4) }
                let took = Date().timeIntervalSince(start)
                try expect(took >= 0.35 && took < 2, "waited \(took)s")
                try expect(stuck.asked.withLock { $0 } == 1, "asked to stop once")
                try expectEqual(session.state.phase, .cancelled)
            }
        },
    ] }

    /// Holds every start (a workspace that takes a while to build) until `gate` is signalled, then
    /// starts for real — the harness launches as the start returns, as AIService's does.
    final class GatedAIService: AIServicing, @unchecked Sendable {
        let base: AIServicing
        let gate = DispatchSemaphore(value: 0)
        let starts = OSAllocatedUnfairLock(initialState: 0)
        init(_ base: AIServicing) { self.base = base }
        func detectHarnesses() async -> [AIHarness] { await base.detectHarnesses() }
        func start(_ request: AISessionRequest, references: [PreparedReference], harness: AIHarness, model: String?) throws -> AISessionHandle {
            starts.withLock { $0 += 1 }
            gate.wait()
            return try base.start(request, references: references, harness: harness, model: model)
        }
        func loadSettings() -> AISettings { base.loadSettings() }
        func saveSettings(_ settings: AISettings) throws { try base.saveSettings(settings) }
    }

    /// A session whose agent doesn't stop until released.
    final class StuckHandle: AISessionTerminating, @unchecked Sendable {
        let id = "stuck"
        let workspace = URL(fileURLWithPath: "/tmp")
        let events = AsyncStream<AISessionEvent> { _ in }
        let release = DispatchSemaphore(value: 0)
        let asked = OSAllocatedUnfairLock(initialState: 0)
        func cancel() {}
        func terminateNow(grace: TimeInterval) -> Bool {
            asked.withLock { $0 += 1 }
            _ = release.wait(timeout: .now() + 30)
            return false
        }
    }

    /// Never asked: the scripted agents in these tests don't finish.
    final class UnusedChecker: SceneChecking, @unchecked Sendable {
        func check(package: URL, options: CheckOptions) async throws -> CheckReport { CheckReport(passed: false) }
    }

    /// A real AIService over `root` whose harness is the /bin/sh script `agent` (a custom template).
    static func scriptedAIService(root: URL, agent: String) throws -> (AIService, AIHarness) {
        let fm = FileManager.default
        let runtime = root.appendingPathComponent("Runtime"), builtins = root.appendingPathComponent("Builtin")
        let template = runtime.appendingPathComponent("templates/web")
        try fm.createDirectory(at: template, withIntermediateDirectories: true)
        try fm.createDirectory(at: builtins, withIntermediateDirectories: true)
        try Data("# Agent guide\n".utf8).write(to: runtime.appendingPathComponent("AGENTS.md"))
        try SceneManifest(id: "untitled", name: "Untitled", kind: .web).write(package: template)
        try Data("LivePaper.scene({ draw(lp) {} });\n".utf8).write(to: template.appendingPathComponent("scene.js"))
        let script = root.appendingPathComponent("agent.sh")
        try Data((agent + "\n").utf8).write(to: script)
        let library = LibraryService(libraryDirectory: root.appendingPathComponent("Library"), builtinDirectory: builtins,
                                     templateDirectory: template)
        let builder = WorkspaceBuilder(library: library, runtimeDirectory: runtime, builtinScenesDirectory: builtins,
                                       workspacesDirectory: root.appendingPathComponent("Workspaces"), cliPath: URL(fileURLWithPath: "/usr/bin/false"))
        let detector = HarnessDetector(shell: .fixed(ShellSnapshot(environment: ["PATH": "/usr/bin:/bin"])), directories: [])
        let ai = AIService(library: library, checker: UnusedChecker(), workspaceBuilder: builder, detector: detector,
                           runner: RecordingCommandRunner(), settingsURL: root.appendingPathComponent("ai-settings.json"))
        return (ai, AIService.customHarness(template: "/bin/sh '\(script.path)'", name: "Scripted agent"))
    }

    // MARK: - Helpers

    /// The sample library as LibraryEntry values (with AI provenance as the mocks write it).
    static func sampleEntries() -> [LibraryEntry] {
        MockSampleData.samples().map { s in
            let item = SceneItem(manifest: s.manifest, packageURL: URL(fileURLWithPath: "/tmp/\(s.manifest.id).lpscene"), isBuiltin: s.builtin)
            return LibraryEntry(item: item, hasAIHistory: s.history.contains { $0["harness"] != nil })
        }
    }

    /// Points every LPPaths override at a scratch root for the duration of `body`.
    static func withScratchPaths(_ name: String, _ body: (URL) throws -> Void) throws {
        let root = try tempDir(name)
        let keys = ["LIVEPAPER_HOME", "LIVEPAPER_SAVERS_DIR", "LIVEPAPER_WALLPAPER_STORE", "LIVEPAPER_LAUNCH_AGENTS_DIR"]
        let previous = keys.map { ProcessInfo.processInfo.environment[$0] }
        setenv("LIVEPAPER_HOME", root.appendingPathComponent("Support").path, 1)
        setenv("LIVEPAPER_SAVERS_DIR", root.appendingPathComponent("Screen Savers").path, 1)
        setenv("LIVEPAPER_WALLPAPER_STORE", root.appendingPathComponent("Wallpaper/Index.plist").path, 1)
        setenv("LIVEPAPER_LAUNCH_AGENTS_DIR", root.appendingPathComponent("LaunchAgents").path, 1)
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    /// Records what AppModel would write to state.json.
    final class SavedStates { var all: [LPSharedState] = []; var count: Int { all.count }; var last: LPSharedState? { all.last } }

    /// What a model test can inspect besides the model.
    struct ModelFixture {
        let services: LivePaperServices
        let saved: SavedStates
        /// The scratch root (LPPaths point into root/Support etc.).
        let root: URL
    }

    /// An environment over a scratch root. `mock: false` exercises the live-only paths (lock now)
    /// with injected stand-ins, so nothing reaches the system either way.
    @MainActor
    static func testEnvironment(root: URL, saved: SavedStates, mock: Bool = true,
                                helperLock: HelperLockChannel? = nil,
                                startScreenSaver: @escaping @MainActor () async throws -> Void = {}) -> AppEnvironment {
        AppEnvironment(isMock: mock, defaults: InMemoryPreferences(), stateURL: root.appendingPathComponent("Support/state.json"),
                       saveState: { saved.all.append($0) }, helperLock: helperLock ?? FixedHelperLockChannel(answers: false),
                       startScreenSaver: startScreenSaver,
                       previewCacheDirectory: root.appendingPathComponent("Previews"), appVersion: "0.0.0-test", appBundlePath: nil)
    }

    /// A started AppModel over fresh mock services (zero delays) in a scratch directory.
    /// `AppModel.startSession` from a synchronous test (it builds the workspace off the main thread).
    @MainActor static func started(_ model: AppModel, _ request: AISessionRequest, references: [PreparedReference] = [], harness: AIHarness,
                                   model name: String?) throws -> AISessionModel {
        var session: AISessionModel?
        try awaitMain { session = await model.startSession(request, references: references, harness: harness, model: name) }
        return try unwrap(session)
    }

    /// `AppModel.retry` from a synchronous test.
    @MainActor static func retried(_ model: AppModel, _ session: AISessionModel, feedback: String) throws -> AISessionModel {
        var next: AISessionModel?
        try awaitMain { next = await model.retry(session, feedback: feedback) }
        return try unwrap(next)
    }

    static func withModel(_ name: String, _ body: @MainActor (AppModel, ModelFixture) throws -> Void) throws {
        try withScratchPaths(name) { root in
            let services = try MockServices.make(root: root.appendingPathComponent("Mock"), pace: 0)
            let saved = SavedStates()
            let fx = ModelFixture(services: services, saved: saved, root: root)
            try MainActor.assumeIsolated {
                let model = AppModel(services: services, environment: testEnvironment(root: root, saved: saved))
                try awaitMain { await model.start() }
                try body(model, fx)
                for s in model.runningSessions { s.cancel() }
            }
        }
    }

    /// Whether the test's Mac counts as locked (AppEnvironment.isSessionLocked).
    final class LockFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        var isLocked: Bool {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    /// A started AppModel whose install service starts from `status`, with a controllable lock.
    /// `prepare` sets the service's test hooks and `configure` the environment before the model starts.
    static func withInstallModel(_ name: String, status: InstallStatus, locked: Bool,
                                 prepare: (MockInstallService) -> Void = { _ in },
                                 configure: @MainActor (inout AppEnvironment) -> Void = { _ in },
                                 _ body: @MainActor (AppModel, MockInstallService, LockFlag) throws -> Void) throws {
        try withScratchPaths(name) { root in
            let mocks = try MockServices.make(root: root.appendingPathComponent("Mock"), pace: 0)
            let install = MockInstallService(status: status)
            prepare(install)
            let services = LivePaperServices(library: mocks.library, publish: mocks.publish, ai: mocks.ai, install: install,
                                             render: mocks.render, checker: mocks.checker, compiler: mocks.compiler)
            let lock = LockFlag(locked)
            try MainActor.assumeIsolated {
                var env = testEnvironment(root: root, saved: SavedStates())
                env.isSessionLocked = { lock.isLocked }
                configure(&env)
                let model = AppModel(services: services, environment: env)
                try awaitMain { await model.start() }
                try body(model, install, lock)
            }
        }
    }

    /// Forwards to a MockInstallService, but holds every saver update until `release()` (and, on
    /// request, every helper repair until `releaseRepair()`, and status reads until
    /// `releaseStatus()`), and logs the order of updates, repairs and uninstalls, and what the
    /// caller's lock probe answered once released.
    final class GatedInstall: InstallServicing, @unchecked Sendable {
        let base: MockInstallService
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private let repairGate = DispatchSemaphore(value: 0)
        private var log: [String] = []
        private var probes: [Bool] = []
        private var holding = false
        private var repairing = false
        private var holdingRepairs = false
        private var holdingStatus = false
        private var statusWaiters = 0

        init(base: MockInstallService) { self.base = base }

        var events: [String] { lock.lock(); defer { lock.unlock() }; return log }
        var lockProbes: [Bool] { lock.lock(); defer { lock.unlock() }; return probes }
        var isHolding: Bool { lock.lock(); defer { lock.unlock() }; return holding }
        func release() { gate.signal() }
        /// Holds every recoverHelper until releaseRepair().
        var holdsRepairs: Bool {
            get { lock.lock(); defer { lock.unlock() }; return holdingRepairs }
            set { lock.lock(); holdingRepairs = newValue; lock.unlock() }
        }
        var isRepairing: Bool { lock.lock(); defer { lock.unlock() }; return repairing }
        func releaseRepair() { repairGate.signal() }
        /// From now on status() reads the state, then waits for releaseStatus() before answering
        /// (sysadminctl and launchctl being slow).
        func holdStatusReads() { lock.lock(); holdingStatus = true; lock.unlock() }
        var isHoldingStatusRead: Bool { lock.lock(); defer { lock.unlock() }; return statusWaiters > 0 }
        func releaseStatus() { lock.lock(); holdingStatus = false; lock.unlock() }
        private func note(_ event: String, holding: Bool? = nil) {
            lock.lock(); log.append(event); if let holding { self.holding = holding }; lock.unlock()
        }

        func status() -> InstallStatus {
            let read = base.status()
            lock.lock(); let hold = holdingStatus; if hold { statusWaiters += 1 }; lock.unlock()
            guard hold else { return read }
            while (lock.withLock { holdingStatus }) { usleep(5_000) }
            lock.lock(); statusWaiters -= 1; lock.unlock()
            return read
        }
        func installSaver() throws -> PublishResult? { note("install"); return try base.installSaver() }
        func updateSaver(isSessionLocked: () -> Bool) throws -> SaverUpdateOutcome {
            note("update", holding: true)
            gate.wait()
            defer { note("updated", holding: false) }
            let locked = isSessionLocked()
            lock.lock(); probes.append(locked); lock.unlock()
            return try base.updateSaver(isSessionLocked: isSessionLocked)
        }
        func selectSaver() throws -> Bool { try base.selectSaver() }
        func registerHelper() throws { try base.registerHelper() }
        func recoverHelper() throws -> HelperRecoveryOutcome {
            note("recover")
            if holdsRepairs {
                lock.lock(); repairing = true; lock.unlock()
                repairGate.wait()
                lock.lock(); repairing = false; lock.unlock()
            }
            defer { note("recovered") }
            return try base.recoverHelper()
        }
        func unregisterHelper() throws { try base.unregisterHelper() }
        func setLockKeysShowScene(_ on: Bool) throws { try base.setLockKeysShowScene(on) }
        func openScreenSaverSettings() { base.openScreenSaverSettings() }
        func performUninstall(removeLibrary: Bool) -> [InstallStep] {
            note("uninstall")
            return base.performUninstall(removeLibrary: removeLibrary)
        }
    }

    /// Plays loginwindow's com.apple.screenIsUnlocked for AppEnvironment.observeUnlock.
    final class UnlockSource: @unchecked Sendable {
        private var handler: (@MainActor () -> Void)?
        private(set) var observeCount = 0
        var isObserving: Bool { handler != nil }
        func observe(_ handler: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) {
            observeCount += 1
            self.handler = handler
            return { [weak self] in self?.handler = nil }
        }
        @MainActor func fire() { handler?() }
    }

    /// Counts calls of an environment action.
    final class OpenCount: @unchecked Sendable { var count = 0 }

    /// In-memory CFPreferences stand-in for InstallService (never touches the real domains).
    final class ScratchPreferences: PreferencesAccessing, @unchecked Sendable {
        var values: [String: Any] = [:]
        func value(domain: String, key: String, currentHost: Bool) -> Any? { values["\(domain)|\(key)"] }
        func set(_ value: Any?, domain: String, key: String, currentHost: Bool) -> Bool {
            values["\(domain)|\(key)"] = value
            return true
        }
    }

    /// Not running from an app bundle: no SMAppService login item.
    struct NoLoginItem: LoginItemRegistering {
        var isAvailable: Bool { false }
        var status: LoginItemStatus { .notFound }
        func register() throws -> LoginItemStatus { .notFound }
        func unregister() throws {}
    }

    @MainActor private final class Completion { var done = false; var error: Error? }

    /// Runs `work` on the main actor and drives the main run loop until it finishes.
    static func awaitMain(timeout: TimeInterval = 20, _ work: @escaping @MainActor () async throws -> Void) throws {
        try MainActor.assumeIsolated {
            let c = Completion()
            Task { @MainActor in
                do { try await work() } catch { c.error = error }
                c.done = true
            }
            try spin(timeout: timeout) { c.done }
            if let error = c.error { throw error }
        }
    }

    /// Drives the main run loop until `condition` holds (MainActor jobs are drained by it).
    static func awaitMain(timeout: TimeInterval = 20, until condition: @MainActor () -> Bool) throws {
        try MainActor.assumeIsolated { try spin(timeout: timeout, condition) }
    }

    @MainActor private static func spin(timeout: TimeInterval, _ condition: () -> Bool) throws {
        // A timer keeps the run loop from returning immediately for lack of input sources.
        let keepAlive = Timer(timeInterval: 0.05, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .default)
        defer { keepAlive.invalidate() }
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw TestFailure(description: "timed out after \(timeout)s") }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    static func unwrap<T>(_ value: T?, file: String = #fileID, line: Int = #line) throws -> T {
        guard let value else { throw TestFailure(description: "\(file):\(line) unexpected nil") }
        return value
    }
}
