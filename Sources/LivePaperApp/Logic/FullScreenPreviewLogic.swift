// FullScreenPreviewLogic — the rules of the full-screen preview that don't need AppKit: which scenes
// ← → step through and in what order, what the keys do, when the hint bar and the pointer show,
// which screen the preview covers, the hint text, and the runtime configuration web scenes get (the
// saver's own, from Saver/SaverLogic.swift). Foundation + CoreGraphics only; also compiled into
// LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/ (where SaverLogic.swift is compiled in
// as well).
import CoreGraphics
import Foundation
import LivePaperCore

// MARK: - What it shows

/// Where a full-screen preview was opened, which decides the order ← → step through.
enum FullScreenPreviewSource: Equatable, Sendable {
    /// A library card, the scene detail view or ⇧⌘F on a scene: the library's order.
    case library
    /// The Screen Saver (playlist) screen or the menu bar: the playlist's order.
    case playlist
    /// An AI session's result before it is accepted: the new scene alone, or (modify) the new
    /// version first and the library's current version second, so ← → compare them.
    case candidate
}

/// A scene the preview shows that isn't (yet) in the library: an AI session's result, which lives
/// in the session's workspace until the user accepts it.
struct FullScreenPreviewCandidate: Equatable, Sendable {
    /// The id the sequence uses for it (never a library id, so it can't be confused with one).
    var key: String
    var item: SceneItem
    /// Shown next to the scene's name ("New version", "Not in your library yet").
    var label: String
}

/// The scenes a full-screen preview steps through and the one it shows; ← → wrap around.
struct FullScreenPreviewSequence: Equatable, Sendable {
    let source: FullScreenPreviewSource
    private(set) var ids: [String]
    private(set) var index: Int

    /// nil when there is nothing to show. Repeated ids are dropped (the first one stays); a `start`
    /// that isn't in `ids` starts at the first scene.
    init?(ids: [String], start: String? = nil, source: FullScreenPreviewSource) {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return nil }
        self.source = source
        self.ids = unique
        index = start.flatMap { unique.firstIndex(of: $0) } ?? 0
    }

    var current: String { ids[index] }
    var count: Int { ids.count }
    /// Whether ← → go anywhere.
    var canStep: Bool { ids.count > 1 }
    /// "2 of 5"; nil for a single scene.
    var positionText: String? { canStep ? "\(index + 1) of \(ids.count)" : nil }

    /// Moves by `delta` scenes (−1 previous, +1 next), wrapping around at either end. Returns false
    /// when there is only one scene.
    @discardableResult
    mutating func step(_ delta: Int) -> Bool {
        guard canStep else { return false }
        let n = ids.count
        index = ((index + delta) % n + n) % n
        return true
    }

    /// Drops scenes that no longer exist (deleted while the preview was open). The current scene
    /// stays current when it still exists, otherwise the next remaining one in order (wrapping).
    /// Returns false when nothing is left.
    @discardableResult
    mutating func retain(available: Set<String>) -> Bool {
        guard ids.contains(where: { !available.contains($0) }) else { return true }
        let n = ids.count
        let candidates = (0..<n).map { ids[(index + $0) % n] }
        guard let next = candidates.first(where: available.contains) else { return false }
        ids = ids.filter(available.contains)
        index = ids.firstIndex(of: next) ?? 0
        return true
    }

    /// ← → and a playlist's own scene change, with the library possibly changed under the preview:
    /// drops the scenes that are gone (`retain`), then moves by `delta`. When the scene on screen is
    /// one of them, `retain` has already moved on to the next remaining scene, and that counts as
    /// the first step forward: → shows the scene after the deleted one (not the one after that), ←
    /// the one before it, and either shows the last scene left. Returns false when nothing is left.
    @discardableResult
    mutating func advance(_ delta: Int, available: Set<String>) -> Bool {
        let shown = current
        guard retain(available: available) else { return false }
        step(current == shown ? delta : (delta > 0 ? delta - 1 : delta))
        return true
    }

    /// The library's order as its grid shows it (search and kind filter applied, the user's scenes
    /// before the built-in ones). A scene the grid doesn't show (a filter hides it) steps through the
    /// whole library instead, so ← → never jump to an unrelated subset.
    static func libraryOrder(visible: [String], all: [String], start: String) -> [String] {
        visible.contains(start) ? visible : all
    }
}

