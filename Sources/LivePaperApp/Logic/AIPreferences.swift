// AIPreferences — rules for the AI settings UI, and prompt helpers (Foundation-only; also
// compiled into LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/).
import Foundation
import LivePaperCore

/// UI rules for the AI settings. The settings themselves are `AISettings` (LivePaperCore), stored by
/// AIServicing in ai-settings.json so the CLI and AI sessions use the same defaults as the app.
enum AIPreferences {
    static let timeoutChoices = [5, 10, 20, 30, 45, 60]

    /// The picker's choices, including a value set elsewhere (e.g. by hand in ai-settings.json).
    static func timeoutChoices(including current: Int) -> [Int] {
        timeoutChoices.contains(current) || current <= 0 ? timeoutChoices : (timeoutChoices + [current]).sorted()
    }

    /// Placeholders understood by the custom-command adapter.
    static var placeholders: [String] { CustomAdapter.placeholders }

    /// Why a custom command can't be used, or nil when it's fine (an empty command means "none").
    static func customCommandProblem(_ template: String) -> String? {
        let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : CustomAdapter.templateProblem(t)
    }

    /// The custom harness, when a usable template is configured.
    static func customHarness(_ settings: AISettings) -> AIHarness? {
        guard let template = settings.customTemplate?.trimmingCharacters(in: .whitespacesAndNewlines), !template.isEmpty,
              customCommandProblem(template) == nil else { return nil }
        return AIHarness.custom(template: template)
    }

    /// Detected harnesses plus the configured custom command. Any custom entry from detection is
    /// replaced, so editing the command in Settings takes effect without detecting again.
    static func availableHarnesses(detected: [AIHarness], settings: AISettings) -> [AIHarness] {
        detected.filter { $0.kind != .custom } + (customHarness(settings).map { [$0] } ?? [])
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

    /// With reference images any prompt will do, even none (`effectivePrompt` fills it in).
    static func isUsable(_ prompt: String, hasReferences: Bool) -> Bool {
        hasReferences || isUsable(prompt)
    }

    /// The prompt to send: what the user typed, or — when they typed nothing but attached images —
    /// the default request for those images (ReferencePrompts.defaultPrompt).
    static func effectivePrompt(_ prompt: String, roles: [AIReferenceRole]) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        return ReferencePrompts.defaultPrompt(roles: roles) ?? trimmed
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
