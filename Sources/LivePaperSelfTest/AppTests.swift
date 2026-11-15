// Self tests owned by WS-app.
//
// The app's testable logic is compiled into this target through the symlinks in
// Sources/LivePaperSelfTest/AppLogic/ (they point at Foundation/Observation-only files in
// Sources/LivePaperApp/{Logic,Model,Mocks}); the SwiftUI views are not part of it. AppModel tests
// run against the mock services with zero delays, in temporary directories, and drive the main run
// loop so MainActor tasks (event streams, banners) make progress. Nothing here touches the user's
// real state or launches a GUI process.
import Foundation
import LivePaperCore

extension SelfTests {
    static var app: [TestCase] { appLogic + appModel }

    // MARK: - Pure logic

    static var appLogic: [TestCase] { [
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
            s.apply(.stillRendered(png), at: t)
            s.apply(.stillRendered(URL(fileURLWithPath: "/tmp/b.png")), at: t)
            try expectEqual(s.stills.count, 2)
            try expectEqual(s.entries.last?.kind, .stills(2))
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
            st.install.helperRunning = true; st.install.managedByMDM = true
            try expectEqual(SetupChecklist.checks(for: .lock, state: st).map(\.state), [.needed, .managed, .done])
            try expect(!SetupChecklist.isComplete(.lock, state: st), "lock keys still off")
            st.install.lockKeysShowScene = true
            try expect(SetupChecklist.isComplete(.lock, state: st), "managed never blocks")
            try expectEqual(SetupChecklist.firstIncompleteStep(state: st), .firstScene)
            try expect(SetupChecklist.checks(for: .welcome, state: st).isEmpty)
            st.install.saverUpToDate = false
            try expectEqual(SetupChecklist.saverSummary(st.install), "Selected \u{2014} update available")
            // A login item waiting for approval says where to allow it.
            st.install.helperRunning = false
            st.install.helperLoginItem = .requiresApproval
            try expect(st.helperNeedsApproval)
            let helper = try unwrap(SetupChecklist.checks(for: .lock, state: st).first { $0.id == .helper })
            try expectEqual(helper.state, .needed)
            try expect(helper.detail.contains("Login Items"), helper.detail)
            st.install.helperLoginItem = .enabled
            try expect(!st.helperNeedsApproval)
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
                let banner = try unwrap(model.banners.banners.last)
                try expectEqual(banner.style, .error)
                try expectEqual(banner.actions.map(\.title), ["Try Again"])
                banner.actions[0].perform()
                try awaitMain(until: { model.playlist.mode == .sequence })
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
                install.failingUninstallStep = nil
                try awaitMain { report = await model.uninstall(keepScenes: false) }
                try expect(report?.succeeded == true)
                try expect(report?.rows.first?.state == .skipped, "finished steps are skipped on retry")
                try expect(!model.hasCompletedOnboarding && !model.installStatus.saverInstalled)
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
                let session = try unwrap(model.startSession(.create(prompt: "Ink drops blooming in water"), harness: claude, model: "  "))
                try expect(session.model == "opus", "an empty model field uses the default from Settings")
                let other = try unwrap(model.startSession(.create(prompt: "Ink drops blooming in water"), harness: claude, model: "haiku"))
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
                let session = try unwrap(model.startSession(.create(prompt: "Paper lanterns drifting upward at night"),
                                                            harness: harness, model: "opus"))
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
            try withModel("ai-modify") { model, _ in
                let harness = try unwrap(model.preferredHarness)
                var started: AISessionModel?
                try awaitMain { started = await model.startModify(sceneID: "aurora-lake", prompt: "Make it slower please", harness: harness, model: nil) }
                let session = try unwrap(started)
                try expectEqual(session.clonedFrom, "Aurora Lake")
                let target = try unwrap(session.targetSceneID)
                try expect(target != "aurora-lake", "built-ins are modified as a copy")
                try awaitMain(until: { !session.isRunning })
                var replaced: SceneItem?
                try awaitMain { replaced = await model.accept(session) }
                try expectEqual(replaced?.id, target)
                let history = ProvenanceLog.load(package: try unwrap(replaced).packageURL)
                try expect(history.contains { $0.action == "modify" })
            }
        },
        TestCase(name: "app.model.ai-failure-retry-discard") {
            try withModel("ai-fail") { model, _ in
                let harness = try unwrap(model.preferredHarness)
                let session = try unwrap(model.startSession(.create(prompt: "This one should fail quickly"), harness: harness, model: nil))
                model.section = .library // away from the session: a banner reports the outcome
                try awaitMain(until: { !session.isRunning })
                guard case .failed(let message) = session.state.phase else { throw TestFailure(description: "expected failure") }
                try expect(message.contains("rate limit"), message)
                try expect(model.banners.banners.contains { $0.style == .warning && $0.actions.map(\.title) == ["Open"] })
                let retry = try unwrap(model.retry(session, feedback: "and use aurora colours"))
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
                let session = try unwrap(model.startSession(.create(prompt: "A slow orbit of planets"), harness: harness, model: nil))
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
    ] }

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
