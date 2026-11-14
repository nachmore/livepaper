// SceneMetrics — pure, UI-independent classification and formatting of scene data.
//
// This file is Foundation-only on purpose: it is also compiled into LivePaperSelfTest through a
// symlink in Sources/LivePaperSelfTest/AppLogic/ so the logic can be tested without launching any
// GUI process. Keep AppKit/SwiftUI out of it.
import Foundation
import LivePaperCore

/// How much energy a scene is expected to use while it runs, derived from `scene.json › performance`
/// (written by `livepaper check`, see ARCHITECTURE §9 and §12).
enum EnergyClass: String, CaseIterable, Sendable {
    case low, medium, high, unmeasured

    /// Hard per-frame budget enforced by `livepaper check` at 1512×982@2x.
    static let benchBudgetMs = 4.0
    /// Bench times at or below this are considered light.
    static let lightBenchMs = 1.5
    /// Live CPU energy thresholds (battery profile), in milliwatts.
    static let lowEnergyMw = 100.0
    static let mediumEnergyMw = 250.0

    /// Classifies a scene. A live energy measurement wins over the bench time because it is the
    /// number that actually matters for battery life; video scenes without a measurement are
    /// treated as low because they are hardware-decoded by the media engine.
    init(manifest: SceneManifest) {
        if let mw = manifest.performance?.energyMw, mw.isFinite, mw >= 0 {
            self = mw <= EnergyClass.lowEnergyMw ? .low : (mw <= EnergyClass.mediumEnergyMw ? .medium : .high)
        } else if let ms = manifest.performance?.benchMs, ms.isFinite, ms >= 0 {
            self = ms <= EnergyClass.lightBenchMs ? .low : (ms <= EnergyClass.benchBudgetMs ? .medium : .high)
        } else {
            self = manifest.kind == .video ? .low : .unmeasured
        }
    }

    var label: String {
        switch self {
        case .low: return "Low energy"
        case .medium: return "Medium energy"
        case .high: return "High energy"
        case .unmeasured: return "Not measured"
        }
    }

    var shortLabel: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .unmeasured: return "—"
        }
    }

    /// SF Symbol name used for the badge.
    var symbolName: String {
        switch self {
        case .low: return "leaf.fill"
        case .medium: return "bolt.fill"
        case .high: return "flame.fill"
        case .unmeasured: return "questionmark.circle"
        }
    }

    var explanation: String {
        switch self {
        case .low: return "Light on the battery. Fine to leave running for hours."
        case .medium: return "Within LivePaper's budget, but noticeably busier than a still wallpaper."
        case .high: return "Over LivePaper's energy budget. Consider \u{201C}Modify with AI\u{201D} to make it lighter."
        case .unmeasured: return "Not checked yet. Run a check to measure its cost."
        }
    }
}

/// The badge shown on a scene card: what kind of scene it is from the user's point of view.
enum SceneBadge: String, CaseIterable, Sendable {
    case web, ai, video

    /// AI provenance (a non-empty history.jsonl) turns a web scene into an "AI" scene.
    init(kind: SceneManifest.Kind, hasAIHistory: Bool) {
        switch kind {
        case .video: self = .video
        case .web: self = hasAIHistory ? .ai : .web
        }
    }

    var label: String {
        switch self {
        case .web: return "Web"
        case .ai: return "AI"
        case .video: return "Video"
        }
    }

    var symbolName: String {
        switch self {
        case .web: return "chevron.left.forwardslash.chevron.right"
        case .ai: return "sparkles"
        case .video: return "film"
        }
    }
}

/// Human-readable formatting shared by the views. All functions are deterministic.
enum LPFormat {
    /// "1.4 ms" / "12 ms" — one decimal below 10 ms.
    static func milliseconds(_ ms: Double) -> String {
        guard ms.isFinite else { return "—" }
        return ms < 10 ? String(format: "%.1f ms", ms) : String(format: "%.0f ms", ms)
    }

    /// "61 mW" / "1.2 W".
    static func power(milliwatts mw: Double) -> String {
        guard mw.isFinite else { return "—" }
        return mw < 1000 ? String(format: "%.0f mW", mw) : String(format: "%.1f W", mw / 1000)
    }

    /// Elapsed time as "0:07", "4:05" or "1:02:03".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "Never changes" / "Every minute" / "Every 5 minutes" / "Every hour".
    static func cycle(minutes: Int) -> String {
        switch minutes {
        case ..<1: return "Never changes"
        case 1: return "Every minute"
        case 60: return "Every hour"
        default: return "Every \(minutes) minutes"
        }
    }

    /// Replaces the user's home directory prefix with "~" so paths shown in the UI (and in logs or
    /// screenshots users may share) don't reveal their account name.
    static func abbreviatingHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !h.isEmpty else { return path }
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }

    /// Short summary of a check report: "Passed · 1.4 ms · 61 mW" / "2 problems".
    static func checkSummary(_ report: CheckReport) -> String {
        if !report.passed {
            // A failed report always has at least one problem, even if it didn't list it.
            let n = max(1, report.problems.count + report.jsErrors.count)
            return n == 1 ? "1 problem" : "\(n) problems"
        }
        var parts = ["Passed"]
        if let bench = CheckReportFile.primaryBenchMs(report) { parts.append(milliseconds(bench)) }
        if let e = report.energyMw { parts.append(power(milliwatts: e)) }
        return parts.joined(separator: " · ")
    }
}

/// Labels for `CheckReport.benchMs` keys ("1512x982@2 t=14").
enum BenchLabel {
    /// "1512x982@2 t=14" → "1512×982 @2x". Unknown formats are returned unchanged.
    static func title(_ key: String) -> String {
        let size = key.split(separator: " ").first.map(String.init) ?? key
        let parts = size.split(separator: "@", maxSplits: 1).map(String.init)
        guard let dims = parts.first, dims.contains("x") else { return key }
        let pretty = dims.replacingOccurrences(of: "x", with: "\u{00D7}")
        return parts.count > 1 ? "\(pretty) @\(parts[1])x" : pretty
    }
}
