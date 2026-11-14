// StreamParsers — turn each harness's stdout into AISessionEvents.
//
// Harness output formats change between versions, so every parser is tolerant: unknown JSON event
// types are ignored, and a line that isn't JSON at all (a warning, a crash message, an older
// version printing text) is passed through as plain assistant text.
import Foundation

public protocol HarnessStreamParser: AnyObject {
    /// Events for one line of stdout.
    func parse(line: String) -> [AISessionEvent]
    /// Events still buffered when the stream ends.
    func finish() -> [AISessionEvent]
    /// The agent's final message, when the format reports one (used as the history summary).
    var finalMessage: String? { get }
}

// MARK: - Shared helpers

enum StreamText {
    /// Removes ANSI escape sequences (colours, cursor movement) from terminal-style output.
    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: #"\u{1B}(\[[0-?]*[ -/]*[@-~]|\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\)|[@-Z\\-_])"#,
                               with: "", options: .regularExpression)
    }

    static func jsonObject(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any]
    }

    /// A non-JSON line as a plain-text event (nil for blank lines).
    static func plain(_ line: String) -> AISessionEvent? {
        let text = stripANSI(line).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .assistantText(text)
    }

    static func truncate(_ s: String, _ limit: Int = 200) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ⏎ ")
        return oneLine.count <= limit ? oneLine : String(oneLine.prefix(limit - 1)) + "…"
    }

    /// Shows workspace paths relative to the workspace ("scene/scene.js").
    static func relative(_ s: String, to root: URL) -> String {
        let prefixes = [root.path + "/", root.resolvingSymlinksInPath().path + "/"]
        var out = s
        for p in prefixes { out = out.replacingOccurrences(of: p, with: "") }
        return out
    }

    /// One-line description of a tool call's input: the command, path, pattern…
    static func toolDetail(_ input: Any?, root: URL) -> String {
        guard let dict = input as? [String: Any] else { return "" }
        for key in ["command", "file_path", "path", "pattern", "url", "query", "description", "prompt"] {
            if let v = dict[key] as? String, !v.isEmpty { return truncate(relative(v, to: root)) }
            if let v = dict[key] as? [String], !v.isEmpty { return truncate(relative(v.joined(separator: " "), to: root)) }
        }
        return ""
    }
}

// MARK: - Claude Code (`--output-format stream-json --verbose`)

/// Lines: `{"type":"system","subtype":"init",…}`, `{"type":"assistant","message":{"content":[…]}}`,
/// `{"type":"user",…}` (tool results), `{"type":"result","result":"…","is_error":false,…}`.
public final class ClaudeStreamParser: HarnessStreamParser {
    private let root: URL
    public private(set) var finalMessage: String?
    public init(workspaceRoot: URL) { root = workspaceRoot }

    public func parse(line: String) -> [AISessionEvent] {
        guard let obj = StreamText.jsonObject(line) else { return StreamText.plain(line).map { [$0] } ?? [] }
        switch obj["type"] as? String {
        case "system":
            guard obj["subtype"] as? String == "init" else { return [] }
            let model = (obj["model"] as? String).map { " (\($0))" } ?? ""
            return [.status("Claude Code started\(model)")]
        case "assistant":
            let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { block -> AISessionEvent? in
                switch block["type"] as? String {
                case "text":
                    guard let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                    finalMessage = text
                    return .assistantText(text)
                case "tool_use":
                    return .toolUse(name: block["name"] as? String ?? "tool", detail: StreamText.toolDetail(block["input"], root: root))
                case "thinking", "redacted_thinking":
                    return .status("Thinking…")
                default:
                    return nil
                }
            }
        case "result":
            if let result = (obj["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
                finalMessage = result
            }
            guard obj["is_error"] as? Bool == true else { return [] }
            let detail = (obj["result"] as? String) ?? (obj["subtype"] as? String) ?? "error"
            return [.status("Claude Code stopped: \(StreamText.truncate(detail))")]
        default:
            return []   // "user" (tool results echo), "stream_event", future types
        }
    }

    public func finish() -> [AISessionEvent] { [] }
}

// MARK: - Codex (`codex exec --json`)

/// Current format: `{"type":"thread.started"}`, `{"type":"item.started"|"item.completed","item":{…}}`,
/// `{"type":"turn.completed"|"turn.failed"}`, `{"type":"error"}`. Items: agent_message, reasoning,
/// command_execution, file_change, mcp_tool_call, web_search, todo_list, error.
/// Older versions (≤ 0.4x) wrote `{"id":…,"msg":{"type":"agent_message","message":…}}`; both are handled.
public final class CodexStreamParser: HarnessStreamParser {
    private let root: URL
    private var startedItems = Set<String>()
    public private(set) var finalMessage: String?
    public init(workspaceRoot: URL) { root = workspaceRoot }

