// KiroAgentConfig — the restricted Kiro CLI agent every Kiro session runs as (ARCHITECTURE §10).
//
// Written to <workspace>/.kiro/agents/livepaper-session.json and selected with
// `kiro-cli chat --agent livepaper-session`; nothing is trusted on the command line (`--trust-tools`
// trusts a tool "on any path it would ask about, outside the workspace too", and a V2 name such as
// fs_write trusts deleting files as well). Checked against kiro-cli 3.3 (`agent validate`,
// `agent list`, and `agent upgrade`'s translation of the same settings):
//
//   * Kiro's V2 engine reads `tools`, `allowedTools` (trusted without asking) and `toolsSettings`:
//     writes are allowed only under scene/**, and the shell runs only commands matching
//     `allowedCommands` — regexes kiro-cli anchors with \A…\z — with `denyByDefault` refusing the
//     rest. The patterns admit nothing but `livepaper <scene command>` followed by plain words
//     (letters, digits, `. _ / = , : @ + -`): no `;`, `&`, `|`, `$`, backticks, quotes, `~`,
//     redirections or newlines, so nothing can be chained onto an allowed command.
//   * The V3 engine ignores `toolsSettings` and reads `permissions.rules` instead: the same commands
//     as globs (V3 parses a command line and judges each command in it), everything else in the
//     shell denied, writes allowed under scene/**, reads allowed.
//
// No MCP servers (`includeMcpJson: false` also keeps the user's own out), no hooks, no resources.
// Anything else a tool asks for needs approval, which a non-interactive session can't give.
import Foundation

public enum KiroAgentConfig {
    public static let name = "livepaper-session"

    /// Where the agent lives in a workspace (Kiro finds local agents in <cwd>/.kiro/agents).
    public static func url(in workspace: AIWorkspace) -> URL {
        workspace.root.appendingPathComponent(".kiro/agents/\(name).json")
    }

    /// Characters a command's arguments may use (see the header).
    static let argumentCharacters = "[A-Za-z0-9 ._/=,:@+-]"

    static var commands: [String] { AISessionPolicy.commands + ["help"] }

    /// V2 `allowedCommands` (anchored by kiro-cli).
    static var shellRegexes: [String] {
        ["livepaper (\(commands.joined(separator: "|")))( \(argumentCharacters)*)?"]
    }

    /// V3 shell globs.
    static var shellGlobs: [String] { commands.flatMap { ["livepaper \($0)", "livepaper \($0) *"] } }

    /// Where writes are allowed: scene/** relative to the workspace, and the same as absolute paths
    /// (Kiro's tools often name files absolutely, and /var vs /private/var spellings differ).
    static func writablePatterns(for workspace: AIWorkspace) -> [String] {
        var roots = [workspace.root.standardizedFileURL.path]
        if let real = AISessionPolicy.realPath(workspace.root.path) { roots.append(real) }
        var seen = Set<String>()
        return (["scene/**"] + roots.map { ($0 as NSString).appendingPathComponent("scene/**") }).filter { seen.insert($0).inserted }
    }

    public static func json(for workspace: AIWorkspace) throws -> Data {
        let writable = writablePatterns(for: workspace)
        let config: [String: Any] = [
            "name": name,
            "description": "LivePaper scene session: edits ./scene and runs only the livepaper scene commands",
            "prompt": NSNull(),
            "mcpServers": [String: Any](),
            "tools": ["read", "write", "shell", "glob", "grep"],
            "toolAliases": [String: Any](),
            "allowedTools": ["read", "glob", "grep"],
            "resources": [String](),
            "hooks": [String: Any](),
            "toolsSettings": [
                "write": ["allowedPaths": writable],
                "shell": ["allowedCommands": shellRegexes, "denyByDefault": true],
            ],
            "includeMcpJson": false,
            "model": NSNull(),
            "permissions": ["rules": [
                ["capability": "shell", "match": shellGlobs, "effect": "allow"],
                ["capability": "shell", "match": ["*"], "exclude": shellGlobs, "effect": "deny"],
                ["capability": "fs_write", "match": writable, "effect": "allow"],
                ["capability": "fs_read", "effect": "allow"],
            ]],
        ]
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public static func write(in workspace: AIWorkspace) throws {
        let url = url(in: workspace)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (json(for: workspace) + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}
