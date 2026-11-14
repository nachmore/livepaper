// HarnessDetector — finds the AI coding CLIs installed on this Mac.
//
// GUI apps started by launchd don't inherit the user's shell environment: their PATH is just
// /usr/bin:/bin:/usr/sbin:/sbin, so CLIs installed with Homebrew, npm, toolbox, … are invisible.
// We ask the user's login shell once (`/bin/zsh -lc 'command -v …'`), then also look in the usual
// install directories (a login shell doesn't read ~/.zshrc, where many installers add PATH entries).
import Foundation

/// What the user's login shell knows: its environment and where it finds each tool.
public struct ShellSnapshot: Sendable, Equatable {
    public var environment: [String: String]
    /// Tool name → absolute path, from `command -v`.
    public var commands: [String: String]
    public init(environment: [String: String] = [:], commands: [String: String] = [:]) {
        self.environment = environment; self.commands = commands
    }
    public var pathDirectories: [String] { (environment["PATH"] ?? "").split(separator: ":").map(String.init) }
}

/// Resolves (once, then cached) the login-shell environment.
public final class LoginShell: @unchecked Sendable {
    public static let shared = LoginShell()
    static let marker = "LPENV"

    private let shell: String
    private let tools: [String]
    private let runner: CommandRunning
    private let lock = NSLock()
    private var cached: ShellSnapshot?

