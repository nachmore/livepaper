// HarnessAdapters — how each AI coding CLI is invoked (ARCHITECTURE §10). Every flag below was
// checked against the `--help` output of the installed CLIs (claude 2.1, codex 0.169, kiro-cli 3.3).
//
// The user's prompt never appears on a command line: it lives in the workspace's TASK.md, which is
// either connected to the harness's stdin or referenced by a fixed instruction. No shell is
// involved — arguments go straight to posix_spawn.
import Foundation

/// A fully resolved harness command.
public struct HarnessInvocation: Sendable, Equatable {
    /// Absolute path of the program.
    public var executable: String
    public var arguments: [String]
    public var currentDirectory: URL
    /// Connected to the harness's stdin (nil = /dev/null).
    public var stdinFile: URL?
    public init(executable: String, arguments: [String], currentDirectory: URL, stdinFile: URL?) {
        self.executable = executable; self.arguments = arguments; self.currentDirectory = currentDirectory; self.stdinFile = stdinFile
    }
}

/// Inputs an adapter needs to build an invocation.
public struct HarnessContext: Sendable {
    public var workspace: AIWorkspace
    public var model: String?
    /// PATH directories, used to resolve a custom harness's program.
    public var searchPath: [String]
    /// User-supplied extra options (e.g. `-c model_reasoning_effort="low"` for codex), inserted
    /// after LivePaper's own options and before any positional prompt argument. Ignored by custom
    /// harnesses, whose template already is the complete command.
    public var extraArguments: [String]
    public init(workspace: AIWorkspace, model: String?, searchPath: [String], extraArguments: [String] = []) {
        self.workspace = workspace; self.model = model?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        self.searchPath = searchPath; self.extraArguments = extraArguments
    }
}

public protocol HarnessAdapter: Sendable {
    func invocation(for harness: AIHarness, context: HarnessContext) throws -> HarnessInvocation
    /// A parser for this harness's stdout.
    func makeParser(workspaceRoot: URL) -> HarnessStreamParser
}

public enum HarnessAdapters {
    /// The fixed first message for harnesses that take their prompt as an argument.
    public static let bootstrapInstruction = "Read TASK.md in the current directory and carry out the task it describes, following AGENTS.md."

    /// - Parameter kiroStreamJSON: whether this kiro-cli supports `--output-format stream-json`.
    /// - Parameter kiroTrustWorkspace: whether it has `--trust-workspace` (V3 engine).
    public static func adapter(for harness: AIHarness, kiroStreamJSON: Bool = true, kiroTrustWorkspace: Bool = false) -> HarnessAdapter {
        switch harness.kind {
        case .claude: return ClaudeAdapter()
        case .codex: return CodexAdapter()
        case .kiro: return KiroAdapter(streamJSON: kiroStreamJSON, trustWorkspace: kiroTrustWorkspace)
        case .custom: return CustomAdapter()
        }
    }
}

/// Claude Code: `claude -p` reads the prompt from stdin; stream-json needs --verbose in print mode.
///
/// Permissions (rule syntax: code.claude.com/docs/en/permissions): `dontAsk` denies every tool call
/// the rules don't allow, with nobody to ask in print mode anyway. The rules allow reading the
/// workspace, editing files in ./scene and running the CLI's scene commands; the deny rules
/// remove web access and protect LivePaper's own files even if the user's settings allow more.
/// (`acceptEdits` would also auto-approve edits and mv/cp anywhere in the workspace — bin/livepaper
/// included — and a bare `Write`/`Edit` allow rule approves writes anywhere on disk.) Claude Code
/// checks each part of a compound command, so `livepaper check scene && rm …` is refused.
public struct ClaudeAdapter: HarnessAdapter {
    public static let allowedTools = (["Read(./**)", "Edit(./scene/**)"]
        + (AISessionPolicy.commands + ["help"]).map { "Bash(livepaper \($0) *)" }).joined(separator: ",")
    public static let disallowedTools = ["WebFetch", "WebSearch", "Edit(./bin/**)", "Edit(./sdk/**)", "Edit(./.livepaper/**)",
                                         "Edit(./.kiro/**)", "Edit(./AGENTS.md)", "Edit(./CLAUDE.md)", "Edit(./TASK.md)"].joined(separator: ",")
    public init() {}