/// Everything a full-screen preview needs to start.
struct FullScreenPreviewRequest: Equatable, Sendable {
    var sequence: FullScreenPreviewSequence
    /// The playlist's clock switch (C toggles it for the preview only).
    var showClock: Bool
    /// The playlist's performance profile (fps cap and render scale, like the saver).
    var performance: LPPerformanceProfile
    /// A playlist preview changes scene on the playlist's own cadence ("Change scene"), like the
    /// saver; 0 = only with ← →.
    var cycleMinutes = 0
    /// Scenes from outside the library, by `FullScreenPreviewCandidate.key` (AI results).
    var candidates: [FullScreenPreviewCandidate] = []
    /// Labels for library scenes in the sequence (the current version when comparing), by id.
    var labels: [String: String] = [:]

    /// The candidate a sequence id stands for (nil: a library scene).
    func candidate(for id: String) -> FullScreenPreviewCandidate? { candidates.first { $0.key == id } }

    /// The ids that can be shown: the library's plus the candidates'.
    func available(library: [String]) -> Set<String> { Set(library).union(candidates.map(\.key)) }

    /// The label shown next to the current scene's name, with its position ("New version · 1 of 2").
    func caption(for id: String, in sequence: FullScreenPreviewSequence) -> String? {
        let parts = [candidate(for: id)?.label ?? labels[id], sequence.positionText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// How long a scene stays before the preview moves on by itself (nil: it doesn't).
    var autoAdvanceInterval: TimeInterval? {
        guard sequence.source == .playlist, sequence.canStep, cycleMinutes > 0 else { return nil }
        return TimeInterval(cycleMinutes) * 60
    }

    /// One library scene, stepping through the library order, with the saved playlist's clock and
    /// performance settings (what the saver would use for it). nil when `start` isn't in the
    /// library (any more, or not yet): the preview never opens on some other scene instead.
    static func library(start: String, visible: [String], all: [String], playlist: PlaylistSettings) -> FullScreenPreviewRequest? {
        guard all.contains(start) else { return nil }
        let ids = FullScreenPreviewSequence.libraryOrder(visible: visible, all: all, start: start)
        guard let sequence = FullScreenPreviewSequence(ids: ids, start: start, source: .library) else { return nil }
        return FullScreenPreviewRequest(sequence: sequence, showClock: playlist.showClock, performance: playlist.performance)
    }

    /// The scenes a playlist plays, in its order (PlaylistDraft.effectiveSceneIDs: one scene for
    /// "One scene", every available scene for "all"), with its clock and performance settings.
    static func playlist(_ settings: PlaylistSettings, available: [String], start: String? = nil) -> FullScreenPreviewRequest? {
        let ids = PlaylistDraft(settings).effectiveSceneIDs(available: available)
        guard let sequence = FullScreenPreviewSequence(ids: ids, start: start, source: .playlist) else { return nil }
        return FullScreenPreviewRequest(sequence: sequence, showClock: settings.showClock, performance: settings.performance,
                                        cycleMinutes: settings.mode == .single ? 0 : settings.cycleMinutes)
    }

    /// An AI session's result before it is accepted, with the saved playlist's clock and performance
    /// settings. Modifying a scene that is still in the library adds its current version, so ← →
    /// compare the two (the new one shows first).
    static func candidate(_ item: SceneItem, session: String, replacing current: String?, available: [String],
                          playlist: PlaylistSettings) -> FullScreenPreviewRequest? {
        let key = candidateKey(session: session)
        let compare = current.flatMap { available.contains($0) ? $0 : nil }
        let label = compare == nil ? "Not in your library yet" : "New version"
        guard let sequence = FullScreenPreviewSequence(ids: [key] + (compare.map { [$0] } ?? []), start: key, source: .candidate)
        else { return nil }
        return FullScreenPreviewRequest(sequence: sequence, showClock: playlist.showClock, performance: playlist.performance,
                                        candidates: [FullScreenPreviewCandidate(key: key, item: item, label: label)],
                                        labels: compare.map { [$0: "Current version"] } ?? [:])
    }

    /// What an AI session's result panel previews: once the result is accepted and in the library,
    /// that library scene (it previews like one). Otherwise the result itself from the session's
    /// workspace, which accepting copies rather than moves — also right after "Add to Library",
    /// before the library has reloaded, and after the accepted scene was deleted again.
    static func aiResult(_ item: SceneItem, session: String, accepted: String?, replacing current: String?,
                         visible: [String], available: [String], playlist: PlaylistSettings) -> FullScreenPreviewRequest? {
        if let accepted, available.contains(accepted) {
            return library(start: accepted, visible: visible, all: available, playlist: playlist)
        }
        return candidate(item, session: session, replacing: current, available: available, playlist: playlist)
    }

    /// The sequence id of a session's candidate. Scene ids are slugs (letters, digits, dashes), so
    /// one with a colon can't collide with a library scene.
    static func candidateKey(session: String) -> String { "ai-candidate:" + session }
}

// MARK: - Hint bar and pointer

/// Something that appears on activity and disappears after `timeout` seconds without any — the hint
/// bar (3 s) and the pointer (2 s). It needs at most one pending one-shot timer: activity while a
/// timer is pending only moves the deadline, and a timer that fires before the (moved) deadline is
/// re-armed for the rest. So moving the mouse never creates timers, and nothing is scheduled once
/// it has hidden.
struct IdleVisibility: Equatable, Sendable {
    let timeout: TimeInterval
    private(set) var isVisible = false
    private(set) var lastActivity: Date?
    /// When the pending timer fires (nil: none pending).
    private(set) var timerDate: Date?

    /// Timers may fire a hair early; within this they count as on time.
    static let tolerance: TimeInterval = 0.02

    init(timeout: TimeInterval) { self.timeout = timeout }

    /// What the owner must do after an event.
    struct Update: Equatable {
        /// The new visibility, when it changed.
        var visible: Bool?
        /// Arm a one-shot timer for this moment.
        var armTimer: Date?
    }

    /// The preview opened, the pointer moved or a key was pressed.
    mutating func noteActivity(at now: Date) -> Update {
        lastActivity = now
        var update = Update()
        if !isVisible {
            isVisible = true
            update.visible = true
        }
        if timerDate == nil {
            timerDate = now.addingTimeInterval(timeout)
            update.armTimer = timerDate
        }
        return update
    }

    /// The pending timer fired.
    mutating func timerFired(at now: Date) -> Update {
        guard timerDate != nil else { return Update() }   // stale (reset or already handled)
        timerDate = nil
        guard isVisible, let last = lastActivity else { return Update() }
        let deadline = last.addingTimeInterval(timeout)
        if now.timeIntervalSince(deadline) >= -Self.tolerance {
            isVisible = false
            return Update(visible: false)
        }
        timerDate = deadline
        return Update(armTimer: deadline)
    }

    /// Hidden, no timer (the preview closed).
    mutating func reset() {
        isVisible = false
        lastActivity = nil
        timerDate = nil
    }
}

/// The hint bar's contents: "← → scenes · C clock · L lock-screen preview · Esc close".
enum FullScreenHint {
    struct Item: Equatable, Sendable, Identifiable {
        /// The key caps, e.g. ["←", "→"].
        var keys: [String]
        var label: String
        /// A toggle that is on (drawn highlighted).
        var isActive = false
        var id: String { keys.joined() }
    }

    /// ← → only when there is somewhere to go ("compare" when they switch between an AI result and
    /// the current version); C and L name their state once changed.
    static func items(canStep: Bool, clockOn: Bool, lockPreview: Bool, source: FullScreenPreviewSource = .library) -> [Item] {
        var items: [Item] = []
        if canStep { items.append(Item(keys: ["\u{2190}", "\u{2192}"], label: source == .candidate ? "compare" : "scenes")) }
        items.append(Item(keys: ["C"], label: clockOn ? "clock" : "clock off"))
        items.append(Item(keys: ["L"], label: lockPreview ? "lock-screen preview on" : "lock-screen preview", isActive: lockPreview))
        items.append(Item(keys: ["Esc"], label: "close"))
        return items
    }

    /// The same as one line of text (accessibility, tests).
    static func text(_ items: [Item]) -> String {
        items.map { $0.keys.joined(separator: " ") + " " + $0.label }.joined(separator: " \u{00B7} ")
    }
}

// MARK: - Keys

/// A key-down as the preview sees it (the parts of an NSEvent its rules look at).
struct FullScreenKeyPress: Equatable, Sendable {
    var keyCode: UInt16
    /// `charactersIgnoringModifiers`, lowercased.
    var key = ""
    var command = false
    var shift = false
    var control = false
    var option = false
    /// An auto-repeat of a key that is being held.
    var isRepeat = false
}

/// What a key does in the preview.
enum FullScreenKeyAction: Equatable, Sendable {
    case close
    case step(Int)
    case toggleClock
    case toggleLockUI
    /// The preview's key, but nothing to do (a held key repeating; ⌘ shortcuts that would otherwise
    /// act on the window behind the preview).
    case swallow
    /// Not the preview's: plain keys are dropped quietly, ⌘ shortcuts go on to the menu.
    case pass
}

/// The preview's keys. Every key acts once per press: the repeats of a held key are swallowed, so
/// holding the Space that opened the preview doesn't close it, and holding C or L doesn't flicker
/// the clock (each flip re-lays out a web scene).
enum FullScreenKeys {
    static let escape: UInt16 = 53, space: UInt16 = 49, left: UInt16 = 123, right: UInt16 = 124

    /// Plain keys: Esc and Space (as in Quick Look) close, ← → step, C and L toggle (also with ⇧).
    static func keyDown(_ press: FullScreenKeyPress) -> FullScreenKeyAction {
        let action: FullScreenKeyAction
        switch press.keyCode {
        case escape, space: action = .close
        case left: action = .step(-1)
        case right: action = .step(1)
        default:
            guard !press.command, !press.control, !press.option else { return .pass }
            switch press.key {
            case "c": action = .toggleClock
            case "l": action = .toggleLockUI
            default: return .pass
            }
        }
        return press.isRepeat ? .swallow : action
    }

    /// ⌘ shortcuts: ⌘. and ⌘W close (so does ⇧⌘F, which opened it); Quit and Hide go on to the
    /// menu; every other one is swallowed so nothing acts on the window behind the preview.
    static func keyEquivalent(_ press: FullScreenKeyPress) -> FullScreenKeyAction {
        guard press.command else { return .pass }
        switch (press.shift, press.control, press.option, press.key) {
        case (false, false, false, "."), (false, false, false, "w"), (true, false, false, "f"):
            return press.isRepeat ? .swallow : .close
        case (false, false, false, "q"), (false, false, false, "h"), (false, false, true, "h"):
            return .pass
        default:
            return .swallow
        }
    }
}

/// The rest of the key press that closed the preview. The preview acts on key-down, so a key held a
/// moment longer goes on repeating after the preview has gone, into whatever has the keyboard next:
/// a library card's Space or the menu's ⇧⌘F would open the preview again, and the app the preview
/// gives focus back to would type the repeats. So the key's repeats are dropped until it is
/// released, and focus goes back only then.
struct FullScreenClosingKey: Equatable, Sendable {
    let keyCode: UInt16

    enum Verdict: Equatable, Sendable {
        /// A repeat of the closing key: dropped.
        case drop
        /// Delivered as usual.
        case deliver
        /// The press is over — its key-up, or another key pressed (which ends the repeating; also
        /// when the key-up went elsewhere): delivered, and the wait ends.
        case released
    }

    func verdict(keyUp: Bool, keyCode: UInt16, isRepeat: Bool) -> Verdict {
        if keyUp { return keyCode == self.keyCode ? .released : .deliver }
        guard isRepeat else { return .released }
        return keyCode == self.keyCode ? .drop : .deliver
    }
}

// MARK: - Which screen

/// Where the request came from, for choosing the screen.
enum FullScreenPreviewOrigin: Equatable, Sendable {
    /// The main window (its frame in screen coordinates, when known): the screen it is on.
    case window(CGRect?)
    /// The menu-bar extra: the screen under the pointer.
    case pointer
}

enum FullScreenScreenChoice {
    /// The index into `screens` (AppKit frames, bottom-left origin; the first is the primary screen)
    /// of the screen to cover, nil without screens. A window counts as on the screen it overlaps
    /// most (what AppKit reports as its screen); otherwise, and for the menu bar, it is the screen
    /// under the pointer, else the one nearest to it, else the primary screen.
    static func index(screens: [CGRect], origin: FullScreenPreviewOrigin, pointer: CGPoint) -> Int? {
        guard !screens.isEmpty else { return nil }
        if case .window(let frame?) = origin {
            var best: (index: Int, area: CGFloat)?
            for (i, screen) in screens.enumerated() {
                let overlap = screen.intersection(frame)
                guard !overlap.isNull, !overlap.isEmpty else { continue }
                let area = overlap.width * overlap.height
                if area > (best?.area ?? 0) { best = (i, area) }
            }
            if let best { return best.index }
        }
        return screenIndex(containing: pointer, in: screens) ?? 0
    }

    /// The screen under `p`. Screen frames are half-open like NSMouseInRect, so a point on the edge
    /// between two screens belongs to one of them; the top edge (where the pointer sits when it is
    /// pushed against the menu bar) still counts. Off every screen: the nearest one.
    static func screenIndex(containing p: CGPoint, in screens: [CGRect]) -> Int? {
        if let i = screens.firstIndex(where: { p.x >= $0.minX && p.x < $0.maxX && p.y >= $0.minY && p.y < $0.maxY }) { return i }
        if let i = screens.firstIndex(where: { p.x >= $0.minX && p.x <= $0.maxX && p.y >= $0.minY && p.y <= $0.maxY }) { return i }
        func distance(_ r: CGRect) -> CGFloat {
            let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
            return dx * dx + dy * dy
        }
        return screens.indices.min { distance(screens[$0]) < distance(screens[$1]) }
    }
}

// MARK: - Rendering like the saver

/// How a web scene is configured, built the way the saver builds it (SaverWebConfig,
/// SaverPerformance, SaverJS in Saver/SaverLogic.swift) so the preview matches the lock screen.
enum FullScreenSceneConfig {
    /// The document-start script defining `window.LIVEPAPER_CONFIG`: the saver's (playlist clock,
    /// the scene's clock position, fps and render scale for the profile and power state, the seed,
    /// power) plus the lock-UI state, exactly as WebSceneHost injects it.
    static func webConfigScript(showClock: Bool, clockPosition: LPClockPosition, performance: LPPerformanceProfile,
                                power: SaverPowerState, seed: Int, lockUI: Bool) -> String {
        let profile = SaverPerformance.resolve(performance, power: power, preview: false)
        let config = SaverWebConfig(showClock: showClock, clockPosition: clockPosition, profile: profile, seed: seed, power: power)
        return config.userScript + "window.LIVEPAPER_CONFIG.lockUI = \(lockUI);"
    }

    /// Brings a running page to the preview's whole state: the clock and lock-UI state (C and L)
    /// and the power state with the profile's fps and render scale for it (AC ⇄ battery and Low
    /// Power Mode changes, which the saver follows with the same `LivePaper.host.power` call). Like
    /// every saver host call it is a no-op until the runtime exists; the host re-applies it on
    /// `ready`, replacing any earlier one — hence always the whole state.
    static func stateScript(showClock: Bool, lockUI: Bool, performance: LPPerformanceProfile, power: SaverPowerState) -> String {
        let profile = SaverPerformance.resolve(performance, power: power, preview: false)
        return SaverJS.hostCall("config", "{\"clock\":\(showClock)}") + SaverJS.lockUI(lockUI)
            + SaverJS.power(SaverPowerUpdate(power: power, profile: profile))
    }

    /// Whether a native (video) clock shows: the clock is on and the (simulated) lock UI isn't up.
    static func nativeClockVisible(showClock: Bool, lockUI: Bool) -> Bool { showClock && !lockUI }

    /// The file a video scene plays, checked the way publishing checks it (scene.json is untrusted
    /// input), so the preview never plays a video the saver wouldn't get: a plain file name inside
    /// the package (LibraryService.isPlainFileName — no path, not hidden), a regular file (not a
    /// symlink), in a format the saver plays (no extension counts as .mov, as publishing does).
    /// nil: the saver won't show the scene; publishing leaves it out and says why.
    static func videoFile(_ name: String?, in package: URL, isRegularFile: (URL) -> Bool = isRegularFile) -> URL? {
        guard let name, !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        let url = package.appendingPathComponent(name)
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        guard LPPlaylistEntry.videoExtensions.contains(ext), isRegularFile(url) else { return nil }
        return url
    }

    /// A regular file itself, not a symlink to one (URL resource values don't follow the last link).
    static func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    /// A fresh scene seed, in the saver's range (1…100 000), as a new saver session would pick.
    static func randomSeed() -> Int { Int.random(in: 1...100_000) }
}