    public func parse(line: String) -> [AISessionEvent] {
        guard let obj = StreamText.jsonObject(line) else { return StreamText.plain(line).map { [$0] } ?? [] }
        if let msg = obj["msg"] as? [String: Any] { return legacy(msg) }
        switch obj["type"] as? String {
        case "thread.started":
            return [.status("Codex started")]
        case "item.started":
            guard let item = obj["item"] as? [String: Any] else { return [] }
            if let id = item["id"] as? String { startedItems.insert(id) }
            return item["type"] as? String == "command_execution" ? self.item(item) : []
        case "item.completed":
            guard let item = obj["item"] as? [String: Any] else { return [] }
            // Commands were reported when they started; don't repeat them.
            if item["type"] as? String == "command_execution", let id = item["id"] as? String, startedItems.contains(id) { return [] }
            return self.item(item)
        case "turn.failed":
            let message = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "turn failed"
            return [.status("Codex stopped: \(StreamText.truncate(message))")]
        case "error":
            return [.status("Codex: \(StreamText.truncate(obj["message"] as? String ?? "error"))")]
        default:
            return []
        }
    }

    private func item(_ item: [String: Any]) -> [AISessionEvent] {
        switch item["type"] as? String {
        case "agent_message":
            guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
            finalMessage = text
            return [.assistantText(text)]
        case "reasoning":
            return [.status("Thinking…")]
        case "command_execution":
            return [.toolUse(name: "shell", detail: StreamText.truncate(StreamText.relative(item["command"] as? String ?? "", to: root)))]
        case "file_change":
            let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            return [.toolUse(name: "edit", detail: StreamText.truncate(paths.map { StreamText.relative($0, to: root) }.joined(separator: ", ")))]
        case "mcp_tool_call":
            let name = [item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: ".")
            return [.toolUse(name: name.isEmpty ? "mcp" : name, detail: StreamText.toolDetail(item["arguments"], root: root))]
        case "web_search":
            return [.toolUse(name: "web_search", detail: StreamText.truncate(item["query"] as? String ?? ""))]
        case "error":
            return [.status("Codex: \(StreamText.truncate(item["message"] as? String ?? "error"))")]
        default:
            return []
        }
    }

