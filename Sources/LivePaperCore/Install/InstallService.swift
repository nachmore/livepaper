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

    public init(saverTemplate: URL, screenSaversDir: URL, launchAgentsDir: URL, wallpaperStore: URL, supportRoot: URL,
                helperExecutable: URL, managedPreferences: [URL]) {
        self.saverTemplate = saverTemplate; self.screenSaversDir = screenSaversDir; self.launchAgentsDir = launchAgentsDir
        self.wallpaperStore = wallpaperStore; self.supportRoot = supportRoot; self.helperExecutable = helperExecutable
        self.managedPreferences = managedPreferences
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
    /// Copy of the wallpaper store taken before LivePaper first changed the selection.
    public var wallpaperStoreBackup: URL { backups.appendingPathComponent("wallpaper-store-Index.plist") }
    /// Previous values of system preferences LivePaper changed.
    public var defaultsBackup: URL { backups.appendingPathComponent("changed-defaults.json") }
    public var fallbackAgentPlist: URL { launchAgentsDir.appendingPathComponent("\(LPPaths.helperLabel).plist") }
    /// Shared with PublishService so installing never copies a playlist that is being swapped.
    public var publishLock: URL { supportRoot.appendingPathComponent("publish.lock") }
}

public enum InstallError: Error, LocalizedError, Sendable, Equatable {
    case saverTemplateMissing(String)
    case helperMissing(String)
    case commandFailed(String, String)
    case uninstallIncomplete([String])

