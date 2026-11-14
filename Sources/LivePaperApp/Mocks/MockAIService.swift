// MockAIService — a believable stand-in for an AI agent session: detects three harnesses and
// streams the kind of event sequence a real agent produces (reading the SDK, writing the scene,
// running `livepaper check`, fixing a budget problem, rendering stills), then hands back a real
// candidate package on disk. A prompt containing "fail" exercises the failure path.
import Foundation
import LivePaperCore

final class MockAIService: AIServicing, @unchecked Sendable {
    private let library: MockLibraryService
    private let workspaces: URL
    private let pace: Double
    /// Snapshot/test hook: sessions stop after this many scripted steps and keep "running" until
    /// cancelled, which freezes the UI in its mid-session state.
    var holdAfterSteps: Int?

    init(library: MockLibraryService, workspaces: URL, pace: Double) {
        self.library = library
        self.workspaces = workspaces
        self.pace = pace
    }

    func detectHarnesses() async -> [AIHarness] {
        try? await MockServices.pause(0.8, pace: pace)
        return [
            AIHarness(kind: .claude, name: "Claude Code", executable: "/usr/local/bin/claude", version: "2.1.4"),
            AIHarness(kind: .codex, name: "Codex", executable: "/opt/homebrew/bin/codex", version: "0.58.0"),
            AIHarness(kind: .kiro, name: "Kiro CLI", executable: "/usr/local/bin/kiro-cli", version: "1.20.0"),
        ]
    }

    func start(_ request: AISessionRequest, harness: AIHarness, model: String?) throws -> AISessionHandle {
        let id = "session-" + UUID().uuidString.prefix(8).lowercased()
        let workspace = workspaces.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("scene"), withIntermediateDirectories: true)
        var base: SceneItem?
        if case .modify(let sceneID, _) = request {
            guard let item = try library.scene(id: sceneID) else { throw LibraryError.notFound(sceneID) }
            base = item
        }
        let session = MockAISession(id: id, workspace: workspace)
        session.run(MockAIScript(request: request, harness: harness, model: model, base: base, workspace: workspace), pace: pace,
                    holdAfter: holdAfterSteps)
        return session
    }
}

final class MockAISession: AISessionHandle, @unchecked Sendable {
    let id: String
    let workspace: URL
    let events: AsyncStream<AISessionEvent>
    private let continuation: AsyncStream<AISessionEvent>.Continuation
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(id: String, workspace: URL) {
        self.id = id
        self.workspace = workspace
        var c: AsyncStream<AISessionEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    func run(_ script: MockAIScript, pace: Double, holdAfter: Int? = nil) {
        let continuation = self.continuation
        let t = Task.detached {
            do {
                let steps = script.steps()
                for step in steps.prefix(holdAfter ?? steps.count) {
                    try await MockServices.pause(step.delay, pace: pace)
                    if let event = try step.make() { continuation.yield(event) }
                }
                if holdAfter != nil {
                    // Stay "running" until cancelled (the stream is finished by cancel()).
                    while !Task.isCancelled { try await Task.sleep(nanoseconds: 1_000_000_000) }
                }
            } catch is CancellationError {
                // Cancelled by the user: the real service kills the harness process group.
            } catch {
                continuation.yield(.failed(error.localizedDescription))
            }
            continuation.finish()
        }
        lock.lock(); task = t; lock.unlock()
    }

    func cancel() {
        lock.lock(); let t = task; lock.unlock()
        t?.cancel()
        continuation.finish()
    }
}

/// The scripted conversation for one mock session.
struct MockAIScript: Sendable {
    struct Step: Sendable {
        var delay: Double
        var make: @Sendable () throws -> AISessionEvent?
    }

    let request: AISessionRequest
    let harness: AIHarness
    let model: String?
    let base: SceneItem?
    let workspace: URL

    var prompt: String { PromptComposer.prompt(of: request) }
    var shouldFail: Bool { prompt.range(of: "fail", options: .caseInsensitive) != nil }

    var style: MockArtwork.Style {
        if let base { return .forScene(id: base.id, tags: base.manifest.tags) }
        let p = prompt.lowercased()
        let keywords: [(String, MockArtwork.Style)] = [
            ("aurora", .aurora), ("northern", .aurora), ("dune", .dunes), ("desert", .dunes), ("lantern", .lanterns),
            ("rain", .rain), ("city", .rain), ("ocean", .ocean), ("sea", .ocean), ("coast", .ocean), ("orbit", .orbit),
            ("planet", .orbit), ("space", .orbit), ("fog", .fog), ("forest", .fog), ("mist", .fog), ("ink", .ink),
            ("glass", .glass),
        ]
        return keywords.first { p.contains($0.0) }?.1 ?? MockArtwork.Style.forScene(id: prompt, tags: [])
    }

    var sceneName: String {
        if let base { return base.manifest.name }
        switch style {
        case .aurora: return "Aurora Mirror"
        case .dunes: return "Dusk Dunes"
        case .lanterns: return "Lantern Night"
        case .rain: return "Window Rain"
        case .ocean: return "Low Tide"
        case .orbit: return "Small Orbit"
        case .fog: return "Pine Fog"
        case .ink: return "Ink Drift"
        case .glass: return "Glass Tide"
        }
    }

