// PlaylistDraft — editing rules for the screen-saver playlist and its multiple-display settings
// (Foundation-only; also compiled into LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/).
//
// `PlaylistSettings.sceneIDs` empty means "all scenes" (new scenes join automatically); a non-empty
// list is an explicit, ordered selection. With `collectionID` the playlist follows a collection (a
// live link: its scenes, in its order, whatever they are when it is published); `sceneIDs` then keeps
// the collection's scenes as they were when the settings were last saved (PlaylistSettings.following).
import Foundation
import LivePaperCore

/// Where the playlist's scenes come from (the Screen Saver screen's "Play" picker).
enum PlaylistSource: Hashable, Sendable {
    /// Every scene; new scenes join automatically.
    case all
    /// The scenes chosen on the Screen Saver screen, in their order.
    case chosen
    /// A collection's scenes, in its order, following its changes.
    case collection(String)
}

struct PlaylistDraft: Equatable, Sendable {
    var settings: PlaylistSettings

    /// Choices offered for "Change scene".
    static let cycleChoices = [0, 2, 5, 10, 15, 30, 60]

    init(_ settings: PlaylistSettings) { self.settings = settings }

    var includesAllScenes: Bool { settings.sceneIDs.isEmpty }

    var source: PlaylistSource {
        if let id = settings.collectionID { return .collection(id) }
        return includesAllScenes ? .all : .chosen
    }

    /// Switches where the scenes come from. Choosing scenes starts from what plays now: every scene,
    /// or the collection's (a copy, which no longer follows it); a collection's scenes are kept as
    /// the stored copy. A collection of several scenes doesn't play as "One scene".
    mutating func setSource(_ source: PlaylistSource, available: [String], collections: [SceneCollection]) {
        switch source {
        case .all:
            settings.collectionID = nil
            settings.sceneIDs = []
        case .chosen:
            let existing = Set(available)
            let playing = settings.following(collections).sceneIDs.filter(existing.contains)
            settings.collectionID = nil
            settings.sceneIDs = playing.isEmpty ? available : playing
        case .collection(let id):
            guard let collection = collections.first(where: { $0.id == id }) else { return }
            settings.collectionID = id
            settings.sceneIDs = collection.sceneIDs
            if settings.mode == .single && collection.sceneIDs.count > 1 { settings.mode = .sequence }
        }
    }

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
        settings.collectionID = nil
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
        settings.collectionID = nil
    }

    /// "Use as Screen Saver" on a collection: the playlist follows it (its scenes, in its order, also
    /// after it changes). The playback settings stay, except that several scenes don't play as "One
    /// scene".
    mutating func follow(_ collection: SceneCollection) {
        settings.collectionID = collection.id
        settings.sceneIDs = collection.sceneIDs
        if settings.mode == .single && collection.sceneIDs.count > 1 { settings.mode = .sequence }
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

    /// "Shuffle · 4 scenes · every 5 minutes" / "Aurora Lake", plus the display mode when it changes
    /// what plays ("… · different on each display"). `displays`: the connected displays (nil =
    /// unknown: the mode is named whenever it applies with two or more).
    /// `collection`: the collection the playlist follows, if any ("“Night Skies” · Shuffle · 4 scenes · …";
    /// an empty one plays every scene). Pass the settings as they play (`following`).
    static func summary(_ s: PlaylistSettings, available: [String], names: [String: String],
                        displays: LPDisplayLayout? = nil, collection: SceneCollection? = nil) -> String {
        let ids = PlaylistDraft(s).effectiveSceneIDs(available: available)
        guard !ids.isEmpty else { return "No scenes yet" }
        let suffix = displaySuffix(s, sceneCount: ids.count, available: available, displays: displays)
        let prefix = collection.map { "\u{201C}\($0.name)\u{201D}" + ($0.sceneIDs.isEmpty ? " is empty" : "") + " \u{00B7} " } ?? ""
        if s.mode == .single || ids.count == 1 { return prefix + (names[ids[0]] ?? ids[0]) + suffix }
        let mode = s.mode == .shuffle ? "Shuffle" : "In order"
        let count = s.sceneIDs.isEmpty ? "all \(ids.count) scenes" : "\(ids.count) scenes"
        let cycle = s.cycleMinutes > 0 ? LPFormat.cycle(minutes: s.cycleMinutes).lowercased() : "one per session"
        return prefix + "\(mode) \u{00B7} \(count) \u{00B7} \(cycle)" + suffix
    }

    /// " · different on each display" and so on, or "" when every display plays the same: "Same";
    /// "Different" and "Span" with one display (they need two, as in the saver); "Different" with one
    /// scene; "Choose" without an assignment that applies to a connected display.
    private static func displaySuffix(_ s: PlaylistSettings, sceneCount: Int, available: [String],
                                      displays: LPDisplayLayout?) -> String {
        switch s.displays.effectiveMode(displayCount: displays?.count ?? 2) {
        case .same:
            return ""
        case .different:
            return sceneCount > 1 ? " \u{00B7} different on each display" : ""
        case .choose:
            var assigned = Set(PlaylistDraft(s).effectiveAssignments(available: available).keys)
            if let displays { assigned.formIntersection(displays.displays.map(\.id)) }
            return assigned.isEmpty ? "" : " \u{00B7} chosen per display"
        case .span:
            return " \u{00B7} spanning all displays"
        }
    }
}

// MARK: - Multiple displays

/// A display with a scene assigned ("Choose per display") that isn't connected right now.
struct RememberedDisplay: Equatable, Sendable, Identifiable {
    /// Display key (`LPDisplay.normalizedID`).
    var id: String
    /// The name it had when its scene was assigned, or a short fallback ("Display 37D8832A").
    var name: String
    var sceneID: String
}

