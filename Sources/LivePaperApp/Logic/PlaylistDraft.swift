// PlaylistDraft — editing rules for the screen-saver playlist (Foundation-only; also compiled into
// LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/).
//
// `PlaylistSettings.sceneIDs` empty means "all scenes" (new scenes join automatically); a non-empty
// list is an explicit, ordered selection.
import Foundation
import LivePaperCore

struct PlaylistDraft: Equatable, Sendable {
    var settings: PlaylistSettings

    /// Choices offered for "Change scene".
    static let cycleChoices = [0, 2, 5, 10, 15, 30, 60]

    init(_ settings: PlaylistSettings) { self.settings = settings }

    var includesAllScenes: Bool { settings.sceneIDs.isEmpty }

    /// The scenes the saver will actually get, in order: explicit IDs that still exist, or every
    /// available scene when the selection is "all" (or every explicit scene has been deleted).
    func effectiveSceneIDs(available: [String]) -> [String] {
        let existing = Set(available)
        let explicit = settings.sceneIDs.filter(existing.contains)
        let ids = explicit.isEmpty ? available : explicit
        return settings.mode == .single ? Array(ids.prefix(1)) : ids
    }

    func isIncluded(_ id: String) -> Bool { includesAllScenes || settings.sceneIDs.contains(id) }

    /// Switches between "all scenes" and an explicit list seeded with everything available.
    mutating func setIncludesAllScenes(_ all: Bool, available: [String]) {
        settings.sceneIDs = all ? [] : available
    }

    /// Adds or removes one scene. Removing from "all" converts to an explicit list first.
    mutating func setIncluded(_ id: String, _ included: Bool, available: [String]) {
        if includesAllScenes {
            guard !included else { return }
            settings.sceneIDs = available.filter { $0 != id }
            return
        }
        if included {
            if !settings.sceneIDs.contains(id) { settings.sceneIDs.append(id) }
        } else {
            settings.sceneIDs.removeAll { $0 == id }
        }
    }

    /// Moves explicit entries (List.onMove semantics: `destination` is an index in the original array).
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ids = settings.sceneIDs
        let moving = source.sorted().filter { $0 < ids.count }.map { ids[$0] }
        let before = source.filter { $0 < destination }.count
        for i in source.sorted(by: >) where i < ids.count { ids.remove(at: i) }
        let insertAt = min(max(0, destination - before), ids.count)
        ids.insert(contentsOf: moving, at: insertAt)
        settings.sceneIDs = ids
    }

    /// "Use as screen saver": show only this scene.
    mutating func useOnly(_ id: String) {
        settings.mode = .single
        settings.sceneIDs = [id]
    }

    /// "Add to playlist". Returns false when the scene is already part of it.
    @discardableResult
    mutating func add(_ id: String) -> Bool {
        if settings.mode == .single {
            // A single-scene playlist that gains a second scene becomes a sequence.
            if settings.sceneIDs == [id] { return false }
            settings.mode = .sequence
            if settings.sceneIDs.isEmpty { settings.sceneIDs = [id]; return true }
        }
        guard !isIncluded(id) else { return false }
        settings.sceneIDs.append(id)
        return true
    }

    /// The menu-bar "Next scene" action: advances what the saver will show next.
    /// single → the next available scene; sequence → rotate the explicit order; shuffle → nil (no
    /// meaningful "next").
    static func advanced(_ s: PlaylistSettings, available: [String]) -> PlaylistSettings? {
        guard !available.isEmpty else { return nil }
        var out = s
        switch s.mode {
        case .shuffle:
            return nil
        case .single:
            let current = PlaylistDraft(s).effectiveSceneIDs(available: available).first
            let idx = current.flatMap { available.firstIndex(of: $0) } ?? -1
            out.sceneIDs = [available[(idx + 1) % available.count]]
        case .sequence:
            var ids = PlaylistDraft(s).effectiveSceneIDs(available: available)
            guard ids.count > 1 else { return nil }
            ids.append(ids.removeFirst())
            out.sceneIDs = ids
        }
        return out
    }

    /// "Shuffle · 4 scenes · every 5 minutes" / "Aurora Lake".
    static func summary(_ s: PlaylistSettings, available: [String], names: [String: String]) -> String {
        let ids = PlaylistDraft(s).effectiveSceneIDs(available: available)
        guard !ids.isEmpty else { return "No scenes yet" }
        if s.mode == .single || ids.count == 1 { return names[ids[0]] ?? ids[0] }
        let mode = s.mode == .shuffle ? "Shuffle" : "In order"
        let count = s.sceneIDs.isEmpty ? "all \(ids.count) scenes" : "\(ids.count) scenes"
        let cycle = s.cycleMinutes > 0 ? LPFormat.cycle(minutes: s.cycleMinutes).lowercased() : "one per session"
        return "\(mode) \u{00B7} \(count) \u{00B7} \(cycle)"
    }
}

// UI titles for core enums. Prefixed `ui` so they can never clash with members LivePaperCore adds.
extension LPPlaylistMode {
    var uiTitle: String {
        switch self {
        case .shuffle: return "Shuffle"
        case .sequence: return "In order"
        case .single: return "One scene"
        }
    }
}

extension LPPerformanceProfile {
    var uiTitle: String {
        switch self {
        case .automatic: return "Automatic"
        case .best: return "Best quality"
        case .balanced: return "Balanced"
        case .battery: return "Battery saver"
        }
    }

    var uiExplanation: String {
        switch self {
        case .automatic: return "Full quality on power; 30 fps at 75 % resolution on battery or in Low Power Mode."
        case .best: return "60 fps at full resolution, always."
        case .balanced: return "60 fps at 75 % resolution."
        case .battery: return "30 fps at 75 % resolution, always. Lowest energy use."
        }
    }
}

extension LPClockPosition {
    var uiTitle: String {
        switch self {
        case .top: return "Top"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .none: return "Drawn by the scene"
        }
    }
}
