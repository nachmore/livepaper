// WallpaperStoreApplier — puts an edited wallpaper store in place so WallpaperAgent actually uses it.
//
// WallpaperAgent reads Index.plist only when it launches and rewrites the whole file from memory on
// almost every lock, unlock or display change. So an edit sticks only if the agent restarts right
// after the file is replaced, and only an edit the agent can decode is safe (an undecodable store
// makes it write a default one, losing the Desktop choices). The sequence (docs/RESEARCH.md §5):
//
//  1. Preflight — refuse unless: the store is the one the agent reads; the session is unlocked;
//     System Settings, its Wallpaper extension and ScreenSaverEngine aren't running; (select only)
//     MDM doesn't force the module or forbid wallpaper changes; the store format version is 10.
//  2. Hold an exclusive lock file; preflight again (another LivePaper process may have held the
//     lock for a while); wait until the store has been unchanged for ~1 s.
//  3. Read it; it must decode with WallpaperAgent's model (WallpaperStoreSchema). Plan the edit.
//  4. Build the edited store and verify it (decodes; only the planned Idle slots differ; Desktop
//     slots byte-identical).
//  5. Re-check that the session is still unlocked and nothing conflicting has opened (the waits
//     above take seconds). Back up (the exact bytes about to be replaced; select: also the raw file
//     once, plus the per-slot manifest) — before writing anything. The file must not have changed
//     since step 3.
//  6. Atomic rename into place, then immediately restart WallpaperAgent (killall; launchd relaunches it).
//  7. Wait for the new agent's own rewrite, re-read and confirm: the planned Idle slots make the
//     planned choice and the Desktop slots are unchanged — a SystemDefault or Space Default the
//     agent replaced with its own choice still counts while every display record shows what the
//     plan asked for (the agent derives those from the displays it shows). Lost change → re-plan
//     and retry (≤ 2, 2 s apart; an empty re-plan is done, without a restart, only while every
//     display shows what the last write asked for — otherwise the change wasn't kept: an error);
//     Desktop changed or unreadable → roll back: put the bytes read in step 3 back through the same
//     protected sequence (re-check, rename, restart, confirm, retry) and report the rollback — or,
//     if it can't be confirmed, that it failed and where the saved copy is.
//  Every agent restart is preceded by the step-5 re-check: never while the Mac is locked (the agent
//  draws the lock-screen saver) or System Settings is open.
//
// Every wait goes through WallpaperClock and every system interaction through WallpaperSystem, so
// the whole sequence runs in tests against temp copies of a real store with a fake agent.
import Darwin
import Foundation

/// Timings of the live sequence.
public struct WallpaperApplyOptions: Sendable, Equatable {
    /// How long the store must stay unchanged before LivePaper reads it, and before the agent's
    /// post-restart rewrite is read back.
    public var quietInterval: TimeInterval = 1
    public var pollInterval: TimeInterval = 0.2
    /// Give up waiting for a quiet store after this long.
    public var quietTimeout: TimeInterval = 15
    /// How long to wait for the restarted agent's first write.
    public var rewriteTimeout: TimeInterval = 10
    public var retryDelay: TimeInterval = 2
    public var maxRetries = 2
    /// How long a rollback waits for the Mac to be unlocked (and System Settings closed) before it
    /// restarts WallpaperAgent to put the previous store back.
    public var rollbackWaitTimeout: TimeInterval = 60

    /// The `StoreIndexMigrationVersion` whose format this code mirrors (macOS 26).
    public static let supportedStoreVersion = 10

    public init() {}
}