    /// - Parameter tools: command names to look up (must be plain `[A-Za-z0-9._-]` names; they are
    ///   embedded in the shell script).
    public init(shell: String = "/bin/zsh", tools: [String] = HarnessDetector.known.map(\.tool),
                runner: CommandRunning = SystemCommandRunner()) {
        self.shell = shell
        self.tools = tools.filter { $0.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) } }
        self.runner = runner
    }

    /// A snapshot that resolved nothing (tests, or when the shell can't be used).
    public static func fixed(_ snapshot: ShellSnapshot) -> LoginShell {
        let shell = LoginShell(tools: [])
        shell.cached = snapshot
        return shell
    }

    /// Runs the login shell the first time (≤ 10 s; a broken profile must not hang detection).
    public func snapshot() -> ShellSnapshot {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let lookups = tools.map { "p=$(command -v -- '\($0)' 2>/dev/null) && printf 'LPBIN\\t%s\\t%s\\n' '\($0)' \"$p\"" }
        let script = (lookups + ["printf '\(Self.marker)\\n'", "/usr/bin/env -0"]).joined(separator: "; ")
        let result = try? runner.run(shell, ["-lc", script], environment: nil, timeout: 10)
        let snapshot = result.map { Self.parse($0.stdout) } ?? ShellSnapshot()
        cached = snapshot
        return snapshot
    }

    /// Parses the script's output. Anything the user's profile prints before our lines is ignored.
    static func parse(_ output: String) -> ShellSnapshot {
        var snapshot = ShellSnapshot()
        let parts = output.components(separatedBy: marker + "\n")
        for line in parts[0].split(separator: "\n") where line.hasPrefix("LPBIN\t") {
            let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
            // `command -v` prints alias/function definitions for non-files; keep real paths only.
            if fields.count == 3, fields[2].hasPrefix("/") { snapshot.commands[fields[1]] = fields[2] }
        }
        if parts.count > 1 {
            for entry in parts[1...].joined(separator: marker + "\n").split(separator: "\0") {
                guard let eq = entry.firstIndex(of: "=") else { continue }
                let key = String(entry[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty { snapshot.environment[key] = String(entry[entry.index(after: eq)...]) }
            }
        }
        return snapshot
    }
}

public struct HarnessDetector: Sendable {
    public struct Known: Sendable {
        public let kind: AIHarness.Kind
        public let tool: String
        public let name: String
    }
    /// The harnesses LivePaper has adapters for, in display order.
    public static let known: [Known] = [
        Known(kind: .claude, tool: "claude", name: "Claude Code"),
        Known(kind: .codex, tool: "codex", name: "Codex"),
        Known(kind: .kiro, tool: "kiro-cli", name: "Kiro CLI"),
    ]

    /// Where installers commonly put these CLIs.
    public static var commonDirectories: [URL] {
        let home = LPPaths.home
        return [home.appendingPathComponent(".toolbox/bin"), URL(fileURLWithPath: "/opt/homebrew/bin"),
                URL(fileURLWithPath: "/usr/local/bin"), home.appendingPathComponent(".local/bin"),
                home.appendingPathComponent(".claude/local")]
    }

    public let shell: LoginShell
    public let directories: [URL]
    let runner: CommandRunning

    public init(shell: LoginShell = .shared, directories: [URL] = HarnessDetector.commonDirectories,
                runner: CommandRunning = SystemCommandRunner()) {
        self.shell = shell; self.directories = directories; self.runner = runner
    }

    /// PATH entries for harness processes: login-shell PATH, then the common directories, then our
    /// own PATH — deduplicated, order preserved.
    public func searchPath() -> [String] {
        var seen = Set<String>()
        let own = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        return (shell.snapshot().pathDirectories + directories.map(\.path) + own).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Absolute path of `tool`, preferring what the user's shell resolves.
    public func locate(_ tool: String) -> String? {
        if let path = shell.snapshot().commands[tool], FileManager.default.isExecutableFile(atPath: path) { return path }
        return Self.find(tool, in: searchPath())
    }

    static func find(_ tool: String, in directories: [String]) -> String? {
        directories.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(tool).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Detects installed harnesses and their versions. Blocking (runs `--version` for each one);
    /// call it off the main thread.
    public func detect() -> [AIHarness] {
        let found = Self.known.compactMap { k in locate(k.tool).map { (k, $0) } }
        let env = HarnessEnvironment.compose(process: ProcessInfo.processInfo.environment, login: shell.snapshot(),
                                             searchPath: searchPath(), workspaceBin: nil)
        var versions = [String?](repeating: nil, count: found.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: found.count) { i in
            // First runs of wrapper-installed CLIs can be slow (self-update checks): be generous.
            let result = try? runner.run(found[i].1, ["--version"], environment: env, timeout: 20)
            let version = result.flatMap { $0.succeeded ? Self.parseVersion($0.combinedOutput) : nil }
            lock.lock(); versions[i] = version; lock.unlock()
        }
        return found.enumerated().map { i, entry in
            AIHarness(kind: entry.0.kind, name: entry.0.name, executable: entry.1, version: versions[i])
        }
    }

    /// "claude 2.1.3 (Claude Code)" → "2.1.3"; falls back to the first line.
    static func parseVersion(_ output: String) -> String? {
        guard let line = output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        if let range = line.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) { return String(line[range]) }
        return String(line.prefix(60))
    }
}

/// Builds the environment harness processes run with.
enum HarnessEnvironment {
    /// Variables a parent Claude Code / Codex session sets for its own children. Inherited by a
    /// harness we start (e.g. when LivePaper itself was launched from such a session) they make it
    /// behave as a nested sub-agent of that session instead of a fresh run.
    static let scrubbed: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_EXECPATH", "CLAUDE_PID", "CLAUDE_AGENT_SDK_VERSION", "CLAUDE_EFFORT",
        "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED",
    ]
    /// Shell bookkeeping that is meaningless in another process.
    static let shellNoise: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_"]

    /// Login-shell variables, overlaid by our own process environment (which wins: it carries
    /// LIVEPAPER_* overrides), with PATH = workspace bin + `searchPath`.
    static func compose(process: [String: String], login: ShellSnapshot, searchPath: [String],
                        workspaceBin: URL?, extra: [String: String] = [:]) -> [String: String] {
        var env = login.environment.filter { !shellNoise.contains($0.key) }
        env.merge(process) { _, mine in mine }
        for key in scrubbed { env.removeValue(forKey: key) }
        env["PATH"] = ((workspaceBin.map { [$0.path] } ?? []) + searchPath).joined(separator: ":")
        // Harness output is parsed, not shown in a terminal.
        env["NO_COLOR"] = "1"
        env.merge(extra) { _, new in new }
        return env
    }
}