extension PlaylistDraft {
    /// The scene assigned to a display (any letter case); nil = it plays the playlist.
    func assignment(for displayID: String) -> String? {
        settings.displays.assignments[LPDisplay.normalizedID(displayID)]
    }

    /// Assigns a scene to a display (nil: back to the playlist). The display's name is remembered
    /// for while it isn't connected; names are kept only for displays that have an assignment.
    mutating func assign(_ sceneID: String?, to display: LPDisplay) {
        let key = LPDisplay.normalizedID(display.id)
        guard !key.isEmpty else { return }
        let scene = sceneID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if scene.isEmpty {
            settings.displays.assignments[key] = nil
        } else {
            settings.displays.assignments[key] = scene
            let name = display.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { settings.displayNames[key] = name }
        }
        pruneDisplayNames()
    }

    /// Drops a display's assignment and remembered name ("Forget" on a display that isn't connected).
    mutating func forgetDisplay(_ displayID: String) {
        let key = LPDisplay.normalizedID(displayID)
        settings.displays.assignments[key] = nil
        settings.displayNames[key] = nil
        pruneDisplayNames()
    }

    /// Names only for displays with an assignment, keyed like the assignments (normalised).
    private mutating func pruneDisplayNames() {
        let assigned = Set(settings.displays.assignments.keys)
        var names: [String: String] = [:]
        for (key, name) in settings.displayNames.sorted(by: { $0.key < $1.key }) {
            let k = LPDisplay.normalizedID(key)
            if assigned.contains(k), names[k] == nil { names[k] = name }
        }
        if names != settings.displayNames { settings.displayNames = names }
    }

    /// The name to show for a display that may not be connected.
    func displayName(for displayID: String) -> String {
        let key = LPDisplay.normalizedID(displayID)
        if let name = settings.displayNames[key], !name.isEmpty { return name }
        return Self.fallbackDisplayName(key)
    }

    /// "Display 37D8832A" (the start of its UUID); "Display 5" for "DISPLAY-5".
    static func fallbackDisplayName(_ displayID: String) -> String {
        let key = LPDisplay.normalizedID(displayID)
        let prefix = String(LPDisplay.fallbackID(0).dropLast())   // "DISPLAY-"
        if key.hasPrefix(prefix), key.count > prefix.count { return "Display " + key.dropFirst(prefix.count) }
        return "Display " + key.prefix(8)
    }

    /// Displays with an assignment that aren't among `connected`, by name.
    func rememberedDisplays(connected: [LPDisplay]) -> [RememberedDisplay] {
        let here = Set(connected.map { LPDisplay.normalizedID($0.id) })
        return settings.displays.assignments
            .filter { !here.contains($0.key) }
            .map { RememberedDisplay(id: $0.key, name: displayName(for: $0.key), sceneID: $0.value) }
            .sorted { a, b in
                let order = a.name.localizedStandardCompare(b.name)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            }
    }

    /// The assignments the saver gets: in "Choose per display" only, and only for scenes that still
    /// exist (a display whose scene was deleted plays the playlist). Mirrors PublishService.
    func effectiveAssignments(available: [String]) -> [String: String] {
        guard settings.displays.mode == .choose else { return [:] }
        let existing = Set(available)
        return settings.displays.assignments.filter { existing.contains($0.value) }
    }

    /// Which of these scenes stretch across the displays in "Span across displays"
    /// (`SceneManifest.spans`: videos unless they opt out, web scenes that declare `"span": true`);
    /// the others show on every display. Ids without a manifest are left out; the order is kept.
    static func spanSupport(ids: [String], manifests: [String: SceneManifest]) -> (spanning: [String], notSpanning: [String]) {
        var spanning: [String] = [], notSpanning: [String] = []
        for id in ids {
            guard let m = manifests[id] else { continue }
            if m.spans { spanning.append(id) } else { notSpanning.append(id) }
        }
        return (spanning, notSpanning)
    }

    /// "Different on each display" with fewer scenes than displays: some displays share a scene
    /// (display k shows what display k + n shows). nil when every display can differ.
    static func differentNote(sceneCount: Int, displayCount: Int) -> String? {
        guard displayCount >= 2, sceneCount > 0, sceneCount < displayCount else { return nil }
        return sceneCount == 1
            ? "The playlist has one scene, so every display shows it."
            : "The playlist has \(sceneCount) scenes for \(displayCount) displays, so some displays show the same scene."
    }

    /// "3 of 5 scenes can span; the others show on every display." ("" without scenes.)
    static func spanSupportSummary(spanning: Int, total: Int) -> String {
        guard total > 0 else { return "" }
        if spanning >= total { return total == 1 ? "This scene can span." : "All \(total) scenes can span." }
        if spanning <= 0 {
            return total == 1 ? "This scene can\u{2019}t span, so it shows on every display."
                              : "None of these scenes can span, so they show on every display."
        }
        return "\(spanning) of \(total) scenes can span; the others show on every display."
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

extension LPDisplayMode {
    var uiTitle: String {
        switch self {
        case .same: return "Same on every display"
        case .different: return "Different on each display"
        case .choose: return "Choose per display"
        case .span: return "Span across displays"
        }
    }

    var uiExplanation: String {
        switch self {
        case .same: return "Every display shows the same scene."
        case .different: return "Each display shows a different scene from the playlist, when it has enough scenes."
        case .choose: return "Pick a scene for each display. Displays without a choice play the playlist."
        case .span:
            return "One scene stretches across all displays, as they\u{2019}re arranged in System Settings \u{203A} Displays. "
                + "Scenes that can\u{2019}t span show on every display."
        }
    }
}

extension LPBatteryDisplays {
    var uiTitle: String {
        switch self {
        case .live: return "The scene"
        case .still: return "A still picture"
        case .off: return "Nothing (black)"
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