/// What an apply did.
public struct WallpaperApplyReport: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// The store already was in the requested state: nothing written, agent not restarted.
        case unchanged
        /// Written, and confirmed after the agent restarted.
        case applied
    }
    public var outcome: Outcome
    /// Idle slots replaced.
    public var changed: [WallpaperRecordPath]
    /// Read-plan-write-confirm rounds (1 + retries).
    public var attempts: Int
    public var agentRestarts: Int
    /// Restore only: root slots that got the built-in saver (WallpaperStorePlan.builtinSaverPaths).
    public var builtinSaverPaths: [WallpaperRecordPath]
    /// Planned records displays fall back to (SystemDefault, a Space's Default) that the restarted
    /// agent wrote its own choice into, accepted because every display record shows what the plan
    /// asked for (WallpaperStoreVerifier.Confirmation.confirmedDefaultsRewritten). A selection notes
    /// them in its manifest (`Entry.agentSlot`), so uninstall still restores them.
    public var rewrittenByAgent: [WallpaperRecordPath]

    public init(outcome: Outcome, changed: [WallpaperRecordPath] = [], attempts: Int = 1, agentRestarts: Int = 0,
                builtinSaverPaths: [WallpaperRecordPath] = [], rewrittenByAgent: [WallpaperRecordPath] = []) {
        self.outcome = outcome; self.changed = changed; self.attempts = attempts; self.agentRestarts = agentRestarts
        self.builtinSaverPaths = builtinSaverPaths; self.rewrittenByAgent = rewrittenByAgent
    }
}

public final class WallpaperStoreApplier: @unchecked Sendable {
    public let storeURL: URL
    public let options: WallpaperApplyOptions
    private let system: WallpaperSystem
    private let clock: WallpaperClock
    private let lockURL: URL?
    private let snapshotURL: URL?

    /// - Parameters:
    ///   - lockURL: exclusive lock file held for the whole sequence (nil: none).
    ///   - snapshotURL: where the exact bytes about to be replaced are saved before every write
    ///     (select and restore), so a failed rollback can point the user at them (nil: not saved).
    public init(storeURL: URL, system: WallpaperSystem, clock: WallpaperClock = SystemWallpaperClock(),
                options: WallpaperApplyOptions = WallpaperApplyOptions(), lockURL: URL? = nil, snapshotURL: URL? = nil) {
        self.storeURL = storeURL; self.system = system; self.clock = clock; self.options = options; self.lockURL = lockURL
        self.snapshotURL = snapshotURL
    }

    // MARK: - Select / restore

    /// LIVE PATH. Makes `module` the screen saver for every display and Space (`scope`: the user's
    /// selection, or the quiet re-apply that only fills placeholders). Before the store is written,
    /// the untouched file is copied to `rawBackupURL` (first time only) and the original of every
    /// replaced Idle slot is recorded in the manifest at `manifestURL`; what the restarted agent wrote
    /// in place of a planned default is noted there too.
    ///
    /// - Parameter stopIf: a reason not to go on (nil: go on), asked again while holding the store
    ///   lock, right before planning and right before writing — so a check the caller made before
    ///   waiting for the lock (LivePaper wasn't uninstalled, still owns the selection) still holds.
    ///   A reason throws `.stopped`, with nothing written. The saver's bundle is checked the same way.
    public func select(_ module: WallpaperSaverModule, manifestURL: URL, rawBackupURL: URL,
                       scope: WallpaperSelectScope = .everyDisplay, stopIf: (() -> String?)? = nil) throws -> WallpaperApplyReport {
        func check() throws {
            let info = module.url.appendingPathComponent("Contents/Info.plist")
            guard FileManager.default.fileExists(atPath: info.path) else { throw WallpaperStoreError.saverMissing(module.url.path) }
            if let why = stopIf?() { throw WallpaperStoreError.stopped(why) }
        }
        try check()
        return try apply(checkModulePolicy: true, acceptingRewrittenDefaults: true, plan: { [clock] document in
            try check()
            return try document.planSelect(module, at: clock.now(), scope: scope)
        }, beforeWrite: { [clock] original, plan in
            try check()
            if !FileManager.default.fileExists(atPath: rawBackupURL.path) { try FileOps.writeAtomically(original, to: rawBackupURL) }
            let now = clock.now()
            let manifest = try WallpaperSelectionManifest.load(from: manifestURL) ?? WallpaperSelectionManifest(module: module.moduleURLString, createdAt: now)
            try manifest.recording(plan, module: module, at: now).write(to: manifestURL)
        }, finish: { [clock] report, document in
            guard !report.rewrittenByAgent.isEmpty, let manifest = try WallpaperSelectionManifest.load(from: manifestURL) else { return }
            try manifest.recordingAgentSlots(report.rewrittenByAgent, in: document, at: clock.now()).write(to: manifestURL)
        })
    }