    public func invocation(for harness: AIHarness, context: HarnessContext) throws -> HarnessInvocation {
        var args = ["-p", "--output-format", "stream-json", "--verbose",
                    "--permission-mode", "dontAsk", "--allowedTools", Self.allowedTools, "--disallowedTools", Self.disallowedTools]
        if let model = context.model { args += ["--model", model] }
        args += context.extraArguments
        return HarnessInvocation(executable: harness.executable, arguments: args,
                                 currentDirectory: context.workspace.root, stdinFile: context.workspace.taskFile)
    }

    public func makeParser(workspaceRoot: URL) -> HarnessStreamParser { ClaudeStreamParser(workspaceRoot: workspaceRoot) }
}

/// Codex: `codex exec … -` reads the prompt from stdin; --json streams JSONL events.
public struct CodexAdapter: HarnessAdapter {
    public init() {}

    public func invocation(for harness: AIHarness, context: HarnessContext) throws -> HarnessInvocation {
        let ws = context.workspace
        var args = ["exec", "-C", ws.root.path, "-s", "workspace-write", "--skip-git-repo-check", "--json",
                    "-o", ws.lastMessageFile.path,
                    // workspace-write blocks all sockets by default, including the Unix socket
                    // `livepaper check` uses to reach the RenderService.
                    "-c", "sandbox_workspace_write.network_access=true"]
        if let model = context.model { args += ["-m", model] }
        args += context.extraArguments
        args.append("-")
        return HarnessInvocation(executable: harness.executable, arguments: args, currentDirectory: ws.root, stdinFile: ws.taskFile)
    }

    public func makeParser(workspaceRoot: URL) -> HarnessStreamParser { CodexStreamParser(workspaceRoot: workspaceRoot) }
}

/// Kiro CLI: `kiro-cli chat --no-interactive` takes the first message as an argument. The session
/// runs as the workspace's own agent (KiroAgentConfig: writes only in ./scene, the shell only for
/// the livepaper scene commands) and trusts nothing on the command line.
public struct KiroAdapter: HarnessAdapter {
    /// `--output-format stream-json` (kiro-cli 3.x); older versions only print text.
    public let streamJSON: Bool
    /// `--trust-workspace` (V3 engine): load the workspace's agent without the "Trust this
    /// workspace?" prompt a non-interactive run can't answer. Only LivePaper writes the workspace's
    /// .kiro/ (the agent itself may write only in ./scene).
    public let trustWorkspace: Bool
    public init(streamJSON: Bool, trustWorkspace: Bool = false) { self.streamJSON = streamJSON; self.trustWorkspace = trustWorkspace }

    public func invocation(for harness: AIHarness, context: HarnessContext) throws -> HarnessInvocation {
        var args = ["chat", "--no-interactive", "--agent", KiroAgentConfig.name]
        if trustWorkspace { args.append("--trust-workspace") }
        // Text mode would otherwise wrap long lines at an assumed terminal width.
        args += streamJSON ? ["--output-format", "stream-json"] : ["--wrap", "never"]
        if let model = context.model { args += ["--model", model] }
        args += context.extraArguments
        args.append(HarnessAdapters.bootstrapInstruction)
        return HarnessInvocation(executable: harness.executable, arguments: args,
                                 currentDirectory: context.workspace.root, stdinFile: nil)
    }

    public func makeParser(workspaceRoot: URL) -> HarnessStreamParser {
        streamJSON ? KiroStreamParser(workspaceRoot: workspaceRoot) : PlainTextParser()
    }

    /// Whether `kiro-cli chat --help` advertises stream-json output.
    public static func supportsStreamJSON(helpOutput: String) -> Bool {
        helpOutput.contains("--output-format") && helpOutput.contains("stream-json")
    }

    /// Whether `kiro-cli chat --help` offers `--trust-workspace`.
    public static func supportsTrustWorkspace(helpOutput: String) -> Bool {
        helpOutput.contains("--trust-workspace")
    }
}

