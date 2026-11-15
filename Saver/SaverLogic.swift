// SaverLogic — the pure, Foundation-only decision logic of LivePaper.saver.
//
// Everything that can be decided without AppKit lives here so it can be unit tested:
// playlist validation, scene selection (shuffle / sequence / single with no-repeat across sessions
// and agreement across displays), the cycle schedule, failure back-off, the prewarm run gate,
// lock-UI state, clock layout and formatting, the web scene bridge, and the Options sheet summary.
//
// This file is compiled twice:
//   * into the saver bundle by scripts/build-saver.sh (same module as PlaylistModel.swift), and
//   * into the LivePaperSelfTest target through the symlink Sources/LivePaperSelfTest/SaverLogic.swift
//     (there LPPlaylist & co. come from LivePaperCore, hence the conditional import below).
// Keep it free of AppKit/WebKit/ScreenSaver, global mutable state and side effects other than the
// explicit file store.
import Foundation
#if canImport(LivePaperCore)
import LivePaperCore
#endif

// MARK: - Playlist content

/// The published playlist as the saver will play it: only entries whose files exist and are safe.
struct SaverContent: Equatable {
    /// The decoded playlist, or nil when it is missing or unreadable.
    var playlist: LPPlaylist?
    /// Playable entries, in playlist order, unique by id.
    var entries: [LPPlaylistEntry]
    /// Human-readable reasons for everything that was skipped (logged by the saver).
    var problems: [String]
    /// The Playlist directory inside the bundle.
    var directory: URL

    var isEmpty: Bool { entries.isEmpty }

    func fileURL(for entry: LPPlaylistEntry) -> URL { directory.appendingPathComponent(entry.file) }

    static func empty(directory: URL, problem: String? = nil) -> SaverContent {
        SaverContent(playlist: nil, entries: [], problems: problem.map { [$0] } ?? [], directory: directory)
    }
}

enum SaverPlaylistLoader {
    static let webExtensions: Set<String> = ["html", "htm"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// Reads `<directory>/playlist.json` and keeps the entries that can actually be played.
    /// Never throws: a missing or broken playlist yields empty content (the saver shows its fallback).
    static func load(from directory: URL,
                     fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> SaverContent {
        let file = directory.appendingPathComponent(LPPlaylist.fileName)
        guard fileExists(file.path) else { return .empty(directory: directory, problem: "no \(LPPlaylist.fileName) published") }
        let playlist: LPPlaylist
        do {
            playlist = try LPPlaylist.load(from: directory)
        } catch {
            return .empty(directory: directory, problem: "\(LPPlaylist.fileName) is unreadable: \(error)")
        }
        var (entries, problems) = playable(playlist, in: directory, fileExists: fileExists)
        if playlist.schema > LPPlaylist.currentSchema {
            problems.insert("playlist schema \(playlist.schema) is newer than this saver (\(LPPlaylist.currentSchema)); playing what it understands", at: 0)
        }
        return SaverContent(playlist: playlist, entries: entries, problems: problems, directory: directory)
    }

    /// Filters a playlist down to entries that are safe and present on disk.
    static func playable(_ playlist: LPPlaylist, in directory: URL,
                         fileExists: (String) -> Bool) -> (entries: [LPPlaylistEntry], problems: [String]) {
        var seen = Set<String>(), entries: [LPPlaylistEntry] = [], problems: [String] = []
        for entry in playlist.scenes {
            guard !entry.id.isEmpty, !seen.contains(entry.id) else {
                problems.append("skipped duplicate or empty scene id '\(entry.id)'"); continue
            }
            guard isPlainFileName(entry.file) else {
                problems.append("\(entry.id): file name '\(entry.file)' must be a plain name inside the Playlist folder"); continue
            }
            let ext = (entry.file as NSString).pathExtension.lowercased()
            let allowed = entry.kind == .web ? webExtensions : videoExtensions
            guard allowed.contains(ext) else {
                problems.append("\(entry.id): '\(entry.file)' is not a supported \(entry.kind.rawValue) file"); continue
            }
            guard fileExists(directory.appendingPathComponent(entry.file).path) else {
                problems.append("\(entry.id): '\(entry.file)' is missing"); continue
            }
            seen.insert(entry.id)
            entries.append(entry)
        }
        return (entries, problems)
    }

    /// A single path component that stays inside the Playlist directory (no separators, no `..`,
    /// not hidden). The saver only ever reads files from its own bundle.
    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".") && !name.contains("\0")
    }
}

