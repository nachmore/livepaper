// InstallService — InstallServicing: puts the saver and helper in place, reports system state,
// and undoes everything on uninstall (ARCHITECTURE §11, onboarding / uninstall).
//
// Every location is injectable (InstallPaths) and every system command goes through a
// CommandRunning, so the whole service runs against temp directories with recorded commands. In
// dry-run mode nothing is written and no command that changes anything is run; each step is only
// recorded in `transcript`.
import Darwin
import Foundation
import os

/// Where the installer reads and writes.
public struct InstallPaths: Sendable, Equatable {
    /// The template saver bundle shipped in the app (Contents/Resources/LivePaper.saver).
    public var saverTemplate: URL
    /// ~/Library/Screen Savers.
    public var screenSaversDir: URL
    /// ~/Library/LaunchAgents (only used by the helper fallback).
    public var launchAgentsDir: URL
    public var wallpaperStore: URL
    public var supportRoot: URL
    /// Contents/Helpers/LivePaperHelper of the app.
    public var helperExecutable: URL
    /// Configuration-profile copies of com.apple.screensaver, in override order.
    public var managedPreferences: [URL]
    /// A screen saver that ships with macOS: what uninstall selects where LivePaper is the screen
    /// saver but no earlier choice is known (WallpaperRestoreFallback).
    public var builtinScreenSaver: URL
    /// Where an installed LivePaper.app lives (/Applications, ~/Applications): without a record of
    /// which copy registered the helper, only a copy in one of these repairs it by itself.
    public var applicationsDirs: [URL]

    public init(saverTemplate: URL, screenSaversDir: URL, launchAgentsDir: URL, wallpaperStore: URL, supportRoot: URL,
                helperExecutable: URL, managedPreferences: [URL], builtinScreenSaver: URL = WallpaperRestoreFallback.systemSaverURL,
                applicationsDirs: [URL] = InstallPaths.defaultApplicationsDirs) {
        self.saverTemplate = saverTemplate; self.screenSaversDir = screenSaversDir; self.launchAgentsDir = launchAgentsDir
        self.wallpaperStore = wallpaperStore; self.supportRoot = supportRoot; self.helperExecutable = helperExecutable
        self.managedPreferences = managedPreferences; self.builtinScreenSaver = builtinScreenSaver
        self.applicationsDirs = applicationsDirs
    }

