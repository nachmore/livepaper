// AIService — AIServicing: detects harnesses, builds session workspaces and starts AISessions.
// Settings (AISettings, ServiceProtocols.swift) live in <support>/ai-settings.json.
import Foundation
import os

public final class AIService: AIServicing, @unchecked Sendable {
    public static let settingsFileName = "ai-settings.json"

    public let settingsURL: URL
    public let workspaceBuilder: WorkspaceBuilder
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
        self.workspaceBuilder = workspaceBuilder ?? WorkspaceBuilder(library: library)
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

    public func start(_ request: AISessionRequest, harness: AIHarness, model: String?) throws -> AISessionHandle {
        let settings = loadSettings()
        // Old workspaces are kept for debugging for a week; tidy up once per app run.
        let firstStart = lock.withLock { () -> Bool in
            let first = !prunedWorkspaces
            prunedWorkspaces = true
            return first
        }
        if firstStart { workspaceBuilder.pruneWorkspaces() }
        let id = Self.makeSessionID()
        let workspace = try workspaceBuilder.build(request, sessionID: id)
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
            timeout: timeoutOverride ?? settings.timeout,
            prepareRenderer: Self.rendererWarmUp(for: checker))
        let chosenModel = model ?? settings.models[harness.kind.rawValue]
        let session = AISession(id: id, workspace: workspace, request: request, harness: harness, model: chosenModel, dependencies: deps)
        log.info("starting AI session \(id, privacy: .public) with \(harness.name, privacy: .public)")
        session.start()
        return session
    }

    // MARK: - Internals

    /// Starts the render server the checker talks to (a no-op when the app's embedded server or a
    /// daemon already listens). Only for the real SceneChecker + RenderClient pair: fakes in tests
    /// get nothing, and LIVEPAPER_NO_SPAWN=1 still forbids starting a daemon.
    static func rendererWarmUp(for checker: SceneChecking) -> () -> Void {
        guard let client = (checker as? SceneChecker)?.render as? RenderClient else { return {} }
        return { try? client.ensureServer(timeout: 40) }
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
