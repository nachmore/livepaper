// AISessionPolicy — what the `livepaper` CLI may do when an AI agent runs it (ARCHITECTURE §10).
//
// An agent session's processes carry LIVEPAPER_AI_SESSION / LIVEPAPER_AI_WORKSPACE (set by the
// session runner for the whole harness, and again by the workspace's bin/livepaper shim). With
// them set, the CLI runs only the scene commands below and only on files inside that workspace —
// no uninstall, publish, import, nested `ai` sessions or server control — however the agent got
// to run it. The harness's own tool rules (Claude's allow list, Kiro's agent config, Codex's
// sandbox) are the first line; this is the one every harness shares.
import Darwin
import Foundation

public enum AISessionPolicy {
    /// The session id; its presence marks a process as part of an AI session.
    public static let sessionVariable = "LIVEPAPER_AI_SESSION"
    /// The session's workspace root: every file the CLI reads or writes must be inside it.
    public static let workspaceVariable = "LIVEPAPER_AI_WORKSPACE"
    /// Where the CLI drops render requests when it can't reach the render socket (a sandboxed agent).
    public static let renderSpoolVariable = "LIVEPAPER_RENDER_SPOOL"

    /// The only CLI commands an agent may run: build, render and measure the scene.
    public static let commands = ["check", "still", "bench", "live", "thumbnail", "compile"]
    /// Also allowed: they only print text.
    public static let informational: Set<String> = ["help", "--help", "-h", "version", "--version"]

    /// Variables of the runner's own environment that must not reach an agent: where the real CLI
    /// and render daemon live (the agent gets the shim and the render server, nothing else).
    public static let withheldVariables: Set<String> = ["LIVEPAPER_CLI", "LIVEPAPER_RENDERD"]

    public static func isActive(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !(environment[sessionVariable] ?? "").isEmpty
    }

    /// The variables that mark a harness's processes as one session.
    public static func environment(sessionID: String, workspace: AIWorkspace) -> [String: String] {
        [sessionVariable: sessionID, workspaceVariable: workspace.root.path, renderSpoolVariable: workspace.renderSpool.path]
    }

    /// Why `command` may not run in this session, or nil.
    public static func refusal(command: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard isActive(environment), !commands.contains(command), !informational.contains(command) else { return nil }
        let name = command.isEmpty ? "that" : "`\(command)`"
        return "livepaper: \(name) is not available in an AI session. Use livepaper " +
            commands.joined(separator: "|") + " <scene> (`livepaper help <command>` lists the options)."
    }

    /// Throws unless `url` (symlinks resolved, including for paths that don't exist yet) lies
    /// inside the session's workspace. A no-op outside AI sessions.
    public static func confine(_ url: URL, what: String,
                               environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard isActive(environment) else { return }
        guard let ws = environment[workspaceVariable], !ws.isEmpty, let root = realPath(ws) else {
            throw AISessionPolicyError("livepaper: this AI session has no workspace (\(workspaceVariable) is not set); nothing can be done")
        }
        guard let resolved = resolve(url), resolved == root || resolved.hasPrefix(root + "/") else {
            throw AISessionPolicyError("\(what) \(url.path) is outside this AI session's workspace; livepaper only works on files inside \(root)")
        }
    }

    /// The real path of `url`, resolving the deepest existing ancestor and appending the rest
    /// (which must not contain "..").
    static func resolve(_ url: URL) -> String? {
        let standardized = url.standardizedFileURL
        guard !standardized.pathComponents.contains("..") else { return nil }
        var existing = standardized, rest: [String] = []
        while realPath(existing.path) == nil {
            guard existing.path != "/" else { return nil }
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        guard let base = realPath(existing.path) else { return nil }
        return rest.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
    }

    static func realPath(_ path: String) -> String? {
        guard let p = Darwin.realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// The real path, or why there is none: `denied` when macOS refused access (EPERM / EACCES:
    /// a privacy-protected folder such as the Desktop that this process may not read), as opposed
    /// to the path not existing.
    static func lookUp(_ path: String) -> (real: String?, denied: Bool) {
        errno = 0
        guard let p = Darwin.realpath(path, nil) else {
            let e = errno
            return (nil, e == EPERM || e == EACCES)
        }
        defer { free(p) }
        return (String(cString: p), false)
    }
}

/// A request the AI-session policy refuses (a usage error for the CLI: exit status 2).
public struct AISessionPolicyError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
