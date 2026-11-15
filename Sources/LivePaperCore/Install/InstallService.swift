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

    public init(saverTemplate: URL, screenSaversDir: URL, launchAgentsDir: URL, wallpaperStore: URL, supportRoot: URL,
                helperExecutable: URL, managedPreferences: [URL], builtinScreenSaver: URL = WallpaperRestoreFallback.systemSaverURL) {
        self.saverTemplate = saverTemplate; self.screenSaversDir = screenSaversDir; self.launchAgentsDir = launchAgentsDir
        self.wallpaperStore = wallpaperStore; self.supportRoot = supportRoot; self.helperExecutable = helperExecutable
        self.managedPreferences = managedPreferences; self.builtinScreenSaver = builtinScreenSaver
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
    /// Uninstall couldn't switch the screen saver away from LivePaper (the reason), so it keeps
    /// LivePaper.saver: the store must never point at a deleted module.
    case screenSaverStillSelected(String)

    public var errorDescription: String? {
        switch self {
        case .saverTemplateMissing(let p): return "LivePaper's screen saver is missing from the app (\(p)). Reinstall LivePaper."
        case .helperMissing(let p): return "LivePaper's helper is missing from the app (\(p)). Reinstall LivePaper."
        case .commandFailed(let cmd, let detail): return "\(cmd) failed: \(detail)"
        case .uninstallIncomplete(let steps): return "Uninstall couldn't finish: " + steps.joined(separator: "; ")
        case .helperDeniedByUser:
            return "LivePaper's helper is switched off in System Settings › General › Login Items. Switch it on there."
        case .screenSaverStillSelected(let why):
            return "LivePaper is still your screen saver (\(why)). Choose another screen saver in System Settings › Wallpaper › " +
                   "Screen Saver, then run uninstall again; until then LivePaper keeps its screen saver and backups."
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
    public init(paths: InstallPaths = .current(), publisher: PublishServicing?, runner: CommandRunning = SystemCommandRunner(),
                loginItem: LoginItemRegistering = SMAppServiceAgent(), preferences: PreferencesAccessing = SystemPreferences(),
                dryRun: Bool = false,
                uid: uid_t = getuid(), osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                wallpaperSystem: WallpaperSystem? = nil, wallpaperClock: WallpaperClock = SystemWallpaperClock(),
                wallpaperOptions: WallpaperApplyOptions = WallpaperApplyOptions()) {
        self.paths = paths; self.publisher = publisher; self.runner = runner; self.loginItem = loginItem
        self.preferences = preferences; self.dryRun = dryRun; self.uid = uid
        self.osMajorVersion = osMajorVersion
        self.store = WallpaperStore(url: paths.wallpaperStore, saver: paths.installedSaver)
        self.wallpaperSystem = wallpaperSystem ?? (runner is SystemCommandRunner
            ? LiveWallpaperSystem(storeURL: paths.wallpaperStore, runner: runner)
            : UnavailableWallpaperSystem(reason: "system commands are only recorded"))
        self.wallpaperClock = wallpaperClock
        self.wallpaperOptions = wallpaperOptions
    }

    /// Every step performed (or, in a dry run, planned) by this instance, oldest first.
    public var transcript: [InstallStep] { lock.withLock { steps } }

    private var guiDomain: String { "gui/\(uid)" }
    /// The login item's job.
    private var helperService: String { "\(guiDomain)/\(LPPaths.helperLabel)" }
    /// The LaunchAgent fallback's job.
    private var fallbackService: String { "\(guiDomain)/\(LaunchAgentPlist.label)" }

    // MARK: - Status

    /// Blocking (runs `sysadminctl` and `launchctl print`, both read-only, ≤ 10 s each): call it
    /// off the main thread.
    public func status() -> InstallStatus {
        let installedVersion = FileOps.bundleInfo(paths.installedSaver, "CFBundleVersion")
        let templateVersion = FileOps.bundleInfo(paths.saverTemplate, "CFBundleVersion")
        let installed = FileOps.isRegularFile(paths.installedSaver.appendingPathComponent("Contents/Info.plist"))
        let managed = SystemProbes.managedSettings(paths.managedPreferences)
        let sysadminctl = try? runner.run("/usr/sbin/sysadminctl", ["-screenLock", "status"], timeout: 10)
        let helperRunning = [helperService, fallbackService].contains { service in
            (try? runner.run("/bin/launchctl", ["print", service], timeout: 10)).map(SystemProbes.helperRunning) ?? false
        }
        let immediate = SystemProbes.passwordImmediately(sysadminctlOutput: sysadminctl?.combinedOutput, managed: managed)
        return InstallStatus(
            saverInstalled: installed,
            // Without a template (development builds) there is nothing newer to install.
            saverUpToDate: installed && (templateVersion == nil || installedVersion == templateVersion),
            saverSelected: store.isSelected(),
            helperRunning: helperRunning,
            helperLoginItem: loginItem.status,
            passwordImmediately: immediate,
            managedByMDM: SystemProbes.isManaged(managed),
            passwordManagedByMDM: !immediate && SystemProbes.passwordEnforcedNotImmediately(
                SystemProbes.enforcedPasswordSettings(managed: managed) {
                    preferences.forcedValue(domain: SystemProbes.screenSaverDomain, key: $0)
                }),
            lockKeysShowScene: lockKeysShowScene,
            lockKeysChangedByLivePaper: loadDefaultsChanges().contains(where: Self.isLockKeysChange))
    }

    // MARK: - Saver

    /// Copies the template saver into ~/Library/Screen Savers, keeping the published Playlist of an
    /// existing install, swaps it in atomically, then publishes. The screen-saver host keeps any
    /// already-loaded copy until it next starts; LivePaper never kills system processes.
    public func installSaver() throws {
        let template = paths.saverTemplate
        guard FileOps.isRegularFile(template.appendingPathComponent("Contents/Info.plist")) else {
            record("Install the screen saver", .failed("template missing"))
            throw InstallError.saverTemplateMissing(template.path)
        }
        try clearUninstallMarker()
        try perform("Install the screen saver into \(paths.screenSaversDir.path)") {
            let fm = FileManager.default
            try fm.createDirectory(at: paths.screenSaversDir, withIntermediateDirectories: true)
            try FileLock.withLock(at: paths.publishLock) {
                // Hidden and without the .saver extension: never listed as a screen saver.
                let staging = FileOps.stagingURL(in: paths.screenSaversDir, tag: "install")
                do {
                    try fm.copyItem(at: template, to: staging)
                    // A downloaded app's resources carry the quarantine flag; the saver host refuses those.
                    FileOps.stripQuarantine(staging)
                    let playlist = staging.appendingPathComponent("Contents/Resources").appendingPathComponent(LPPlaylist.directoryName)
                    if FileOps.isDirectory(paths.installedPlaylist) {
                        try FileOps.removeIfPresent(playlist)
                        try fm.createDirectory(at: playlist.deletingLastPathComponent(), withIntermediateDirectories: true)
                        // APFS clones the files, so even large videos cost no time or space.
                        try fm.copyItem(at: paths.installedPlaylist, to: playlist)
                    }
                    try FileOps.installReplacing(paths.installedSaver, with: staging)
                } catch {
                    try? FileOps.removeIfPresent(staging)
                    throw error
                }
            }
            return nil
        }
        guard let publisher else { return }
        try perform("Publish scenes into the screen saver") {
            do { try publisher.publish() } catch PublishError.noScenes { return "no scenes yet" }
            return nil
        }
    }

    /// Makes LivePaper the screen saver for every display and Space by editing the wallpaper store
    /// and restarting WallpaperAgent (WallpaperStoreApplier; only ever on an explicit user action).
    /// The original of every replaced Idle slot is recorded in backups/ first.
    ///
    /// - Returns: true only when the selection is in place and confirmed after the agent restarted
    ///   (or already was). false when LivePaper refused to touch the store — locked, System
    ///   Settings open, MDM, an unknown store format, … (the reason is in the transcript) — so the UI
    ///   shows the guided step.
    /// - Throws: when the store was written but the change couldn't be confirmed or was rolled back.
    public func selectSaver() throws -> Bool {
        let title = "Select LivePaper as the screen saver"
        // Nothing to change (also when it was picked by hand in System Settings). A selection of
        // LivePaper.saver at another location still gets rewritten to the installed one.
        if let document = try? store.read(), (try? document.planSelect(store.module, at: Date()))?.isEmpty == true {
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
    /// for good. Idempotent; "Start Helper" calls it to restart a helper that was quit:
    /// * login item enabled: start its job (`launchctl kickstart`), or register it again when launchd
    ///   doesn't have it loaded;
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
            try startRegisteredHelper()
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
            record(title, .done)
            if status == .requiresApproval { log.notice("helper needs approval in System Settings › General › Login Items") }
            return
        } catch {
            switch LoginItemRegistrationFailure(error) {
            case .alreadyRegistered:
                record(title, .skipped("already registered"))
                try startRegisteredHelper()
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
    }

    /// The login item is registered and enabled, but its job may have stopped: the helper exits
    /// cleanly when quit, and KeepAlive {SuccessfulExit: false} then leaves it stopped.
    private func startRegisteredHelper() throws {
        guard helperLoaded(helperService) else {
            // Registered but not loaded (e.g. booted out): registering again loads it.
            try perform("Register the helper login item again") {
                try? loginItem.unregister()
                _ = try loginItem.register()
                return nil
            }
            return
        }
        try perform("Start the helper (\(helperService))", skipIf: { helperIsRunning(helperService) ? "already running" : nil }) {
            let result = try runner.run("/bin/launchctl", ["kickstart", helperService], timeout: 15)
            guard result.succeeded else {
                throw InstallError.commandFailed("launchctl kickstart", result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }
    }

    /// Title of the step that unregisters the helper's login item.
    public static let unregisterLoginItemTitle = "Unregister the helper login item"

    /// Unregisters the login item, unloads the jobs and removes the fallback plists. Idempotent.
    public func unregisterHelper() throws {
        let title = Self.unregisterLoginItemTitle
        if loginItem.isAvailable {
            try perform(title, skipIf: { [.enabled, .requiresApproval].contains(loginItem.status) ? nil : "not registered" }) {
                try loginItem.unregister(); return nil
            }
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
        let app = paths.helperExecutable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
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

    private func helperIsRunning(_ service: String) -> Bool {
        (try? runner.run("/bin/launchctl", ["print", service], timeout: 10)).map(SystemProbes.helperRunning) ?? false
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

    /// Files in the support directory that are kept when the library is kept: the scenes and the
    /// user's preferences, so reinstalling picks up where they left off.
    static let keptWithLibrary: Set<String> = ["Library", "state.json", PublishService.settingsFileName, AIService.settingsFileName]

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
                let doomed = FileOps.stagingURL(in: paths.screenSaversDir, tag: "uninstall")
                try fm.moveItem(at: paths.installedSaver, to: doomed)
                try fm.removeItem(at: doomed)
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
