// WallpaperSystem — everything the store applier needs from the running Mac: the read-only
// preflight facts and the one live action, restarting WallpaperAgent. Tests inject a fake (and a
// fake clock); only LiveWallpaperSystem touches the real system.
import CoreFoundation
import CoreGraphics
import Darwin
import Foundation

/// Lock state of this login session.
public enum WallpaperSessionState: Sendable, Equatable {
    case unlocked
    case locked
    /// No console session (remote shell, or another user is switched in).
    case unknown
}

public protocol WallpaperSystem: Sendable {
    /// Why the live sequence can't run against the store at `url` at all (nil: it can). Checked
    /// before every other probe.
    func unavailability(forStoreAt url: URL) -> String?
    var sessionState: WallpaperSessionState { get }
    /// Names of running processes that rule out editing the store: System Settings and its Wallpaper
    /// pane extension (their view model would go stale and could write it back), ScreenSaverEngine.
    func conflictingProcesses() -> [String]
    /// MDM forces `com.apple.screensaver moduleName` (WallpaperAgent then ignores the store's choice).
    var screenSaverModuleForced: Bool { get }
    /// MDM sets `com.apple.applicationaccess allowWallpaperModification = false`.
    var wallpaperChangesDisabled: Bool { get }
    /// `com.apple.wallpaper StoreIndexMigrationVersion` (10 on macOS 26).
    var storeMigrationVersion: Int? { get }
    /// Makes WallpaperAgent re-read the store: it reads Index.plist only at launch. launchd starts a
    /// new agent at once; expect about a second of blank desktop.
    func restartWallpaperAgent() throws
}

/// Time for the applier's waits (a fake clock in tests makes them instant).
public protocol WallpaperClock: Sendable {
    func now() -> Date
    func sleep(_ seconds: TimeInterval)
}

public struct SystemWallpaperClock: WallpaperClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
}

/// For installers whose system commands are only recorded or planned: refuses everything.
public struct UnavailableWallpaperSystem: WallpaperSystem {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public func unavailability(forStoreAt url: URL) -> String? { reason }
    public var sessionState: WallpaperSessionState { .unknown }
    public func conflictingProcesses() -> [String] { [] }
    public var screenSaverModuleForced: Bool { false }
    public var wallpaperChangesDisabled: Bool { false }
    public var storeMigrationVersion: Int? { nil }
    public func restartWallpaperAgent() throws { throw WallpaperStoreError.unavailable(reason) }
}

// MARK: - Live

/// The real Mac. LIVE PATH: `restartWallpaperAgent()` runs `/usr/bin/killall WallpaperAgent`
/// (through `runner`). It is only ever reached from an explicit user action (select, uninstall),
/// and refuses unless `storeURL` is the store WallpaperAgent itself reads — so tests and any
/// redirected store (LIVEPAPER_WALLPAPER_STORE) can never restart the agent.
public struct LiveWallpaperSystem: WallpaperSystem {
    /// The store the applier edits.
    public let storeURL: URL
    private let runner: CommandRunning

    public init(storeURL: URL, runner: CommandRunning) {
        self.storeURL = storeURL
        self.runner = runner
    }

    /// Where WallpaperAgent reads its store: the account's real home (not $HOME, not
    /// LIVEPAPER_WALLPAPER_STORE).
    public static var agentStoreURL: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    public func unavailability(forStoreAt url: URL) -> String? {
        guard Self.samePath(url, Self.agentStoreURL), Self.samePath(storeURL, Self.agentStoreURL) else {
            return "\(url.path) isn't the store WallpaperAgent reads"
        }
        if CFPreferencesCopyAppValue("OverrideSystemWallpaperStoreDirectoryURL" as CFString, "com.apple.wallpaper" as CFString) != nil {
            return "WallpaperAgent is configured to use another store folder"
        }
        return nil
    }

    /// `CGSSessionScreenIsLocked` is present (true) in the session dictionary only while locked.
    public var sessionState: WallpaperSessionState {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return .unknown }
        if let onConsole = session[kCGSessionOnConsoleKey as String] as? NSNumber, !onConsole.boolValue { return .unknown }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true ? .locked : .unlocked
    }

    /// Executable-path suffixes of the conflicting processes, with the names shown to the user.
    static let conflicts: [(suffix: String, name: String)] = [
        ("/System Settings.app/Contents/MacOS/System Settings", "System Settings"),
        ("/Wallpaper.appex/Contents/MacOS/Wallpaper", "System Settings"),   // the Wallpaper pane extension
        ("/ScreenSaverEngine.app/Contents/MacOS/ScreenSaverEngine", "The screen saver"),
    ]

    public func conflictingProcesses() -> [String] {
        var names: [String] = []
        for path in Self.processPaths(uid: getuid()) {
            for conflict in Self.conflicts where path.hasSuffix(conflict.suffix) && !names.contains(conflict.name) {
                names.append(conflict.name)
            }
        }
        return names
    }

    public var screenSaverModuleForced: Bool {
        CFPreferencesAppValueIsForced("moduleName" as CFString, "com.apple.screensaver" as CFString)
    }

    public var wallpaperChangesDisabled: Bool {
        let value = CFPreferencesCopyAppValue("allowWallpaperModification" as CFString, "com.apple.applicationaccess" as CFString)
        return (value as? NSNumber)?.boolValue == false
    }

    public var storeMigrationVersion: Int? {
        (CFPreferencesCopyAppValue("StoreIndexMigrationVersion" as CFString, "com.apple.wallpaper" as CFString) as? NSNumber)?.intValue
    }

    public func restartWallpaperAgent() throws {
        if let why = unavailability(forStoreAt: storeURL) { throw WallpaperStoreError.unavailable(why) }
        // SIGTERM: the agent has no handler and nothing to flush; launchd (KeepAlive) relaunches it.
        let result = try runner.run("/usr/bin/killall", ["WallpaperAgent"], timeout: 10)
        guard result.succeeded else {
            throw WallpaperStoreError.agentRestartFailed(result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: Helpers

    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Executable paths of this user's processes (libproc; read-only, no permissions needed).
    static func processPaths(uid: uid_t) -> [String] {
        let capacity = Int(proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), nil, 0)) / MemoryLayout<pid_t>.size + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = pids.withUnsafeMutableBufferPointer {
            proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), $0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard bytes > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).compactMap { pid in
            guard pid > 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return String(cString: buffer)
        }
    }
}