    public var errorDescription: String? {
        switch self {
        case .saverTemplateMissing(let p): return "LivePaper's screen saver is missing from the app (\(p)). Reinstall LivePaper."
        case .helperMissing(let p): return "LivePaper's helper is missing from the app (\(p)). Reinstall LivePaper."
        case .commandFailed(let cmd, let detail): return "\(cmd) failed: \(detail)"
        case .uninstallIncomplete(let steps): return "Uninstall couldn't finish: " + steps.joined(separator: "; ")
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
    private let lock = NSRecursiveLock()
    private var steps: [InstallStep] = []
    private let log = Logger(subsystem: LPPaths.bundleID, category: "install")

    /// - Parameters:
    ///   - publisher: publishes content after installSaver (nil: don't publish).
    ///   - dryRun: record every step instead of performing it.
    public init(paths: InstallPaths = .current(), publisher: PublishServicing?, runner: CommandRunning = SystemCommandRunner(),
                loginItem: LoginItemRegistering = SMAppServiceAgent(), preferences: PreferencesAccessing = SystemPreferences(),
                dryRun: Bool = false,
                uid: uid_t = getuid(), osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
        self.paths = paths; self.publisher = publisher; self.runner = runner; self.loginItem = loginItem
        self.preferences = preferences; self.dryRun = dryRun; self.uid = uid
        self.osMajorVersion = osMajorVersion
        self.store = WallpaperStore(url: paths.wallpaperStore)
    }

    /// Every step performed (or, in a dry run, planned) by this instance, oldest first.
    public var transcript: [InstallStep] { lock.withLock { steps } }

    private var guiDomain: String { "gui/\(uid)" }
    private var helperService: String { "\(guiDomain)/\(LPPaths.helperLabel)" }

    // MARK: - Status

    /// Blocking (runs `sysadminctl` and `launchctl print`, both read-only, ≤ 10 s each): call it
    /// off the main thread.
    public func status() -> InstallStatus {
        let installedVersion = FileOps.bundleInfo(paths.installedSaver, "CFBundleVersion")
        let templateVersion = FileOps.bundleInfo(paths.saverTemplate, "CFBundleVersion")
        let installed = FileOps.isRegularFile(paths.installedSaver.appendingPathComponent("Contents/Info.plist"))
        let managed = SystemProbes.managedSettings(paths.managedPreferences)
        let sysadminctl = try? runner.run("/usr/sbin/sysadminctl", ["-screenLock", "status"], timeout: 10)
        let launchctl = try? runner.run("/bin/launchctl", ["print", helperService], timeout: 10)
        return InstallStatus(
            saverInstalled: installed,
            // Without a template (development builds) there is nothing newer to install.
            saverUpToDate: installed && (templateVersion == nil || installedVersion == templateVersion),
            saverSelected: store.isSelected(),
            helperRunning: launchctl.map(SystemProbes.helperRunning) ?? false,
            helperLoginItem: loginItem.status,
            passwordImmediately: SystemProbes.passwordImmediately(sysadminctlOutput: sysadminctl?.combinedOutput, managed: managed),
            managedByMDM: SystemProbes.isManaged(managed),
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

    public func selectSaver() throws -> Bool {
        if store.isSelected() {
            record("Select LivePaper as the screen saver", .skipped("already selected"))
            return true
        }
        var selected = false
        try perform("Select LivePaper as the screen saver") {
            selected = try store.select(backupTo: paths.wallpaperStoreBackup)
            return selected ? nil : "needs the guided step in System Settings"
        }
        return selected
    }

    // MARK: - Helper

    /// The login item's state (e.g. `.requiresApproval` → onboarding points the user to System
    /// Settings › General › Login Items). `.notFound` when running outside the app bundle.
    public var helperLoginItemStatus: LoginItemStatus { loginItem.status }

    /// Registers the helper as a login item (SMAppService), falling back to a LaunchAgent plist
    /// when the process isn't the app bundle or SMAppService refuses. Idempotent.
    public func registerHelper() throws {
        if loginItem.isAvailable {
            // A LaunchAgent from an earlier unbundled install uses the same label; launchd can't
            // load the login item while it is loaded.
            if FileOps.entryExists(paths.fallbackAgentPlist) {
                try stopHelperJob()
                try removeFallbackAgent()
            }
            do {
                var status = LoginItemStatus.notRegistered
                try perform("Register the helper as a login item") {
                    status = try loginItem.register()
                    return nil
                }
                if status == .requiresApproval { log.notice("helper needs approval in System Settings › Login Items") }
                return
            } catch {
                log.error("SMAppService registration failed, using a LaunchAgent: \(error.localizedDescription, privacy: .public)")
            }
        }
        try installFallbackAgent()
    }

    /// Unregisters the login item, unloads the job and removes a fallback plist. Idempotent.
    public func unregisterHelper() throws {
        if loginItem.isAvailable {
            try perform("Unregister the helper login item",
                        skipIf: { [.enabled, .requiresApproval].contains(loginItem.status) ? nil : "not registered" }) {
                try loginItem.unregister(); return nil
            }
        }
        try stopHelperJob()
        try removeFallbackAgent()
    }

    private func stopHelperJob() throws {
        try perform("Stop the helper (\(helperService))", skipIf: { helperLoaded() ? nil : "not loaded" }) {
            let result = try runner.run("/bin/launchctl", ["bootout", helperService], timeout: 15)
            // Unregistering the login item may already have unloaded it.
            guard result.succeeded || !helperLoaded() else {
                throw InstallError.commandFailed("launchctl bootout", result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }
    }

    /// `launchctl print` (read-only) succeeds only for a loaded job.
    private func helperLoaded() -> Bool {
        (try? runner.run("/bin/launchctl", ["print", helperService], timeout: 10))?.succeeded ?? false
    }

    private func installFallbackAgent() throws {
        let program = paths.helperExecutable
        guard FileManager.default.isExecutableFile(atPath: program.path) else {
            record("Install the helper LaunchAgent", .failed("helper missing"))
            throw InstallError.helperMissing(program.path)
        }
        let plist = paths.fallbackAgentPlist
        try perform("Install the helper LaunchAgent at \(plist.path)") {
            try FileOps.writeAtomically(try LaunchAgentPlist.contents(label: LPPaths.helperLabel, program: program), to: plist)
            return nil
        }
        try perform("Start the helper (\(helperService))") {
            // Replace a running copy so a new app version's helper takes over.
            _ = try runner.run("/bin/launchctl", ["bootout", helperService], timeout: 15)
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
        let plist = paths.fallbackAgentPlist
        try perform("Remove the helper LaunchAgent plist", skipIf: { FileOps.entryExists(plist) ? nil : "not present" }) {
            try FileManager.default.removeItem(at: plist)
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

    /// On: sets the preference, remembering the value from before LivePaper's first change for
    /// uninstall (already on: nothing changes, nothing to restore). Off: restores that value, and
    /// turns it off explicitly if it was "on" (the backup then keeps "on" so uninstall leaves the
    /// Mac as LivePaper found it).
    public func setLockKeysShowScene(_ on: Bool) throws {
        if on {
            if lockKeysShowScene {
                record("Set \(Self.lockKeysDomain) \(Self.lockKeysKey)", .skipped("already on"))
                return
            }
            try changeSystemDefault(domain: Self.lockKeysDomain, key: Self.lockKeysKey, to: true)
            return
        }
        try restoreSystemDefault(domain: Self.lockKeysDomain, key: Self.lockKeysKey)
        if lockKeysShowScene {
            try changeSystemDefault(domain: Self.lockKeysDomain, key: Self.lockKeysKey, to: false)
        }
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

    /// Runs every uninstall step (continuing past failures; each step is idempotent, so running
    /// uninstall again retries what failed) and returns what happened. In a dry run nothing
    /// changes: steps with something to do are `.planned`, the rest `.skipped`. The lock keys are
    /// restored with the other changed preferences (step 3).
    @discardableResult public func performUninstall(removeLibrary: Bool) -> [InstallStep] {
        let start = transcript.count
        let fm = FileManager.default
        // 1. The helper first, so nothing restarts the saver or reacts to the changes below.
        attempt { try unregisterHelper() }
        // 2. The previous screen-saver choice, 3. the lock keys, 4. any other preference LivePaper changed.
        attempt {
            try perform("Restore the previous screen saver choice",
                        skipIf: { FileOps.entryExists(paths.wallpaperStoreBackup) ? nil : "LivePaper didn't change it" }) {
                try store.restore(from: paths.wallpaperStoreBackup)
                return nil
            }
        }
        attempt { try restoreSystemDefault(domain: Self.lockKeysDomain, key: Self.lockKeysKey, title: Self.restoreLockKeysTitle) }
        attempt {
            try perform("Restore changed system settings", skipIf: { loadDefaultsChanges().isEmpty ? "nothing changed" : nil }) {
                try restoreDefaults()
                return nil
            }
        }
        // 5. The saver bundle (renamed first so it leaves the screen-saver list atomically).
        attempt {
            try perform("Remove \(paths.installedSaver.path)",
                        skipIf: { FileOps.entryExists(paths.installedSaver) ? nil : "not installed" }) {
                let doomed = FileOps.stagingURL(in: paths.screenSaversDir, tag: "uninstall")
                try fm.moveItem(at: paths.installedSaver, to: doomed)
                try fm.removeItem(at: doomed)
                return nil
            }
        }
        // 6. LivePaper's data. Backups survive a failed restore so a second uninstall can retry it.
        let restoreFailed = transcript.dropFirst(start).contains { if case .failed = $0.outcome { return true }; return false }
        var kept = removeLibrary ? Set<String>() : Self.keptWithLibrary
        if restoreFailed { kept.insert(paths.backups.lastPathComponent) }
        let root = paths.supportRoot
        let doomed = { ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { !kept.contains($0) } }
        let title = removeLibrary ? "Delete \(root.path), including the scene library"
                                  : "Delete LivePaper's caches, workspaces and backups (keeping the scene library)"
        let deleteRoot = removeLibrary && !restoreFailed
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
