// Self tests for AI session records and recovery (ARCHITECTURE §10 "Session records and recovery"):
// the record's round trip and tolerance, the recovery decisions, a real orphaned agent watched to its
// exit and stopped (a process group of its own, adopted by launchd — exactly what an agent is once
// its app is gone), pid reuse, pruning and the accept path's scene id. The app side is in
// AppRecoveryTests.swift. Everything runs in scratch directories; the only processes ever
// signalled are the ones these tests start.
import Darwin
import Foundation
import LivePaperCore

extension SelfTests {
    static var recovery: [TestCase] { recoveryCore + recoveryApp }

    static var recoveryCore: [TestCase] { [
        TestCase(name: "recovery.record.round-trip") {
            let facts = LPProcessFacts(pid: 4242, group: 4242, start: LPProcessStart(seconds: 1_794_850_774, microseconds: 333_794))
            var record = AISessionRecord(id: "20261116T101500Z-ab12cd", origin: .cli, runner: facts, request: .modify(sceneID: "sky", prompt: "Add stars"),
                                         prompt: "Add stars\n\nFeedback on the previous attempt (please address it): brighter",
                                         feedback: ["brighter"],
                                         references: [.init(role: .animate, name: "heron.jpg", file: "references/ref-01.jpg", copy: "ref-01.jpg",
                                                            format: .jpeg, width: 2000, height: 1333, summary: nil)],
                                         animate: .init(asset: "assets/reference.jpg", copy: "asset.jpg", sha256: String(repeating: "a", count: 64),
                                                        width: 3840, height: 2560, transparent: false, flattened: false),
                                         harness: AIHarness(kind: .claude, name: "Claude Code", executable: "/usr/local/bin/claude", version: "2.1"),
                                         model: "opus", timeout: 1200, clonedFrom: "Aurora", sceneBefore: String(repeating: "b", count: 64),
                                         startedAt: Date(timeIntervalSince1970: 1_794_850_000))
            record.agent = LPProcessFacts(pid: 4300, group: 4300, start: LPProcessStart(seconds: 1_794_850_001, microseconds: 5))
            record.finishedAt = Date(timeIntervalSince1970: 1_794_851_000)
            record.outcome = .init(status: .failed, message: "The scene didn't pass", checkPassed: false, problems: ["Bench 9 ms"])
            record.recoveredAt = Date(timeIntervalSince1970: 1_794_852_000)
            for resolution in [AISessionRecord.Resolution.accepted(sceneID: "sky"), .discarded, nil] {
                record.resolution = resolution
                let data = try AISessionRecord.encoder().encode(record)
                try expectEqual(AISessionRecord.decode(data), record)
            }
            try expectEqual(record.request, .modify(sceneID: "sky", prompt: record.prompt))
            // The JSON is plain: dates as ISO 8601, the request as a word, the resolution as an action.
            record.resolution = .accepted(sceneID: "sky")
            let json = String(decoding: try AISessionRecord.encoder().encode(record), as: UTF8.self)
            for fragment in [#""request" : "modify""#, #""sceneID" : "sky""#, #""startedAt" : "2026-11-16T"#, #""action" : "accepted""#,
                             #""start" : {"#, #""microseconds" : 333794"#] {
                try expect(json.contains(fragment), "\(fragment) in \(json)")
            }
            try expectEqual(AISessionRecord.decode(Data(#"{"id":"x","request":"create","prompt":"p"}"#.utf8))?.request, .create(prompt: "p"))
        },
        TestCase(name: "recovery.record.tolerant") {
            // Written by another version, or damaged: what can be read is kept.
            let json = #"""
            {"id":"s1","request":"create","prompt":"Embers","schema":7,"future":{"x":1},
             "startedAt":"not a date","timeout":"long","origin":"tablet",
             "references":[{"role":"reference","name":"a.jpg","file":"references/ref-01.jpg","copy":"ref-01.jpg","format":"jpeg","width":10,"height":10},
                           {"role":"sideways","name":"b.jpg"}],
             "agent":{"pid":12,"group":12,"start":{"seconds":5,"microseconds":6}},
             "runner":{"pid":"nope"},
             "outcome":{"status":"passed","problems":[]},
             "resolution":{"action":"archived"}}
            """#
            let r = try unwrap(AISessionRecord.decode(Data(json.utf8)))
            try expectEqual(r.id, "s1"); try expectEqual(r.prompt, "Embers"); try expectEqual(r.schema, 7)
            try expectEqual(r.startedAt, Date(timeIntervalSince1970: 0))
            try expectEqual(r.timeout, AISettings().timeout)
            try expectEqual(r.origin, .app)
            try expectEqual(r.references.map(\.name), ["a.jpg"])
            try expectEqual(r.agent, LPProcessFacts(pid: 12, group: 12, start: LPProcessStart(seconds: 5, microseconds: 6)))
            try expect(r.runner == nil)
            try expectEqual(r.outcome?.status, .passed)
            try expectEqual(r.harness.harness.kind, .custom)
            // A decision this version doesn't know still means it was decided.
            try expectEqual(r.resolution, .discarded)
            try expect(r.isSettled)
            // Without an id or a usable request it isn't a record.
            for bad in [#"{"request":"create"}"#, #"{"id":"s","request":"remix"}"#, #"{"id":"s","request":"modify"}"#, "[]", "garbage"] {
                try expect(AISessionRecord.decode(Data(bad.utf8)) == nil, bad)
            }
            // The store skips damaged files and names that aren't session ids.
            try CoreSandbox.with("record-store") { sb in
                let store = AISessionRecordStore(workspacesDirectory: sb.workspaces)
                try store.save(AISessionRecord(id: "good", origin: .app, runner: nil, request: .create(prompt: "x"), harness: fakeHarness,
                                               model: nil, timeout: 60))
                try FileManager.default.createDirectory(at: store.folder(for: "broken"), withIntermediateDirectories: true)
                try Data("{".utf8).write(to: store.url(for: "broken"))
                try expectEqual(store.records().map(\.id), ["good"])
                try expect(store.load("../good") == nil && !AISessionRecordStore.isValidID(".lock") && !AISessionRecordStore.isValidID("a/b"))
                try expectEqual(Set(store.folderIDs()), ["good", "broken"])
                // A record whose file names another session isn't taken for this one.
                try FileManager.default.createDirectory(at: store.folder(for: "copy"), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: store.url(for: "good"), to: store.url(for: "copy"))
                try expect(store.load("copy") == nil)
            }
        },
        TestCase(name: "recovery.record.written-by-sessions") {
            try CoreSandbox.with("record-sessions") { sb in
                let (ai, harness) = try sessionFixture(sb, agent: """
                printf 'LivePaper.scene({ draw(lp) {} });\\n' > scene/scene.js
                printf '{"id":"untitled","name":"Night Lake","kind":"web"}' > scene/scene.json
                """)
                let handle = try ai.start(.create(prompt: "A night lake"), harness: harness, model: "m1")
                let events = try collect(handle)
                try expectEqual(events.last, .finished(package: AIWorkspace(root: handle.workspace).scene))
                let r = try unwrap(ai.records.load(handle.id))
                try expectEqual(r.origin, .app)
                try expect(r.runner?.isSameProcess(as: ProcessProbe.current) == true, "the runner is this process")
                let agent = try unwrap(r.agent)
                try expect(agent.group == agent.pid && agent.pid != getpid(), "the agent leads its own group: \(agent)")
                try expectEqual(r.prompt, "A night lake"); try expectEqual(r.model, "m1"); try expectEqual(r.harness.harness, harness)
                try expectEqual(r.sceneBefore, FileDigest.sha256(Data(CoreSandbox.templateJS.utf8)))
                try expectEqual(r.outcome, .init(status: .passed, checkPassed: true))
                try expect(r.finishedAt != nil && r.resolution == nil && r.timeout == 30)
                // Next to the workspace, not in it.
                try expectEqual(ai.records.url(for: handle.id).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, ".sessions")
                try expect(!FileManager.default.fileExists(atPath: handle.workspace.appendingPathComponent(".livepaper/session.json").path))

                // With images, feedback and the CLI as its runner; a failure keeps no copies.
                let refs = try ReferenceTests.sampleReferences(in: sb.root.appendingPathComponent("Pictures"))
                let (failing, h2) = try sessionFixture(sb, agent: "sleep 0.3\nexit 3")
                let h = try failing.start(.create(prompt: "Animate it\n\nFeedback on the previous attempt (please address it): calmer"),
                                          references: refs, harness: h2, model: nil,
                                          details: AISessionDetails(origin: .cli, feedback: ["calmer"], clonedFrom: nil))
                let copies = failing.records.folder(for: h.id)
                let names = try FileManager.default.contentsOfDirectory(atPath: copies.path).sorted()
                try expectEqual(names, ["asset.jpg", "ref-01.jpg", "ref-02.png", "ref-03.jpg", "session.json"])
                let started = try unwrap(failing.records.load(h.id))
                try expectEqual(started.origin, .cli); try expectEqual(started.feedback, ["calmer"])
                try expectEqual(started.references.map(\.name), ["heron-secret-name.jpg", "cutout-secret.png", "city-secret.jpg"])
                try expectEqual(started.references.map(\.file), ["references/ref-01.jpg", "references/ref-02.png", "references/ref-03.jpg"])
                try expectEqual(started.references.first?.role, .animate)
                try expectEqual(started.animate?.asset, "assets/reference.jpg")
                try expectEqual(started.animate?.sha256, FileDigest.sha256(AIWorkspace(root: h.workspace).scene.appendingPathComponent("assets/reference.jpg")))
                // Names stay out of the workspace; paths are in neither.
                let raw = String(decoding: try Data(contentsOf: failing.records.url(for: h.id)), as: UTF8.self)
                try expect(!raw.contains(sb.root.appendingPathComponent("Pictures").path) && !raw.contains("/refs/"),
                           "no paths of the pictures in the record")
                for file in ["TASK.md", "AGENTS.md", "references/references.json", "references/ref-01.json"] {
                    let text = (try? String(contentsOf: h.workspace.appendingPathComponent(file), encoding: .utf8)) ?? ""
                    try expect(!text.contains("heron-secret-name"), "\(file) names the picture")
                }
                let ended = try collect(h)
                try expectEqual(ended.last, .failed("Fake agent exited with status 3."))
                let after = try unwrap(failing.records.load(h.id))
                try expectEqual(after.outcome?.status, .failed)
                try expectEqual(try FileManager.default.contentsOfDirectory(atPath: copies.path), ["session.json"])
                // Cancelled.
                let (slow, h3) = try sessionFixture(sb, agent: "echo started\nsleep 30")
                let c = try slow.start(.create(prompt: "x"), harness: h3, model: nil)
                _ = try collect(c) { if $0 == .assistantText("started") { c.cancel() } }
                try expectEqual(slow.records.load(c.id)?.outcome?.status, .cancelled)
            }
        },
        TestCase(name: "recovery.decide") {
            try CoreSandbox.with("recover-decide") { sb in
                let (ai, _) = try sessionFixture(sb, agent: "true")
                let runner = LPProcessFacts(pid: 500, group: 500, start: LPProcessStart(seconds: 100, microseconds: 1))
                let agent = LPProcessFacts(pid: 600, group: 600, start: LPProcessStart(seconds: 200, microseconds: 2))
                func later(_ f: LPProcessFacts) -> LPProcessFacts {
                    LPProcessFacts(pid: f.pid, group: f.pid, start: LPProcessStart(seconds: f.start.seconds + 3_600, microseconds: 0))
                }
                func decide(_ r: AISessionRecord, alive: [LPProcessFacts]) -> AISessionRecovery.Decision {
                    AISessionRecovery.decide(r, workspace: AIWorkspace(root: sb.workspaces.appendingPathComponent(r.id))) { pid in
                        alive.first { $0.pid == pid }
                    }
                }
                let (ws, base) = try leftBehind(ai, id: "s-decide") { $0.runner = runner; $0.agent = agent }
                var r = base
                try expectEqual(decide(r, alive: [agent]), .watch(agent: agent))
                try expectEqual(decide(r, alive: [runner, agent]), .leave(.runnerAlive))
                // A pid that now belongs to a later process is someone else's.
                try expectEqual(decide(r, alive: [later(runner), agent]), .watch(agent: agent))
                try expectEqual(decide(r, alive: [later(runner), later(agent)]), .discard)
                var moved = agent; moved.group = 1
                try expectEqual(decide(r, alive: [moved]), .discard)
                try expectEqual(decide(r, alive: []), .discard)
                try sb.write("// embers\n", to: ws.scene.appendingPathComponent("scene.js"))
                try expectEqual(decide(r, alive: [later(agent)]), .review)
                try expectEqual(decide(r, alive: []), .review)
                // Finished and checked, but nobody decided (the app went away during the review).
                r.outcome = .init(status: .passed, checkPassed: true)
                try expectEqual(decide(r, alive: []), .review)
                for settled in [AISessionRecord.Outcome(status: .failed, message: "x"), .init(status: .cancelled, message: "Cancelled.")] {
                    r.outcome = settled
                    try expectEqual(decide(r, alive: [agent]), .leave(.settled))
                }
                r.outcome = nil
                r.resolution = .accepted(sceneID: "embers")
                try expectEqual(decide(r, alive: [agent]), .leave(.settled))
                r.resolution = .discarded
                try expectEqual(decide(r, alive: []), .leave(.settled))
                // No record of the scene's start: the check decides.
                r = base; r.sceneBefore = nil
                try sb.write(CoreSandbox.templateJS, to: ws.scene.appendingPathComponent("scene.js"))
                try expectEqual(decide(r, alive: []), .review)
                try FileManager.default.removeItem(at: ws.root)
                try expectEqual(decide(base, alive: [agent]), .leave(.noWorkspace))

                // What `livepaper ai sessions` shows.
                func state(_ change: (inout AISessionRecord) -> Void, alive: [LPProcessFacts]) -> AISessionRecovery.State {
                    var x = base; change(&x)
                    return AISessionRecovery.state(of: x) { pid in alive.first { $0.pid == pid } }
                }
                try expectEqual(state({ _ in }, alive: [runner, agent]), .running)
                try expectEqual(state({ $0.recoveredAt = Date() }, alive: [runner]), .recovered)
                try expectEqual(state({ _ in }, alive: [agent]), .orphaned)
                try expectEqual(state({ _ in }, alive: [later(agent)]), .unreviewed)
                try expectEqual(state({ $0.outcome = .init(status: .passed) }, alive: []), .unreviewed)
                try expectEqual(state({ $0.outcome = .init(status: .failed) }, alive: []), .failed)
                try expectEqual(state({ $0.outcome = .init(status: .cancelled) }, alive: []), .cancelled)
                try expectEqual(state({ $0.resolution = .accepted(sceneID: "x") }, alive: [runner]), .accepted)
                try expectEqual(state({ $0.resolution = .discarded }, alive: []), .discarded)
            }
        },
        TestCase(name: "recovery.watch-orphaned-agent") {
            // LivePaper went away while the agent worked: a later LivePaper finds it still running,
            // shows its stills, notices its exit at once (a process source, no polling) and checks the
            // result like any session's — scene id from the name, the same history entry.
            try CoreSandbox.with("recover-watch") { sb in
                let (ai, _) = try sessionFixture(sb, agent: "true")
                let (ws, record) = try leftBehind(ai, id: "s-watch")
                let agent = try Orphans.start("""
                mkdir -p scene/.check && cp '\(sb.png.path)' scene/.check/1512x982@2-t4.png
                while [ ! -e .livepaper/go ]; do sleep 0.05; done
                printf 'LivePaper.scene({ draw(lp) { lp.ctx.fillStyle = "#301008"; } });\\n' > scene/scene.js
                printf '{"id":"quiet-aurora","name":"Ember Field","kind":"web"}' > scene/scene.json
                """, in: ws)
                defer { Orphans.kill(agent) }
                ai.records.update(record.id) { $0.agent = agent; return true }
                // The stills the agent renders appear: one is there before the session is picked up.
                let still = ws.scene.appendingPathComponent(".check").appendingPathComponent("1512x982@2-t4.png", isDirectory: false)
                for _ in 0..<200 where !FileManager.default.fileExists(atPath: still.path) { usleep(10_000) }

                let found = ai.recoverSessions()
                try expectEqual(found.map(\.record.id), [record.id])
                let recovered = try unwrap(found.first)
                try expect(recovered.agentRunning && recovered.references.isEmpty)
                let claimed = try unwrap(ai.records.load(record.id))
                try expect(claimed.runner?.isSameProcess(as: ProcessProbe.current) == true && claimed.recoveredAt != nil, "taken over")
                // Another LivePaper launched meanwhile leaves it to this one.
                let (other, _) = try sessionFixture(sb, agent: "true")
                try expect(other.recoverSessions().isEmpty, "two LivePapers never both take a session over")

                final class Timing: @unchecked Sendable { var go: Date?; var done: Date? }
                let timing = Timing()
                let events = try collect(recovered.handle) { event in
                    if event == .status(AISession.recoveredRunningStatus) {
                        timing.go = Date()
                        FileManager.default.createFile(atPath: ws.internalDirectory.appendingPathComponent("go").path, contents: nil)
                    }
                    if case .finished = event { timing.done = Date() }
                }
                try expectEqual(events.first, .status(AISession.recoveredRunningStatus))
                try expect(events.contains(.stillRendered(still)), "\(events)")
                try expect(events.contains(.status("Validating the scene…")))
                try expectEqual(events.last, .finished(package: ws.scene))
                let took = try unwrap(timing.done).timeIntervalSince(try unwrap(timing.go))
                try expect(took < 3, "the exit was noticed promptly: \(took) s")
                try expect(!Orphans.isAlive(agent))
                let m = try SceneManifest.load(package: ws.scene)
                try expectEqual(m.id, "ember-field")
                let history = SceneHistory.entries(in: ws.scene)
                try expectEqual(history.map(\.action), [.create])
                try expectEqual(history.first?.harness, "custom"); try expectEqual(history.first?.model, "m1")
                try expectEqual(history.first?.prompt, record.prompt)
                let after = try unwrap(ai.records.load(record.id))
                try expectEqual(after.outcome?.status, .passed)
                try expect(after.finishedAt != nil && after.resolution == nil)
                // Accepted like any session's result.
                let item = try AICandidate.accept(ws.scene, request: record.request, library: sb.makeLibrary())
                try expectEqual(item.id, "ember-field")
                try expectEqual(SceneHistory.entries(in: item.packageURL).map(\.action), [.create])
            }
        },
        TestCase(name: "recovery.review-left-behind") {
            // The app went away while LivePaper checked a finished session (or before the user decided):
            // the agent is gone, the scene changed. The next LivePaper puts the picture to animate back
            // from its own copy, checks against it, and offers the result with the session's images.
            try CoreSandbox.with("recover-review") { sb in
                let refs = try ReferenceTests.sampleReferences(in: sb.root.appendingPathComponent("Pictures"))
                let (ai, harness) = try sessionFixture(sb, agent: """
                printf 'LivePaper.scene({ draw(lp) { LivePaper.image("reference.jpg"); } });\\n' > scene/scene.js
                printf '{"id":"untitled","name":"Heron Morning","kind":"web"}' > scene/scene.json
                """)
                let first = try ai.start(.create(prompt: "Animate the heron"), references: refs, harness: harness, model: nil)
                try expectEqual(try collect(first).last, .finished(package: AIWorkspace(root: first.workspace).scene))
                let ws = AIWorkspace(root: first.workspace)
                let original = try Data(contentsOf: ws.scene.appendingPathComponent("assets/reference.jpg"))
                // As if LivePaper had died during that check: no outcome, its runner gone — and the
                // agent changed the picture after all.
                ai.records.update(first.id) { r in r.outcome = nil; r.finishedAt = nil; r.runner = goneRunner; return true }
                try Data("not the picture".utf8).write(to: ws.scene.appendingPathComponent("assets/reference.jpg"))

                let checker = FakeChecker.recording()
                let (later, _) = try sessionFixture(sb, checker: checker, agent: "true")
                let found = later.recoverSessions()
                let recovered = try unwrap(found.first)
                try expect(found.count == 1 && !recovered.agentRunning)
                // The images come back from LivePaper's copies, ref-01 (the picture to animate) first.
                try expectEqual(recovered.references.map(\.displayName), ["heron-secret-name.jpg", "cutout-secret.png", "city-secret.jpg"])
                try expectEqual(recovered.references.map(\.role), [.animate, .reference, .reference])
                try expectEqual(recovered.references.first?.master.data, original)
                try expectEqual(recovered.references.map(\.vision.data), ReferenceWorkspace.numbered(refs).map(\.vision.data))
                let events = try collect(recovered.handle)
                try expectEqual(events.first, .status("Recovered: Fake agent finished while LivePaper wasn't running."))
                try expect(events.contains(.status("Put back scene/assets/reference.jpg, which Fake agent had changed.")), "\(events)")
                try expectEqual(events.last, .finished(package: ws.scene))
                try expectEqual(try Data(contentsOf: ws.scene.appendingPathComponent("assets/reference.jpg")), original)
                try expectEqual(checker.recordedOptions.last?.reference?.assetSHA256, FileDigest.sha256(original))
                // Checked and finished once more, still with one history entry.
                let history = SceneHistory.entries(in: ws.scene)
                try expectEqual(history.map(\.action), [.create])
                try expectEqual(history.first?.references, ReferenceCounts(reference: 2, animate: 1))
                try expectEqual(try SceneManifest.load(package: ws.scene).id, "heron-morning")
                // Without LivePaper's copy of the picture it can't be checked as asked.
                ai.records.update(first.id) { r in r.outcome = nil; r.runner = goneRunner; return true }
                try FileManager.default.removeItem(at: ai.records.folder(for: first.id).appendingPathComponent("asset.jpg"))
                let again = try unwrap(later.recoverSessions().first)
                try expect(again.references.count == 2, "the picture to animate can't be offered again")
                let last = try collect(again.handle).last
                try expect({ if case .failed(let m) = last { return m.contains("copy of the picture to animate") }; return false }(), "\(String(describing: last))")
            }
        },
        TestCase(name: "recovery.nothing-happened") {
            try CoreSandbox.with("recover-unchanged") { sb in
                let (ai, _) = try sessionFixture(sb, agent: "true")
                let (_, gone) = try leftBehind(ai, id: "s-gone")
                let (_, spawned) = try leftBehind(ai, id: "s-spawned") { $0.agent = LPProcessFacts(pid: 1, group: 1, start: .init(seconds: 1, microseconds: 0)) }
                try expect(ai.recoverSessions().isEmpty)
                for id in [gone.id, spawned.id] {
                    let r = try unwrap(ai.records.load(id))
                    try expectEqual(r.resolution, .discarded)
                    try expect(r.finishedAt != nil)
                }
                try expect(ai.recoverSessions().isEmpty, "discarded once")
            }
        },
        TestCase(name: "recovery.stop") {
            // Stop on a recovered session stops its agent's group like a cancel; quitting stops it
            // synchronously, also one that ignores SIGTERM and has a child of its own.
            try CoreSandbox.with("recover-stop") { sb in
                let (ai, _) = try sessionFixture(sb, agent: "true")
                let (wsA, a) = try leftBehind(ai, id: "s-stop-a")
                let (wsB, b) = try leftBehind(ai, id: "s-stop-b")
                let agentA = try Orphans.start("while :; do sleep 0.2; done", in: wsA)
                let agentB = try Orphans.start("""
                trap '' TERM
                sh -c 'trap "" TERM; while :; do sleep 0.2; done' &
                echo $! > .livepaper/grandchild.pid
                while :; do sleep 0.2; done
                """, in: wsB)
                defer { Orphans.kill(agentA); Orphans.kill(agentB) }
                ai.records.update(a.id) { $0.agent = agentA; return true }
                ai.records.update(b.id) { $0.agent = agentB; return true }
                let found = Dictionary(uniqueKeysWithValues: ai.recoverSessions().map { ($0.record.id, $0) })
                let sa = try unwrap(found[a.id]), sb2 = try unwrap(found[b.id])
                try expect(sa.agentRunning && sb2.agentRunning)
                let eventsA = try collect(sa.handle) { if $0 == .status(AISession.recoveredRunningStatus) { sa.handle.cancel() } }
                try expectEqual(eventsA.last, .failed("Cancelled."))
                try expect(!Orphans.isAlive(agentA) && killpg(agentA.group, 0) != 0, "stopped with its group")
                try expectEqual(ai.records.load(a.id)?.outcome?.status, .cancelled)

                let terminating = try unwrap(sb2.handle as? AISessionTerminating)
                for _ in 0..<200 where !FileManager.default.fileExists(atPath: wsB.internalDirectory.appendingPathComponent("grandchild.pid").path) {
                    usleep(10_000)
                }
                let grandchild = pid_t((try? String(contentsOf: wsB.internalDirectory.appendingPathComponent("grandchild.pid"), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
                try expect(grandchild > 0)
                let began = Date()
                try expect(terminating.terminateNow(grace: 0.3), "the group emptied")
                try expect(Date().timeIntervalSince(began) < 2)
                try expect(kill(agentB.pid, 0) != 0 && kill(grandchild, 0) != 0 && killpg(agentB.group, 0) != 0, "nothing left")
                try expectEqual(try collect(sb2.handle).last, .failed("Cancelled."))
            }
        },
        TestCase(name: "recovery.pid-reused") {
            // Nothing ever signals a process whose start time doesn't match the record — not recovery,
            // not Stop All, not uninstall's sweep of orphaned agents.
            try CoreSandbox.with("recover-reuse") { sb in
                let (ai, _) = try sessionFixture(sb, agent: "true")
                let (ws, _) = try leftBehind(ai, id: "s-reuse-1")
                let someone = try Orphans.start("while :; do sleep 0.2; done", in: ws)
                defer { Orphans.kill(someone) }
                var impostor = someone
                impostor.start.microseconds += 1
                ai.records.update("s-reuse-1") { $0.agent = impostor; return true }
                // Changed scene, so it isn't simply discarded: reviewed — and the process left alone.
                let (ws2, _) = try leftBehind(ai, id: "s-reuse-2") { $0.agent = impostor }
                try sb.write("// changed\n", to: ws2.scene.appendingPathComponent("scene.js"))
                let found = ai.recoverSessions()
                try expectEqual(found.map(\.record.id), ["s-reuse-2"])
                try expect(found.allSatisfy { !$0.agentRunning })
                try expectEqual(ai.records.load("s-reuse-1")?.resolution, .discarded)
                found.forEach { $0.handle.cancel() }
                _ = try collect(found[0].handle)
                try expect(Orphans.isAlive(someone), "a process with the agent's pid but another start time is someone else's")
                // Uninstall's sweep: an orphan whose runner is gone is stopped, one with a live
                // runner (another LivePaper's session) or a wrong start time is not.
                _ = try leftBehind(ai, id: "s-reuse-3") { $0.agent = impostor }
                _ = try leftBehind(ai, id: "s-reuse-4") { $0.agent = someone; $0.runner = ProcessProbe.current }
                try expectEqual(ai.stopOrphanedAgents(grace: 0.3), 0)
                try expect(Orphans.isAlive(someone))
                _ = try leftBehind(ai, id: "s-reuse-5") { $0.agent = someone }
                try expectEqual(ai.stopOrphanedAgents(grace: 0.3), 1)
                try expect(!Orphans.isAlive(someone) && killpg(someone.group, 0) != 0)
            }
        },
        TestCase(name: "recovery.prune") {
            try CoreSandbox.with("recover-prune") { sb in
                let (ai, _) = try sessionFixture(sb, agent: "true")
                let store = ai.records
                let agent = LPProcessFacts(pid: 700, group: 700, start: LPProcessStart(seconds: 7, microseconds: 7))
                let reviewer = LPProcessFacts(pid: 800, group: 800, start: LPProcessStart(seconds: 8, microseconds: 8))
                let alive = [agent, reviewer]
                let probe: (pid_t) -> LPProcessFacts? = { pid in alive.first { $0.pid == pid } }
                func age(_ ws: AIWorkspace, days: Double) throws {
                    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: ws.root.path)
                }
                // An unreviewed recovered session a week old goes with its workspace, even while the
                // app that recovered it waits for a decision.
                let (old, _) = try leftBehind(ai, id: "s-old") { r in
                    r.runner = reviewer; r.recoveredAt = Date(); r.outcome = .init(status: .passed, checkPassed: true)
                }
                try age(old, days: 8)
                // One whose agent still runs stays, however old its workspace looks.
                let (running, _) = try leftBehind(ai, id: "s-running") { $0.agent = agent }
                try age(running, days: 8)
                // A settled session keeps its record (and workspace) for the week, without the image copies.
                _ = try ai.workspaceBuilder.buildSession(.create(prompt: "x"), sessionID: "s-settled")
                var settled = AISessionRecord(id: "s-settled", origin: .app, runner: nil, request: .create(prompt: "x"), harness: fakeHarness,
                                              model: nil, timeout: 60)
                settled.resolution = .accepted(sceneID: "x")
                try store.create(settled, copies: ["ref-01.jpg": Data("jpg".utf8)])
                // As old as its record says, even when something touched its workspace since.
                let (touched, _) = try leftBehind(ai, id: "s-touched") { $0.startedAt = Date().addingTimeInterval(-9 * 86_400) }
                // A record whose workspace is gone goes too.
                try store.create(AISessionRecord(id: "s-orphan-record", origin: .app, runner: nil, request: .create(prompt: "x"),
                                                 harness: fakeHarness, model: nil, timeout: 60))
                ai.workspaceBuilder.pruneWorkspaces(probe: probe)
                try expect(!FileManager.default.fileExists(atPath: old.root.path) && store.load("s-old") == nil, "pruned with its workspace")
                try expect(FileManager.default.fileExists(atPath: running.root.path) && store.load("s-running") != nil, "in use")
                try expect(store.load("s-settled") != nil && store.copy(named: "ref-01.jpg", for: "s-settled") == nil)
                try expect(!FileManager.default.fileExists(atPath: store.folder(for: "s-orphan-record").path))
                try expect(!FileManager.default.fileExists(atPath: touched.root.path) && store.load("s-touched") == nil)
                // Once its agent is gone, it goes too.
                ai.workspaceBuilder.pruneWorkspaces(probe: { _ in nil })
                try expect(!FileManager.default.fileExists(atPath: running.root.path) && store.load("s-running") == nil)
            }
        },
        TestCase(name: "recovery.accept-derives-id") {
            // Every accept path names a created scene after itself: never the template's id
            // ("quiet-aurora" leaked into a hand import) or one an agent typed.
            try CoreSandbox.with("accept-id") { sb in
                let lib = sb.makeLibrary()
                func candidate(_ name: String, id: String) throws -> URL {
                    let dir = sb.root.appendingPathComponent("candidates/\(UUID().uuidString.prefix(6))/scene")
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try SceneManifest(id: id, name: name, kind: .web).write(package: dir)
                    try sb.write("LivePaper.scene({ draw(lp) {} });\n", to: dir.appendingPathComponent("scene.js"))
                    return dir
                }
                let first = try AICandidate.accept(try candidate("Ember Field", id: "quiet-aurora"), request: .create(prompt: "x"), library: lib)
                try expectEqual(first.id, "ember-field")
                let second = try AICandidate.accept(try candidate("Ember Field", id: "quiet-aurora"), request: .create(prompt: "x"), library: lib)
                try expectEqual(second.id, "ember-field-2")
                let typed = try AICandidate.accept(try candidate("Slow Tide", id: "my-cool-id"), request: .create(prompt: "x"), library: lib)
                try expectEqual(typed.id, "slow-tide")
                let template = try lib.scene(id: "quiet-aurora")
                try expect(template == nil)
                // Changing a scene keeps its id, whatever the candidate says.
                _ = try lib.createWebScene(name: "Sky", description: "")
                let replaced = try AICandidate.accept(try candidate("Starry Sky", id: "quiet-aurora"), request: .modify(sceneID: "sky", prompt: "x"),
                                                      library: lib)
                try expectEqual(replaced.id, "sky")
                try expectEqual(replaced.manifest.name, "Starry Sky")
            }
        },
    ] }

    /// A harness for records that are never run.
    static let fakeHarness = AIHarness.custom(template: "/bin/sh agent.sh", name: "Fake agent")

    /// A runner that is gone: this process's pid with another start time (as after a pid reuse).
    static var goneRunner: LPProcessFacts {
        LPProcessFacts(pid: getpid(), group: getpgrp(), start: LPProcessStart(seconds: 1, microseconds: 0))
    }

    /// A session an earlier LivePaper left behind: its workspace (built as for any session) and a
    /// record whose runner is gone, started a minute ago. `configure` changes the record before it
    /// is written.
    @discardableResult
    static func leftBehind(_ ai: AIService, id: String, request: AISessionRequest = .create(prompt: "Embers drifting over a dark field"),
                           configure: (inout AISessionRecord) -> Void = { _ in }) throws -> (AIWorkspace, AISessionRecord) {
        let built = try ai.workspaceBuilder.buildSession(request, sessionID: id)
        var record = AISessionRecord(id: id, origin: .app, runner: goneRunner, request: request, prompt: built.taskPrompt,
                                     harness: fakeHarness, model: "m1", timeout: 600,
                                     sceneBefore: FileDigest.sha256(built.workspace.scene.appendingPathComponent("scene.js")),
                                     startedAt: Date().addingTimeInterval(-60))
        configure(&record)
        try ai.records.create(record)
        return (built.workspace, record)
    }

    /// Agents that outlive their app.
    enum Orphans {
        /// Starts the /bin/sh `script` as an agent is once its app has gone: working in `ws`, leading a
        /// process group of its own, and not this process's child (the shell that starts it exits at
        /// once, so launchd adopts it).
        static func start(_ script: String, in ws: AIWorkspace) throws -> LPProcessFacts {
            let file = ws.internalDirectory.appendingPathComponent("agent-\(UUID().uuidString.prefix(6)).sh")
            try FileManager.default.createDirectory(at: ws.internalDirectory, withIntermediateDirectories: true)
            try Data((script + "\n").utf8).write(to: file)
            let pidFile = file.appendingPathExtension("pid")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            // `set -m`: the background job gets a process group of its own. No pipes: nothing of this
            // process may stay open in the agent.
            p.arguments = ["-c", #"set -m; cd "$1" || exit 1; /bin/sh "$2" </dev/null >/dev/null 2>&1 & echo $! > "$3""#, "sh",
                           ws.root.path, file.path, pidFile.path]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            let text = (try? String(contentsOf: pidFile, encoding: .utf8)) ?? ""
            guard let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw TestFailure(description: "no agent pid: \(text)")
            }
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let facts = ProcessProbe.facts(pid), facts.group == pid { return facts }
                usleep(10_000)
            }
            throw TestFailure(description: "agent \(pid) didn't get a group of its own")
        }

        static func isAlive(_ agent: LPProcessFacts) -> Bool { agent.isSameProcess(as: ProcessProbe.facts(agent.pid)) }

        /// Clean-up: only ever a group these tests started, and only while it is that process.
        static func kill(_ agent: LPProcessFacts) {
            if isAlive(agent) { _ = killpg(agent.group, SIGKILL) }
        }
    }
}

extension FakeChecker {
    /// Passes, remembering the options (CheckOptions.reference) of every check.
    static func recording() -> FakeChecker { FakeChecker { _ in CheckReport(passed: true) } }
}