    /// LIVE PATH. Undoes the selection of `module` in every Idle slot that is still LivePaper's (see
    /// `WallpaperStoreDocument.planRestore`): the recorded original from the manifest at
    /// `manifestURL` if there is one, else the placeholder or — at the root records — `fallback`'s
    /// choice; display records that would inherit a choice restored into SystemDefault or a Space's
    /// Default get it themselves. Confirmed by what every display shows. Then deletes the manifest —
    /// only then: a restore that wasn't confirmed throws and keeps it. The manifest is read and
    /// deleted while holding the store lock. Works without a manifest too (LivePaper picked by
    /// hand). Call it before the `.saver` is removed.
    public func restore(_ module: WallpaperSaverModule, manifestURL: URL, fallback: WallpaperRestoreFallback = WallpaperRestoreFallback(),
                        moduleExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) throws -> WallpaperApplyReport {
        try apply(checkModulePolicy: false, acceptingRewrittenDefaults: true, plan: { [clock] document in
            let manifest = try WallpaperSelectionManifest.load(from: manifestURL)
                ?? WallpaperSelectionManifest(module: module.moduleURLString, createdAt: clock.now())
            return try document.planRestore(manifest, module: module, at: clock.now(), fallback: fallback, moduleExists: moduleExists)
        }, finish: { _, _ in try FileOps.removeIfPresent(manifestURL) })
    }

    // MARK: - The sequence

    /// Runs the full live sequence for an arbitrary plan (select/restore use it; tests use it to
    /// prove that a plan producing an invalid store is refused).
    ///
    /// - Parameters:
    ///   - checkModulePolicy: also refuse when MDM forces the screen-saver module or forbids
    ///     wallpaper changes (for selecting; undoing LivePaper's own change is always allowed).
    ///   - acceptingRewrittenDefaults: planned defaults the restarted agent rewrote count as kept
    ///     while every display record shows what the plan asked for (`WallpaperStoreVerifier.confirm`).
    ///     false: every planned slot must be kept.
    ///   - plan: computes the edit from the current store; an empty plan means nothing to do.
    ///   - beforeWrite: called with the store's current bytes and the plan right before the edited
    ///     store is put in place (backups).
    ///   - finish: called, still holding the lock, with the report and the store as last read, before
    ///     a successful apply returns (bookkeeping that must not race another LivePaper process).
    public func apply(checkModulePolicy: Bool, acceptingRewrittenDefaults: Bool = false,
                      plan makePlan: (WallpaperStoreDocument) throws -> WallpaperStorePlan,
                      beforeWrite: ((Data, WallpaperStorePlan) throws -> Void)? = nil,
                      finish: ((WallpaperApplyReport, WallpaperStoreDocument) throws -> Void)? = nil) throws -> WallpaperApplyReport {
        // Refuse at once rather than after waiting for another LivePaper process's lock.
        try preflight(checkModulePolicy: checkModulePolicy)
        func run() throws -> WallpaperApplyReport {
            let (report, document) = try attempts(checkModulePolicy: checkModulePolicy, acceptingRewrittenDefaults: acceptingRewrittenDefaults,
                                                  makePlan: makePlan, beforeWrite: beforeWrite)
            try finish?(report, document)
            return report
        }
        guard let lockURL else { return try run() }
        return try FileLock.withLock(at: lockURL, run)
    }

    /// What was written in the last round, for confirming it.
    private struct Written {
        var original: WallpaperStoreDocument
        var originalBytes: Data
        var plan: WallpaperStorePlan
    }