/// A user-defined command template, e.g. `mytool --prompt-file {prompt_file} --cwd {workspace}`.
///
/// Placeholders: `{prompt_file}` (TASK.md), `{workspace}`, `{scene}`, `{model}`, `{instructions}`
/// (the fixed bootstrap sentence). A token that is exactly `{model}` is dropped when no model is
/// chosen. Quoting follows POSIX shell rules ('…', "…", backslash), but no shell ever runs it.
/// TASK.md is also connected to stdin.
public struct CustomAdapter: HarnessAdapter {
    /// Every placeholder a template may use.
    public static let placeholders = ["{prompt_file}", "{workspace}", "{scene}", "{model}", "{instructions}"]

    public init() {}

    /// Why `template` can't be used as a custom command, as a sentence for the settings UI, or nil
    /// when it's fine. (Whether the program exists is only known when a session starts.)
    public static func templateProblem(_ template: String) -> String? {
        let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "Enter the command to run." }
        let tokens: [String]
        do { tokens = try CommandTemplate.tokenize(t) } catch { return error.localizedDescription }
        guard let program = tokens.first, !program.isEmpty, !program.contains("{") else {
            return "Start with the program to run, e.g. mytool {prompt_file}."
        }
        let unknown = t.matches(of: #/\{[A-Za-z_]+\}/#).map { String($0.output) }.filter { !placeholders.contains($0) }
        if let first = unknown.first { return "Unknown placeholder \(first). Use \(placeholders.joined(separator: ", "))." }
        return nil
    }

    public func invocation(for harness: AIHarness, context: HarnessContext) throws -> HarnessInvocation {
        let template = harness.customTemplate ?? harness.executable
        let ws = context.workspace
        let values = ["{prompt_file}": ws.taskFile.path, "{workspace}": ws.root.path, "{scene}": ws.scene.path,
                      "{model}": context.model ?? "", "{instructions}": HarnessAdapters.bootstrapInstruction]
        var tokens = try CommandTemplate.tokenize(template)
        if context.model == nil { tokens.removeAll { $0 == "{model}" } }
        tokens = tokens.map { token in values.reduce(token) { $0.replacingOccurrences(of: $1.key, with: $1.value) } }
        guard let program = tokens.first, !program.isEmpty else { throw AIError.invalidTemplate("the command is empty") }
        guard let executable = Self.resolve(program, searchPath: context.searchPath) else { throw AIError.harnessNotFound(program) }
        return HarnessInvocation(executable: executable, arguments: Array(tokens.dropFirst()),
                                 currentDirectory: ws.root, stdinFile: ws.taskFile)
    }

    public func makeParser(workspaceRoot: URL) -> HarnessStreamParser { PlainTextParser() }

    static func resolve(_ program: String, searchPath: [String]) -> String? {
        let expanded = program.hasPrefix("~/") ? LPPaths.home.appendingPathComponent(String(program.dropFirst(2))).path : program
        if expanded.contains("/") {
            return expanded.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        return HarnessDetector.find(expanded, in: searchPath)
    }
}

/// POSIX-shell-like word splitting (without expansion of any kind).
public enum CommandTemplate {
    public static func tokenize(_ s: String) throws -> [String] {
        var tokens: [String] = [], current = "", inToken = false
        var quote: Character?
        var it = s.makeIterator()
        while let c = it.next() {
            switch quote {
            case "'":
                if c == "'" { quote = nil } else { current.append(c) }
            case "\"":
                if c == "\"" { quote = nil }
                else if c == "\\" {
                    guard let n = it.next() else { throw AIError.invalidTemplate("ends with a backslash") }
                    if !"\"\\$`".contains(n) { current.append("\\") }
                    current.append(n)
                } else { current.append(c) }
            default:
                if c == "'" || c == "\"" { quote = c; inToken = true }
                else if c == "\\" {
                    guard let n = it.next() else { throw AIError.invalidTemplate("ends with a backslash") }
                    current.append(n); inToken = true
                } else if c.isWhitespace {
                    if inToken { tokens.append(current); current = ""; inToken = false }
                } else { current.append(c); inToken = true }
            }
        }
        if quote != nil { throw AIError.invalidTemplate("unterminated quote") }
        if inToken { tokens.append(current) }
        return tokens
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
