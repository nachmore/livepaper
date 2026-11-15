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
//  2. Hold an exclusive lock file; wait until the store has been unchanged for ~1 s.
//  3. Read it; it must decode with WallpaperAgent's model (WallpaperStoreSchema). Plan the edit.
//  4. Back up (select: the raw file once, plus the per-slot manifest) — before writing anything.
//  5. Build the edited store and verify it (decodes; only the planned Idle slots differ; Desktop
//     slots byte-identical). The file must not have changed since step 3.
//  6. Atomic rename into place, then immediately restart WallpaperAgent (killall; launchd relaunches it).
//  7. Wait for the new agent's own rewrite, re-read and confirm: the planned Idle slots survived
//     and the Desktop slots are unchanged. Lost change → retry (≤ 2, 2 s apart); Desktop changed or
//     unreadable → put the bytes read in step 3 back, restart again, and report a rollback.
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

    public init(outcome: Outcome, changed: [WallpaperRecordPath] = [], attempts: Int = 1, agentRestarts: Int = 0) {
        self.outcome = outcome; self.changed = changed; self.attempts = attempts; self.agentRestarts = agentRestarts
    }
}

public final class WallpaperStoreApplier: @unchecked Sendable {
    public let storeURL: URL
    public let options: WallpaperApplyOptions
    private let system: WallpaperSystem
    private let clock: WallpaperClock
    private let lockURL: URL?

    /// - Parameter lockURL: exclusive lock file held for the whole sequence (nil: none).
    public init(storeURL: URL, system: WallpaperSystem, clock: WallpaperClock = SystemWallpaperClock(),
                options: WallpaperApplyOptions = WallpaperApplyOptions(), lockURL: URL? = nil) {
        self.storeURL = storeURL; self.system = system; self.clock = clock; self.options = options; self.lockURL = lockURL
    }

    // MARK: - Select / restore