    /// The rounds, and the store the successful one read last.
    private func attempts(checkModulePolicy: Bool, acceptingRewrittenDefaults: Bool,
                          makePlan: (WallpaperStoreDocument) throws -> WallpaperStorePlan,
                          beforeWrite: ((Data, WallpaperStorePlan) throws -> Void)?) throws -> (WallpaperApplyReport, WallpaperStoreDocument) {
        var written: Written?
        var restarts = 0
        var lastProblem = "the store kept changing"
        /// The last round read the restarted agent's own rewrite (and found the change lost), as
        /// opposed to giving up waiting for that rewrite.
        var agentRewrote = false
        for attempt in 1...(1 + max(0, options.maxRetries)) {
            do {
                if attempt > 1 { clock.sleep(options.retryDelay) }
                // Inside the lock, and on every retry: the Mac may have locked in the meantime.
                try preflight(checkModulePolicy: checkModulePolicy)
                try waitForQuiet()
                let (bytes, signature) = try readStore()
                let document = try WallpaperStoreDocument(data: bytes)
                let plan = try makePlan(document)
                if plan.isEmpty {
                    guard let current = written else { return (WallpaperApplyReport(outcome: .unchanged, attempts: attempt, agentRestarts: restarts), document) }
                    if agentRewrote {
                        // Nothing left to plan after the restarted agent's rewrite: confirmed without
                        // restarting it again only when every display shows what the last write asked
                        // for (the agent spelled a planned slot differently, or let it inherit the same
                        // choice) and the Desktop is intact. A planned slot the agent replaced with
                        // something LivePaper no longer plans to change — a restored SystemDefault it
                        // put a placeholder into — wasn't kept.
                        if case .desktopChanged(let paths) = WallpaperStoreVerifier.confirm(current: document, original: current.original, plan: WallpaperStorePlan()) {
                            throw rollBack(current, because: Self.desktopChanged(paths), restarts: &restarts)
                        }
                        guard let expected = try? current.original.applying(current.plan), document.showsTheSameOnEveryDisplay(as: expected) else {
                            throw WallpaperStoreError.notConfirmed(lastProblem)
                        }
                        // Planned defaults that hold the agent's own choice now (a selection notes them).
                        let rewritten = current.plan.changes.filter { change in
                            change.path.displayID == nil && document.idleSlot(at: change.path).map { WallpaperSlot.sameChoices($0, change.after) } != true
                        }.map(\.path)
                        return (report(.applied, current, attempts: attempt, restarts: restarts, rewritten: rewritten), document)
                    }
                    // An earlier round's write is on disk unconfirmed (the agent didn't rewrite in
                    // time): restart and confirm again below.
                    try recheck()
                } else {
                    let edited = try document.applying(plan).data()
                    try WallpaperStoreVerifier.verify(edited: edited, original: document, plan: plan)
                    // The waits above take seconds: check again right before writing and restarting.
                    try recheck()
                    if let snapshotURL { try FileOps.writeAtomically(bytes, to: snapshotURL) }
                    try beforeWrite?(bytes, plan)
                    guard fileSignature() == signature else { lastProblem = "the store changed while LivePaper was editing it"; continue }
                    try replaceStore(with: edited)
                    written = Written(original: document, originalBytes: bytes, plan: plan)
                }
                guard let current = written else { continue }
                let ours = fileSignature()
                try system.restartWallpaperAgent()
                restarts += 1
                guard waitForRewrite(differentFrom: ours) else {
                    lastProblem = "WallpaperAgent didn't rewrite the store after restarting"
                    agentRewrote = false
                    continue
                }
                try? waitForQuiet()
                let (afterBytes, _) = try readStore()
                guard let after = try? WallpaperStoreDocument(data: afterBytes) else {
                    throw rollBack(current, because: "the restarted WallpaperAgent wrote a store LivePaper can't read", restarts: &restarts)
                }
                switch WallpaperStoreVerifier.confirm(current: after, original: current.original, plan: current.plan,
                                                      acceptingRewrittenDefaults: acceptingRewrittenDefaults) {
                case .confirmed:
                    return (report(.applied, current, attempts: attempt, restarts: restarts), after)
                case .confirmedDefaultsRewritten(let paths):
                    return (report(.applied, current, attempts: attempt, restarts: restarts, rewritten: paths), after)
                case .changeLost(let paths):
                    lastProblem = "WallpaperAgent overwrote " + Self.list(paths)
                    agentRewrote = true
                case .desktopChanged(let paths):
                    throw rollBack(current, because: Self.desktopChanged(paths), restarts: &restarts)
                }
            } catch let error as WallpaperStoreError where written != nil && !error.wroteStore {
                // A refusal after LivePaper already wrote: the change is on disk but unconfirmed.
                throw WallpaperStoreError.notConfirmed(error.localizedDescription)
            }
        }
        throw written == nil ? WallpaperStoreError.storeBusy : WallpaperStoreError.notConfirmed(lastProblem)
    }