// MARK: - Sessions (no-repeat across sessions, agreement across displays)

/// What the saver remembers between runs (ScreenSaverDefaults in the real host).
struct SaverSessionRecord: Codable, Equatable {
    /// The 30 s epoch the session started in; doubles as the shuffle seed.
    var epoch: Int
    /// Session start (seconds since 1970), aligned to the epoch start.
    var startedAt: TimeInterval
    /// Scene the session avoids starting with (the one shown last in the previous session).
    var avoid: String?
    /// Scene on screen most recently (the next session avoids it).
    var lastShown: String?
    /// Scenes shown recently, most recent first (shuffle avoids starting a session with any of the
    /// newest half of the deck). Optional for records written by older builds.
    var recent: [String]? = nil
    /// When the session ended (willstop). Only a session that is still running can be joined, so a
    /// quick unlock → lock starts a NEW session instead of replaying the previous one.
    var endedAt: TimeInterval? = nil

    static let recentCapacity = 12

    /// Records `id` as on screen now.
    mutating func noteShown(_ id: String) {
        lastShown = id
        var list = (recent ?? []).filter { $0 != id }
        list.insert(id, at: 0)
        recent = Array(list.prefix(Self.recentCapacity))
    }
}

/// One screen-saver session as seen by every display that starts within it.
struct SaverSession: Equatable {
    var epoch: Int
    var startedAt: Date
    var avoid: String?
    /// Recently shown scenes, most recent first (see `SaverDeck.recent`).
    var recent: [String] = []

    /// Seed for the scene shuffle (identical on every display of the session).
    var shuffleSeed: UInt64 { UInt64(bitPattern: Int64(epoch)) }
    /// Seed handed to web scenes so every display renders the same variation.
    var sceneSeed: Int { (epoch % 100_000 + 100_000) % 100_000 + 1 }
}

enum SaverSessionPlanner {
    /// Length of the epoch every display starting at about the same time agrees on.
    static let epochLength: TimeInterval = 30
    /// A display starting this long after a session began still joins it (one epoch plus grace,
    /// so displays straddling an epoch boundary agree too).
    static let joinWindow: TimeInterval = 45

    /// Decides which session a starting display belongs to.
    /// - Returns: the session, the record to persist (non-preview instances only), and whether an
    ///   existing session was joined.
    static func plan(now: Date, stored: SaverSessionRecord?) -> (session: SaverSession, record: SaverSessionRecord, joined: Bool) {
        let t = now.timeIntervalSince1970
        // Join only a session that is still running (another display started it a moment ago). A
        // session that already ended — the user unlocked and locked again quickly — must not be
        // replayed: that showed the same scene lock after lock.
        if let stored, stored.endedAt == nil, t - stored.startedAt >= -epochLength, t - stored.startedAt < joinWindow {
            return (SaverSession(epoch: stored.epoch, startedAt: Date(timeIntervalSince1970: stored.startedAt), avoid: stored.avoid,
                                 recent: stored.recent ?? []), stored, true)
        }
        var epoch = Int((t / epochLength).rounded(.down))
        // A new session in the same 30 s epoch as an ended one still needs a different shuffle.
        if let stored, epoch <= stored.epoch { epoch = stored.epoch + 1 }
        let start = t >= TimeInterval(epoch) * epochLength ? TimeInterval(epoch) * epochLength : t
        let recent = stored?.recent ?? (stored?.lastShown.map { [$0] } ?? [])
        let record = SaverSessionRecord(epoch: epoch, startedAt: start, avoid: stored?.lastShown, lastShown: nil,
                                        recent: recent, endedAt: nil)
        return (SaverSession(epoch: epoch, startedAt: Date(timeIntervalSince1970: start), avoid: record.avoid, recent: recent),
                record, false)
    }
}

/// Persistence for `SaverSessionRecord`.
protocol SaverSessionStore: AnyObject {
    func load() -> SaverSessionRecord?
    func save(_ record: SaverSessionRecord)
}

