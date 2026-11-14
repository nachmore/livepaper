// AIPreferences — the user's AI authoring defaults and prompt helpers (Foundation-only; also
// compiled into LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/).
import Foundation
import LivePaperCore

/// Stored as one JSON value in the app's preferences (these are app-only preferences; the helper
/// and saver never need them, so they don't belong in state.json).
struct AIPreferences: Codable, Equatable, Sendable {
    static let defaultsKey = "aiPreferences"
    static let timeoutChoices = [5, 10, 20, 30, 45, 60]
    static let defaultTimeoutMinutes = 20

    /// `AIHarness.id` of the preferred harness; nil = first detected.
    var defaultHarnessID: String?
    /// Optional model name passed to the harness (empty = harness default).
    var model: String = ""
    var timeoutMinutes: Int = AIPreferences.defaultTimeoutMinutes
    /// Template for a user-defined harness, e.g. `mytool --prompt {prompt_file} --dir {workspace}`.
    var customCommand: String = ""

    init(defaultHarnessID: String? = nil, model: String = "", timeoutMinutes: Int = AIPreferences.defaultTimeoutMinutes,
         customCommand: String = "") {
        self.defaultHarnessID = defaultHarnessID; self.model = model
        self.timeoutMinutes = timeoutMinutes; self.customCommand = customCommand
    }

    // Tolerant decoding so adding fields later never resets the user's preferences.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultHarnessID = try c.decodeIfPresent(String.self, forKey: .defaultHarnessID)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        timeoutMinutes = try c.decodeIfPresent(Int.self, forKey: .timeoutMinutes) ?? AIPreferences.defaultTimeoutMinutes
        customCommand = try c.decodeIfPresent(String.self, forKey: .customCommand) ?? ""
    }

    static func load(from defaults: PreferenceStore) -> AIPreferences {
        guard let data = defaults.data(forKey: defaultsKey),
              let prefs = try? JSONDecoder().decode(AIPreferences.self, from: data) else { return AIPreferences() }
        return prefs
    }

    func save(to defaults: PreferenceStore) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: AIPreferences.defaultsKey) }
    }

    var timeout: TimeInterval { TimeInterval(max(1, timeoutMinutes)) * 60 }
    var trimmedModel: String? {
        let t = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// The custom harness, when a valid template is configured.
    var customHarness: AIHarness? {
        let template = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty, AIPreferences.customCommandProblem(template) == nil,
              let exe = template.split(separator: " ").first else { return nil }
        return AIHarness(kind: .custom, name: "Custom command", executable: String(exe), customTemplate: template)
    }

    /// Placeholders understood by the custom-command adapter.
    static let placeholders = ["{prompt_file}", "{prompt}", "{workspace}", "{model}"]

    /// Why a custom command can't be used, or nil when it's fine.
    static func customCommandProblem(_ template: String) -> String? {
        let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if !t.contains("{prompt_file}") && !t.contains("{prompt}") {
            return "Include {prompt_file} or {prompt} so the agent receives the instructions."
        }
        let unknown = t.matches(of: #/\{[a-z_]+\}/#).map { String($0.output) }.filter { !placeholders.contains($0) }
        if let first = unknown.first { return "Unknown placeholder \(first). Use \(placeholders.joined(separator: ", "))." }
        return nil
    }

    /// Picks the harness to preselect: the preferred one if still installed, else the first.
    static func preferredHarness(in harnesses: [AIHarness], preferredID: String?) -> AIHarness? {
        if let id = preferredID, let h = harnesses.first(where: { $0.id == id }) { return h }
        return harnesses.first
    }
}

extension AIHarness {
    /// "Claude Code 2.1.4" / "Custom command".
    var uiTitle: String {
        guard let v = version?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return name }
        return "\(name) \(v)"
    }
}

/// Prompt helpers for the "Describe it" box and the session's "Try again with feedback".
enum PromptComposer {
    /// Inspiration chips (original ideas; tapping one fills the prompt).
    static let inspirations: [String] = [
        "A calm aurora over a mirror-still lake, slowly shifting greens and violets",
        "Paper lanterns drifting upward through a warm summer night",
        "Ink drops blooming in water, deep blues fading into black",
        "A minimalist orbit of glowing planets around a soft sun",
        "Rain on a window at night with blurred city lights behind it",
        "Gentle sand dunes at dusk with long moving shadows",
    ]

    /// Minimum prompt length that's worth sending to an agent.
    static let minimumPromptLength = 8

    static func isUsable(_ prompt: String) -> Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumPromptLength
    }

    /// Builds the prompt for another attempt: the original request plus the user's feedback.
    static func retry(original: String, feedback: String) -> String {
        let o = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty else { return o }
        return "\(o)\n\nFeedback on the previous attempt (please address it): \(f)"
    }

    /// The prompt carried by a request.
    static func prompt(of request: AISessionRequest) -> String {
        switch request {
        case .create(let p): return p
        case .modify(_, let p): return p
        }
    }

    /// A short title for a session row: the first words of the prompt.
    static func title(for prompt: String, limit: Int = 42) -> String {
        let flat = prompt.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard flat.count > limit else { return flat.isEmpty ? "Untitled" : flat }
        let cut = flat.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return String(atWord) + "\u{2026}"
    }
}
