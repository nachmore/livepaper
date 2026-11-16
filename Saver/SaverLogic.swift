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
    /// Playable scenes published only for displays assigned to them ("Choose per display"); never in
    /// the deck. Unique by id, and never an id of `entries`.
    var displayEntries: [LPPlaylistEntry] = []

    var isEmpty: Bool { entries.isEmpty }

    func fileURL(for entry: LPPlaylistEntry) -> URL { directory.appendingPathComponent(entry.file) }

    /// A playable scene by id: the deck first, then the display-only scenes.
    func entry(id: String) -> LPPlaylistEntry? {
        entries.first { $0.id == id } ?? displayEntries.first { $0.id == id }
    }

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
        var seen = Set<String>()
        var (entries, problems) = playable(playlist.scenes, in: directory, seen: &seen, fileExists: fileExists)
        // Display-only scenes go through the same checks; one that duplicates a deck id is dropped.
        let (displayEntries, displayProblems) = playable(playlist.displayScenes, in: directory, seen: &seen, fileExists: fileExists)
        problems += displayProblems.map { "display scene " + $0 }
        if playlist.schema > LPPlaylist.currentSchema {
            problems.insert("playlist schema \(playlist.schema) is newer than this saver (\(LPPlaylist.currentSchema)); playing what it understands", at: 0)
        }
        return SaverContent(playlist: playlist, entries: entries, problems: problems, directory: directory, displayEntries: displayEntries)
    }

    /// Filters entries down to those that are safe and present on disk, unique by id across calls
    /// sharing `seen`.
    static func playable(_ list: [LPPlaylistEntry], in directory: URL, seen: inout Set<String>,
                         fileExists: (String) -> Bool) -> (entries: [LPPlaylistEntry], problems: [String]) {
        var entries: [LPPlaylistEntry] = [], problems: [String] = []
        for entry in list {
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
///
/// Two kinds of fields: the ones that define the session (`epoch`, `startedAt`, `avoid`, `startRecent`)
/// are fixed when the session starts, so every display that joins it later builds the same deck; the
/// history (`lastShown`, `recent`, `endedAt`) changes while it runs and is what the NEXT session reads.
struct SaverSessionRecord: Codable, Equatable {
    /// The shuffle seed: normally the 30 s epoch the session started in, but one past the previous
    /// session's epoch when that one is the same or later (a quick re-lock), so the shuffle differs.
    var epoch: Int
    /// Session start (seconds since 1970): the start of `epoch`, or the actual start time when the
    /// epoch was bumped ahead of the clock. Displays join within `joinWindow` of it, and the cycle
    /// schedule steps from it.
    var startedAt: TimeInterval
    /// Scene the session avoids starting with (the one shown last in the previous session).
    var avoid: String?
    /// Scene on screen most recently (the next session avoids it).
    var lastShown: String?
    /// Scenes shown recently, most recent first; grows as scenes show. The next session's first scene
    /// avoids the newest half of the deck in it (shuffle). Optional for records written by older builds.
    var recent: [String]? = nil
    /// `recent` as it was when this session started: what THIS session's first scene avoids. Frozen —
    /// by the time a second display joins, `recent` already holds the scene the first display is
    /// showing, and a deck built from it would start elsewhere. Nil in records from older builds.
    var startRecent: [String]? = nil
    /// When the session ended (willstop). Only a session that is still running can be joined, so a
    /// quick unlock → lock starts a NEW session instead of replaying the previous one.
    var endedAt: TimeInterval? = nil
    /// Display key → the scene that display showed most recently (history, like `recent`): what
    /// "Different on each display" keeps a display from starting with again. Nil in older records.
    var shownOn: [String: String]? = nil
    /// `shownOn` as it was when this session started (frozen, like `startRecent`).
    var startShownOn: [String: String]? = nil

    static let recentCapacity = 12
    /// `shownOn` keeps at most this many displays.
    static let shownOnCapacity = 16

    /// The session as every display of it plays it. Built only from the fields fixed at its start, so
    /// `noteShown` and `endedAt` never change it.
    var session: SaverSession {
        SaverSession(epoch: epoch, startedAt: Date(timeIntervalSince1970: startedAt), avoid: avoid, recent: startRecent ?? [],
                     shownOn: startShownOn ?? [:])
    }

    /// Records `id` as on screen now (history only; the session is unchanged): as the scene shown
    /// last (unless `updatesLastShown` is false: in "Different on each display" only the lead display,
    /// the last one in layout order, writes it), in `recent`, and as what `display` shows.
    mutating func noteShown(_ id: String, display: String? = nil, updatesLastShown: Bool = true) {
        if updatesLastShown { lastShown = id }
        var list = (recent ?? []).filter { $0 != id }
        list.insert(id, at: 0)
        recent = Array(list.prefix(Self.recentCapacity))
        if let display {
            var map = shownOn ?? [:]
            map[display] = id
            while map.count > Self.shownOnCapacity, let drop = map.keys.filter({ $0 != display }).min() { map.removeValue(forKey: drop) }
            shownOn = map
        }
    }
}

/// One screen-saver session as seen by every display that starts within it.
struct SaverSession: Equatable {
    var epoch: Int
    var startedAt: Date
    var avoid: String?
    /// Recently shown scenes when the session started, most recent first (see `SaverDeck.recent`).
    var recent: [String] = []
    /// What each display (by key) showed last when the session started (see `SaverDeck.previous`).
    var shownOn: [String: String] = [:]

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
    /// A stored epoch more than this many epochs (one day) ahead of the clock is not followed: the
    /// clock was moved back, or the record is damaged (and `+ 1` must never overflow).
    static let maxEpochLead = 2880

    /// Decides which session a starting display belongs to.
    /// - Returns: the session, the record to persist (non-preview instances only), and whether an
    ///   existing session was joined.
    static func plan(now: Date, stored: SaverSessionRecord?) -> (session: SaverSession, record: SaverSessionRecord, joined: Bool) {
        let t = now.timeIntervalSince1970
        // Join only a session that is still running (another display started it a moment ago). A
        // session that already ended — the user unlocked and locked again quickly — must not be
        // replayed: that showed the same scene lock after lock.
        if let stored, stored.endedAt == nil, t - stored.startedAt >= -epochLength, t - stored.startedAt < joinWindow {
            return (stored.session, stored, true)
        }
        var epoch = clockEpoch(now)
        // A new session in the same 30 s epoch as an ended one still needs a different shuffle (and
        // so does one after quick re-locks ran the epoch ahead of the clock, up to `maxEpochLead`).
        if let stored, epoch <= stored.epoch, isPlausible(stored.epoch, at: now) { epoch = stored.epoch + 1 }
        let start = t >= TimeInterval(epoch) * epochLength ? TimeInterval(epoch) * epochLength : t
        let recent = stored?.recent ?? (stored?.lastShown.map { [$0] } ?? [])
        let record = SaverSessionRecord(epoch: epoch, startedAt: start, avoid: stored?.lastShown, lastShown: nil,
                                        recent: recent, startRecent: recent, endedAt: nil,
                                        shownOn: stored?.shownOn, startShownOn: stored?.shownOn)
        return (record.session, record, false)
    }

    /// The record to save after a display put `id` on screen at `now`, or nil when there is nothing
    /// new. `own` is the record of the session this display plays, `stored` what the shared store
    /// holds. When the store holds the same session or a newer one, the scene goes into THAT record,
    /// so displays never drop each other's history: one that skipped a failing scene, or one still in
    /// the session a late display (> `joinWindow`, however much later) started after. Only an older
    /// record — the previous session, when this display's session has just begun — or an implausible
    /// one is replaced by `own`.
    ///
    /// `display` (the display's key) also records what that display shows (`shownOn`), and
    /// `updatesLastShown: false` leaves `lastShown` alone (displays other than the lead in "Different
    /// on each display"). Without a display the record is unchanged when it already shows `id` last.
    static func recordShown(_ id: String, own: SaverSessionRecord, stored: SaverSessionRecord?, now: Date,
                            display: String? = nil, updatesLastShown: Bool = true) -> SaverSessionRecord? {
        var record = own
        if let stored, stored.session == own.session || isSession(stored, newerThan: own, at: now) { record = stored }
        if display == nil && updatesLastShown {
            guard record.lastShown != id else { return nil }
        }
        let before = record
        record.noteShown(id, display: display, updatesLastShown: updatesLastShown)
        return record == before ? nil : record
    }

    /// Whether `record` is a session that began after `other`'s, judged at `now`: `plan` gives every
    /// new session a later epoch than the stored one, however long after it starts. A later epoch
    /// that `plan` would not follow at `now` (`maxEpochLead` or more ahead of the clock: damaged, or
    /// written before the clock was moved back) is not a newer session. The bound is the clock, not
    /// the gap between the two sessions: a display that starts days into a session that never ended
    /// (the Mac stayed locked over a weekend) begins a genuinely newer one. Never overflows.
    static func isSession(_ record: SaverSessionRecord, newerThan other: SaverSessionRecord, at now: Date) -> Bool {
        record.epoch > other.epoch && isPlausible(record.epoch, at: now)
    }

    /// The 30 s epoch `now` falls in.
    static func clockEpoch(_ now: Date) -> Int { Int((now.timeIntervalSince1970 / epochLength).rounded(.down)) }

    /// Whether a stored `epoch` is one `plan` follows at `now`: less than `maxEpochLead` ahead of the
    /// clock. Never overflows, whatever the record holds.
    static func isPlausible(_ epoch: Int, at now: Date) -> Bool {
        let (bound, overflow) = clockEpoch(now).addingReportingOverflow(maxEpochLead)
        return overflow || epoch < bound
    }

    /// The record to save when the saver stops (willstop), or nil when the store already says so.
    /// Marks whatever the store holds — it is what the next session reads, and every session ends at
    /// willstop — instead of saving this display's own copy: each display's view handles willstop,
    /// and the last one to save its copy would drop what the others recorded.
    static func recordEnded(at t: TimeInterval, own: SaverSessionRecord, stored: SaverSessionRecord?) -> SaverSessionRecord? {
        var record = stored ?? own
        guard record.endedAt == nil else { return nil }
        record.endedAt = t
        return record
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

/// The order scenes play in. Deterministic for a given (ids, mode, seed, avoid, recent, spread,
/// previous), so every display of a session computes the same scene for the same step without talking
/// to each other.
///
/// "Different on each display" plays display k (layout order) at step s + k, with `spread` = the number
/// of displays: then any `spread` consecutive steps are distinct (across reshuffles too), the first
/// `spread` positions avoid what was on screen recently, and no display starts with the scene it showed
/// last (`previous`). With `spread` 1 every rule reduces exactly to the single-display deck.
struct SaverDeck: Equatable {
    let ids: [String]
    let mode: LPPlaylistMode
    let seed: UInt64
    /// Scene to avoid at step 0 (shown last in the previous session).
    let avoid: String?
    /// Recently shown scenes when the session started, most recent first. Shuffle never starts a
    /// session with one of the newest ⌊n/2⌋ of them (or `avoid`), so locking repeatedly walks through
    /// the deck instead of repeating.
    var recent: [String] = []
    /// How many displays play consecutive steps ("Different on each display"; 1 otherwise).
    var spread: Int = 1
    /// For display index k (layout order): the scene it showed last, if known.
    var previous: [String?] = []

    init(ids: [String], mode: LPPlaylistMode, seed: UInt64, avoid: String?, recent: [String] = [],
         spread: Int = 1, previous: [String?] = []) {
        self.ids = ids; self.mode = mode; self.seed = seed; self.avoid = avoid; self.recent = recent
        self.spread = max(1, spread); self.previous = previous
    }

    /// The deck every display of `session` plays.
    init(ids: [String], mode: LPPlaylistMode, session: SaverSession, spread: Int = 1, previous: [String?] = []) {
        self.init(ids: ids, mode: mode, seed: session.shuffleSeed, avoid: session.avoid, recent: session.recent,
                  spread: spread, previous: previous)
    }

    /// The ids the first scenes of a session (the first `spread` positions) must not be: the newest
    /// ⌊n/2⌋ of `[avoid] + recent`, fewer when `spread` displays need room (empty for one-scene decks).
    var startAvoidSet: Set<String> {
        let n = ids.count
        guard n > 1 else { return [] }
        var list = recent
        if let avoid, !list.contains(avoid) { list.insert(avoid, at: 0) }
        let size = spread <= 1 ? max(1, n / 2) : max(0, min(max(1, n / 2), n - spread))
        return Set(list.filter { ids.contains($0) }.prefix(size))
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
            return (sequenceStart + s) % n
        case .shuffle:
            return shuffledRound(s / n)[s % n]
        }
    }

    /// Sequence: continue after the scene shown last; with several displays, the first start from
    /// there at which no display gets the scene it showed last.
    var sequenceStart: Int {
        let n = ids.count
        let base = avoid.flatMap { ids.firstIndex(of: $0) }.map { ($0 + 1) % n } ?? 0
        guard spread > 1, !previous.isEmpty, n > 1 else { return base }
        let k = min(spread, previous.count)
        for shift in 0..<n {
            let b = (base + shift) % n
            if !(0..<k).contains(where: { previous[$0] == ids[(b + $0) % n] }) { return b }
        }
        return base
    }

    /// The permutation for one pass through the deck. Each pass is reshuffled. The first pass starts
    /// clear of the avoid set (its first `spread` positions) and of each display's previous scene; a
    /// later pass doesn't repeat any of the previous pass's last scenes within `spread` steps (for one
    /// display: its first scene isn't the previous pass's last).
    func shuffledRound(_ round: Int) -> [Int] {
        let n = ids.count
        guard n > 1 else { return Array(0..<n) }
        let w = min(max(2, spread), n)
        var prevOrder: [Int] = []
        var order: [Int] = []
        for r in 0...max(0, round) {
            var rng = SaverRandom(seed: seed &+ UInt64(r) &* 0xD1B5_4A32_D192_ED03)
            order = Array(0..<n)
            for i in stride(from: n - 1, to: 0, by: -1) { order.swapAt(i, rng.next(below: i + 1)) }
            if r == 0 {
                let avoidSet = startAvoidSet
                for i in 0..<min(spread, n) where avoidSet.contains(ids[order[i]]) {
                    if let j = ((i + 1)..<n).first(where: { !avoidSet.contains(ids[order[$0]]) }) { order.swapAt(i, j) }
                }
                let m = min(spread, n)
                if m >= 2 {
                    for i in 0..<m where i < previous.count && previous[i] == ids[order[i]] { order.swapAt(i, (i + 1) % m) }
                }
            } else {
                for i in 0..<(w - 1) {
                    let forbidden = Set(prevOrder.suffix(w - 1 - i))
                    guard forbidden.contains(order[i]) else { continue }
                    if let j = ((i + 1)..<n).first(where: { !forbidden.contains(order[$0]) }) { order.swapAt(i, j) }
                }
            }
            prevOrder = order
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

    /// When `step` began (the session start when scenes never change).
    func start(ofStep step: Int) -> Date {
        guard let cycle else { return startedAt }
        return startedAt.addingTimeInterval(TimeInterval(max(0, step)) * cycle)
    }
}

// MARK: - Multiple displays

/// What a display shows of its scene: the live scene, one still frame (nothing runs), or nothing.
enum SaverDisplayLiveness: String, Equatable {
    case live, still, off

    init(_ battery: LPBatteryDisplays) {
        switch battery {
        case .live: self = .live
        case .still: self = .still
        case .off: self = .off
        }
    }
}

/// What one display needs to draw its slice of a scene that spans all displays.
struct SaverSpan: Equatable {
    /// The virtual canvas (the union of all displays), points.
    var canvasWidth: Double
    var canvasHeight: Double
    /// This display's part of the canvas (canvas coordinates, points, top-left).
    var viewport: LPRect
    /// The main display's part: the clock is placed inside it (and shown only there).
    var clockViewport: LPRect
    /// Scene time 0 for every display: when the step began (wall clock), so slices line up.
    var timeOrigin: Date
    var isMain: Bool
}

/// A display's scene for one step: the entry, and its slice when the step spans the displays.
struct SaverResolvedScene: Equatable {
    var entry: LPPlaylistEntry
    var span: SaverSpan?
}

/// How one display takes part in the playlist, decided from the display settings, the arrangement of
/// all displays, this display's key and the power state (ARCHITECTURE §6, "Multiple displays").
/// Pure: every display computes every other display's plan the same way.
struct SaverDisplayPlan: Equatable {
    enum Source: Equatable {
        /// The deck, `offset` steps ahead ("Different on each display": the display's index).
        case deck(offset: Int)
        /// The scene assigned to this display ("Choose per display").
        case assigned(String)
    }

    /// Effective mode (previews, a single display or an unknown display: `.same`).
    var mode: LPDisplayMode
    var layout: LPDisplayLayout
    /// This display's key, normalised (nil when unknown).
    var key: String?
    /// Position in the layout (0 when the display is unknown).
    var index: Int
    var isMain: Bool
    var source: Source
    /// Displays playing consecutive steps: the display count in "Different", else 1.
    var spread: Int
    var liveness: SaverDisplayLiveness
    /// Writes `lastShown` (what the next session continues after): every display, except in
    /// "Different", where only the last display in layout order that shows anything does.
    var isLead: Bool
    /// Steps whose scene supports it span all displays.
    var spanAllowed: Bool

    /// Whether this display's scenes go into the history (assigned scenes and black displays don't).
    var recordsHistory: Bool {
        if case .deck = source { return liveness != .off }
        return false
    }

    var isAssigned: Bool {
        if case .assigned = source { return true }
        return false
    }

    /// The plan of a preview, or of a display whose key or arrangement is unknown: today's single-display
    /// behaviour (never black on uncertainty).
    static func standard(layout: LPDisplayLayout = LPDisplayLayout([]), key: String? = nil) -> SaverDisplayPlan {
        SaverDisplayPlan(mode: .same, layout: layout, key: key, index: 0, isMain: true, source: .deck(offset: 0), spread: 1,
                         liveness: .live, isLead: true, spanAllowed: false)
    }

    static func make(settings: LPDisplaySettings, layout: LPDisplayLayout, key rawKey: String?, content: SaverContent,
                     power: SaverPowerState, preview: Bool) -> SaverDisplayPlan {
        let key = rawKey.map(LPDisplay.normalizedID)
        guard !preview, let key, let index = layout.index(of: key) else { return standard(layout: layout, key: key) }
        let mode = settings.effectiveMode(displayCount: layout.count)
        let mainID = layout.main?.id
        let saving = power.prefersBatterySaver
        func liveness(_ id: String) -> SaverDisplayLiveness { id != mainID && saving ? SaverDisplayLiveness(settings.onBattery) : .live }
        var source = Source.deck(offset: 0)
        switch mode {
        case .choose:
            if let id = settings.assignments[key], content.entry(id: id) != nil { source = .assigned(id) }
        case .different:
            source = .deck(offset: index)
        case .same, .span:
            break
        }
        var isLead = true
        if mode == .different {
            let lead = layout.displays.indices.last { liveness(layout.displays[$0].id) != .off } ?? 0
            isLead = index == lead
        }
        return SaverDisplayPlan(mode: mode, layout: layout, key: key, index: index, isMain: key == mainID, source: source,
                                spread: mode == .different ? layout.count : 1, liveness: liveness(key), isLead: isLead,
                                spanAllowed: mode == .span && !(saving && settings.onBattery == .off))
    }

    /// For each display index (layout order) in "Different": the scene it showed last in the history
    /// the session froze at its start. Empty in other modes.
    func previous(for session: SaverSession) -> [String?] {
        guard mode == .different else { return [] }
        return layout.displays.map { session.shownOn[$0.id] }
    }

    /// The scene this display shows at `step`. `skipOffset` counts scenes recovery skipped after
    /// failures: an assigned scene that keeps failing gives way to the playlist. Nil when there is
    /// nothing to play.
    func resolve(step: Int, skipOffset: Int, deck: SaverDeck, content: SaverContent, session: SaverSession,
                 schedule: SaverSchedule) -> SaverResolvedScene? {
        var offset = 0, skip = skipOffset
        switch source {
        case .assigned(let id):
            if skip == 0, let entry = content.entry(id: id) { return SaverResolvedScene(entry: entry, span: nil) }
            skip = max(0, skip - 1)
        case .deck(let o):
            offset = o
        }
        guard !content.entries.isEmpty else { return nil }
        let index = deck.entryIndex(atStep: step + skip + offset)
        guard content.entries.indices.contains(index) else { return nil }
        let entry = content.entries[index]
        var span: SaverSpan?
        if spanAllowed, entry.span == true, let key, let viewport = layout.viewport(of: key) {
            let canvas = layout.canvas
            let clock = layout.main.flatMap { layout.viewport(of: $0.id) } ?? viewport
            span = SaverSpan(canvasWidth: canvas.width, canvasHeight: canvas.height, viewport: viewport, clockViewport: clock,
                             timeOrigin: schedule.start(ofStep: step), isMain: isMain)
        }
        return SaverResolvedScene(entry: entry, span: span)
    }

    /// One line for the log: "display 2/3 main=0 mode=different liveness=still key=37D8832A".
    var summary: String {
        "display \(index + 1)/\(max(1, layout.count)) main=\(isMain ? 1 : 0) mode=\(mode.rawValue) liveness=\(liveness.rawValue) "
            + "lead=\(isLead ? 1 : 0) key=\(key.map { String($0.prefix(8)) } ?? "?")"
            + (isAssigned ? " assigned" : "")
    }
}

/// Geometry of a spanning video: the player layer covers the whole canvas, offset so this display's
/// viewport is what shows (the host view clips to its bounds).
enum SaverSpanGeometry {
    /// The player layer's frame in a bottom-left-origin host view of height `vh` (AppKit layers).
    static func layerFrame(span: SaverSpan, viewHeight vh: Double) -> SaverRect {
        SaverRect(x: -span.viewport.x, y: vh - span.canvasHeight + span.viewport.y, width: span.canvasWidth, height: span.canvasHeight)
    }

    /// The clock layout of a span step: placed by the scene's clock position inside the main
    /// display's viewport, in this display's own (top-left) coordinates. Nil without a clock.
    static func clockRect(span: SaverSpan, position: LPClockPosition) -> SaverRect? {
        guard let layout = SaverClockLayout.make(width: span.clockViewport.width, height: span.clockViewport.height, position: position) else { return nil }
        let r = layout.rect
        return SaverRect(x: r.x + span.clockViewport.x - span.viewport.x, y: r.y + span.clockViewport.y - span.viewport.y,
                         width: r.width, height: r.height)
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
    /// Displays were connected, disconnected or rearranged (NSApplication.didChangeScreenParameters).
    case screensChanged

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
    static let screensChangedName = "LivePaperScreensChanged"

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
        case Self.screensChangedName: self = .screensChanged
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
        case .lockUIShown, .lockUIHidden, .published, .windowChanged, .screensChanged: break
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
    /// Span steps only (absent otherwise, so the JSON is unchanged): the virtual canvas and this
    /// page's viewport in it (CSS px), the main display's viewport (the clock box), and scene time 0
    /// (ms since 1970) shared by every display.
    var spanW: Double? = nil
    var spanH: Double? = nil
    var spanX: Double? = nil
    var spanY: Double? = nil
    var spanClockX: Double? = nil
    var spanClockY: Double? = nil
    var spanClockW: Double? = nil
    var spanClockH: Double? = nil
    var timeOrigin: Double? = nil
    /// Start paused (one frame, no frame loop): still displays. Only written when true.
    var paused: Bool? = nil

    init(showClock: Bool, clockPosition: LPClockPosition, profile: LPPerformanceProfile.Resolved, seed: Int, power: SaverPowerState,
         span: SaverSpan? = nil, paused: Bool = false) {
        clock = showClock
        self.clockPosition = clockPosition.rawValue
        fps = profile.fps
        scale = profile.scale
        self.seed = seed
        self.power = power.onBattery ? "battery" : "ac"
        lowPower = power.lowPowerMode
        if let span {
            spanW = span.canvasWidth; spanH = span.canvasHeight
            spanX = span.viewport.x; spanY = span.viewport.y
            spanClockX = span.clockViewport.x; spanClockY = span.clockViewport.y
            spanClockW = span.clockViewport.width; spanClockH = span.clockViewport.height
            timeOrigin = (span.timeOrigin.timeIntervalSince1970 * 1000).rounded()
        }
        self.paused = paused ? true : nil
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
    /// Multiple displays, when not the standard settings ("Different on each display · …").
    var displays: String? = nil

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
                            footnote: "Scenes and settings are managed in the LivePaper app. Version \(version), publish \(playlist.generation).",
                            displays: displaysText(playlist.displays))
    }

    /// "Different on each display · on battery, other displays show a still"; nil for the standard settings.
    static func displaysText(_ d: LPDisplaySettings) -> String? {
        guard d != .standard else { return nil }
        var parts: [String]
        switch d.mode {
        case .same: parts = ["Same on every display"]
        case .different: parts = ["Different on each display"]
        case .choose:
            let n = d.assignments.count
            parts = ["Chosen per display" + (n == 0 ? "" : " (\(n) display\(n == 1 ? "" : "s") assigned)")]
        case .span: parts = ["Spans all displays"]
        }
        switch d.onBattery {
        case .live: break
        case .still: parts.append("on battery, other displays show a still")
        case .off: parts.append("on battery, other displays are black")
        }
        return parts.joined(separator: " · ")
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
