// AISessionState — folds the AISessionEvent stream into what the session view shows
// (Foundation-only; also compiled into LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/).
//
// Sessions can run for 20+ minutes and agents can be chatty, so the reducer coalesces streamed
// prose, groups consecutive tool calls, keeps one filmstrip tile per still file and caps the
// timeline length. That keeps SwiftUI diffing cheap and memory bounded however long the agent runs.
import Foundation
import LivePaperCore

struct AISessionState: Equatable {
    /// Lifecycle of a session as the UI understands it.
    enum Phase: Equatable {
        case starting
        case running
        /// The agent is done and LivePaper is running its own `livepaper check`.
        case validating
        case succeeded(package: URL)
        case failed(String)
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .succeeded, .failed, .cancelled: return true
            case .starting, .running, .validating: return false
            }
        }
    }

    /// Short phase description for status pills and VoiceOver.
    static func describe(_ phase: Phase) -> String {
        switch phase {
        case .starting: return "Starting"
        case .running: return "Working"
        case .validating: return "Checking the result"
        case .succeeded: return "Ready to review"
        case .failed: return "Didn\u{2019}t finish"
        case .cancelled: return "Stopped"
        }
    }

    struct ToolCall: Equatable, Sendable {
        var name: String
        var detail: String
    }

    /// One row of the timeline.
    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable {
            case status(String)
            case text(String)
            /// Consecutive tool calls collapse into one expandable row.
            case tools([ToolCall])
            /// Consecutive stills collapse into one row ("Rendered 3 stills").
            case stills(Int)
            case check(passed: Bool, summary: String)
            case finished
            case failed(String)
            case cancelled
        }
        let id: Int
        var date: Date
        var kind: Kind
    }

    /// Bounds that keep long sessions cheap.
    static let maxEntries = 400
    static let maxTextLength = 16_000
    static let maxToolsPerGroup = 200

    private(set) var phase: Phase = .starting
    private(set) var entries: [Entry] = []
    /// One entry per still file, in the order of their latest render (the filmstrip; the last one
    /// is the newest picture). `livepaper check` writes the same file names on every run.
    private(set) var stills: [URL] = []
    /// How often each still was re-rendered since it first appeared (missing = 0). Views key their
    /// image caches on it, so a rewritten file is decoded again instead of showing the first run.
    private(set) var stillRevisions: [URL: Int] = [:]
    private(set) var report: CheckReport?
    /// Latest status line ("Running claude…"), for compact displays such as the menu bar.
    private(set) var lastStatus: String = "Starting…"
    private(set) var toolCallCount = 0
    /// How many old timeline rows were dropped to respect `maxEntries`.
    private(set) var droppedEntries = 0
    private var nextID = 0

    var package: URL? {
        if case .succeeded(let url) = phase { return url }
        return nil
    }

    /// The revision of a still's current picture (0 until it is re-rendered).
    func stillRevision(_ url: URL) -> Int { stillRevisions[url] ?? 0 }

    /// Applies one event. Events after a terminal phase are ignored (e.g. late output from an
    /// agent that was cancelled).
    mutating func apply(_ event: AISessionEvent, at date: Date = Date()) {
        guard !phase.isTerminal else { return }
        if phase == .starting { phase = .running }
        switch event {
        case .status(let s):
            lastStatus = s
            if s.range(of: "validat", options: .caseInsensitive) != nil || s.range(of: "checking", options: .caseInsensitive) != nil {
                phase = .validating
            }
            append(.status(s), date)
        case .assistantText(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if case .text(let previous) = entries.last?.kind {
                replaceLast(.text(AISessionState.join(previous, text)), date)
            } else {
                append(.text(AISessionState.clamp(text)), date)
            }
        case .toolUse(let name, let detail):
            toolCallCount += 1
            let call = ToolCall(name: name, detail: detail)
            if case .tools(var calls) = entries.last?.kind, calls.count < AISessionState.maxToolsPerGroup {
                calls.append(call)
                replaceLast(.tools(calls), date)
            } else {
                append(.tools([call]), date)
            }
        case .stillRendered(let url):
            // AISession reports a file again only when it was rewritten (a later check run): a new
            // picture under the same name. It moves to the end and gets a new revision.
            if let index = stills.firstIndex(of: url) {
                stills.remove(at: index)
                stillRevisions[url, default: 0] += 1
            }
            stills.append(url)
            // The check's motion heat maps join the filmstrip but aren't counted as stills (the
            // check's summary doesn't either).
            guard !SceneChecker.isMotionMap(url) else { break }
            if case .stills(let n) = entries.last?.kind {
                replaceLast(.stills(n + 1), date)
            } else {
                append(.stills(1), date)
            }
        case .checkResult(let r):
            report = r
            append(.check(passed: r.passed, summary: LPFormat.checkSummary(r)), date)
        case .finished(let package):
            phase = .succeeded(package: package)
            lastStatus = "Ready to review"
            append(.finished, date)
        case .failed(let message):
            phase = .failed(message)
            lastStatus = "Failed"
            append(.failed(message), date)
        }
    }

    /// The user cancelled; later events are ignored.
    mutating func markCancelled(at date: Date = Date()) {
        guard !phase.isTerminal else { return }
        phase = .cancelled
        lastStatus = "Cancelled"
        append(.cancelled, date)
    }

    /// The event stream ended. A session that never reported success or failure failed.
    mutating func streamEnded(at date: Date = Date()) {
        guard !phase.isTerminal else { return }
        apply(.failed("The agent stopped without producing a scene."), at: date)
    }

    // MARK: helpers

    private mutating func append(_ kind: Entry.Kind, _ date: Date) {
        entries.append(Entry(id: nextID, date: date, kind: kind))
        nextID += 1
        if entries.count > AISessionState.maxEntries {
            let overflow = entries.count - AISessionState.maxEntries
            entries.removeFirst(overflow)
            droppedEntries += overflow
        }
    }

    private mutating func replaceLast(_ kind: Entry.Kind, _ date: Date) {
        guard !entries.isEmpty else { return append(kind, date) }
        entries[entries.count - 1].kind = kind
        entries[entries.count - 1].date = date
    }

    /// Joins streamed prose. Token-style deltas ("Hel" + "lo") are concatenated; complete messages
    /// (previous chunk ends a sentence or a line) become separate paragraphs.
    static func join(_ previous: String, _ next: String) -> String {
        let endsSentence = previous.last.map { ".!?:\n".contains($0) } ?? true
        let startsWithSpace = next.first.map { $0.isWhitespace } ?? false
        let joined = (endsSentence && !startsWithSpace) ? previous + "\n\n" + next : previous + next
        return clamp(joined)
    }

    /// Keeps the tail of very long prose (the most recent part is what matters while watching).
    static func clamp(_ text: String) -> String {
        guard text.count > maxTextLength else { return text }
        return "\u{2026}" + String(text.suffix(maxTextLength))
    }
}

/// One-line titles for collapsed groups of tool calls: "Used 3 tools · Read ×2, Write".
enum ToolSummary {
    static func title(_ calls: [AISessionState.ToolCall]) -> String {
        guard !calls.isEmpty else { return "No tools used" }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for call in calls {
            if counts[call.name] == nil { order.append(call.name) }
            counts[call.name, default: 0] += 1
        }
        let names = order.prefix(4).map { name in
            let n = counts[name] ?? 1
            return n > 1 ? "\(name) \u{00D7}\(n)" : name
        }
        let more = order.count > 4 ? ", \u{2026}" : ""
        let head = calls.count == 1 ? "Used 1 tool" : "Used \(calls.count) tools"
        return "\(head) \u{00B7} \(names.joined(separator: ", "))\(more)"
    }
}
