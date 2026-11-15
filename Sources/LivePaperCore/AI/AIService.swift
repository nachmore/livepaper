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
    /// kiro-cli executable → whether it supports `--output-format stream-json`.
    private var kiroStreamJSON: [String: Bool] = [:]
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
                for h in harnesses where h.kind == .kiro { _ = self.kiroSupportsStreamJSON(h.executable) }
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
                HarnessAdapters.adapter(for: harness, kiroStreamJSON: harness.kind == .kiro ? kiroSupportsStreamJSON(harness.executable) : true)
            },
            environment: {
                HarnessEnvironment.compose(process: ProcessInfo.processInfo.environment, login: detector.shell.snapshot(),
                                           searchPath: detector.searchPath(), workspaceBin: workspace.bin)
            },
            searchPath: { detector.searchPath() },
            extraArguments: settings.extraArguments[harness.kind.rawValue] ?? [],
            timeout: timeoutOverride ?? settings.timeout)
        let chosenModel = model ?? settings.models[harness.kind.rawValue]
        let session = AISession(id: id, workspace: workspace, request: request, harness: harness, model: chosenModel, dependencies: deps)
        log.info("starting AI session \(id, privacy: .public) with \(harness.name, privacy: .public)")
        session.start()
        return session
    }

    // MARK: - Internals

    /// `20261113T175610Z-3f9a1c`: sortable, unique, file-name safe.
    static func makeSessionID(date: Date = Date()) -> String {
        "\(FileOps.timestamp(date))-\(UUID().uuidString.prefix(6).lowercased())"
    }

    /// Asks `kiro-cli chat --help` once per executable (older versions only print text).
    func kiroSupportsStreamJSON(_ executable: String) -> Bool {
        if let known = lock.withLock({ kiroStreamJSON[executable] }) { return known }
        let env = HarnessEnvironment.compose(process: ProcessInfo.processInfo.environment, login: detector.shell.snapshot(),
                                             searchPath: detector.searchPath(), workspaceBin: nil)
        let help = (try? runner.run(executable, ["chat", "--help"], environment: env, timeout: 20))?.combinedOutput ?? ""
        let supported = KiroAdapter.supportsStreamJSON(helpOutput: help)
        lock.withLock { kiroStreamJSON[executable] = supported }
        return supported
    }
}