/// JSON file store (dev/test hosts point LIVEPAPER_SAVER_STATE_FILE at a temp file).
final class SaverFileSessionStore: SaverSessionStore {
    let url: URL
    init(url: URL) { self.url = url }
    func load() -> SaverSessionRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SaverSessionRecord.self, from: data)
    }
    func save(_ record: SaverSessionRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Non-persistent store, used when no preferences are available.
final class SaverMemorySessionStore: SaverSessionStore {
    private var record: SaverSessionRecord?
    func load() -> SaverSessionRecord? { record }
    func save(_ record: SaverSessionRecord) { self.record = record }
}

// MARK: - Scene order

/// SplitMix64: tiny, fast, and identical on every architecture (the deck must match across displays).
struct SaverRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform-enough integer in 0..<n (modulo bias is irrelevant for playlist sizes).
    mutating func next(below n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
}

/// The order scenes play in. Deterministic for a given (ids, mode, seed, avoid), so every display of
/// a session computes the same scene for the same step without talking to each other.
struct SaverDeck: Equatable {
    let ids: [String]
    let mode: LPPlaylistMode
    let seed: UInt64
    /// Scene to avoid at step 0 (shown last in the previous session).
    let avoid: String?
    /// Recently shown scenes, most recent first. Shuffle never starts a session with one of the
    /// newest ⌊n/2⌋ of them, so locking repeatedly walks through the deck instead of repeating.
    var recent: [String] = []

    init(ids: [String], mode: LPPlaylistMode, seed: UInt64, avoid: String?, recent: [String] = []) {
        self.ids = ids; self.mode = mode; self.seed = seed; self.avoid = avoid; self.recent = recent
    }

    /// The ids the first scene of a session must not be (empty for one-scene decks).
    var startAvoidSet: Set<String> {
        guard ids.count > 1 else { return [] }
        var list = recent
        if let avoid, !list.contains(avoid) { list.insert(avoid, at: 0) }
        return Set(list.filter { ids.contains($0) }.prefix(max(1, ids.count / 2)))
    }

    var count: Int { ids.count }

    /// Index into `ids` of the scene for a cycle step (0 = first scene of the session).
    func entryIndex(atStep step: Int) -> Int {
        let n = ids.count, s = max(0, step)
        guard n > 1 else { return 0 }
        switch mode {
        case .single:
            return 0
        case .sequence:
            // Continue where the previous session left off.
            let start = avoid.flatMap { ids.firstIndex(of: $0) }.map { ($0 + 1) % n } ?? 0
            return (start + s) % n
        case .shuffle:
            return shuffledRound(s / n)[s % n]
        }
    }

    /// The permutation for one pass through the deck. Each pass is reshuffled; its first scene never
    /// repeats the scene just before it (the previous pass's last, or `avoid` for the first pass).
    func shuffledRound(_ round: Int) -> [Int] {
        let n = ids.count
        guard n > 1 else { return Array(0..<n) }
        var previous = avoid.flatMap { ids.firstIndex(of: $0) }
        var order: [Int] = []
        for r in 0...max(0, round) {
            var rng = SaverRandom(seed: seed &+ UInt64(r) &* 0xD1B5_4A32_D192_ED03)
            order = Array(0..<n)
            for i in stride(from: n - 1, to: 0, by: -1) { order.swapAt(i, rng.next(below: i + 1)) }
            if r == 0 {
                let avoidSet = startAvoidSet
                if let k = order.firstIndex(where: { !avoidSet.contains(ids[$0]) }), k > 0 { order.swapAt(0, k) }
            } else if let previous, order[0] == previous {
                order.swapAt(0, 1)
            }
            previous = order[n - 1]
        }
        return order
    }
}

/// When scenes change. Steps are derived from wall-clock time since the session start, so every
/// display switches at the same moment and a view that slept catches up to the right scene.
struct SaverSchedule: Equatable {
    let startedAt: Date
    /// Seconds per scene; nil = never change while running.
    let cycle: TimeInterval?

    init(startedAt: Date, cycleMinutes: Int, deckCount: Int, mode: LPPlaylistMode, cycles: Bool) {
        self.startedAt = startedAt
        let changes = cycles && cycleMinutes > 0 && deckCount > 1 && mode != .single
        cycle = changes ? TimeInterval(cycleMinutes) * 60 : nil
    }

    func step(at date: Date) -> Int {
        guard let cycle else { return 0 }
        return max(0, Int((date.timeIntervalSince(startedAt) / cycle).rounded(.down)))
    }

    /// The next moment the scene changes after `date`, or nil if it never does.
    func nextChange(after date: Date) -> Date? {
        guard let cycle else { return nil }
        return startedAt.addingTimeInterval(TimeInterval(step(at: date) + 1) * cycle)
    }
}

// MARK: - Failure recovery

enum SaverRecoveryDecision: Equatable {
    /// Reload after `delay` seconds, moving on to the next scene when `skipScene` is set.
    case retry(after: TimeInterval, skipScene: Bool)
    /// Too many failures: show the static fallback instead of crash-looping all night.
    case giveUp
}

/// Back-off for scene failures (web content crashes, failed loads, undecodable videos).
struct SaverRecoveryPolicy: Equatable {
    static let window: TimeInterval = 120
    static let skipAfter = 2
    static let giveUpAfter = 4

    private(set) var failures: [Date] = []

    mutating func recordFailure(at now: Date) -> SaverRecoveryDecision {
        failures = failures.filter { now.timeIntervalSince($0) < Self.window } + [now]
        let n = failures.count
        if n >= Self.giveUpAfter { return .giveUp }
        return .retry(after: pow(2, Double(n - 1)), skipScene: n >= Self.skipAfter)
    }

    mutating func reset() { failures = [] }
}

// MARK: - System events and lock-UI hand-off

/// Everything the saver reacts to, decoupled from where it came from (distributed notifications,
/// NSWorkspace, the view's own window, or the in-process test hook).
enum SaverSystemEvent: String {
    /// loginwindow drew its lock UI (clock + password field) over the running saver.
    case lockUIShown
    /// …and removed it again.
    case lockUIHidden
    case screenLocked, screenUnlocked, willStop, screensDidSleep, screensDidWake, published
    /// loginwindow started / stopped a screen saver run (com.apple.screensaver.didstart / didstop).
    case saverDidStart, saverDidStop
    /// ScreenSaverEngine (what LivePaper's lock and `open -a ScreenSaverEngine` launch) started / quit.
    case engineLaunched, engineTerminated
    /// The app that shows previews (System Settings) became / stopped being the frontmost app.
    case previewHostActivated, previewHostDeactivated
    /// The view's window was ordered in/out, (de)miniaturised, closed or changed occlusion/screen.
    case windowChanged

    /// Names of NSWorkspace's display-sleep notifications (`NSWorkspace.screensDid…Notification.rawValue`).
    static let screensDidSleepName = "NSWorkspaceScreensDidSleepNotification"
    static let screensDidWakeName = "NSWorkspaceScreensDidWakeNotification"
    /// Names the saver's notification relay gives to NSWorkspace app notifications it has already
    /// filtered (the plain NSWorkspace names say nothing about which app). Also used by the dev host.
    static let engineLaunchedName = "LivePaperScreenSaverEngineLaunched"
    static let engineTerminatedName = "LivePaperScreenSaverEngineTerminated"
    static let previewHostActivatedName = "LivePaperPreviewHostActivated"
    static let previewHostDeactivatedName = "LivePaperPreviewHostDeactivated"
    static let windowChangedName = "LivePaperWindowChanged"

    init?(notificationName name: String) {
        // `lockUIShowing` is an alias of `lockUIShown` on current macOS; both mean "hide our clock".
        if name == LPNotification.lockUIShowing || name == LPNotification.lockUIShown { self = .lockUIShown; return }
        switch name {
        case LPNotification.lockUIHidden: self = .lockUIHidden
        case LPNotification.screenLocked: self = .screenLocked
        case LPNotification.screenUnlocked: self = .screenUnlocked
        case LPNotification.saverWillStop: self = .willStop
        case LPNotification.saverDidStart: self = .saverDidStart
        case LPNotification.saverDidStop: self = .saverDidStop
        case LPNotification.published: self = .published
        case Self.screensDidSleepName: self = .screensDidSleep
        case Self.screensDidWakeName: self = .screensDidWake
        case Self.engineLaunchedName: self = .engineLaunched
        case Self.engineTerminatedName: self = .engineTerminated
        case Self.previewHostActivatedName: self = .previewHostActivated
        case Self.previewHostDeactivatedName: self = .previewHostDeactivated
        case Self.windowChangedName: self = .windowChanged
        default: return nil
        }
    }

    /// The distributed notifications the saver subscribes to (each name once).
    static let distributedNames: [String] = {
        let all = [LPNotification.lockUIShowing, LPNotification.lockUIShown, LPNotification.lockUIHidden,
                   LPNotification.screenLocked, LPNotification.screenUnlocked, LPNotification.saverWillStop,
                   LPNotification.saverDidStart, LPNotification.saverDidStop, LPNotification.published]
        var seen = Set<String>()
        return all.filter { seen.insert($0).inserted }
    }()
}

/// Whether macOS is drawing its lock UI (with its own clock) over the running saver.
struct SaverLockUIState: Equatable {
    private(set) var isShowing = false

    /// Applies an event; returns true when `isShowing` changed.
    @discardableResult
    mutating func apply(_ event: SaverSystemEvent) -> Bool {
        let old = isShowing
        switch event {
        case .lockUIShown: isShowing = true
        // Unlocking removes the lock UI even if its IsHidden notification was missed.
        case .lockUIHidden, .screenUnlocked: isShowing = false
        default: break
        }
        return old != isShowing
    }
}

// MARK: - Run gate (prewarm)

/// Which signals open the run gate of a real (non-preview) instance — the one place to change once
/// real lock cycles have been logged (category `lifecycle`, see Saver/README.md "Run gate"). The
/// self tests say what each switch does.
struct SaverGatePolicy: Equatable {
    /// A locked session opens the gate. Kept on while it is unverified that didstart reaches the
    /// sandboxed host: without it, every lock would stay black if it doesn't. The cost: a prewarmed
    /// instance that has had startAnimation also renders behind a direct lock (⌃⌘Q without the lock
    /// keys switch, lid close, display sleep) while the displays are on, until unlock. Turn it off
    /// once the logs show didstart arriving for idle, hot-corner, lock-key and LivePaper starts.
    var sessionLockOpens = true
    /// loginwindow's com.apple.screensaver.didstart opens the gate — also while the session is
    /// unlocked (a password delay, "Never", a hot corner), where the saver used to stay black.
    var didStartOpens = true
    /// A running ScreenSaverEngine opens the gate: it only runs while a saver it started is up (it
    /// quits on didstop). Covers LivePaper's own lock if didstart were not delivered.
    var engineOpens = true
    /// Frame-rate cap for web scenes in previews (System Settings).
    var previewFPS = 15

    static let standard = SaverGatePolicy()
}

/// Decides when the saver may load and animate scenes.
///
/// After every unlock WallpaperAgent spawns a hidden, never-presented saver instance so that the
/// next start is fast. Web scenes run with WebKit's occlusion detection disabled (they would never
/// draw otherwise, see WebSceneHost), so that hidden copy would animate for as long as the user
/// works — measured at ~45 % of a CPU core in the prototype. So a real (non-preview) instance runs
/// only while all of these hold:
///  * startAnimation has been called and stopAnimation hasn't (and willstop hasn't arrived);
///  * something says a saver is actually up (`SaverGatePolicy`): the session is locked, or
///    loginwindow posted didstart (cleared by didstop, willstop and unlock), or ScreenSaverEngine
///    runs;
///  * the displays are awake.
/// Nothing is loaded before that (also not while the displays sleep), and a loaded instance whose
/// gate closes for good (unlock, stopAnimation) releases its scenes (`shouldRelease`).
/// Previews (System Settings) run while started, unless the session is locked, the displays sleep,
/// their window can't be seen or System Settings isn't the frontmost app.
struct SaverRunGate: Equatable {
    /// System Settings preview or another small host (`isPreview || width < 500`).
    var preview: Bool
    /// The login session is locked: `CGSSessionScreenIsLocked` at start, then
    /// com.apple.screenIsLocked / com.apple.screenIsUnlocked.
    var sessionLocked: Bool
    /// Between startAnimation and stopAnimation.
    var animating = false
    var displaysAsleep = false
    /// com.apple.screensaver.willstop arrived; the host process is about to exit.
    var exiting = false
    /// loginwindow posted didstart and no didstop, willstop or unlock since.
    var saverStarted = false
    /// ScreenSaverEngine is running.
    var engineRunning = false
    /// Previews: the window is ordered in, not miniaturised, and not reported occluded.
    var windowVisible = true
    /// Previews: the app that shows them (System Settings) is frontmost (or that is unknown).
    var previewHostActive = true
    var policy = SaverGatePolicy.standard

    init(preview: Bool, sessionLocked: Bool, policy: SaverGatePolicy = .standard) {
        self.preview = preview
        self.sessionLocked = sessionLocked
        self.policy = policy
    }

    /// What says a saver is up for a real instance (nil: nothing does). For previews: "preview".
    var openedBy: String? {
        if preview { return "preview" }
        if policy.didStartOpens && saverStarted { return "didstart" }
        if policy.engineOpens && engineRunning { return "engine" }
        if policy.sessionLockOpens && sessionLocked { return "locked" }
        return nil
    }

    /// Every condition except display sleep holds.
    var active: Bool {
        guard animating, !exiting else { return false }
        if preview { return !sessionLocked && windowVisible && previewHostActive }
        return openedBy != nil
    }
    /// Loaded scenes may animate or play, and the cycle and clock timers may run.
    var shouldRun: Bool { active && !displaysAsleep }
    /// Scenes may be loaded and session bookkeeping written: only when they would run right away
    /// (never while the displays sleep, or for an instance nothing has presented).
    var mayLoad: Bool { shouldRun }
    /// A loaded real instance whose gate has closed (unlock, didstop, stopAnimation) should free its
    /// scenes — after a grace period, so loginwindow's fade-out still shows the last frame. Previews
    /// and instances that are about to exit keep theirs.
    var shouldRelease: Bool { !preview && !exiting && !active }

    /// Why nothing runs (for the log), or nil when it runs.
    var waitingFor: String? {
        if shouldRun { return nil }
        if exiting { return "exit (willstop)" }
        if !animating { return "startAnimation" }
        if preview {
            if sessionLocked { return "unlock (previews pause while locked)" }
            if !windowVisible { return "the preview window to be visible" }
            if !previewHostActive { return "System Settings to be frontmost" }
        } else if openedBy == nil {
            return "a saver start (didstart, ScreenSaverEngine or a locked session)"
        }
        return "the displays to wake"
    }

    /// One line for the lifecycle log.
    var summary: String {
        func b(_ v: Bool) -> Int { v ? 1 : 0 }
        return "anim=\(b(animating)) locked=\(b(sessionLocked)) didstart=\(b(saverStarted)) engine=\(b(engineRunning)) "
            + "asleep=\(b(displaysAsleep)) exiting=\(b(exiting))"
            + (preview ? " window=\(b(windowVisible)) host=\(b(previewHostActive))" : "")
            + " → \(shouldRun ? "run (\(openedBy ?? "?"))" : "wait for \(waitingFor ?? "?")")"
    }

    /// Applies a system event (lock-UI, publish and window events don't change the gate).
    mutating func apply(_ event: SaverSystemEvent) {
        switch event {
        case .screenLocked: sessionLocked = true
        // A run that was started ends with the unlock, its didstop or willstop.
        case .screenUnlocked: sessionLocked = false; saverStarted = false
        case .saverDidStart: saverStarted = true
        case .saverDidStop, .willStop: saverStarted = false
        case .screensDidSleep: displaysAsleep = true
        case .screensDidWake: displaysAsleep = false
        case .engineLaunched: engineRunning = true
        case .engineTerminated: engineRunning = false
        case .previewHostActivated: previewHostActive = true
        case .previewHostDeactivated: previewHostActive = false
        case .lockUIShown, .lockUIHidden, .published, .windowChanged: break
        }
    }
}

/// "A saver run is in progress", remembered per host process so that an instance created after
/// didstart (WallpaperAgent may add the presented view next to the prewarmed one) still knows.
struct SaverStartLatch: Equatable {
    private(set) var started = false

    mutating func apply(_ event: SaverSystemEvent) {
        switch event {
        case .saverDidStart: started = true
        case .saverDidStop, .willStop, .screenUnlocked: started = false
        default: break
        }
    }
}

/// Whether a preview's window can be seen, from what AppKit reports in the (remote-view) host. Each
/// signal is trusted only once it has said "visible": the macOS 26 saver host reports its window as
/// always occluded, and a host that never reports visibility must not pause previews forever.
/// (Which signals System Settings' preview host reports is unverified; see Saver/README.md.)
struct SaverWindowVisibility: Equatable {
    private(set) var orderedInTrusted = false
    private(set) var occlusionTrusted = false

    mutating func isVisible(orderedIn: Bool, miniaturized: Bool, occlusionVisible: Bool) -> Bool {
        if orderedIn { orderedInTrusted = true }
        if occlusionVisible { occlusionTrusted = true }
        return !miniaturized && (!orderedInTrusted || orderedIn) && (!occlusionTrusted || occlusionVisible)
    }
}

/// The app whose windows show LivePaper's preview instances.
enum SaverPreviewHost {
    static let bundleIdentifiers: Set<String> = ["com.apple.systempreferences"]

    /// Previews run while their host app is frontmost. Unknown (nil) counts as frontmost, so a
    /// preview is never paused on a guess.
    static func isActive(frontmostBundleIdentifier: String?) -> Bool {
        frontmostBundleIdentifier.map(bundleIdentifiers.contains) ?? true
    }
}

// MARK: - Power

struct SaverPowerState: Equatable {
    var onBattery: Bool
    var lowPowerMode: Bool
    var prefersBatterySaver: Bool { onBattery || lowPowerMode }
}

enum SaverPerformance {
    /// Frame rate / render scale for web scenes. Previews (System Settings thumbnails) are tiny, so
    /// they render at full scale but at `SaverGatePolicy.previewFPS` (15 fps).
    static func resolve(_ profile: LPPerformanceProfile, power: SaverPowerState, preview: Bool,
                        policy: SaverGatePolicy = .standard) -> LPPerformanceProfile.Resolved {
        if preview { return .init(fps: policy.previewFPS, scale: 1) }
        return profile.resolved(onBatteryOrLowPower: power.prefersBatterySaver)
    }
}

// MARK: - Web scene bridge

/// Sorted-key JSON for the small objects the saver hands to web scenes.
private func saverJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

/// `window.LIVEPAPER_CONFIG`, injected as a user script before the scene's own code runs. The keys
/// are the runtime's (Runtime/runtime.js `TYPES`); fps/scale are already resolved from the profile.
struct SaverWebConfig: Codable, Equatable {
    /// Playlist-level clock switch (false hides every clock, including scene-drawn ones).
    var clock: Bool
    /// Clock position for this scene (`LPClockPosition` raw value; "none" = scene draws its own).
    var clockPosition: String
    var fps: Int
    var scale: Double
    /// Identical on every display of a session, so they all render the same variation.
    var seed: Int
    /// "ac" | "battery" (becomes `lp.env.power`).
    var power: String
    var lowPower: Bool

    init(showClock: Bool, clockPosition: LPClockPosition, profile: LPPerformanceProfile.Resolved, seed: Int, power: SaverPowerState) {
        clock = showClock
        self.clockPosition = clockPosition.rawValue
        fps = profile.fps
        scale = profile.scale
        self.seed = seed
        self.power = power.onBattery ? "battery" : "ac"
        lowPower = power.lowPowerMode
    }

    var json: String { saverJSON(self) }
    var userScript: String { "window.LIVEPAPER_CONFIG = \(json);" }
}

/// The argument of `LivePaper.host.power(…)` after an AC ⇄ battery or Low Power Mode change.
struct SaverPowerUpdate: Codable, Equatable {
    var power: String
    var lowPower: Bool
    var fps: Int
    var scale: Double

    init(power state: SaverPowerState, profile: LPPerformanceProfile.Resolved) {
        power = state.onBattery ? "battery" : "ac"
        lowPower = state.lowPowerMode
        fps = profile.fps
        scale = profile.scale
    }
}

/// JavaScript the saver evaluates in web scenes. Every call is guarded so it is a harmless no-op
/// before the runtime has defined `LivePaper.host` (state is re-applied once the scene is ready).
enum SaverJS {
    static func hostCall(_ method: String, _ argument: String = "") -> String {
        "(function(h){if(h&&typeof h.\(method)==='function'){h.\(method)(\(argument));}})(window.LivePaper&&window.LivePaper.host);"
    }
    static func lockUI(_ showing: Bool) -> String { hostCall("lockUI", showing ? "true" : "false") }
    static let pause = hostCall("pause")
    static let resume = hostCall("resume")
    static func power(_ update: SaverPowerUpdate) -> String { hostCall("power", saverJSON(update)) }
}

// MARK: - Native clock (video scenes and the fallback)

/// A rectangle in top-left-origin points. (Foundation's CGRect lacks its geometry accessors without
/// CoreGraphics, and this file must stay Foundation-only.)
struct SaverRect: Equatable {
    var x: Double, y: Double, width: Double, height: Double
    var minX: Double { x }
    var maxX: Double { x + width }
    var minY: Double { y }
}

/// Geometry of the native clock. Mirrors the runtime clock (Runtime/runtime.js `clockSizes` /
/// `rectFor` / `drawClock`) so web and video scenes put the clock in the same place.
/// Coordinates are top-left based, in points.
struct SaverClockLayout: Equatable {
    enum Alignment: Equatable { case left, center, right }

    var timeSize: Double
    var dateSize: Double
    var alignment: Alignment
    /// x of the left edge, centre or right edge (per `alignment`).
    var anchorX: Double
    /// Baselines measured from the top of the view.
    var dateBaseline: Double
    var timeBaseline: Double
    /// The region the clock occupies (what the runtime exposes as `lp.clockRect`).
    var rect: SaverRect

    static func make(width w: Double, height h: Double, position: LPClockPosition) -> SaverClockLayout? {
        guard position != .none, w > 0, h > 0 else { return nil }
        let time = min(max(min(w * 0.11, h * 0.15), 40), 210)
        let date = max(13, time * 0.2)
        let boxWidth = time * 3.4
        let boxHeight = date * 1.6 + time * 1.1
        let pad = max(24, min(w, h) * 0.06)
        let rect: SaverRect
        let alignment: Alignment
        let anchor: Double
        switch position {
        case .bottomLeft:
            rect = SaverRect(x: pad, y: h - pad - boxHeight, width: boxWidth, height: boxHeight)
            alignment = .left
            anchor = rect.minX
        case .bottomRight:
            rect = SaverRect(x: w - pad - boxWidth, y: h - pad - boxHeight, width: boxWidth, height: boxHeight)
            alignment = .right
            anchor = rect.maxX
        case .top, .none:
            rect = SaverRect(x: w / 2 - boxWidth / 2, y: h * 0.07, width: boxWidth, height: boxHeight)
            alignment = .center
            anchor = w / 2
        }
        let dateBaseline = rect.minY + date * 1.1
        return SaverClockLayout(timeSize: time, dateSize: date, alignment: alignment, anchorX: anchor,
                                dateBaseline: dateBaseline, timeBaseline: dateBaseline + time * 0.98, rect: rect)
    }
}

enum SaverClockFormat {
    /// Hour + minutes in the user's locale and 12/24-hour preference, without AM/PM — the way the
    /// macOS lock screen (and the runtime clock) shows it.
    static func timePattern(locale: Locale) -> String {
        let pattern = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: locale) ?? "H:mm"
        let stripped = removingDayPeriod(from: pattern)
        return stripped.isEmpty ? "H:mm" : stripped
    }

    /// "Thursday, November 13" style (weekday, month, day — like the runtime's Intl format).
    static func datePattern(locale: Locale) -> String {
        DateFormatter.dateFormat(fromTemplate: "EEEEMMMMd", options: 0, locale: locale) ?? "EEEE, MMMM d"
    }

    /// Removes day-period fields (`a`, `b`, `B`) outside quoted literals, then tidies whitespace.
    static func removingDayPeriod(from pattern: String) -> String {
        var out = "", quoted = false
        for c in pattern {
            if c == "'" { quoted.toggle(); out.append(c); continue }
            if !quoted, c == "a" || c == "b" || c == "B" { continue }
            out.append(c)
        }
        let collapsed = out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    /// The first whole minute strictly after `date` (minute boundaries are the same in every time
    /// zone in use today, so seconds-since-1970 arithmetic is exact).
    static func nextMinuteBoundary(after date: Date) -> Date {
        let t = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: ((t / 60).rounded(.down) + 1) * 60)
    }
}