    private func legacy(_ msg: [String: Any]) -> [AISessionEvent] {
        switch msg["type"] as? String {
        case "agent_message":
            guard let text = (msg["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
            finalMessage = text
            return [.assistantText(text)]
        case "agent_reasoning":
            return [.status("Thinking…")]
        case "exec_command_begin":
            let command = (msg["command"] as? [String])?.joined(separator: " ") ?? (msg["command"] as? String ?? "")
            return [.toolUse(name: "shell", detail: StreamText.truncate(StreamText.relative(command, to: root)))]
        case "patch_apply_begin":
            let paths = (msg["changes"] as? [String: Any])?.keys.sorted() ?? []
            return [.toolUse(name: "edit", detail: StreamText.truncate(paths.map { StreamText.relative($0, to: root) }.joined(separator: ", ")))]
        case "task_complete":
            if let text = msg["last_agent_message"] as? String, !text.isEmpty { finalMessage = text }
            return []
        case "error":
            return [.status("Codex: \(StreamText.truncate(msg["message"] as? String ?? "error"))")]
        default:
            return []
        }
    }

    public func finish() -> [AISessionEvent] { [] }
}

// MARK: - Kiro CLI (`--output-format stream-json`: Agent Client Protocol events)

/// ACP `session/update` notifications, one per line. Message and thought text arrives in small
/// chunks; they are coalesced into whole lines/paragraphs so the UI isn't flooded.
public final class KiroStreamParser: HarnessStreamParser {
    private let root: URL
    private var text = ""
    private var thinking = false
    private var announcedTools = Set<String>()
    private var lastMessage = ""
    public var finalMessage: String? { lastMessage.isEmpty ? nil : lastMessage }
    public init(workspaceRoot: URL) { root = workspaceRoot }

    public func parse(line: String) -> [AISessionEvent] {
        guard let obj = StreamText.jsonObject(line) else { return flush() + (StreamText.plain(line).map { [$0] } ?? []) }
        guard let update = Self.update(in: obj), let kind = (update["sessionUpdate"] ?? update["type"]) as? String else { return [] }
        switch kind {
        case "agent_message_chunk":
            thinking = false
            guard let chunk = Self.text(of: update["content"]) else { return [] }
            text += chunk
            return drainCompleteParagraphs()
        case "agent_thought_chunk":
            guard !thinking else { return [] }
            thinking = true
            return flush() + [.status("Thinking…")]
        case "tool_call":
            thinking = false
            let id = update["toolCallId"] as? String ?? UUID().uuidString
            guard announcedTools.insert(id).inserted else { return [] }
            return flush() + [toolEvent(update)]
        case "tool_call_update":
            // Some agents only fill in the title/input in a later update; announce once.
            guard let id = update["toolCallId"] as? String, !announcedTools.contains(id),
                  update["title"] != nil || update["rawInput"] != nil else { return [] }
            announcedTools.insert(id)
            return flush() + [toolEvent(update)]
        default:
            return flush()
        }
    }

    public func finish() -> [AISessionEvent] { flush() }

    private func toolEvent(_ update: [String: Any]) -> AISessionEvent {
        let title = (update["title"] as? String) ?? (update["kind"] as? String) ?? "tool"
        var detail = StreamText.toolDetail(update["rawInput"], root: root)
        if detail.isEmpty, let locations = update["locations"] as? [[String: Any]] {
            detail = locations.compactMap { $0["path"] as? String }.map { StreamText.relative($0, to: root) }.joined(separator: ", ")
        }
        return .toolUse(name: StreamText.truncate(StreamText.relative(title, to: root), 80), detail: StreamText.truncate(detail))
    }

    /// Emits text up to the last blank line (paragraph boundary); keeps the rest buffered.
    private func drainCompleteParagraphs() -> [AISessionEvent] {
        guard let cut = text.range(of: "\n\n", options: .backwards) else { return [] }
        let ready = String(text[..<cut.lowerBound])
        text = String(text[cut.upperBound...])
        return emit(ready)
    }

    private func flush() -> [AISessionEvent] {
        defer { text = "" }
        return emit(text)
    }

    private func emit(_ s: String) -> [AISessionEvent] {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        lastMessage = trimmed
        return [.assistantText(trimmed)]
    }

    /// The `update` object of a `session/update` notification, wherever the envelope puts it.
    static func update(in obj: [String: Any]) -> [String: Any]? {
        if let params = obj["params"] as? [String: Any], let u = params["update"] as? [String: Any] { return u }
        if let u = obj["update"] as? [String: Any] { return u }
        if obj["sessionUpdate"] != nil { return obj }
        return nil
    }

    static func text(of content: Any?) -> String? {
        if let c = content as? [String: Any] { return c["text"] as? String }
        if let list = content as? [[String: Any]] { return list.compactMap { $0["text"] as? String }.joined() }
        return content as? String
    }
}

// MARK: - Plain text (kiro text mode, custom harnesses)

/// Every non-blank line is assistant text, except lines announcing a tool ("Using tool: fs_write").
public final class PlainTextParser: HarnessStreamParser {
    private var lastLine: String?
    public var finalMessage: String? { lastLine }
    public init() {}

    public func parse(line: String) -> [AISessionEvent] {
        let text = StreamText.stripANSI(line).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        if let range = text.range(of: "Using tool: ") {
            let rest = text[range.upperBound...]
            let name = rest.prefix { !$0.isWhitespace }
            return [.toolUse(name: String(name), detail: StreamText.truncate(rest.dropFirst(name.count).trimmingCharacters(in: .whitespaces)))]
        }
        lastLine = text
        return [.assistantText(text)]
    }

    public func finish() -> [AISessionEvent] { [] }
}
