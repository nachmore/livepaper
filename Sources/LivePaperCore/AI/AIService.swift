// AIService — AIServicing: detects harnesses, builds session workspaces and starts AISessions,
// keeps each session's record (AISessionRecord, <Workspaces>/.sessions/) and takes over the sessions
// an earlier run left behind (AISessionRecovery).
// Settings (AISettings, ServiceProtocols.swift) live in <support>/ai-settings.json.
import Foundation
import os

public final class AIService: AIServicing, @unchecked Sendable {
    public static let settingsFileName = "ai-settings.json"

    public let settingsURL: URL
    public let workspaceBuilder: WorkspaceBuilder
    /// The sessions' records, next to their workspaces.
    public let records: AISessionRecordStore
    public let detector: HarnessDetector
    private let checker: SceneChecking
    private let runner: CommandRunning
    private let timeoutOverride: TimeInterval?
    private let lock = NSLock()
    /// kiro-cli executable → what its `chat --help` offers.
    private var kiroCapabilities: [String: KiroCapabilities] = [:]
    private var prunedWorkspaces = false
    private let log = Logger(subsystem: LPPaths.bundleID, category: "ai")

    /// - Parameter timeout: overrides the timeout from the settings (CLI option, tests).
    public init(library: LibraryServicing, checker: SceneChecking,
                workspaceBuilder: WorkspaceBuilder? = nil,
                detector: HarnessDetector = HarnessDetector(),
                runner: CommandRunning = SystemCommandRunner(),
                settingsURL: URL = LPPaths.supportRoot.appendingPathComponent(AIService.settingsFileName),
                timeout: TimeInterval? = nil) {
        self.checker = checker
        self.timeoutOverride = timeout
        let builder = workspaceBuilder ?? WorkspaceBuilder(library: library)
        self.workspaceBuilder = builder
        self.records = AISessionRecordStore(workspacesDirectory: builder.workspacesDirectory)
        self.detector = detector
        self.runner = runner
        self.settingsURL = settingsURL
    }

    // MARK: - Settings