// MARK: - Options sheet text

struct SaverSummary: Equatable {
    var playlist: String
    var clock: String
    var performance: String
    /// Scene names (nil when nothing is published).
    var scenes: String?
    var footnote: String

    static func make(content: SaverContent, version: String) -> SaverSummary {
        guard let playlist = content.playlist, !content.entries.isEmpty else {
            return SaverSummary(playlist: "No scenes published yet", clock: "Shown", performance: performanceText(.automatic),
                                scenes: nil, footnote: "Open LivePaper to choose scenes. Version \(version).")
        }
        let n = content.entries.count
        var parts = [n == 1 ? "1 scene" : "\(n) scenes"]
        if n > 1 {
            switch playlist.mode {
            case .shuffle: parts.append("shuffled")
            case .sequence: parts.append("in order")
            case .single: parts.append("first scene only")
            }
            if playlist.mode != .single {
                switch playlist.cycleMinutes {
                case ...0: parts.append("one scene per session")
                case 1: parts.append("new scene every minute")
                default: parts.append("new scene every \(playlist.cycleMinutes) minutes")
                }
            }
        }
        let names = content.entries.map(\.name)
        let shown = names.prefix(4).joined(separator: ", ")
        let scenes = names.count > 4 ? "\(shown) and \(names.count - 4) more" : shown
        return SaverSummary(playlist: parts.joined(separator: " · "), clock: playlist.showClock ? "Shown" : "Hidden",
                            performance: performanceText(playlist.performance), scenes: scenes,
                            footnote: "Scenes and settings are managed in the LivePaper app. Version \(version), publish \(playlist.generation).")
    }

    static func performanceText(_ profile: LPPerformanceProfile) -> String {
        switch profile {
        case .automatic: return "Automatic (battery saver on battery or in Low Power Mode)"
        case .best: return "Best quality (60 fps)"
        case .balanced: return "Balanced (60 fps, 75% resolution)"
        case .battery: return "Battery saver (30 fps, 75% resolution)"
        }
    }
}