    private func report(_ outcome: WallpaperApplyReport.Outcome, _ written: Written, attempts: Int, restarts: Int,
                        rewritten: [WallpaperRecordPath] = []) -> WallpaperApplyReport {
        WallpaperApplyReport(outcome: outcome, changed: written.plan.paths, attempts: attempts, agentRestarts: restarts,
                             builtinSaverPaths: written.plan.builtinSaverPaths, rewrittenByAgent: rewritten)
    }

    private static func desktopChanged(_ paths: [WallpaperRecordPath]) -> String {
        "Desktop of " + list(paths) + " changed"
    }

    /// Record paths for a message: the first three, then how many more (a store has dozens).
    static func list(_ paths: [WallpaperRecordPath]) -> String {
        let shown = paths.prefix(3).map(\.description).joined(separator: ", ")
        return paths.count > 3 ? "\(shown) and \(paths.count - 3) more" : shown
    }

    // MARK: - Steps

    private func preflight(checkModulePolicy: Bool) throws {
        if let why = system.unavailability(forStoreAt: storeURL) { throw WallpaperStoreError.unavailable(why) }
        try recheck()
        if checkModulePolicy {
            if system.screenSaverModuleForced { throw WallpaperStoreError.moduleForcedByMDM }
            if system.wallpaperChangesDisabled { throw WallpaperStoreError.wallpaperChangesDisabledByMDM }
        }
        let version = system.storeMigrationVersion
        guard version == WallpaperApplyOptions.supportedStoreVersion else { throw WallpaperStoreError.unsupportedStoreVersion(version) }
        guard fileSignature() != nil else { throw WallpaperStoreError.storeMissing(storeURL.path) }
    }

    /// The facts that change from moment to moment, checked right before every write and agent
    /// restart: the session is unlocked and nothing that keeps its own copy of the settings (or
    /// shows a screen saver) is running.
    private func recheck() throws {
        switch system.sessionState {
        case .unlocked: break
        case .locked: throw WallpaperStoreError.sessionLocked
        case .unknown: throw WallpaperStoreError.sessionUnknown
        }
        if let process = system.conflictingProcesses().first { throw WallpaperStoreError.conflictingProcess(process) }
    }

    /// Identity of the store file: a new inode after every atomic write, plus size and mtime.
    struct FileSignature: Equatable {
        var inode: UInt64, size: Int64, seconds: Int, nanoseconds: Int
    }