    public func loadSettings() -> AISettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(AISettings.self, from: data) else { return AISettings() }
        return settings
    }

    public func saveSettings(_ settings: AISettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileOps.writeAtomically(try encoder.encode(settings), to: settingsURL)
    }

    /// A harness for the user's custom command template (Settings › AI › Custom).
    public static func customHarness(template: String, name: String = "Custom command") -> AIHarness {
        AIHarness.custom(template: template, name: name)
    }

    // MARK: - AIServicing

    /// Installed harnesses, plus the custom command when one is configured. Runs the login shell
    /// and `--version` probes off the caller's thread.
    public func detectHarnesses() async -> [AIHarness] {
        let found = await withCheckedContinuation { (done: CheckedContinuation<[AIHarness], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let harnesses = self.detector.detect()
                // Probe capabilities now so starting a session never waits for it.
                for h in harnesses where h.kind == .kiro { _ = self.kiroCapabilities(h.executable) }
                done.resume(returning: harnesses)
            }
        }
        guard let template = loadSettings().customTemplate?.trimmingCharacters(in: .whitespacesAndNewlines), !template.isEmpty else {
            return found
        }
        return found + [Self.customHarness(template: template)]
    }

    public func start(_ request: AISessionRequest, references refs: [PreparedReference], harness: AIHarness,
                      model: String?) throws -> AISessionHandle {
        try start(request, references: refs, harness: harness, model: model, details: AISessionDetails())
    }

    public func start(_ request: AISessionRequest, references refs: [PreparedReference], harness: AIHarness,
                      model: String?, details: AISessionDetails) throws -> AISessionHandle {
        try ReferencePrompts.validate(refs)
        let settings = loadSettings()
        // Old workspaces are kept for debugging for a week; tidy up once per app run.
        pruneOncePerRun()
        let id = Self.makeSessionID()
        let built = try workspaceBuilder.buildSession(request, references: refs, sessionID: id)
        let workspace = built.workspace
        let timeout = timeoutOverride ?? settings.timeout
        let detector = self.detector
        let deps = AISession.Dependencies(
            checker: checker,
            adapter: { [self] in
                let kiro = harness.kind == .kiro ? kiroCapabilities(harness.executable) : KiroCapabilities(streamJSON: true, trustWorkspace: false)
                return HarnessAdapters.adapter(for: harness, kiroStreamJSON: kiro.streamJSON, kiroTrustWorkspace: kiro.trustWorkspace)
            },
            environment: {
                // Marks every process of the harness as this session (the CLI then runs only the scene
                // commands, on this workspace) and keeps the real CLI's location out of its view.
                HarnessEnvironment.compose(process: ProcessInfo.processInfo.environment.filter { !AISessionPolicy.withheldVariables.contains($0.key) },
                                           login: detector.shell.snapshot().withoutVariables(AISessionPolicy.withheldVariables),
                                           searchPath: detector.searchPath(), workspaceBin: workspace.bin,
                                           extra: AISessionPolicy.environment(sessionID: id, workspace: workspace))
            },
            searchPath: { detector.searchPath() },
            extraArguments: settings.extraArguments[harness.kind.rawValue] ?? [],
            timeout: timeout,
            prepareRenderer: Self.rendererWarmUp(for: checker),
            renderRelay: Self.renderRelay(for: checker, workspace: workspace),
            records: records)
        let chosenModel = model ?? settings.models[harness.kind.rawValue]
        let session = AISession(id: id, workspace: workspace, request: request, harness: harness, model: chosenModel, dependencies: deps,
                                references: built.references, recordedPrompt: built.taskPrompt)
        // Before the agent starts: whatever happens to this process from here on, a later LivePaper
        // finds the session.
        let images = AISessionRecovery.recordedReferences(ReferenceWorkspace.numbered(refs), written: built.references)
        let record = AISessionRecord(id: id, origin: details.origin, runner: ProcessProbe.current, request: request, prompt: built.taskPrompt,
                                     feedback: details.feedback, references: images.references, animate: images.animate, harness: harness,
                                     model: session.model, timeout: timeout, clonedFrom: details.clonedFrom,
                                     sceneBefore: FileDigest.sha256(workspace.scene.appendingPathComponent(SceneCompiler.sceneFile)))
        do { try records.create(record, copies: images.copies) } catch {
            log.error("session \(id, privacy: .public): couldn't write its record: \(error.localizedDescription, privacy: .public)")
        }
        // Counts only: names and paths of the user's pictures never reach the log.
        let counts = built.references.counts.map { " · \($0.reference) reference, \($0.animate) to animate" } ?? ""
        log.info("starting AI session \(id, privacy: .public) with \(harness.name, privacy: .public)\(counts, privacy: .public)")
        session.start()
        return session
    }

    // MARK: - Records and recovery

    /// Old workspaces are kept for debugging for a week; tidied up once per run (at the first
    /// session, or when the app recovers sessions at launch).
    private func pruneOncePerRun() {
        let first = lock.withLock { () -> Bool in
            let first = !prunedWorkspaces
            prunedWorkspaces = true
            return first
        }
        if first { workspaceBuilder.pruneWorkspaces() }
    }

    public func pruneSessions() { workspaceBuilder.pruneWorkspaces() }

    public func recoverSessions() -> [RecoveredAISession] {
        pruneOncePerRun()
        guard let me = ProcessProbe.current else { return [] }
        var recovered: [RecoveredAISession] = []
        for id in records.records().map(\.id) {
            let workspace = AIWorkspace(root: workspaceBuilder.workspacesDirectory.appendingPathComponent(id))
            var decision = AISessionRecovery.Decision.leave(.settled)
            // Decided and claimed in one step under the store's lock: two LivePapers launched at
            // once never both take a session over (the second sees the first as its runner).
            let claimed = records.update(id) { record in
                decision = AISessionRecovery.decide(record, workspace: workspace)
                switch decision {
                case .leave:
                    return false
                case .discard:
                    record.resolution = .discarded
                    if record.finishedAt == nil { record.finishedAt = Date() }
                    return true
                case .watch, .review:
                    record.runner = me
                    record.recoveredAt = Date()
                    return true
                }
            }
            guard let record = claimed else { continue }
            switch decision {
            case .leave:
                continue
            case .discard:
                records.removeCopies(for: id)
                log.info("session \(id, privacy: .public): left behind without changes; discarded")
            case .watch(let agent):
                recovered.append(resume(record, workspace: workspace, agent: agent))
            case .review:
                recovered.append(resume(record, workspace: workspace, agent: nil))
            }
        }
        return recovered
    }

    /// A session for a record this run took over, already running.
    private func resume(_ record: AISessionRecord, workspace: AIWorkspace, agent: LPProcessFacts?) -> RecoveredAISession {
        let harness = record.harness.harness
        let (references, problem) = AISessionRecovery.sessionReferences(record, store: records)
        let deps = AISession.Dependencies(
            checker: checker,
            // Nothing is launched: the agent runs already, or ran.
            adapter: { HarnessAdapters.adapter(for: harness, kiroStreamJSON: true, kiroTrustWorkspace: false) },
            environment: { [:] }, searchPath: { [] }, extraArguments: [],
            timeout: record.timeout,
            prepareRenderer: Self.rendererWarmUp(for: checker),
            // A sandboxed agent still running relays its render requests through the spool, as before.
            renderRelay: agent == nil ? nil : Self.renderRelay(for: checker, workspace: workspace),
            records: records)
        let session = AISession(id: record.id, workspace: workspace, request: record.request, harness: harness, model: record.model,
                                dependencies: deps, references: references, recordedPrompt: record.prompt, startedAt: record.startedAt,
                                sceneBefore: record.sceneBefore, recoveryProblem: problem)
        log.info("recovering AI session \(record.id, privacy: .public): \(agent == nil ? "checking what it left" : "its agent still runs", privacy: .public)")
        session.resume(agent: agent)
        return RecoveredAISession(record: record, handle: session, references: AISessionRecovery.preparedReferences(record, store: records),
                                  agentRunning: agent != nil)
    }

    public func recordResolution(_ resolution: AISessionRecord.Resolution, sessionID: String) {
        records.update(sessionID) { record in
            record.resolution = resolution
            return true
        }
        records.removeCopies(for: sessionID)
    }

    public func stopOrphanedAgents(grace: TimeInterval) -> Int {
        var stopped = 0
        for record in records.records() where !record.isSettled {
            guard let agent = record.agent, agent.isSameProcess(as: ProcessProbe.facts(agent.pid)) else { continue }
            // One its app or CLI still runs is that process's to stop.
            if let runner = record.runner, runner.isSameProcess(as: ProcessProbe.facts(runner.pid)) { continue }
            log.info("session \(record.id, privacy: .public): stopping its orphaned agent (pid \(agent.pid))")
            if AISession.stopGroup(agent.group, grace: grace) { stopped += 1 }
        }
        return stopped
    }

    // MARK: - Internals

    /// Starts the render server the checker talks to (a no-op when the app's embedded server or a
    /// daemon already listens). Only for the real SceneChecker + RenderClient pair: fakes in tests
    /// get nothing, and LIVEPAPER_NO_SPAWN=1 still forbids starting a daemon.
    static func rendererWarmUp(for checker: SceneChecking) -> () -> Void {
        guard let client = (checker as? SceneChecker)?.render as? RenderClient else { return {} }
        return { try? client.ensureServer(timeout: 40) }
    }

    /// The relay for an agent whose sandbox keeps its CLI off the render socket, talking to the
    /// checker's own renderer (fakes in tests get none unless they use a SceneChecker).
    static func renderRelay(for checker: SceneChecking, workspace: AIWorkspace) -> RenderRelay? {
        guard let checker = checker as? SceneChecker else { return nil }
        return RenderRelay(workspace: workspace, privateDirectory: workspace.relayDirectory, render: checker.render, compiler: checker.compiler)
    }

    /// `20261113T175610Z-3f9a1c`: sortable, unique, file-name safe.
    static func makeSessionID(date: Date = Date()) -> String {
        "\(FileOps.timestamp(date))-\(UUID().uuidString.prefix(6).lowercased())"
    }

    struct KiroCapabilities: Equatable { var streamJSON: Bool; var trustWorkspace: Bool }

    /// Asks `kiro-cli chat --help` once per executable (older versions only print text).
    func kiroCapabilities(_ executable: String) -> KiroCapabilities {
        if let known = lock.withLock({ kiroCapabilities[executable] }) { return known }
        let env = HarnessEnvironment.compose(process: ProcessInfo.processInfo.environment, login: detector.shell.snapshot(),
                                             searchPath: detector.searchPath(), workspaceBin: nil)
        let help = (try? runner.run(executable, ["chat", "--help"], environment: env, timeout: 20))?.combinedOutput ?? ""
        let found = KiroCapabilities(streamJSON: KiroAdapter.supportsStreamJSON(helpOutput: help),
                                     trustWorkspace: KiroAdapter.supportsTrustWorkspace(helpOutput: help))
        lock.withLock { kiroCapabilities[executable] = found }
        return found
    }
}
