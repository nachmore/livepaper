// LibraryQuery — search, filtering and naming rules for the scene library (Foundation-only; also
// compiled into LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/).
import Foundation
import LivePaperCore

/// A library scene plus the facts the UI needs to draw its card, computed once per reload (they
/// require disk access, which must not happen in view bodies).
struct LibraryEntry: Identifiable, Equatable, Hashable, Sendable {
    var item: SceneItem
    var badge: SceneBadge
    var energy: EnergyClass
    var id: String { item.id }
    var manifest: SceneManifest { item.manifest }

    init(item: SceneItem, hasAIHistory: Bool) {
        self.item = item
        self.badge = SceneBadge(kind: item.manifest.kind, hasAIHistory: hasAIHistory)
        self.energy = EnergyClass(manifest: item.manifest)
    }
}

/// The kind filter in the library toolbar.
enum LibraryKindFilter: String, CaseIterable, Identifiable, Sendable {
    case all, web, ai, video
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .web: return "Web"
        case .ai: return "AI"
        case .video: return "Video"
        }
    }

    func includes(_ badge: SceneBadge) -> Bool {
        switch self {
        case .all: return true
        case .web: return badge == .web
        case .ai: return badge == .ai
        case .video: return badge == .video
        }
    }
}

/// Search text + kind filter. Every whitespace-separated token must match the scene's name,
/// description, id or one of its tags (case- and diacritic-insensitive).
struct LibraryQuery: Equatable, Sendable {
    var text: String = ""
    var kind: LibraryKindFilter = .all

    var isActive: Bool { kind != .all || !tokens.isEmpty }

    private var tokens: [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    func matches(_ entry: LibraryEntry) -> Bool {
        guard kind.includes(entry.badge) else { return false }
        let m = entry.manifest
        let haystack = ([m.name, m.description, m.id] + m.tags)
        return tokens.allSatisfy { token in
            haystack.contains { $0.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    func apply(_ entries: [LibraryEntry]) -> [LibraryEntry] { entries.filter(matches) }
}

/// Naming helpers for clone and import.
enum SceneNaming {
    /// "Aurora Lake" → "Aurora Lake copy", then "Aurora Lake copy 2", … (case-insensitive check).
    static func uniqueCopyName(for name: String, existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Scene" : name
        let first = "\(base) copy"
        if !taken.contains(first.lowercased()) { return first }
        var n = 2
        while taken.contains("\(first) \(n)".lowercased()) { n += 1 }
        return "\(first) \(n)"
    }

    /// A friendly scene name from a file name: "coastline_at-dusk.mov" → "Coastline at dusk".
    static func suggestedName(forFile url: URL) -> String {
        let raw = url.deletingPathExtension().lastPathComponent
        let spaced = raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let words = spaced.split(whereSeparator: { $0.isWhitespace })
        guard let first = words.first else { return "Video" }
        let joined = words.joined(separator: " ")
        // Only touch capitalisation when the name is all lower-case (keep "NYC Skyline" as is).
        guard joined == joined.lowercased() else { return joined }
        return first.prefix(1).uppercased() + joined.dropFirst()
    }

    /// Trims and validates a user-entered scene name. Returns nil when it can't be used.
    static func validated(_ name: String) -> String? {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.count > 80 ? nil : t
    }
}