    func fileSignature() -> FileSignature? {
        var info = stat()
        guard stat(storeURL.path, &info) == 0 else { return nil }
        return FileSignature(inode: UInt64(info.st_ino), size: Int64(info.st_size),
                             seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }

    /// Returns once the file has been unchanged for `quietInterval`; throws `.storeBusy` after `quietTimeout`.
    private func waitForQuiet() throws {
        let deadline = clock.now().addingTimeInterval(options.quietTimeout)
        var last = fileSignature()
        var stableSince = clock.now()
        while clock.now().timeIntervalSince(stableSince) < options.quietInterval {
            guard clock.now() < deadline else { throw WallpaperStoreError.storeBusy }
            clock.sleep(options.pollInterval)
            let current = fileSignature()
            if current != last { last = current; stableSince = clock.now() }
        }
    }

    /// True once the file is no longer the one LivePaper put in place (the restarted agent wrote it).
    private func waitForRewrite(differentFrom ours: FileSignature?) -> Bool {
        let deadline = clock.now().addingTimeInterval(options.rewriteTimeout)
        while clock.now() < deadline {
            if fileSignature() != ours { return true }
            clock.sleep(options.pollInterval)
        }
        return fileSignature() != ours
    }

    private func readStore() throws -> (Data, FileSignature?) {
        let before = fileSignature()
        guard before != nil, let data = FileManager.default.contents(atPath: storeURL.path) else {
            throw WallpaperStoreError.storeMissing(storeURL.path)
        }
        return (data, before)
    }

    /// Writes a temp file next to the store, flushes it, and rename(2)s it over the store — the same
    /// atomic replace WallpaperAgent itself does. Keeps the store's permission bits.
    func replaceStore(with data: Data) throws {
        let directory = storeURL.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(storeURL.lastPathComponent).livepaper-\(UUID().uuidString.prefix(8))")
        var info = stat()
        let mode = stat(storeURL.path, &info) == 0 ? mode_t(info.st_mode & 0o777) : 0o644
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw Self.posix("create \(temp.lastPathComponent)") }
        var ok = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; return false }
                offset += n
            }
            return true
        }
        ok = ok && fsync(fd) == 0
        close(fd)
        guard ok, rename(temp.path, storeURL.path) == 0 else {
            let error = Self.posix("replace \(storeURL.lastPathComponent)")
            unlink(temp.path)
            throw error
        }
    }

    // MARK: - Rollback

    /// Puts the bytes `written` replaced back and makes a restarted agent use them, through the same
    /// protections as the forward path: it waits (bounded) until the Mac is unlocked and System
    /// Settings closed, renames, restarts, waits for the agent's rewrite and confirms that the
    /// Desktop slots and the replaced Idle slots are as they were — retrying like the forward path
    /// (the old agent can write its in-memory model between the rename and the restart).
    ///
    /// - Returns: the error to throw: `.rolledBack(why)` once the previous store is confirmed back,
    ///   otherwise `.rollbackFailed`, naming the saved copy of the previous store.
    private func rollBack(_ written: Written, because why: String, restarts: inout Int) -> WallpaperStoreError {
        let undo = WallpaperStorePlan(changes: written.plan.changes.map {
            WallpaperSlotChange(path: $0.path, before: $0.after, after: $0.before, recordsOriginal: false)
        })
        var problem = "WallpaperAgent kept its own copy"
        rounds: for round in 1...(1 + max(0, options.maxRetries)) {
            if round > 1 { clock.sleep(options.retryDelay) }
            if let refusal = waitUntilSafeToRestart() { problem = refusal.localizedDescription; break rounds }
            try? waitForQuiet()
            do { try replaceStore(with: written.originalBytes) } catch { problem = error.localizedDescription; continue }
            let ours = fileSignature()
            do { try system.restartWallpaperAgent() } catch { problem = error.localizedDescription; continue }
            restarts += 1
            // No rewrite in time: the file still holds the previous bytes, which the agent read at launch.
            _ = waitForRewrite(differentFrom: ours)
            try? waitForQuiet()
            guard let (bytes, _) = try? readStore(), let after = try? WallpaperStoreDocument(data: bytes) else {
                problem = "the restarted WallpaperAgent wrote a store LivePaper can't read"
                continue
            }
            switch WallpaperStoreVerifier.confirm(current: after, original: written.original, plan: undo) {
            case .confirmed, .confirmedDefaultsRewritten: return .rolledBack(why)
            case .changeLost(let paths): problem = "WallpaperAgent overwrote " + Self.list(paths)
            case .desktopChanged(let paths): problem = Self.desktopChanged(paths)
            }
        }
        let copy = snapshotURL.map { "; the previous settings are saved in \($0.path)" } ?? ""
        return .rollbackFailed("\(why); then \(problem)\(copy)")
    }

    /// Waits up to `rollbackWaitTimeout` for `recheck()` to pass; returns the last refusal if it never does.
    private func waitUntilSafeToRestart() -> WallpaperStoreError? {
        let deadline = clock.now().addingTimeInterval(options.rollbackWaitTimeout)
        while true {
            do { try recheck(); return nil } catch let error as WallpaperStoreError {
                guard clock.now() < deadline else { return error }
            } catch { return .unavailable(error.localizedDescription) }
            clock.sleep(max(options.pollInterval, 0.5))
        }
    }

    private static func posix(_ what: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Couldn't \(what): \(String(cString: strerror(errno)))"])
    }
}
