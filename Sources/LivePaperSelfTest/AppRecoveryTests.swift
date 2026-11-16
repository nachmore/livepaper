// Self tests for recovered AI sessions in the app (AppModel.recoverSessions, AISessionModel): a real
// AIService (records, recovery) under an AppModel with a real library and mocks for the rest. The
// agents are real processes these tests start, orphaned the way an agent is once its app is gone
// (SelfTests.Orphans); nothing else is ever signalled. Scratch directories only.
import Darwin
import Foundation
import LivePaperCore

extension SelfTests {
    static var recoveryApp: [TestCase] { [
        TestCase(name: "recovery.app.still-running") {
            // LivePaper went away while the agent worked; the next launch shows the session as
            // "Still working (recovered)" among the AI jobs, with the agent's stills, and reviews it
            // once the agent finishes.
            try withScratchPaths("rec-app-running") { root in
                let fx = try recoveryFixture(root: root)
                let (ws, record) = try leftBehind(fx.ai, id: "s-app-running")
                let agent = try Orphans.start("""
                mkdir -p scene/.check && printf 'png' > scene/.check/1512x982@2-t4.png
                while [ ! -e .livepaper/go ]; do sleep 0.05; done
                printf '// embers\\n' > scene/scene.js
                printf '{"id":"quiet-aurora","name":"Ember Field","kind":"web"}' > scene/scene.json
                """, in: ws)
                defer { Orphans.kill(agent) }
                fx.ai.records.update(record.id) { $0.agent = agent; return true }
                try MainActor.assumeIsolated {
                    let model = AppModel(services: fx.services, environment: testEnvironment(root: root, saved: SavedStates()))
                    try awaitMain { await model.start() }
                    let session = try unwrap(model.session(id: record.id))
                    try expect(session.isRecovered && session.isRunning)
                    try awaitMain(until: { session.state.lastStatus == AISession.recoveredRunningStatus })
                    // In the menu bar's AI jobs (Stop All stops it), marked as recovered.
                    try expectEqual(model.runningSessions.map(\.id), [record.id])
                    try expect(session.menuTitle.hasSuffix("\u{2014} Still working (recovered)"), session.menuTitle)
                    try expect(model.hasAgentsToStop)
                    let banner = try unwrap(model.banners.banners.first { $0.title == "Recovered an AI session" })
                    try expect(banner.message?.contains("was still running when LivePaper quit") == true, banner.message ?? "")
                    banner.actions.first?.perform()
                    try expectEqual(model.section, .session(record.id))
                    // Its time and settings are the earlier run's.
                    try expect(abs(session.startedAt.timeIntervalSince(record.startedAt)) < 1)
                    try expectEqual(session.timeout, record.timeout)
                    try expectEqual(session.model, "m1"); try expectEqual(session.harness, fakeHarness)
                    try awaitMain(until: { session.state.stills.count == 1 })
                    FileManager.default.createFile(atPath: ws.internalDirectory.appendingPathComponent("go").path, contents: nil)
                    try awaitMain(until: { !session.isRunning })
                    guard case .succeeded = session.state.phase else { throw TestFailure(description: "phase \(session.state.phase)") }
                    try expectEqual(session.state.report?.passed, true)
                    try expect(!Orphans.isAlive(agent))
                    // Waiting for a decision: the menu bar lists it.
                    try expect(model.sessions.contains { $0 === session && $0.state.package != nil && $0.resolution == nil })
                    try expect(session.menuTitle.hasSuffix("\u{2014} Ready to review (recovered)"), session.menuTitle)
                    // A second start (Reload) takes nothing over twice.
                    try awaitMain { await model.start() }
                    try expectEqual(model.sessions.filter { $0.id == record.id }.count, 1)
                }
            }
        },
        TestCase(name: "recovery.app.review-accept") {
            // The agent finished while LivePaper wasn't running (the incident this is for): the next
            // launch checks the scene and offers it; accepting names it after itself — never the
            // template's "quiet-aurora" — with the history entry a normal session writes.
            try withScratchPaths("rec-app-review") { root in
                let fx = try recoveryFixture(root: root)
                let (ws, record) = try leftBehind(fx.ai, id: "s-app-review")
                try Data("LivePaper.scene({ draw(lp) {} }); // embers\n".utf8).write(to: ws.scene.appendingPathComponent("scene.js"))
                try Data(#"{"schema":1,"id":"quiet-aurora","name":"Ember Field","kind":"web","runtime":1}"#.utf8)
                    .write(to: ws.scene.appendingPathComponent("scene.json"))
                try MainActor.assumeIsolated {
                    let model = AppModel(services: fx.services, environment: testEnvironment(root: root, saved: SavedStates()))
                    try awaitMain { await model.start() }
                    let session = try unwrap(model.session(id: record.id))
                    try expect(session.isRecovered)
                    try awaitMain(until: { !session.isRunning })
                    guard case .succeeded(let package) = session.state.phase else { throw TestFailure(description: "phase \(session.state.phase)") }
                    try expectEqual(package, ws.scene)
                    try expect(session.state.entries.contains { $0.kind == .status("Recovered: Fake agent finished while LivePaper wasn't running.") })
                    let banner = try unwrap(model.banners.banners.first { $0.title == "Recovered an AI session" })
                    try expect(banner.message?.contains("finished while LivePaper wasn't running") == true, banner.message ?? "")
                    var added: SceneItem?
                    try awaitMain { added = await model.accept(session) }
                    let item = try unwrap(added)
                    try expectEqual(item.id, "ember-field")
                    try expect(model.entry(id: "ember-field") != nil && model.entry(id: "quiet-aurora") == nil)
                    try expectEqual(session.resolution, .accepted(sceneID: "ember-field"))
                    let history = SceneHistory.entries(in: item.packageURL)
                    try expectEqual(history.map(\.action), [.create])
                    try expectEqual(history.first?.harness, "custom"); try expectEqual(history.first?.model, "m1")
                    try expectEqual(history.first?.prompt, record.prompt)
                    try expectEqual(fx.ai.records.load(record.id)?.resolution, .accepted(sceneID: "ember-field"))
                    // A normal session's accept goes the same way: the template's id never survives.
                    let normal = try started(model, .create(prompt: "Ink drops blooming in water"), harness: fx.harness, model: nil)
                    try awaitMain(until: { !normal.isRunning })
                    var second: SceneItem?
                    try awaitMain { second = await model.accept(normal) }
                    try expectEqual(second?.id, "ink-bloom")
                    try expectEqual(fx.ai.records.load(normal.id)?.resolution, .accepted(sceneID: "ink-bloom"))
                }
            }
        },
        TestCase(name: "recovery.app.retry-keeps-references") {
            // Try Again with Feedback on a recovered session keeps its reference images (rebuilt from
            // LivePaper's own copies — no original is opened) and adds to the feedback chain.
            try withScratchPaths("rec-app-retry") { root in
                let fx = try recoveryFixture(root: root)
                let refs = try ReferenceTests.sampleReferences(in: root.appendingPathComponent("Pictures"))
                let first = try fx.ai.start(.create(prompt: "Animate the heron"), references: refs, harness: fx.harness, model: nil,
                                            details: AISessionDetails(feedback: []))
                _ = try collect(first)
                // As if LivePaper had gone away before the user decided.
                fx.ai.records.update(first.id) { r in r.runner = goneRunner; r.outcome = nil; return true }
                try MainActor.assumeIsolated {
                    let model = AppModel(services: fx.services, environment: testEnvironment(root: root, saved: SavedStates()))
                    try awaitMain { await model.start() }
                    let session = try unwrap(model.session(id: first.id))
                    try awaitMain(until: { !session.isRunning })
                    guard case .succeeded = session.state.phase else { throw TestFailure(description: "phase \(session.state.phase)") }
                    try expectEqual(session.references.map(\.displayName), ["heron-secret-name.jpg", "cutout-secret.png", "city-secret.jpg"])
                    try expectEqual(session.referenceCounts, ReferenceCounts(reference: 2, animate: 1))
                    let next = try retried(model, session, feedback: "  Slower, please ")
                    try expect(!next.isRecovered)
                    try expectEqual(next.references.map(\.displayName), session.references.map(\.displayName))
                    try expectEqual(next.references.map(\.role), [.animate, .reference, .reference])
                    try expectEqual(next.feedback, ["Slower, please"])
                    try expect(next.prompt.contains("Slower, please"), next.prompt)
                    try awaitMain(until: { !next.isRunning })
                    guard case .succeeded = next.state.phase else { throw TestFailure(description: "retry: \(next.state.phase)") }
                    let nextRecord = try unwrap(fx.ai.records.load(next.id))
                    try expectEqual(nextRecord.feedback, ["Slower, please"])
                    try expectEqual(nextRecord.references.map(\.name), ["heron-secret-name.jpg", "cutout-secret.png", "city-secret.jpg"])
                    // The same picture to animate went into the new scene.
                    try expectEqual(try Data(contentsOf: next.workspace.appendingPathComponent("scene/assets/reference.jpg")),
                                    try Data(contentsOf: first.workspace.appendingPathComponent("scene/assets/reference.jpg")))
                    try awaitMain(until: { fx.ai.records.load(first.id)?.resolution == .discarded })
                    try expect(model.session(id: first.id) == nil, "the retry replaces it")
                }
            }
        },
        TestCase(name: "recovery.app.discard") {
            try withScratchPaths("rec-app-discard") { root in
                let fx = try recoveryFixture(root: root)
                // Nothing happened in this one: gone without a trace, no banner.
                let (_, quiet) = try leftBehind(fx.ai, id: "s-app-nothing")
                let (ws, changed) = try leftBehind(fx.ai, id: "s-app-discard")
                try Data("LivePaper.scene({ draw(lp) {} }); // v2\n".utf8).write(to: ws.scene.appendingPathComponent("scene.js"))
                try MainActor.assumeIsolated {
                    let model = AppModel(services: fx.services, environment: testEnvironment(root: root, saved: SavedStates()))
                    try awaitMain { await model.start() }
                    try expectEqual(model.sessions.map(\.id), [changed.id])
                    try expectEqual(fx.ai.records.load(quiet.id)?.resolution, .discarded)
                    try expectEqual(model.banners.banners.filter { $0.title.hasPrefix("Recovered") }.count, 1)
                    let session = try unwrap(model.session(id: changed.id))
                    try awaitMain(until: { !session.isRunning })
                    model.section = .session(session.id)
                    model.discard(session)
                    try expect(model.sessions.isEmpty)
                    try expectEqual(model.section, .create)
                    try awaitMain(until: { fx.ai.records.load(changed.id)?.resolution == .discarded })
                    // Never offered again.
                    let again = AppModel(services: fx.services, environment: testEnvironment(root: root, saved: SavedStates()))
                    try awaitMain { await again.start() }
                    try expect(again.sessions.isEmpty)
                }
            }
        },
        TestCase(name: "recovery.app.quit-and-uninstall-stop-agents") {
            // Quitting (Stop All, ⌘Q, SIGTERM) stops recovered agents like any other — this one ignores
            // SIGTERM. Uninstalling also stops orphans no session watches (their app went away after
            // this launch).
            try withScratchPaths("rec-app-quit") { root in
                let fx = try recoveryFixture(root: root)
                let (ws, record) = try leftBehind(fx.ai, id: "s-app-quit")
                let agent = try Orphans.start("trap '' TERM\nwhile :; do sleep 0.2; done", in: ws)
                defer { Orphans.kill(agent) }
                fx.ai.records.update(record.id) { $0.agent = agent; return true }
                try MainActor.assumeIsolated {
                    let model = AppModel(services: fx.services, environment: testEnvironment(root: root, saved: SavedStates()))
                    try awaitMain { await model.start() }
                    let session = try unwrap(model.session(id: record.id))
                    try awaitMain(until: { session.state.lastStatus == AISession.recoveredRunningStatus })
                    let began = Date()
                    try awaitMain { await model.stopAllAgents() }
                    try expect(Date().timeIntervalSince(began) < AgentShutdown.limit)
                    try expect(!Orphans.isAlive(agent) && killpg(agent.group, 0) != 0, "stopped before LivePaper would exit")
                    try expectEqual(session.state.phase, .cancelled)
                    try awaitMain(until: { fx.ai.records.load(record.id)?.outcome?.status == .cancelled })

                    let later = AppModel(services: fx.services, environment: testEnvironment(root: root, saved: SavedStates()))
                    try awaitMain { await later.start() }
                    try expect(later.sessions.isEmpty, "a cancelled session isn't recovered")
                    let (ws2, orphan) = try leftBehind(fx.ai, id: "s-app-orphan")
                    let stray = try Orphans.start("while :; do sleep 0.2; done", in: ws2)
                    defer { Orphans.kill(stray) }
                    fx.ai.records.update(orphan.id) { $0.agent = stray; return true }
                    try awaitMain { _ = await later.uninstall(keepScenes: true) }
                    try expect(!Orphans.isAlive(stray), "uninstall stopped the orphaned agent")
                }
            }
        },
        TestCase(name: "recovery.app.expire") {
            // Unreviewed recovered sessions don't outlive the workspace retention: pruned at launch,
            // and dropped from a LivePaper that has been running since.
            try withScratchPaths("rec-app-expire") { root in
                let fx = try recoveryFixture(root: root)
                let (oldWS, old) = try leftBehind(fx.ai, id: "s-app-old") { $0.startedAt = Date().addingTimeInterval(-8 * 86_400) }
                try Data("// v2\n".utf8).write(to: oldWS.scene.appendingPathComponent("scene.js"))
                let (ws, recent) = try leftBehind(fx.ai, id: "s-app-recent")
                try Data("// v2\n".utf8).write(to: ws.scene.appendingPathComponent("scene.js"))
                try MainActor.assumeIsolated {
                    let model = AppModel(services: fx.services, environment: testEnvironment(root: root, saved: SavedStates()))
                    try awaitMain { await model.start() }
                    try expectEqual(model.sessions.map(\.id), [recent.id])
                    try expect(!FileManager.default.fileExists(atPath: oldWS.root.path) && fx.ai.records.load(old.id) == nil,
                               "a week-old session is pruned with its workspace")
                    let session = try unwrap(model.session(id: recent.id))
                    try awaitMain(until: { !session.isRunning })
                    model.section = .session(recent.id)
                    model.expireOldSessions(now: Date().addingTimeInterval(6 * 86_400))
                    try expectEqual(model.sessions.count, 1)
                    model.expireOldSessions(now: Date().addingTimeInterval(8 * 86_400))
                    try expect(model.sessions.isEmpty)
                    try expectEqual(model.section, .create)
                }
            }
        },
    ] }

    struct RecoveryFixture {
        let services: LivePaperServices
        let ai: AIService
        /// The harness new sessions run: an agent that writes a scene named "Ink Bloom".
        let harness: AIHarness
        let library: LibraryService
    }

    /// A real AIService (records, recovery; a check that passes) and a real library over `root`,
    /// with the template LivePaper ships ("quiet-aurora"), under mocks for everything else.
    static func recoveryFixture(root: URL) throws -> RecoveryFixture {
        let fm = FileManager.default
        let runtime = root.appendingPathComponent("Runtime"), builtins = root.appendingPathComponent("Builtin")
        let template = runtime.appendingPathComponent("templates/web")
        try fm.createDirectory(at: template, withIntermediateDirectories: true)
        try fm.createDirectory(at: builtins, withIntermediateDirectories: true)
        try Data("# Agent guide\n".utf8).write(to: runtime.appendingPathComponent("AGENTS.md"))
        try SceneManifest(id: "quiet-aurora", name: "Quiet Aurora", kind: .web).write(package: template)
        try Data("LivePaper.scene({ draw(lp) {} });\n".utf8).write(to: template.appendingPathComponent("scene.js"))
        let script = root.appendingPathComponent("agent.sh")
        try Data("""
        printf 'LivePaper.scene({ draw(lp) { lp.ctx.fillStyle = "#123"; } });\\n' > scene/scene.js
        printf '{"id":"quiet-aurora","name":"Ink Bloom","kind":"web"}' > scene/scene.json

        """.utf8).write(to: script)
        let library = LibraryService(libraryDirectory: root.appendingPathComponent("Library"), builtinDirectory: builtins,
                                     templateDirectory: template)
        let builder = WorkspaceBuilder(library: library, runtimeDirectory: runtime, builtinScenesDirectory: builtins,
                                       workspacesDirectory: root.appendingPathComponent("Workspaces"), cliPath: URL(fileURLWithPath: "/usr/bin/false"))
        let detector = HarnessDetector(shell: .fixed(ShellSnapshot(environment: ["PATH": "/usr/bin:/bin"])), directories: [])
        let ai = AIService(library: library, checker: FakeChecker { _ in CheckReport(passed: true) }, workspaceBuilder: builder,
                           detector: detector, runner: RecordingCommandRunner(), settingsURL: root.appendingPathComponent("ai-settings.json"),
                           timeout: 600)
        let mock = try MockServices.make(root: root.appendingPathComponent("Mock"), pace: 0)
        let services = LivePaperServices(library: library, publish: mock.publish, ai: ai, install: mock.install, render: mock.render,
                                         checker: mock.checker, compiler: mock.compiler)
        return RecoveryFixture(services: services, ai: ai, harness: AIService.customHarness(template: "/bin/sh '\(script.path)'",
                                                                                            name: "Scripted agent"),
                               library: library)
    }
}