    private var sceneDir: URL { workspace.appendingPathComponent("scene") }

    func steps() -> [Step] {
        let harnessName = harness.uiTitle
        let style = self.style
        let seed = MockArtwork.stableHash(workspace.lastPathComponent)
        let stillsDir = workspace.appendingPathComponent("stills")
        func still(_ n: Int, t: Double, wide: Bool = false) -> Step {
            Step(delay: 1.2) {
                try FileManager.default.createDirectory(at: stillsDir, withIntermediateDirectories: true)
                let url = stillsDir.appendingPathComponent("still-\(n).png")
                MockArtwork.writeImage(style: style, seed: seed, width: wide ? 640 : 480, height: wide ? 180 : 300, t: t, to: url)
                return .stillRendered(url)
            }
        }
        func say(_ delay: Double, _ e: AISessionEvent) -> Step { Step(delay: delay) { e } }
        let isModify = base != nil

        var s: [Step] = [
            say(0.3, .status("Preparing workspace\u{2026}")),
            say(0.8, .status("Running \(harnessName)\(model.map { " (\($0))" } ?? "")\u{2026}")),
            say(1.5, .assistantText(isModify
                ? "I'll read the current scene and the scene API first so the change fits the existing structure."
                : "I'll start by reading the scene API and the template, then sketch the layers.")),
            say(0.6, .toolUse(name: "Read", detail: "sdk/SCENE_API.md")),
            say(0.4, .toolUse(name: "Read", detail: "sdk/livepaper.d.ts")),
            say(0.4, .toolUse(name: "Read", detail: "scene/scene.js")),
            say(2.0, .assistantText(isModify
                ? "Plan: keep the palette and composition, apply the requested change in update(), and avoid new per-frame allocations."
                : "Plan: a gradient sky, three slow layers with parallax, and a calm area at the top so the clock stays readable. Everything is driven by lp.t so stills are deterministic.")),
            say(2.5, .toolUse(name: "Write", detail: "scene/scene.js (214 lines)")),
            say(0.8, .toolUse(name: "Bash", detail: "livepaper check scene --quick")),
        ]
        if shouldFail {
            s.append(say(1.5, .assistantText("The check could not start the render service.")))
            s.append(say(0.6, .failed("\(harness.name) exited with status 1: rate limit reached. Try again in a few minutes.")))
            return s
        }
        s += [
            still(1, t: 4),
            say(1.6, .assistantText("The quick check passes, but the bench is 5.2 ms/frame at 1512\u{00D7}982@2, over the 4 ms budget. I'll pre-render the static layers into an offscreen canvas and draw fewer glow sprites.")),
            say(2.0, .toolUse(name: "Edit", detail: "scene/scene.js: cache static layers in setup()")),
            say(0.8, .toolUse(name: "Edit", detail: "scene/scene.js: scale sprite count by lp.quality")),
            say(0.8, .toolUse(name: "Bash", detail: "livepaper check scene")),
            still(2, t: 12),
            still(3, t: 20, wide: true),
            say(1.4, .assistantText("Bench is now 1.6 ms/frame and the clock region stays dark. Done \u{2014} the scene is in ./scene.")),
            say(0.6, .status("Validating with livepaper check\u{2026}")),
            Step(delay: 1.5) { .checkResult(try self.writeCandidate(style: style, seed: seed)) },
            still(4, t: 600),
            Step(delay: 0.4) { .finished(package: self.sceneDir) },
        ]
        return s
    }

    /// Writes the candidate package the session hands back and returns its check report.
    private func writeCandidate(style: MockArtwork.Style, seed: UInt64) throws -> CheckReport {
        let fm = FileManager.default
        try fm.createDirectory(at: sceneDir, withIntermediateDirectories: true)
        var manifest = base?.manifest ?? SceneManifest(id: SceneManifest.slug(from: sceneName), name: sceneName,
                                                       description: PromptComposer.title(for: prompt, limit: 90),
                                                       kind: .web, author: "you", tags: [style.rawValue])
        manifest.performance = .init(benchMs: 1.6, energyMw: 72, checkedAt: Date())
        manifest.updated = Date()
        try manifest.write(package: sceneDir)
        try Data(MockSampleData.sceneJS.utf8).write(to: sceneDir.appendingPathComponent("scene.js"))
        MockArtwork.writeImage(style: style, seed: seed, width: 640, height: 400, t: 12, to: sceneDir.appendingPathComponent("thumbnail.jpg"))
        try MockServices.appendHistory([[
            "date": ISO8601DateFormatter().string(from: Date()), "action": base == nil ? "create" : "modify",
            "harness": harness.uiTitle, "model": model ?? "", "prompt": prompt,
            "summary": "Layered scene with cached static layers; 1.6 ms/frame.",
        ]], package: sceneDir)
        let report = CheckReport(passed: true, warnings: ["Scene is a little bright at t=600 (mean luminance 71); fine for most wallpapers."],
                                 benchMs: ["1512x982@2 t=14": 1.6, "5120x1440@1 t=14": 2.4], energyMw: 72)
        try MockServices.writeReport(report, package: sceneDir)
        return report
    }
}