    public static var defaultApplicationsDirs: [URL] {
        [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    /// The real locations (honouring the LIVEPAPER_* overrides, plus LIVEPAPER_LAUNCH_AGENTS_DIR).
    public static func current() -> InstallPaths {
        let env = ProcessInfo.processInfo.environment
        let agents = env["LIVEPAPER_LAUNCH_AGENTS_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? LPPaths.home.appendingPathComponent("Library/LaunchAgents")
        return InstallPaths(
            saverTemplate: LPPaths.appResources.appendingPathComponent(LPPaths.saverName),
            screenSaversDir: LPPaths.screenSaversDir,
            launchAgentsDir: agents,
            wallpaperStore: LPPaths.wallpaperStore,
            supportRoot: LPPaths.supportRoot,
            helperExecutable: LPPaths.appResources.deletingLastPathComponent().appendingPathComponent("Helpers/LivePaperHelper"),
            managedPreferences: SystemProbes.managedScreenSaverPreferences())
    }

    public var installedSaver: URL { screenSaversDir.appendingPathComponent(LPPaths.saverName) }
    public var installedPlaylist: URL { installedSaver.appendingPathComponent("Contents/Resources").appendingPathComponent(LPPlaylist.directoryName) }
    public var backups: URL { supportRoot.appendingPathComponent("backups") }
    /// Copy of the wallpaper store taken before LivePaper first changed the selection (kept for
    /// manual recovery; restore never puts the whole file back).
    public var wallpaperStoreBackup: URL { backups.appendingPathComponent("wallpaper-store-Index.plist") }
    /// The Idle slots LivePaper replaced, with their originals (WallpaperSelectionManifest, JSON):
    /// what uninstall restores. Also written (without slots) when LivePaper finds itself already
    /// selected, e.g. picked by hand in System Settings.
    public var wallpaperSelectionBackup: URL { backups.appendingPathComponent("wallpaper-selection.json") }
    /// The exact store bytes LivePaper replaced most recently (select or restore), saved right before
    /// each write: what to recover from by hand if a rollback can't be confirmed.
    public var wallpaperStoreSnapshot: URL { backups.appendingPathComponent("wallpaper-store-before-last-change.plist") }
    /// Held while LivePaper edits the wallpaper store, so two LivePaper processes never race.
    public var wallpaperStoreLock: URL { supportRoot.appendingPathComponent("wallpaper-store.lock") }
    /// Previous values of system preferences LivePaper changed.
    public var defaultsBackup: URL { backups.appendingPathComponent("changed-defaults.json") }
    /// The helper's LaunchAgent fallback (its own label, never the login item's).
    public var fallbackAgentPlist: URL { launchAgentsDir.appendingPathComponent("\(LaunchAgentPlist.label).plist") }
    /// Where versions before the separate label put the fallback (the login item's label).
    public var legacyAgentPlist: URL { launchAgentsDir.appendingPathComponent("\(LaunchAgentPlist.legacyLabel).plist") }
    /// Records that the app bundle fell back to the LaunchAgent because SMAppService refused, so
    /// later registrations keep to that choice instead of registering a login item next to it.
    public var helperLaunchChoice: URL { supportRoot.appendingPathComponent("helper-launch.json") }
    /// Which copy of LivePaper registered the helper's login item, and whether a re-registration is
    /// still to finish (HelperRegistrationRecord).
    public var helperRegistration: URL { supportRoot.appendingPathComponent("helper-registration.json") }
    /// The app bundle the helper belongs to (…/LivePaper.app for …/LivePaper.app/Contents/Helpers/LivePaperHelper).
    public var appBundle: URL {
        helperExecutable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    /// Written by uninstall, outside the support directory (LPPaths.uninstallMarker for the real
    /// locations): a helper that finds it exits at launch, so a login item this process couldn't
    /// unregister can't bring LivePaper back. Installing again removes it.
    public var uninstallMarker: URL { supportRoot.deletingLastPathComponent().appendingPathComponent("LivePaper.uninstalled") }
    /// Shared with PublishService so installing never copies a playlist that is being swapped.
    public var publishLock: URL { supportRoot.appendingPathComponent("publish.lock") }
}

public enum InstallError: Error, LocalizedError, Sendable, Equatable {
    case saverTemplateMissing(String)
    case helperMissing(String)
    case commandFailed(String, String)
    case uninstallIncomplete([String])
    /// The user switched the helper off in System Settings › General › Login Items.
    case helperDeniedByUser
    /// launchd can't start the helper (what it reports, and what LivePaper tried).
    case helperCannotStart(String)
    /// launchd started the helper's job, but no helper runs and nothing says why (what was seen).
    /// LivePaper doesn't register it again on no evidence.
    case helperNotRunning(String)
    /// Uninstall couldn't switch the screen saver away from LivePaper (the reason), so it keeps
    /// LivePaper.saver: the store must never point at a deleted module.
    case screenSaverStillSelected(String)
    /// Uninstall wrote the previous screen-saver choice back but couldn't confirm that the displays
    /// show it (why; the previous saver's name, when known).
    case screenSaverNotRestored(String, previous: String?)

    public var errorDescription: String? {
        switch self {
        case .saverTemplateMissing(let p): return "LivePaper's screen saver is missing from the app (\(p)). Reinstall LivePaper."
        case .helperMissing(let p): return "LivePaper's helper is missing from the app (\(p)). Reinstall LivePaper."
        case .commandFailed(let cmd, let detail): return "\(cmd) failed: \(detail)"
        case .uninstallIncomplete(let steps): return "Uninstall couldn't finish: " + steps.joined(separator: "; ")
        case .helperDeniedByUser:
            return "LivePaper's helper is switched off in System Settings › General › Login Items. Switch it on there."
        case .helperCannotStart(let detail):
            return "macOS can't start LivePaper's helper (\(detail)). Switch LivePaper off and on again in System Settings › " +
                   "General › Login Items, or log out and back in."
        case .helperNotRunning(let detail):
            return "LivePaper's helper doesn't stay running (\(detail)). Try Start Helper again; if it still doesn't run, log " +
                   "out and back in."
        case .screenSaverStillSelected(let why):
            return "LivePaper is still your screen saver (\(why)). Choose another screen saver in System Settings › Wallpaper › " +
                   "Screen Saver, then run uninstall again; until then LivePaper keeps its screen saver and backups."
        case .screenSaverNotRestored(let why, let previous):
            let pick = previous.map { "Before LivePaper it was \u{201C}\($0)\u{201D}: pick it again in System Settings › Wallpaper › Screen Saver" }
                ?? "Pick the screen saver you want in System Settings › Wallpaper › Screen Saver"
            return "LivePaper couldn't confirm that your previous screen saver is back (\(why)). \(pick), then run uninstall " +
                   "again; until then LivePaper keeps its screen saver and backups."
        }
    }
}

/// A preference LivePaper changed, with the value to put back on uninstall.
public struct DefaultsChange: Codable, Sendable, Equatable {
    public var domain: String
    public var key: String
    public var currentHost: Bool
    /// Binary plist of `["value": previous]`, or nil when the key wasn't set before.
    public var previous: Data?
}

/// Reads and writes user preferences (CFPreferences), behind a protocol for tests.
public protocol PreferencesAccessing: Sendable {
    func value(domain: String, key: String, currentHost: Bool) -> Any?
    /// nil removes the key. Returns false if the value couldn't be stored.
    func set(_ value: Any?, domain: String, key: String, currentHost: Bool) -> Bool
    /// The value a configuration profile forces for `key` (`CFPreferencesAppValueIsForced`), or nil
    /// when the user may change it. Read-only.
    func forcedValue(domain: String, key: String) -> Any?
}

extension PreferencesAccessing {
    /// Stand-ins know of no configuration profile unless they say so.
    public func forcedValue(domain: String, key: String) -> Any? { nil }
}

/// CFPreferences for the current user; goes through cfprefsd, like `defaults`.
public struct SystemPreferences: PreferencesAccessing {
    public init() {}
    public func value(domain: String, key: String, currentHost: Bool) -> Any? {
        CFPreferencesCopyValue(key as CFString, domain as CFString, kCFPreferencesCurrentUser, Self.host(currentHost))
    }
    public func set(_ value: Any?, domain: String, key: String, currentHost: Bool) -> Bool {
        CFPreferencesSetValue(key as CFString, value as CFPropertyList?, domain as CFString, kCFPreferencesCurrentUser, Self.host(currentHost))
        return CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, Self.host(currentHost))
    }
    public func forcedValue(domain: String, key: String) -> Any? {
        guard CFPreferencesAppValueIsForced(key as CFString, domain as CFString) else { return nil }
        // Forced values win over the user's, so the app-level lookup returns the profile's value.
        return CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }
    private static func host(_ current: Bool) -> CFString { current ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost }
}

public final class InstallService: InstallServicing, @unchecked Sendable {
    public let paths: InstallPaths
    public let dryRun: Bool
    private let publisher: PublishServicing?
    private let runner: CommandRunning
    private let loginItem: LoginItemRegistering
    private let preferences: PreferencesAccessing
    private let uid: uid_t
    private let osMajorVersion: Int
    private let store: WallpaperStore
    private let wallpaperSystem: WallpaperSystem
    private let wallpaperClock: WallpaperClock
    private let wallpaperOptions: WallpaperApplyOptions
    private let probe: HelperProcessProbing
    private let readScreenTimers: @Sendable () -> LPScreenTimers
    private let helperStartTimeout: TimeInterval
    private let helperRegisterTimeout: TimeInterval
    private let lock = NSRecursiveLock()
    private var steps: [InstallStep] = []
    private let log = Logger(subsystem: LPPaths.bundleID, category: "install")

    /// - Parameters:
    ///   - publisher: publishes content after installSaver (nil: don't publish).
    ///   - dryRun: record every step instead of performing it.
    ///   - wallpaperSystem: what selecting / restoring the screen saver may do to the running Mac.
    ///     nil: the live system (it restarts WallpaperAgent) when `runner` really runs commands, and
    ///     one that refuses everything when commands are only recorded.
    ///   - wallpaperClock, wallpaperOptions: the timings of the store applier (tests: a fake clock).
    ///   - probe: what the helper's process runs and how helpers are signed (HelperProbe).
    ///   - helperStartTimeout: how long starting the helper waits for it to run (0: look once).
    ///   - helperRegisterTimeout: how long registering the helper again waits for launchd to have and
    ///     run its job (smd submits it asynchronously), and for a late unregister to finish (0: look once).
    ///   - screenTimers: reads the display-sleep timers and the screen saver's idle time for the status.
    ///     nil: the live system (LPPowerProbe: `pmset -g custom`, `preferences`, IOKit) when `runner`
    ///     really runs commands, and "unknown" when commands are only recorded.
    public init(paths: InstallPaths = .current(), publisher: PublishServicing?, runner: CommandRunning = SystemCommandRunner(),
                loginItem: LoginItemRegistering = SMAppServiceAgent(), preferences: PreferencesAccessing = SystemPreferences(),
                dryRun: Bool = false,
                uid: uid_t = getuid(), osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                wallpaperSystem: WallpaperSystem? = nil, wallpaperClock: WallpaperClock = SystemWallpaperClock(),
                wallpaperOptions: WallpaperApplyOptions = WallpaperApplyOptions(),
                probe: HelperProcessProbing = SystemHelperProbe(), helperStartTimeout: TimeInterval = 3,
                helperRegisterTimeout: TimeInterval = 10, screenTimers: (@Sendable () -> LPScreenTimers)? = nil) {
        self.paths = paths; self.publisher = publisher; self.runner = runner; self.loginItem = loginItem
        self.preferences = preferences; self.dryRun = dryRun; self.uid = uid
        self.osMajorVersion = osMajorVersion
        self.store = WallpaperStore(url: paths.wallpaperStore, saver: paths.installedSaver)
        self.wallpaperSystem = wallpaperSystem ?? (runner is SystemCommandRunner
            ? LiveWallpaperSystem(storeURL: paths.wallpaperStore, runner: runner)
            : UnavailableWallpaperSystem(reason: "system commands are only recorded"))
        self.wallpaperClock = wallpaperClock
        self.wallpaperOptions = wallpaperOptions
        self.probe = probe
        if let screenTimers {
            self.readScreenTimers = screenTimers
        } else if runner is SystemCommandRunner {
            let powerProbe = LPPowerProbe(runner: runner, preferences: preferences, managedPreferences: paths.managedPreferences)
            self.readScreenTimers = { powerProbe.screenTimers() }
        } else {
            self.readScreenTimers = { LPScreenTimers() }
        }
        self.helperStartTimeout = helperStartTimeout
        self.helperRegisterTimeout = helperRegisterTimeout
    }

    /// Every step performed (or, in a dry run, planned) by this instance, oldest first.
    public var transcript: [InstallStep] { lock.withLock { steps } }

    private var guiDomain: String { "gui/\(uid)" }
    /// The login item's job.
    private var helperService: String { "\(guiDomain)/\(LPPaths.helperLabel)" }
    /// The LaunchAgent fallback's job.
    private var fallbackService: String { "\(guiDomain)/\(LaunchAgentPlist.label)" }

    // MARK: - Status

    /// Blocking (runs `sysadminctl`, `launchctl print` and `pmset -g custom`, all read-only, ≤ 10 s
    /// each, and checks the running helper's code signature): call it off the main thread.
    public func status() -> InstallStatus {
        let installedVersion = FileOps.bundleInfo(paths.installedSaver, "CFBundleVersion")
        let templateVersion = FileOps.bundleInfo(paths.saverTemplate, "CFBundleVersion")
        let installed = FileOps.isRegularFile(paths.installedSaver.appendingPathComponent("Contents/Info.plist"))
        let managed = SystemProbes.managedSettings(paths.managedPreferences)
        let sysadminctl = try? runner.run("/usr/sbin/sysadminctl", ["-screenLock", "status"], timeout: 10)
        let loginJob = lookup(helperService), fallbackJob = lookup(fallbackService)
        let helperRunning = [loginJob, fallbackJob].contains { runningHelper($0) != nil }
        let loginItemStatus = loginItem.status
        let immediate = SystemProbes.passwordImmediately(sysadminctlOutput: sysadminctl?.combinedOutput, managed: managed)
        // Without a template (development builds) there is nothing newer to install.
        let upToDate = installed && (templateVersion == nil || installedVersion == templateVersion)
        return InstallStatus(
            saverInstalled: installed,
            saverUpToDate: upToDate,
            saverNewerInstalled: installed && !upToDate && Self.isNewerBuild(installedVersion, than: templateVersion),
            saverSelection: store.selectionState(connectedDisplays: wallpaperSystem.connectedDisplayIDs),
            selectionReapplyNeeded: selectionReapplyBlocker() == nil,
            helperRunning: helperRunning,
            helperLoginItem: loginItemStatus,
            helperProblem: helperAssessment(loginItem: loginItemStatus, loginJob: loginJob, fallbackJob: fallbackJob)?.problem,
            passwordImmediately: immediate,
            managedByMDM: SystemProbes.isManaged(managed),
            passwordManagedByMDM: !immediate && SystemProbes.passwordEnforcedNotImmediately(
                SystemProbes.enforcedPasswordSettings(managed: managed) {
                    preferences.forcedValue(domain: SystemProbes.screenSaverDomain, key: $0)
                }),
            lockKeysShowScene: lockKeysShowScene,
            lockKeysChangedByLivePaper: loadDefaultsChanges().contains(where: Self.isLockKeysChange),
            screenTimers: readScreenTimers())
    }

    // MARK: - Saver

    /// `build` is a later build than `other`. CFBundleVersion is the commit count
    /// (scripts/build.sh), so the higher number is the newer build; values that aren't whole
    /// numbers don't compare (neither is newer).
    public static func isNewerBuild(_ build: String?, than other: String?) -> Bool {
        func number(_ v: String?) -> Int? { v.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        guard let a = number(build), let b = number(other) else { return false }
        return a > b
    }

    /// Copies the template saver into ~/Library/Screen Savers, keeping the published Playlist of an
    /// existing install, swaps it in atomically, then publishes. The screen-saver host keeps any
    /// already-loaded copy until it next starts; LivePaper never kills system processes. An
    /// explicit install: whatever build is installed is replaced, and the uninstall marker goes.
    @discardableResult public func installSaver() throws -> PublishResult? {
        try requireTemplate("Install the screen saver")
        try clearUninstallMarker()
        _ = try replaceSaver("Install the screen saver into \(paths.screenSaversDir.path)", unless: { nil })
        return try publishIntoSaver()
    }

    /// The launch-time update (AppModel, after the app itself was updated): the saver's code lives
    /// in ~/Library/Screen Savers, not in the app, so the installed copy is replaced with the
    /// bundled one — but only by a newer build (an older LivePaper launched next to a newer one
    /// leaves the newer saver alone), only while one is installed, never after an uninstall (the
    /// marker stays; only setting LivePaper up again removes it) and never while
    /// `isSessionLocked()`. Everything is checked again while holding publish.lock right before
    /// the swap, so a lock, a publish or an uninstall (which removes the bundle under the same lock)
    /// in the meantime can't be overrun. The playlist is then republished from the current
    /// settings and library, and the report says which scenes that left out.
    public func updateSaver(isSessionLocked: () -> Bool) throws -> SaverUpdateOutcome {
        let title = "Update the screen saver in \(paths.screenSaversDir.path)"
        func blocker() -> String? { saverUpdateBlocker() ?? (isSessionLocked() ? SaverUpdateOutcome.sessionLockedReason : nil) }
        if let why = blocker() {
            record(title, .skipped(why))
            return .skipped(why)
        }
        try requireTemplate(title)
        if let why = try replaceSaver(title, unless: blocker) { return .skipped(why) }
        return .updated(try publishIntoSaver())
    }

    /// Why the launch-time update must leave the installed saver alone (nil: it may replace it).
    private func saverUpdateBlocker() -> String? {
        if FileOps.entryExists(paths.uninstallMarker) { return "LivePaper was uninstalled; setting it up again installs the screen saver" }
        guard FileOps.isRegularFile(paths.installedSaver.appendingPathComponent("Contents/Info.plist")) else { return "not installed" }
        let installed = FileOps.bundleInfo(paths.installedSaver, "CFBundleVersion")
        let bundled = FileOps.bundleInfo(paths.saverTemplate, "CFBundleVersion")
        if bundled == nil || installed == bundled { return "already this build" }
        if Self.isNewerBuild(installed, than: bundled) {
            return "a newer build is installed (build \(installed ?? "?"); this LivePaper has \(bundled ?? "?"))"
        }
        return nil
    }

    private func requireTemplate(_ title: String) throws {
        let template = paths.saverTemplate
        guard FileOps.isRegularFile(template.appendingPathComponent("Contents/Info.plist")) else {
            record(title, .failed("template missing"))
            throw InstallError.saverTemplateMissing(template.path)
        }
    }

    /// Stages a copy of the template (with the installed Playlist) and swaps it in, under
    /// publish.lock. `blocker` is asked after taking the lock and again right before the swap;
    /// a reason stops it with nothing changed (recorded as skipped and returned).
    private func replaceSaver(_ title: String, unless blocker: () -> String?) throws -> String? {
        var stopped: String?
        try perform(title) {
            let fm = FileManager.default
            try fm.createDirectory(at: paths.screenSaversDir, withIntermediateDirectories: true)
            return try FileLock.withLock(at: paths.publishLock) { () -> String? in
                if let why = blocker() { stopped = why; return why }
                // Hidden and without the .saver extension: never listed as a screen saver.
                let staging = FileOps.stagingURL(in: paths.screenSaversDir, tag: "install")
                do {
                    try fm.copyItem(at: paths.saverTemplate, to: staging)
                    // A downloaded app's resources carry the quarantine flag; the saver host refuses those.
                    FileOps.stripQuarantine(staging)
                    let playlist = staging.appendingPathComponent("Contents/Resources").appendingPathComponent(LPPlaylist.directoryName)
                    if FileOps.isDirectory(paths.installedPlaylist) {
                        try FileOps.removeIfPresent(playlist)
                        try fm.createDirectory(at: playlist.deletingLastPathComponent(), withIntermediateDirectories: true)
                        // APFS clones the files, so even large videos cost no time or space.
                        try fm.copyItem(at: paths.installedPlaylist, to: playlist)
                    }
                    if let why = blocker() {
                        try? FileOps.removeIfPresent(staging)
                        stopped = why
                        return why
                    }
                    try FileOps.installReplacing(paths.installedSaver, with: staging)
                } catch {
                    try? FileOps.removeIfPresent(staging)
                    throw error
                }
                return nil
            }
        }
        return stopped
    }

    /// Publishes into the freshly installed saver; an empty library isn't a failure.
    private func publishIntoSaver() throws -> PublishResult? {
        guard let publisher else { return nil }
        var result: PublishResult?
        try perform("Publish scenes into the screen saver") {
            do { result = try publisher.publishReport() } catch PublishError.noScenes { return "no scenes yet" }
            return nil
        }
        return result
    }

    /// Makes LivePaper the screen saver for every display and Space by editing the wallpaper store
    /// and restarting WallpaperAgent (WallpaperStoreApplier; only ever on an explicit user action —
    /// the app's quiet re-apply is `reapplySelectionIfNeeded`, which only fills placeholders):
    /// SystemDefault, every explicit Idle slot and the placeholder Idle slot of every display record
    /// (`WallpaperSelectScope.everyDisplay`). The original of every replaced Idle slot is recorded in
    /// backups/ first. A SystemDefault the restarted agent wrote its own choice into is accepted while
    /// every display resolves to LivePaper (and noted, so uninstall still restores it).
    ///
    /// - Returns: true only when the selection is in place and confirmed after the agent restarted
    ///   (or already was). false when LivePaper refused to touch the store — locked, System
    ///   Settings open, MDM, an unknown store format, … (the reason is in the transcript) — so the UI
    ///   shows the guided step.
    /// - Throws: when the store was written but the change couldn't be confirmed or was rolled back.
    public func selectSaver() throws -> Bool {
        let title = "Select LivePaper as the screen saver"
        // Nothing to change: every display record already shows this LivePaper.saver from a
        // display's own record (a SystemDefault the agent kept its placeholder in doesn't matter).
        // System Settings' own selection — display placeholders inheriting SystemDefault — gets the
        // placeholders filled: WallpaperAgent copies them into SystemDefault at its next launch.
        // A selection of LivePaper.saver at another location still gets rewritten.
        if let document = try? store.read(),
           document.isCurrentChoiceOnEveryDisplay(store.module) || (try? document.planSelect(store.module, at: Date()))?.isEmpty == true {
            if !dryRun { recordSelectionOwnership() }
            record(title, .skipped("already selected"))
            return true
        }
        if dryRun { record(title, .planned); return false }
        do {
            let report = try wallpaperApplier.select(store.module, manifestURL: paths.wallpaperSelectionBackup,
                                                     rawBackupURL: paths.wallpaperStoreBackup)
            if report.outcome == .applied {
                log.notice("selected LivePaper in \(report.changed.count, privacy: .public) Idle slot(s) after \(report.attempts, privacy: .public) attempt(s)")
                if !report.rewrittenByAgent.isEmpty {
                    log.notice("WallpaperAgent kept its own choice in \(report.rewrittenByAgent.map(\.description).joined(separator: ", "), privacy: .public); every display uses LivePaper")
                }
                record(title, .done)
            } else {
                recordSelectionOwnership()
                record(title, .skipped("already selected"))
            }
            return true
        } catch let error as WallpaperStoreError where !error.wroteStore {
            record(title, .skipped("needs the guided step in System Settings: \(error.localizedDescription)"))
            return false
        } catch {
            record(title, .failed(error.localizedDescription))
            throw error
        }
    }

    public static let reapplySelectionTitle = "Select LivePaper for the displays that fell back to macOS\u{2019}s default screen saver"

    /// The app's quiet re-apply (InstallServicing.reapplySelectionIfNeeded): only while LivePaper owns
    /// the selection — its manifest exists (LivePaper made the selection, or found itself selected
    /// and recorded that) — the saver is installed, LivePaper wasn't uninstalled and is still chosen
    /// in some Idle slot; then only the placeholder Idle slots of display records that show macOS's
    /// default screen saver or inherit LivePaper from SystemDefault or a Space's Default, and
    /// SystemDefault's placeholder with them (`WallpaperSelectScope.placeholdersOnly`), each original
    /// recorded for uninstall unless one is recorded already. The uninstall marker, the manifest and
    /// the saver are checked again while holding the store lock (an uninstall in another process may
    /// have started meanwhile). A refusal (locked, System Settings open, …) is an outcome, not an error.
    public func reapplySelectionIfNeeded() throws -> SelectionReapplyOutcome {
        let title = Self.reapplySelectionTitle
        if let why = selectionReapplyBlocker() { return .notNeeded(why) }
        if dryRun { record(title, .planned); return .notNeeded("dry run") }
        do {
            let report = try wallpaperApplier.select(store.module, manifestURL: paths.wallpaperSelectionBackup,
                                                     rawBackupURL: paths.wallpaperStoreBackup, scope: .placeholdersOnly,
                                                     stopIf: { [self] in selectionOwnershipLost() })
            guard report.outcome == .applied else { return .notNeeded("every display already resolves to LivePaper or a screen saver you chose") }
            let displays = Set(report.changed.compactMap(\.displayID)).count
            log.notice("re-applied LivePaper on \(displays, privacy: .public) display(s) that fell back to macOS's default screen saver")
            record(title, .done)
            return .reapplied(displays: displays)
        } catch WallpaperStoreError.stopped(let why) {
            record(title, .skipped(why))
            return .notNeeded(why)
        } catch let error as WallpaperStoreError where !error.wroteStore {
            record(title, .skipped(error.localizedDescription))
            return .refused(error.localizedDescription)
        } catch {
            record(title, .failed(error.localizedDescription))
            throw error
        }
    }

    /// Why the quiet re-apply has nothing to do (nil: some display needs it).
    private func selectionReapplyBlocker() -> String? {
        if let why = selectionOwnershipLost() { return why }
        guard FileOps.isRegularFile(paths.installedSaver.appendingPathComponent("Contents/Info.plist")) else { return "the screen saver isn't installed" }
        guard let document = try? store.read() else { return "the wallpaper settings can't be read" }
        guard document.selection(of: store.module).isSelected else {
            return "LivePaper isn\u{2019}t chosen for any display any more (selecting it again is up to you)"
        }
        guard let plan = try? document.planSelect(store.module, at: Date(), scope: .placeholdersOnly), !plan.isEmpty else {
            return "no display falls back to macOS\u{2019}s default screen saver"
        }
        return nil
    }

    /// Why LivePaper doesn't own the selection (nil: it does): it was uninstalled, or it has no
    /// manifest. Also asked while holding the store lock, right before the re-apply plans and writes.
    private func selectionOwnershipLost() -> String? {
        if FileOps.entryExists(paths.uninstallMarker) { return "LivePaper was uninstalled" }
        guard FileOps.entryExists(paths.wallpaperSelectionBackup) else { return "LivePaper didn't make the selection" }
        return nil
    }

    /// Runs the live store sequence (WallpaperStoreApplier) with this installer's system and timings.
    private var wallpaperApplier: WallpaperStoreApplier {
        store.applier(system: wallpaperSystem, clock: wallpaperClock, options: wallpaperOptions, lockURL: paths.wallpaperStoreLock,
                      snapshotURL: paths.wallpaperStoreSnapshot)
    }

    /// LivePaper is the selected screen saver without having written the store (picked by hand in
    /// System Settings): leave a manifest without originals, so the backups say that LivePaper owns
    /// those slots (uninstall finds them in the store either way). Best effort.
    private func recordSelectionOwnership() {
        guard !FileOps.entryExists(paths.wallpaperSelectionBackup) else { return }
        do {
            try WallpaperSelectionManifest(module: store.module.moduleURLString, createdAt: Date()).write(to: paths.wallpaperSelectionBackup)
        } catch {
            log.error("couldn't record the screen-saver selection: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helper

    /// The login item's state (e.g. `.requiresApproval` → onboarding points the user to System
    /// Settings › General › Login Items). `.notFound` when running outside the app bundle.
    public var helperLoginItemStatus: LoginItemStatus { loginItem.status }

    /// Registers the helper as a login item (SMAppService) and makes sure it runs, falling back to a
    /// LaunchAgent plist (its own label) when the process isn't the app bundle or SMAppService refuses
    /// for good. Idempotent; "Start Helper" / "Repair Helper" call it — the user's request, so unlike
    /// recoverHelper it also takes the helper over from another copy of LivePaper:
    /// * login item enabled: make its job run this build's helper (`runRegisteredHelper`: start it,
    ///   or register it again when launchd can't run this build's helper);
    /// * waiting for approval / switched off by the user: nothing LivePaper can do — the user allows
    ///   it in System Settings › General › Login Items (no fallback: that would bypass their choice);
    /// * SMAppService fails otherwise: the LaunchAgent, and that choice is remembered
    ///   (`helperLaunchChoice`) so later calls don't register a login item next to it.
    public func registerHelper() throws {
        try clearUninstallMarker()
        // Earlier versions' fallback plist used the login item's own label.
        if FileOps.entryExists(paths.legacyAgentPlist) {
            try stopHelperJobs(only: [helperService])
            try perform("Remove the old helper LaunchAgent plist") { try FileManager.default.removeItem(at: paths.legacyAgentPlist); return nil }
        }
        guard loginItem.isAvailable, !FileOps.entryExists(paths.helperLaunchChoice) else {
            try installFallbackAgent()
            return
        }
        // A fallback left by an unbundled (development) build: the app bundle uses its login item.
        if FileOps.entryExists(paths.fallbackAgentPlist) {
            try stopHelperJobs(only: [fallbackService])
            try removeFallbackAgent()
        }
        switch loginItem.status {
        case .enabled:
            _ = try runRegisteredHelper(automatic: false)
            return
        case .requiresApproval:
            record("Register the helper as a login item", .skipped("waiting for approval in System Settings › General › Login Items"))
            return
        case .notRegistered, .notFound:
            break
        }
        let title = "Register the helper as a login item"
        if dryRun { record(title, .planned); return }
        do {
            let status = try loginItem.register()
            saveRegistrationRecord()
            record(title, .done)
            if status == .requiresApproval { log.notice("helper needs approval in System Settings › General › Login Items") }
            return
        } catch {
            switch LoginItemRegistrationFailure(error) {
            case .alreadyRegistered:
                record(title, .skipped("already registered"))
                _ = try runRegisteredHelper(automatic: false)
                return
            case .deniedByUser:
                record(title, .failed(InstallError.helperDeniedByUser.localizedDescription))
                throw InstallError.helperDeniedByUser
            case .other:
                record(title, .skipped("SMAppService refused (\(error.localizedDescription)); using a LaunchAgent"))
                log.error("SMAppService registration failed, using a LaunchAgent: \(error.localizedDescription, privacy: .public)")
            }
        }
        try installFallbackAgent()
        try perform("Remember to use the helper LaunchAgent") {
            let choice = ["launchAgent": true, "since": ISO8601DateFormatter().string(from: Date())] as [String: Any]
            try FileOps.writeAtomically(try JSONSerialization.data(withJSONObject: choice, options: [.prettyPrinted, .sortedKeys]),
                                        to: paths.helperLaunchChoice)
            return nil
        }
        // The login item isn't LivePaper's helper any more; nothing is left to register again.
        clearRegistrationRecord()
    }

    /// The app's automatic repair (InstallServicing.recoverHelper; at most once per launch): makes the
    /// job of a helper that is set up run this build's helper — the login item's
    /// (`runRegisteredHelper`), or the LaunchAgent fallback's (written again and bootstrapped) — but
    /// only from the copy of LivePaper the helper belongs to (`automaticRepairBlocker`). Leaves alone
    /// what the user hasn't set up, a login item waiting for approval, and an uninstall. A login item
    /// that LivePaper unregistered to register it again, without that finishing, is registered again.
    public func recoverHelper() throws -> HelperRecoveryOutcome {
        func notNeeded(_ why: String) -> HelperRecoveryOutcome {
            record(Self.recoverHelperTitle, .skipped(why))
            return .notNeeded(why)
        }
        if FileOps.entryExists(paths.uninstallMarker) { return notNeeded("LivePaper was uninstalled") }
        if !loginItem.isAvailable || FileOps.entryExists(paths.helperLaunchChoice) {
            // The LaunchAgent fallback: unbundled builds, or SMAppService refused for good.
            guard FileOps.entryExists(paths.fallbackAgentPlist) else { return notNeeded("the helper isn't set up") }
            let assessment = assessFallbackJob(lookup(fallbackService))
            if case .leave(let why) = assessment.action { return notNeeded(why) }
            guard let problem = assessment.problem else { return notNeeded(HelperJobAssessment.runsThisBuild) }
            log.notice("starting the helper LaunchAgent again: \(problem.summary, privacy: .public)")
            try installFallbackAgent()
            return .started
        }
        switch loginItem.status {
        case .enabled: return try runRegisteredHelper(automatic: true)
        case .requiresApproval: return notNeeded("waiting for approval in System Settings › General › Login Items")
        case .notRegistered, .notFound:
            guard registrationRecord()?.pendingSince != nil else { return notNeeded("the helper isn't set up") }
            if let blocker = automaticRepairBlocker(loginRegistration()) { return notNeeded(blocker) }
            let why = "LivePaper unregistered it to register it again, and registering didn't finish"
            log.notice("registering the helper login item again: \(why, privacy: .public)")
            return try registerLoginItem(title: "\(Self.reregisterLoginItemTitle) (\(why))")
        }
    }

    /// Title of the step recoverHelper records when it has nothing to do.
    public static let recoverHelperTitle = "Repair the helper"
    /// Title of the step that registers the helper's login item again.
    public static let reregisterLoginItemTitle = "Register the helper login item again"

    /// Why the automatic repair must leave the login item to another copy of LivePaper (nil: this copy
    /// may register it again). Registering moves the login item to the copy that registers, so only
    /// the copy that registered it does — or, when that isn't known (registered before LivePaper kept
    /// a record, or by a copy that is gone), a copy in /Applications or ~/Applications: never a
    /// download that was just opened, a translocated copy, a disk image or a build folder. The user's
    /// Repair Helper / Start Helper / Use This Copy's Helper (registerHelper) can always take it over.
    func automaticRepairBlocker(_ registration: HelperRegistration) -> String? {
        switch registration {
        case .thisCopy: return nil
        case .otherCopy(let app):
            return "the helper belongs to the LivePaper at \(app); open that copy, or use Repair Helper in this one"
        case .unknown:
            let parent = Self.realPath(paths.appBundle.deletingLastPathComponent().path)
            if paths.applicationsDirs.contains(where: { Self.realPath($0.path) == parent }) { return nil }
            return "this LivePaper (\(paths.appBundle.path)) isn't the one in /Applications; use Repair Helper to move the helper to it"
        }
    }

    /// The login item is registered and enabled; makes its job run this build's helper
    /// (HelperJobAssessment). A job that is merely stopped — the helper exits cleanly when quit, and
    /// KeepAlive {SuccessfulExit: false} leaves it stopped — is started when launchd should accept this
    /// build's helper, and one running an older helper with this one's Team ID is restarted; both are
    /// registered again only if launchd then reports it can't start them. One that launchd doesn't
    /// have, can't start, or that runs (or would start) a helper the recorded requirement doesn't
    /// cover is registered again. `automatic`: the app's own repair, which never moves the helper to
    /// this copy (`automaticRepairBlocker`).
    private func runRegisteredHelper(automatic: Bool) throws -> HelperRecoveryOutcome {
        let current = lookup(helperService)
        let assessment = assessLoginJob(current)
        /// `cannotStart`: launchd reports it can't start the helper — a repair left to another copy
        /// is then still a failure to report.
        func reregister(_ why: String, cannotStart: Bool) throws -> HelperRecoveryOutcome {
            if automatic, let blocker = automaticRepairBlocker(loginRegistration()) {
                record(Self.recoverHelperTitle, .skipped(blocker))
                if cannotStart { throw InstallError.helperCannotStart("\(why); \(blocker)") }
                return .notNeeded(blocker)
            }
            return try reregisterLoginItem(because: why)
        }
        /// Unregistering ends a helper that still works: not for a registration that would fail.
        func reregisterUnlessUnsigned(_ why: String, cannotStart: Bool) throws -> HelperRecoveryOutcome {
            if runningHelper(current) != nil, probe.signatureIsValid(paths.appBundle) != true {
                let blocker = "this LivePaper's code signature doesn't check out, so registering it would fail; the running helper keeps going"
                record(Self.reregisterLoginItemTitle, .skipped(blocker))
                return .notNeeded(blocker)
            }
            return try reregister(why, cannotStart: cannotStart)
        }
        switch assessment.action {
        case .leave(let why):
            // Another copy's helper runs, and the user asked for this copy's (Settings › Lock › Use
            // This Copy's Helper): registering moves the login item here. Never by itself.
            if !automatic, case .otherCopy(let app)? = assessment.problem {
                return try reregisterUnlessUnsigned("asked to run this copy's helper instead of the one of the LivePaper at \(app)", cannotStart: false)
            }
            record("Start the helper (\(helperService))", .skipped(why))
            return .notNeeded(why)
        case .reregister(let why):
            return try reregisterUnlessUnsigned(why, cannotStart: assessment.problem?.cannotStart == true)
        case .start, .restart:
            let restart = assessment.action == .restart
            let title = restart ? "Restart the helper with this build (\(helperService))" : "Start the helper (\(helperService))"
            let previous = runningHelper(current)?.pid
            if automatic, restart, let blocker = automaticRepairBlocker(loginRegistration()) {
                record(Self.recoverHelperTitle, .skipped(blocker))
                return .notNeeded(blocker)
            }
            try perform(title) { try kickstart(helperService, kill: restart); return nil }
            if dryRun { return .notNeeded("dry run") }
            // A start may start another copy's helper (its job, or a job that still points there):
            // the job runs, which is what was asked. A restart is for this build's helper.
            switch awaitStart(replacing: previous, acceptingOtherCopy: !restart, timeout: helperStartTimeout) {
            case .running:
                return .started
            case .cannotStart(let why):
                return try reregister("launchd couldn't start it: \(why)", cannotStart: true)
            case .notLoaded:
                return try reregister("launchd no longer has its job", cannotStart: false)
            case .notRunning where restart && runningHelper(lookup(helperService)).map({ Self.isOutdated($0.code) }) == true:
                // launchd started the old copy's helper again (its job still points at the app in the
                // Trash, or at the replaced file): only registering from this copy moves it here.
                return try reregister("launchd restarted it as the older build", cannotStart: false)
            case .notRunning:
                // Nothing says why, so registering again would rest on nothing: say so instead.
                let failure = InstallError.helperNotRunning("launchd reported no running helper after `launchctl kickstart`")
                record(title, .failed(failure.localizedDescription))
                throw failure
            }
        }
    }

    /// Unregisters the login item and registers it again: what SMAppService.h asks for after the
    /// helper changed, and the only thing that gets launchd a job for the current helper once it
    /// can't start the recorded one (docs/RESEARCH.md §6). Only ever done for an enabled item, and new
    /// agents start out allowed; should macOS ask for approval anyway, that is reported
    /// (.needsApproval) and nothing else is tried — no LaunchAgent behind the user's back. The intent
    /// is recorded first (`pendingSince`), so a registration that fails after the unregister is
    /// tried again at the next launch instead of leaving the helper unregistered and forgotten.
    private func reregisterLoginItem(because why: String) throws -> HelperRecoveryOutcome {
        let title = "\(Self.reregisterLoginItemTitle) (\(why))"
        if dryRun { record(title, .planned); return .notNeeded("dry run") }
        log.notice("registering the helper login item again: \(why, privacy: .public)")
        markRegistrationPending()
        // SMAppServiceAgent.unregister returns once the old job is gone (at most 10 s).
        do { try loginItem.unregister() } catch {
            log.error("unregistering the helper login item failed: \(error.localizedDescription, privacy: .public)")
        }
        return try registerLoginItem(title: title)
    }

    /// Registers the (unregistered) login item, records it, and waits for launchd to run its job.
    private func registerLoginItem(title: String) throws -> HelperRecoveryOutcome {
        let status: LoginItemStatus
        do {
            status = try registerWaitingForUnregister()
        } catch {
            let failure: Error
            switch LoginItemRegistrationFailure(error) {
            case .deniedByUser: failure = InstallError.helperDeniedByUser
            case .alreadyRegistered: failure = InstallError.helperCannotStart("macOS kept the old registration: \(error.localizedDescription)")
            case .other: failure = error
            }
            // Still registered (the unregister didn't happen): nothing is left to finish later.
            if [.enabled, .requiresApproval].contains(loginItem.status) { clearRegistrationPending() }
            record(title, .failed(failure.localizedDescription))
            throw failure
        }
        saveRegistrationRecord()
        if status == .requiresApproval {
            record(title, .done)
            log.notice("helper needs approval in System Settings › General › Login Items")
            return .needsApproval
        }
        switch awaitRegisteredJob() {
        case .running:
            record(title, .done)
            return .reregistered
        case .cannotStart(let detail):
            let failure = InstallError.helperCannotStart("launchd reports \(detail), even after LivePaper registered it again")
            record(title, .failed(failure.localizedDescription))
            throw failure
        case .notLoaded, .notRunning:
            let failure = InstallError.helperCannotStart(lookup(helperService).job == nil
                ? "launchd has no job for it, even after LivePaper registered it again"
                : "it doesn't run, even after LivePaper registered it again")
            record(title, .failed(failure.localizedDescription))
            throw failure
        }
    }

    /// `register()`; when SMAppService still has the item (an unregister that finished late, after
    /// SMAppServiceAgent stopped waiting), waits for it to go — up to helperRegisterTimeout — and
    /// tries once more.
    private func registerWaitingForUnregister() throws -> LoginItemStatus {
        do {
            return try loginItem.register()
        } catch where LoginItemRegistrationFailure(error) == .alreadyRegistered {
            let deadline = Date().addingTimeInterval(helperRegisterTimeout)
            while loginItem.status == .enabled, Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
            return try loginItem.register()
        }
    }

    private func kickstart(_ service: String, kill: Bool = false) throws {
        let result = try runner.run("/bin/launchctl", ["kickstart"] + (kill ? ["-k"] : []) + [service], timeout: 15)
        guard result.succeeded else {
            throw InstallError.commandFailed("launchctl kickstart", result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private enum JobStart { case running, cannotStart(String), notLoaded, notRunning }

    /// Watches the login item's job for up to `timeout` until a helper runs in it (another process
    /// than `previous`, the one a restart replaces; with `acceptingOtherCopy`, also another copy's
    /// helper — what starting that copy's job starts); otherwise what launchd last said. A live
    /// helper process of this copy counts as running even when launchd's text doesn't say so.
    private func awaitStart(replacing previous: Int32?, acceptingOtherCopy: Bool = false, timeout: TimeInterval) -> JobStart {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let current = lookup(helperService)
            if let running = runningHelper(current), Self.isNewHelper(running, replacing: previous, acceptingOtherCopy: acceptingOtherCopy) {
                return .running
            }
            if Date() >= deadline { return verdict(current, replacing: previous) }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// After registering again: smd submits the job asynchronously and RunAtLoad starts it, so this
    /// waits up to helperRegisterTimeout for it to run; a job that is loaded but still idle after
    /// helperStartTimeout gets one kickstart.
    private func awaitRegisteredJob() -> JobStart {
        let start = Date()
        let deadline = start.addingTimeInterval(helperRegisterTimeout)
        var kicked = false
        while true {
            let current = lookup(helperService)
            if let running = runningHelper(current), Self.isNewHelper(running, replacing: nil) { return .running }
            if !kicked, current.job != nil, Date().timeIntervalSince(start) >= helperStartTimeout {
                kicked = true
                try? kickstart(helperService)
                continue
            }
            if Date() >= deadline { return verdict(current, replacing: nil) }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// A helper that runs this build (or can't be told apart; with `acceptingOtherCopy`, another
    /// copy's), not the old process a restart ends.
    private static func isNewHelper(_ running: RunningHelper, replacing previous: Int32?, acceptingOtherCopy: Bool = false) -> Bool {
        if let previous, running.pid == nil || running.pid == previous { return false }
        switch running.code {
        case .current, .unknown: return true
        case .otherCopy: return acceptingOtherCopy
        case .replaced, .gone: return false
        }
    }

    /// It runs code that is no longer this copy's helper on disk.
    private static func isOutdated(_ code: RunningHelper.Code) -> Bool {
        switch code {
        case .replaced, .gone: return true
        case .current, .otherCopy, .unknown: return false
        }
    }

    private func verdict(_ current: LaunchdLookup, replacing previous: Int32?) -> JobStart {
        if let why = current.job?.cannotStartReason { return .cannotStart(why) }
        // launchd's text is no API: a live helper of this copy that runs this build counts.
        let own = probe.processes(running: Self.realPath(paths.helperExecutable.path)).filter { $0 != previous }
        if own.contains(where: { probe.runsCodeOnDisk($0) != false }) { return .running }
        if case .notFound = current { return .notLoaded }
        return .notRunning
    }

    /// `launchctl print` (read-only) of `service`.
    private func lookup(_ service: String) -> LaunchdLookup {
        LaunchdLookup.from(try? runner.run("/bin/launchctl", ["print", service], timeout: 10))
    }

    /// The live process in a job, checked through the process itself: a `pid` launchd shows that is
    /// alive counts whatever `state` says. nil: nothing runs.
    private func runningHelper(_ lookup: LaunchdLookup) -> RunningHelper? {
        guard let job = lookup.job else { return nil }
        if let pid = job.pid, probe.isAlive(pid) { return RunningHelper(pid: pid, code: runningCode(pid)) }
        return job.isRunning ? RunningHelper(pid: job.pid, code: .unknown) : nil
    }

    /// Which helper process `pid` runs (HelperProbe; see RunningHelper.Code).
    private func runningCode(_ pid: Int32) -> RunningHelper.Code {
        let path: String
        switch probe.executable(of: pid) {
        case .path(let found): path = found
        case .deleted: return .gone(nil)
        case .unknown: return .unknown
        }
        let real = Self.realPath(path)
        if real == Self.realPath(paths.helperExecutable.path) {
            switch probe.runsCodeOnDisk(pid) {
            case true?: return .current
            case false?: return .replaced
            case nil: return .unknown
            }
        }
        if Self.isInTrash(real) || !FileManager.default.fileExists(atPath: real) { return .gone(real) }
        return .otherCopy(Self.appDisplayPath(helper: real))
    }

    private func assessLoginJob(_ lookup: LaunchdLookup) -> HelperJobAssessment {
        HelperJobAssessment.assessLoginItem(lookup, running: runningHelper(lookup), appBuild: appBuild,
                                            helper: probe.signature(at: paths.helperExecutable), registration: loginRegistration())
    }

    private func assessFallbackJob(_ lookup: LaunchdLookup) -> HelperJobAssessment {
        HelperJobAssessment.assessFallback(lookup, running: runningHelper(lookup), registration: fallbackRegistration())
    }

    /// Which copy registered the login item, from LivePaper's record.
    private func loginRegistration() -> HelperRegistration {
        guard let record = registrationRecord() else { return .unknown }
        let app = Self.realPath(record.app)
        if app == Self.realPath(paths.appBundle.path) { return .thisCopy(record) }
        if FileManager.default.fileExists(atPath: app), !Self.isInTrash(app) { return .otherCopy(record.app) }
        return .unknown
    }

    /// Which copy the fallback plist's program belongs to (read from the plist LivePaper wrote, not
    /// from launchctl).
    private func fallbackRegistration() -> HelperRegistration {
        guard let plist = NSDictionary(contentsOf: paths.fallbackAgentPlist),
              let program = (plist["ProgramArguments"] as? [String])?.first else { return .unknown }
        let real = Self.realPath(program)
        if real == Self.realPath(paths.helperExecutable.path) { return .thisCopy(nil) }
        if FileManager.default.fileExists(atPath: real), !Self.isInTrash(real) { return .otherCopy(Self.appDisplayPath(helper: real)) }
        return .unknown
    }

    /// The helper status() reports on: the login item's job whenever launchd has it (the CLI can't
    /// ask SMAppService about the app's login item, but launchd knows), else the fallback when its
    /// plist is in place, else an enabled login item whose job is missing, else a login item that a
    /// re-registration left unregistered. nil: no helper is set up, or LivePaper was uninstalled.
    private func helperAssessment(loginItem status: LoginItemStatus, loginJob: LaunchdLookup, fallbackJob: LaunchdLookup) -> HelperJobAssessment? {
        guard !FileOps.entryExists(paths.uninstallMarker) else { return nil }
        if case .loaded = loginJob { return assessLoginJob(loginJob) }
        if FileOps.entryExists(paths.fallbackAgentPlist) { return assessFallbackJob(fallbackJob) }
        if status == .enabled { return assessLoginJob(loginJob) }
        if status != .requiresApproval, let since = registrationRecord()?.pendingSince {
            let detail = "since \(ISO8601DateFormatter().string(from: since))"
            return HelperJobAssessment(problem: .unregistered(detail), action: .reregister("registering it again didn't finish \(detail)"))
        }
        return nil
    }

    // MARK: Registration record

    private func registrationRecord() -> HelperRegistrationRecord? {
        guard let data = try? Data(contentsOf: paths.helperRegistration) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HelperRegistrationRecord.self, from: data)
    }

    private func writeRegistrationRecord(_ record: HelperRegistrationRecord) {
        guard !dryRun else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: paths.supportRoot, withIntermediateDirectories: true)
            try FileOps.writeAtomically(try encoder.encode(record), to: paths.helperRegistration)
        } catch {
            log.error("couldn't record the helper's registration: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// After a registration that worked: this copy, its build and its helper's signature.
    private func saveRegistrationRecord() {
        writeRegistrationRecord(HelperRegistrationRecord(app: paths.appBundle.path, build: appBuild,
                                                         helper: probe.signature(at: paths.helperExecutable), registeredAt: Date()))
    }

    /// Right before unregistering for a re-registration.
    private func markRegistrationPending() {
        var record = registrationRecord() ?? HelperRegistrationRecord(app: paths.appBundle.path, build: appBuild)
        record.app = paths.appBundle.path
        record.pendingSince = Date()
        writeRegistrationRecord(record)
    }

    private func clearRegistrationPending() {
        guard var record = registrationRecord(), record.pendingSince != nil else { return }
        record.pendingSince = nil
        writeRegistrationRecord(record)
    }

    private func clearRegistrationRecord() {
        guard !dryRun else { return }
        try? FileOps.removeIfPresent(paths.helperRegistration)
    }

    // MARK: Paths

    /// `path` with symlinks resolved (realpath), or as given when it doesn't exist.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// In a Trash folder (~/.Trash, or a volume's .Trashes): what Finder does with a replaced app.
    static func isInTrash(_ path: String) -> Bool { path.contains("/.Trash/") || path.contains("/.Trashes/") }

    /// The app a helper belongs to (…/LivePaper.app for …/LivePaper.app/Contents/Helpers/LivePaperHelper),
    /// else the helper's own path.
    static func appDisplayPath(helper path: String) -> String {
        let suffix = "/Contents/Helpers/LivePaperHelper"
        return path.hasSuffix(suffix) ? String(path.dropLast(suffix.count)) : path
    }

    /// CFBundleVersion of the app the helper belongs to.
    private var appBuild: String? { FileOps.bundleInfo(paths.appBundle, "CFBundleVersion") }

    /// Title of the step that unregisters the helper's login item.
    public static let unregisterLoginItemTitle = "Unregister the helper login item"

    /// Unregisters the login item (and forgets LivePaper's record of it, so nothing registers it
    /// again), unloads the jobs and removes the fallback plists. Idempotent.
    public func unregisterHelper() throws {
        let title = Self.unregisterLoginItemTitle
        if loginItem.isAvailable {
            try perform(title, skipIf: { [.enabled, .requiresApproval].contains(loginItem.status) ? nil : "not registered" }) {
                try loginItem.unregister(); return nil
            }
            clearRegistrationRecord()
        } else if let app = loginItemApp {
            // Only the app's own executable can talk to SMAppService about its login item (the CLI
            // can't). The uninstall marker keeps that entry from starting the helper again.
            record(title, .skipped("only \(app.lastPathComponent) itself can remove its entry from System Settings › General › Login " +
                                   "Items. It can't start the helper any more; remove it there (or delete \(app.lastPathComponent))"))
        }
        try stopHelperJobs(only: [helperService, fallbackService])
        try removeFallbackAgent()
    }

    /// The app bundle whose embedded login item this process can't reach — the CLI inside
    /// LivePaper.app (Contents/Helpers) — or nil.
    private var loginItemApp: URL? {
        let app = paths.appBundle
        guard app.pathExtension == "app",
              FileOps.entryExists(app.appendingPathComponent("Contents/Library/LaunchAgents/\(LPPaths.helperLabel).plist")) else { return nil }
        return app
    }

    /// Boots out whichever of `services` launchd has loaded (one step).
    private func stopHelperJobs(only services: [String]) throws {
        try perform("Stop the helper", skipIf: { services.contains(where: helperLoaded) ? nil : "not loaded" }) {
            for service in services where helperLoaded(service) {
                let result = try runner.run("/bin/launchctl", ["bootout", service], timeout: 15)
                // Unregistering the login item may already have unloaded it.
                guard result.succeeded || !helperLoaded(service) else {
                    throw InstallError.commandFailed("launchctl bootout", result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            return nil
        }
    }

    /// `launchctl print` (read-only) succeeds only for a loaded job.
    private func helperLoaded(_ service: String) -> Bool {
        (try? runner.run("/bin/launchctl", ["print", service], timeout: 10))?.succeeded ?? false
    }

    private func installFallbackAgent() throws {
        let program = paths.helperExecutable
        guard FileManager.default.isExecutableFile(atPath: program.path) else {
            record("Install the helper LaunchAgent", .failed("helper missing"))
            throw InstallError.helperMissing(program.path)
        }
        let plist = paths.fallbackAgentPlist
        try perform("Install the helper LaunchAgent at \(plist.path)") {
            try FileOps.writeAtomically(try LaunchAgentPlist.contents(label: LaunchAgentPlist.label, program: program), to: plist)
            return nil
        }
        try perform("Start the helper (\(fallbackService))") {
            // Replace a running copy so a new app version's helper takes over.
            _ = try runner.run("/bin/launchctl", ["bootout", fallbackService], timeout: 15)
            var result = try runner.run("/bin/launchctl", ["bootstrap", guiDomain, plist.path], timeout: 15)
            if !result.succeeded {
                // bootout finishes asynchronously; bootstrap right after it can fail with EIO.
                Thread.sleep(forTimeInterval: 1)
                result = try runner.run("/bin/launchctl", ["bootstrap", guiDomain, plist.path], timeout: 15)
            }
            guard result.succeeded else {
                throw InstallError.commandFailed("launchctl bootstrap", result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }
    }

    private func removeFallbackAgent() throws {
        let plists = [paths.fallbackAgentPlist, paths.legacyAgentPlist]
        try perform("Remove the helper LaunchAgent plist", skipIf: { plists.contains(where: FileOps.entryExists) ? nil : "not present" }) {
            for plist in plists where FileOps.entryExists(plist) { try FileManager.default.removeItem(at: plist) }
            return nil
        }
    }

    /// Installing LivePaper again lifts the uninstall marker (or the helper would exit at launch).
    private func clearUninstallMarker() throws {
        guard FileOps.entryExists(paths.uninstallMarker) else { return }
        try perform("Clear the uninstall marker \(paths.uninstallMarker.path)") {
            try FileOps.removeIfPresent(paths.uninstallMarker)
            return nil
        }
    }

    // MARK: - System Settings (only ever on user action)

    /// Wallpaper › Screen Saver on macOS 26 (the screen saver moved into the Wallpaper pane);
    /// the Screen Saver pane before that.
    public var screenSaverSettingsURL: String {
        osMajorVersion >= 26 ? "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension?ScreenSaver"
                             : "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension"
    }

    public func openScreenSaverSettings() { openURL(screenSaverSettingsURL) }

    /// Core doesn't link AppKit, so NSWorkspace isn't available: /usr/bin/open does the same.
    private func openURL(_ url: String) {
        try? perform("Open \(url)") {
            let result = try runner.run("/usr/bin/open", [url], timeout: 15)
            guard result.succeeded else { throw InstallError.commandFailed("open", result.combinedOutput) }
            return nil
        }
    }

    // MARK: - Changed system preferences

    /// Changes a user preference on LivePaper's behalf. The value from before LivePaper's *first*
    /// change of that key is kept in backups/ so uninstall can put it back.
    public func changeSystemDefault(domain: String, key: String, to value: Any?, currentHost: Bool = false) throws {
        try perform("Set \(domain) \(key)") {
            var changes = loadDefaultsChanges()
            if !changes.contains(where: { $0.domain == domain && $0.key == key && $0.currentHost == currentHost }) {
                let previous = try preferences.value(domain: domain, key: key, currentHost: currentHost).map {
                    try PropertyListSerialization.data(fromPropertyList: ["value": $0], format: .binary, options: 0)
                }
                changes.append(DefaultsChange(domain: domain, key: key, currentHost: currentHost, previous: previous))
                try saveDefaultsChanges(changes)
            }
            guard preferences.set(value, domain: domain, key: key, currentHost: currentHost) else {
                throw InstallError.commandFailed("Setting \(domain) \(key)", "the preference couldn't be saved")
            }
            return nil
        }
    }

    /// Puts one preference changed with `changeSystemDefault` back to its value from before
    /// LivePaper and forgets the backup. No-op if LivePaper never changed it.
    /// - Parameter title: the step's title in the transcript (default "Restore <domain> <key>").
    public func restoreSystemDefault(domain: String, key: String, currentHost: Bool = false, title: String? = nil) throws {
        let matches = { (c: DefaultsChange) in c.domain == domain && c.key == key && c.currentHost == currentHost }
        try perform(title ?? "Restore \(domain) \(key)", skipIf: { loadDefaultsChanges().contains(where: matches) ? nil : "not changed by LivePaper" }) {
            var changes = loadDefaultsChanges()
            guard let index = changes.firstIndex(where: matches) else { return "not changed by LivePaper" }
            guard preferences.set(Self.previousValue(changes[index]), domain: domain, key: key, currentHost: currentHost) else {
                throw InstallError.commandFailed("Restoring \(domain) \(key)", "the preference couldn't be saved")
            }
            changes.remove(at: index)
            if changes.isEmpty { try FileOps.removeIfPresent(paths.defaultsBackup) } else { try saveDefaultsChanges(changes) }
            return nil
        }
    }

    // MARK: - Lock keys (ARCHITECTURE §1, §7)

    /// With this loginwindow preference on, ⌃⌘Q, the Apple-menu Lock Screen item and the Touch ID /
    /// lock key start the screen saver before locking, so the lock screen shows the scene. It is a
    /// plain user preference (no permissions needed); loginwindow picks it up without a logout and
    /// still locks if the saver can't run. Lid-close and display-sleep locks aren't affected.
    public static let lockKeysDomain = "com.apple.loginwindow"
    public static let lockKeysKey = "immediateLockLaunchesScreenSaver"

    /// Whether the lock keys currently show the scene (the live preference, whoever set it).
    public var lockKeysShowScene: Bool {
        (preferences.value(domain: Self.lockKeysDomain, key: Self.lockKeysKey, currentHost: false) as? NSNumber)?.boolValue == true
    }

    /// Sets the preference, remembering the value from before LivePaper's first change so
    /// uninstall can put it back. Going back to that original value restores it and drops the
    /// backup; asking for the current value changes nothing (and creates no backup).
    public func setLockKeysShowScene(_ on: Bool) throws {
        if let backup = loadDefaultsChanges().first(where: Self.isLockKeysChange),
           ((Self.previousValue(backup) as? NSNumber)?.boolValue ?? false) == on {
            // An absent key reads as off, which is also loginwindow's default.
            try restoreSystemDefault(domain: Self.lockKeysDomain, key: Self.lockKeysKey)
            return
        }
        if lockKeysShowScene == on {
            record("Set \(Self.lockKeysDomain) \(Self.lockKeysKey)", .skipped(on ? "already on" : "already off"))
            return
        }
        try changeSystemDefault(domain: Self.lockKeysDomain, key: Self.lockKeysKey, to: on)
    }

    /// Title of the uninstall step that puts the lock keys back.
    public static let restoreLockKeysTitle = "Restore what \u{2303}\u{2318}Q and the lock key do"

    private static func isLockKeysChange(_ c: DefaultsChange) -> Bool {
        c.domain == lockKeysDomain && c.key == lockKeysKey && !c.currentHost
    }

    @available(*, deprecated, renamed: "lockKeysDomain")
    public static var lockTakeoverDomain: String { lockKeysDomain }
    @available(*, deprecated, renamed: "lockKeysKey")
    public static var lockTakeoverKey: String { lockKeysKey }
    @available(*, deprecated, renamed: "lockKeysShowScene")
    public var systemLockTakeoverEnabled: Bool { lockKeysShowScene }
    @available(*, deprecated, renamed: "setLockKeysShowScene(_:)")
    public func setSystemLockTakeover(_ enabled: Bool) throws { try setLockKeysShowScene(enabled) }

    private static func previousValue(_ change: DefaultsChange) -> Any? {
        change.previous.flatMap { (try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any])?["value"] }
    }

    private func loadDefaultsChanges() -> [DefaultsChange] {
        guard let data = try? Data(contentsOf: paths.defaultsBackup) else { return [] }
        return (try? JSONDecoder().decode([DefaultsChange].self, from: data)) ?? []
    }

    private func saveDefaultsChanges(_ changes: [DefaultsChange]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileOps.writeAtomically(try encoder.encode(changes), to: paths.defaultsBackup)
    }

    private func restoreDefaults() throws {
        let changes = loadDefaultsChanges()
        var failed: [String] = []
        for change in changes.reversed() {
            if !preferences.set(Self.previousValue(change), domain: change.domain, key: change.key, currentHost: change.currentHost) {
                failed.append("\(change.domain) \(change.key)")
            }
        }
        guard failed.isEmpty else { throw InstallError.commandFailed("Restoring preferences", failed.joined(separator: ", ")) }
        try FileOps.removeIfPresent(paths.defaultsBackup)
    }

    // MARK: - Uninstall

    /// Files in the support directory that are kept when the library is kept: the scenes, their
    /// collections and the user's preferences, so reinstalling picks up where they left off.
    static let keptWithLibrary: Set<String> = ["Library", CollectionsFile.fileName, "state.json", PublishService.settingsFileName,
                                               AIService.settingsFileName]

    /// Title of the uninstall step that undoes the screen-saver selection.
    public static let restoreScreenSaverTitle = "Restore the previous screen saver choice"
    /// Logged after it when SystemDefault had no known earlier choice and got macOS's Message saver.
    public static let builtinSaverTitle = "Set the screen saver to macOS's Message saver (LivePaper had no record of an earlier one; " +
                                          "pick another in System Settings › Wallpaper › Screen Saver)"

    /// Runs every uninstall step (continuing past failures; each step is idempotent, so running
    /// uninstall again retries what failed) and returns what happened. In a dry run nothing
    /// changes: steps with something to do are `.planned`, the rest `.skipped`. The lock keys are
    /// restored with the other changed preferences (step 3).
    @discardableResult public func performUninstall(removeLibrary: Bool) -> [InstallStep] {
        let start = transcript.count
        let fm = FileManager.default
        // 0. The marker first: a login item this process can't unregister (the CLI can't) then can't
        //    bring the helper back at the next login.
        attempt {
            try perform("Mark LivePaper as uninstalled (\(paths.uninstallMarker.path))",
                        skipIf: { FileOps.entryExists(paths.uninstallMarker) ? "already marked" : nil }) {
                let note = "LivePaper was uninstalled on \(ISO8601DateFormatter().string(from: Date())). Its helper doesn't start " +
                           "while this file exists; setting LivePaper up again removes it.\n"
                try FileOps.writeAtomically(Data(note.utf8), to: paths.uninstallMarker)
                return nil
            }
        }
        // 1. The helper, so nothing restarts the saver or reacts to the changes below.
        attempt { try unregisterHelper() }
        // 2. The screen-saver choice (before the saver goes: the store must never point at a missing
        //    module), 3. the lock keys, 4. any other preference LivePaper changed.
        attempt { try restoreScreenSaverChoice() }
        attempt { try restoreSystemDefault(domain: Self.lockKeysDomain, key: Self.lockKeysKey, title: Self.restoreLockKeysTitle) }
        attempt {
            try perform("Restore changed system settings", skipIf: { loadDefaultsChanges().isEmpty ? "nothing changed" : nil }) {
                try restoreDefaults()
                return nil
            }
        }
        // 5. The saver bundle (renamed first so it leaves the screen-saver list atomically) — only
        //    once the store no longer depends on it, re-read right before removing it.
        let restoreFailed = transcript.dropFirst(start).contains { $0.title == Self.restoreScreenSaverTitle && $0.isFailure }
        attempt {
            try perform("Remove \(paths.installedSaver.path)", skipIf: {
                if !FileOps.entryExists(paths.installedSaver) { return "not installed" }
                return restoreFailed ? "kept while it is still the selected screen saver; run uninstall again" : nil
            }) {
                guard !store.dependsOnSaver() else {
                    throw InstallError.screenSaverStillSelected("the wallpaper settings still point at \(paths.installedSaver.path)")
                }
                // Under publish.lock: a publish or saver update in another LivePaper process can't
                // swap anything into the bundle while it goes, and finds it gone (and the uninstall
                // marker in place) afterwards.
                try withPublishLockIfPresent {
                    let doomed = FileOps.stagingURL(in: paths.screenSaversDir, tag: "uninstall")
                    try fm.moveItem(at: paths.installedSaver, to: doomed)
                    try fm.removeItem(at: doomed)
                }
                return nil
            }
        }
        // 6. LivePaper's data. Backups survive any failure (a restore that couldn't run, a saver that
        //    had to stay) so a second uninstall — or the user — can still use them.
        let anyFailed = transcript.dropFirst(start).contains(where: \.isFailure)
        var kept = removeLibrary ? Set<String>() : Self.keptWithLibrary
        if anyFailed { kept.insert(paths.backups.lastPathComponent) }
        let root = paths.supportRoot
        let doomed = { ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { !kept.contains($0) } }
        let title = removeLibrary ? "Delete \(root.path), including the scene library"
                                  : "Delete LivePaper's caches, workspaces and backups (keeping the scene library)"
        let deleteRoot = removeLibrary && !anyFailed
        attempt {
            try perform(title, skipIf: {
                if deleteRoot { return FileOps.entryExists(root) ? nil : "not present" }
                return doomed().isEmpty ? "nothing to delete" : nil
            }) {
                if deleteRoot { try fm.removeItem(at: root); return nil }
                for name in doomed() { try fm.removeItem(at: root.appendingPathComponent(name)) }
                return nil
            }
        }
        return Array(transcript.dropFirst(start))
    }

    /// publish.lock around `body`, when there is a support directory to hold it: nothing can be
    /// publishing without one, and uninstall shouldn't create it.
    private func withPublishLockIfPresent(_ body: () throws -> Void) throws {
        guard FileOps.isDirectory(paths.supportRoot) else { return try body() }
        try FileLock.withLock(at: paths.publishLock, body)
    }

    /// Uninstall step 2: switches every Idle slot that still names LivePaper.saver to the user's
    /// recorded original, the placeholder, or (SystemDefault without a known original) the
    /// pre-LivePaper store's choice or macOS's own Message saver — whether or not LivePaper made the
    /// selection itself. Fails, so the saver and backups stay, whenever that can't be done.
    private func restoreScreenSaverChoice() throws {
        let manifest = paths.wallpaperSelectionBackup
        try perform(Self.restoreScreenSaverTitle, skipIf: {
            // isSelected() also scans a store in an unknown format.
            guard !store.isSelected() else { return nil }
            return FileOps.entryExists(manifest) ? "the screen saver was changed since" : "LivePaper isn't the selected screen saver"
        }) {
            let report: WallpaperApplyReport
            do {
                report = try wallpaperApplier.restore(store.module, manifestURL: manifest, fallback: restoreFallback())
            } catch let error as WallpaperStoreError where !error.isTransient && !error.wroteStore {
                // Retrying alone can't help (unknown store format, a layout LivePaper doesn't edit, no
                // earlier choice to put back, …): the user has to pick another screen saver.
                let previous = previousSaverName().map { "; before LivePaper it was \u{201C}\($0)\u{201D}" } ?? ""
                throw InstallError.screenSaverStillSelected("LivePaper couldn't change it back automatically: \(error.localizedDescription)\(previous)")
            } catch let error as WallpaperStoreError where error.wroteStore {
                // Written, but the displays don't show the previous choice (WallpaperAgent replaced it):
                // the manifest and every backup stay, and the user learns what to pick.
                throw InstallError.screenSaverNotRestored(error.localizedDescription, previous: previousSaverName())
            }
            if !report.builtinSaverPaths.isEmpty {
                record(Self.builtinSaverTitle, .done)
            }
            return report.outcome == .applied ? nil : "the screen saver was changed since"
        }
    }

    /// The screen saver SystemDefault chose before LivePaper (from the manifest), e.g. "Voltron", so
    /// the user can pick it again by hand.
    private func previousSaverName() -> String? {
        guard let manifest = try? WallpaperSelectionManifest.load(from: paths.wallpaperSelectionBackup),
              let slot = try? manifest.entry(for: .systemDefault)?.originalSlot(),
              let module = WallpaperSlot.moduleURLs(slot).first, !store.module.names(module) else { return nil }
        return module.deletingPathExtension().lastPathComponent
    }

    /// The root-slot fallback for a restore: the raw store backup from before LivePaper's first
    /// selection (if readable), then the built-in saver.
    private func restoreFallback() -> WallpaperRestoreFallback {
        let previous = FileManager.default.contents(atPath: paths.wallpaperStoreBackup.path).flatMap { try? WallpaperStoreDocument(data: $0) }
        return WallpaperRestoreFallback(previousStore: previous, builtinSaver: WallpaperSaverModule(url: paths.builtinScreenSaver))
    }

    // MARK: - Step bookkeeping

    /// Records one step. `skipIf` (read-only; also evaluated in dry runs) returns a reason when
    /// there is nothing to do. Otherwise `body` runs — unless this is a dry run — and returns nil
    /// when it did its work or a reason when it turned out there was nothing to do.
    private func perform(_ title: String, skipIf: () -> String? = { nil }, _ body: () throws -> String?) throws {
        if let reason = skipIf() { record(title, .skipped(reason)); return }
        if dryRun { record(title, .planned); return }
        do {
            if let reason = try body() { record(title, .skipped(reason)) } else { record(title, .done) }
        } catch {
            record(title, .failed(error.localizedDescription))
            throw error
        }
    }

    /// Uninstall keeps going after a failed step; the failure is already in the transcript.
    private func attempt(_ body: () throws -> Void) { try? body() }

    private func record(_ title: String, _ outcome: InstallStep.Outcome) {
        lock.withLock { steps.append(InstallStep(title: title, outcome: outcome)) }
        switch outcome {
        case .done: log.info("\(title, privacy: .public): done")
        case .planned: log.info("\(title, privacy: .public): planned (dry run)")
        case .skipped(let why): log.info("\(title, privacy: .public): skipped (\(why, privacy: .public))")
        case .failed(let why): log.error("\(title, privacy: .public): failed (\(why, privacy: .public))")
        }
    }
}