    /// LIVE PATH. Makes `module` the screen saver for every display and Space. Before the store is
    /// written, the untouched file is copied to `rawBackupURL` (first time only) and the original of
    /// every replaced Idle slot is recorded in the manifest at `manifestURL`.
    public func select(_ module: WallpaperSaverModule, manifestURL: URL, rawBackupURL: URL) throws -> WallpaperApplyReport {
        let info = module.url.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: info.path) else { throw WallpaperStoreError.saverMissing(module.url.path) }
        return try apply(checkModulePolicy: true, plan: { [clock] document in
            try document.planSelect(module, at: clock.now())
        }, beforeWrite: { [clock] original, plan in
            if !FileManager.default.fileExists(atPath: rawBackupURL.path) { try FileOps.writeAtomically(original, to: rawBackupURL) }
            let now = clock.now()
            let manifest = try WallpaperSelectionManifest.load(from: manifestURL) ?? WallpaperSelectionManifest(module: module.moduleURLString, createdAt: now)
            try manifest.recording(plan, module: module, at: now).write(to: manifestURL)
        })
    }

    /// LIVE PATH. Puts back the recorded original of every Idle slot that still points at `module`
    /// (see `WallpaperStoreDocument.planRestore`), then deletes the manifest. No manifest: nothing
    /// to do. Call it before the `.saver` is removed.
    public func restore(_ module: WallpaperSaverModule, manifestURL: URL,
                        moduleExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) throws -> WallpaperApplyReport {
        guard let manifest = try WallpaperSelectionManifest.load(from: manifestURL) else { return WallpaperApplyReport(outcome: .unchanged) }
        let report = try apply(checkModulePolicy: false, plan: { [clock] document in
            try document.planRestore(manifest, module: module, at: clock.now(), moduleExists: moduleExists)
        })
        try FileOps.removeIfPresent(manifestURL)
        return report
    }

    // MARK: - The sequence

    /// Runs the full live sequence for an arbitrary plan (select/restore use it; tests use it to
    /// prove that a plan producing an invalid store is refused).
    ///
    /// - Parameters:
    ///   - checkModulePolicy: also refuse when MDM forces the screen-saver module or forbids
    ///     wallpaper changes (for selecting; undoing LivePaper's own change is always allowed).
    ///   - plan: computes the edit from the current store; an empty plan means nothing to do.
    ///   - beforeWrite: called with the store's current bytes and the plan right before the edited
    ///     store is put in place (backups).
    public func apply(checkModulePolicy: Bool, plan makePlan: (WallpaperStoreDocument) throws -> WallpaperStorePlan,
                      beforeWrite: ((Data, WallpaperStorePlan) throws -> Void)? = nil) throws -> WallpaperApplyReport {
        try preflight(checkModulePolicy: checkModulePolicy)
        guard let lockURL else { return try attempts(checkModulePolicy: checkModulePolicy, makePlan: makePlan, beforeWrite: beforeWrite) }
        return try FileLock.withLock(at: lockURL) {
            try attempts(checkModulePolicy: checkModulePolicy, makePlan: makePlan, beforeWrite: beforeWrite)
        }
    }

    /// What was written in the last round, for confirming it.
    private struct Written {
        var original: WallpaperStoreDocument
        var originalBytes: Data
        var plan: WallpaperStorePlan
    }

    private func attempts(checkModulePolicy: Bool, makePlan: (WallpaperStoreDocument) throws -> WallpaperStorePlan,
                          beforeWrite: ((Data, WallpaperStorePlan) throws -> Void)?) throws -> WallpaperApplyReport {
        var written: Written?
        var restarts = 0
        var lastProblem = "the store kept changing"
        for attempt in 1...(1 + max(0, options.maxRetries)) {
            do {
                if attempt > 1 {
                    clock.sleep(options.retryDelay)
                    try preflight(checkModulePolicy: checkModulePolicy)
                }
                try waitForQuiet()
                let (bytes, signature) = try readStore()
                let document = try WallpaperStoreDocument(data: bytes)
                let plan = try makePlan(document)
                if plan.isEmpty {
                    // Nothing to change — unless an earlier round's write is on disk unconfirmed
                    // (the agent didn't rewrite in time): then restart and confirm again below.
                    guard written != nil else { return WallpaperApplyReport(outcome: .unchanged, attempts: attempt, agentRestarts: restarts) }
                } else {
                    let edited = try document.applying(plan).data()
                    try WallpaperStoreVerifier.verify(edited: edited, original: document, plan: plan)
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
                    continue
                }
                try? waitForQuiet()
                let (afterBytes, _) = try readStore()
                guard let after = try? WallpaperStoreDocument(data: afterBytes) else {
                    restarts += rollBack(to: current.originalBytes)
                    throw WallpaperStoreError.rolledBack("the restarted WallpaperAgent wrote a store LivePaper can't read")
                }
                switch WallpaperStoreVerifier.confirm(current: after, original: current.original, plan: current.plan) {
                case .confirmed:
                    return WallpaperApplyReport(outcome: .applied, changed: current.plan.paths, attempts: attempt, agentRestarts: restarts)
                case .changeLost(let paths):
                    lastProblem = "WallpaperAgent overwrote " + paths.map(\.description).joined(separator: ", ")
                case .desktopChanged(let paths):
                    restarts += rollBack(to: current.originalBytes)
                    throw WallpaperStoreError.rolledBack("Desktop of " + paths.map(\.description).joined(separator: ", ") + " changed")
                }
            } catch let error as WallpaperStoreError where written != nil && !error.wroteStore {
                // A refusal after LivePaper already wrote: the change is on disk but unconfirmed.
                throw WallpaperStoreError.notConfirmed(error.localizedDescription)
            }
        }
        throw written == nil ? WallpaperStoreError.storeBusy : WallpaperStoreError.notConfirmed(lastProblem)
    }

    // MARK: - Steps

    private func preflight(checkModulePolicy: Bool) throws {
        if let why = system.unavailability(forStoreAt: storeURL) { throw WallpaperStoreError.unavailable(why) }
        switch system.sessionState {
        case .unlocked: break
        case .locked: throw WallpaperStoreError.sessionLocked
        case .unknown: throw WallpaperStoreError.sessionUnknown
        }
        if let process = system.conflictingProcesses().first { throw WallpaperStoreError.conflictingProcess(process) }
        if checkModulePolicy {
            if system.screenSaverModuleForced { throw WallpaperStoreError.moduleForcedByMDM }
            if system.wallpaperChangesDisabled { throw WallpaperStoreError.wallpaperChangesDisabledByMDM }
        }
        let version = system.storeMigrationVersion
        guard version == WallpaperApplyOptions.supportedStoreVersion else { throw WallpaperStoreError.unsupportedStoreVersion(version) }
        guard fileSignature() != nil else { throw WallpaperStoreError.storeMissing(storeURL.path) }
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

    /// Best effort: puts `bytes` back and restarts the agent so it uses them. Returns the number of
    /// restarts performed (0 or 1).
    private func rollBack(to bytes: Data) -> Int {
        guard (try? replaceStore(with: bytes)) != nil, (try? system.restartWallpaperAgent()) != nil else { return 0 }
        return 1
    }

    private static func posix(_ what: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Couldn't \(what): \(String(cString: strerror(errno)))"])
    }
}
