// HelperLockPolicy — the helper's decisions, kept free of AppKit/Carbon so they can be tested:
// whether to start the screen saver, which hotkey to (un)register, how to read the recorder's
// notification, request debouncing and command-line parsing.
//
// Pure logic (Foundation + LivePaperCore), also compiled into LivePaperSelfTest.
import Foundation
import LivePaperCore

// MARK: - Lock flow

/// What asked for a lock.
enum HelperLockTrigger: String, Sendable {
    /// LivePaper's own Carbon hotkey.
    case hotkey
    /// LPNotification.lockNow (the app's menu-bar "Lock Now").
    case lockNowNotification
}

/// The facts the lock decision depends on.
struct HelperLockSituation: Equatable, Sendable {
    /// /System/Library/CoreServices/ScreenSaverEngine.app exists.
    var engineExists: Bool
    /// A ScreenSaverEngine process is running (a saver is up, locked or not).
    var screenSaverRunning: Bool
    /// `CGSSessionScreenIsLocked`: the session is already locked.
    var sessionLocked: Bool
    /// The helper already asked Launch Services to start the engine and hasn't heard back.
    var launchInFlight: Bool
}

enum HelperLockDecision: Equatable, Sendable {
    /// Launch ScreenSaverEngine; with "require password immediately" the saver locks.
    case startScreenSaver
    /// Do nothing (the reason is logged).
    case skip(String)
    /// Can't lock (the reason is logged as an error).
    case fail(String)
}

enum HelperLockPolicy {
    /// LivePaper's lock is "saver first, the saver locks". Never start a saver once the session is
    /// locked: loginwindow only shows a saver that was running when the lock began (see main.swift).
    static func decide(_ situation: HelperLockSituation) -> HelperLockDecision {
        if situation.sessionLocked { return .skip("the session is already locked") }
        if situation.screenSaverRunning { return .skip("a screen saver is already running") }
        if situation.launchInFlight { return .skip("the screen saver is already being started") }
        if !situation.engineExists { return .fail("ScreenSaverEngine.app is missing") }
        return .startScreenSaver
    }
}

// MARK: - Hotkey registration

enum HelperHotkeyAction: Equatable, Sendable {
    case unregister
    case register(LPHotkey)
}

enum HelperHotkeyPlan {
    /// The hotkey that should be registered right now: the configured one, unless the app's
    /// recorder is active or the combination is refused by HelperHotkeyMapping.
    static func desired(config: HelperLockConfig, suspended: Bool) -> LPHotkey? {
        guard !suspended, let hotkey = config.hotkey, HelperHotkeyMapping.problem(with: hotkey) == nil else { return nil }
        return hotkey
    }

    /// Steps from the registered hotkey to the desired one; empty when nothing changes (so a
    /// stateChanged that didn't touch the shortcut doesn't churn the registration).
    static func actions(registered: LPHotkey?, desired: LPHotkey?) -> [HelperHotkeyAction] {
        guard !equivalent(registered, desired) else { return [] }
        var steps: [HelperHotkeyAction] = []
        if registered != nil { steps.append(.unregister) }
        if let desired { steps.append(.register(desired)) }
        return steps
    }

    /// Same key and same modifier set (modifier order and duplicates don't matter to Carbon).
    static func equivalent(_ a: LPHotkey?, _ b: LPHotkey?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a.keyCode == b.keyCode && Set(a.modifiers) == Set(b.modifiers)
        default: return false
        }
    }
}

/// LPNotification.hotkeyRecording: `userInfo["active"]` says whether the app's recorder is active.
enum HelperRecordingSignal {
    static let activeKey = "active"

    /// nil when the notification doesn't say (it is then ignored).
    static func isActive(userInfo: [AnyHashable: Any]?) -> Bool? {
        guard let value = userInfo?[activeKey] else { return nil }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            switch text.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        }
        return nil
    }
}

/// Drops repeats of a request that arrive within `minimumInterval` of the last accepted one
/// (a double-clicked "Open LivePaper…"). Compares timestamps; no timers.
struct HelperRequestGate: Sendable {
    var minimumInterval: TimeInterval
    private(set) var lastAccepted: Date?

    init(minimumInterval: TimeInterval) { self.minimumInterval = minimumInterval }

    mutating func accept(at now: Date) -> Bool {
        if let last = lastAccepted, now.timeIntervalSince(last) < minimumInterval, now >= last { return false }
        lastAccepted = now
        return true
    }
}

// MARK: - Launch

/// Whether the agent may start at all.
enum HelperLaunchDecision: Equatable, Sendable {
    case run
    /// LivePaper was uninstalled (`LPPaths.uninstallMarker` exists). The agent exits 0 before it
    /// creates anything: a login item that is still registered (a terminal uninstall can't
    /// unregister it) must not recreate LivePaper's data folder or register the default shortcut.
    /// launchd's KeepAlive {SuccessfulExit: false} restarts the job only after a crash, so a clean
    /// exit keeps it stopped until the next login, where the same check stops it again.
    case exitUninstalled
}

enum HelperLaunchPolicy {
    /// Checked first thing in agent mode, before the single-instance file (which would create the
    /// support folder). Reads one path; creates nothing.
    static func decide(uninstallMarker: URL,
                       fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> HelperLaunchDecision {
        fileExists(uninstallMarker.path) ? .exitUninstalled : .run
    }
}

// MARK: - Command line

enum HelperCommand: Equatable, Sendable {
    /// Normal operation: the LaunchAgent.
    case agent
    /// Print the resolved configuration as JSON and exit (no window server, no hotkeys).
    case printConfig
    /// Print a short human-readable check and exit 1 if something is broken (no window server).
    case selfCheck
    case version
    case help
    case usageError(String)

    static let usage = """
    usage: LivePaperHelper [--print-config | --self-check | --version | --help]

    Without options, runs LivePaper's login agent (started by launchd; not meant to be run by hand).
      --print-config   print the resolved configuration and state as JSON, then exit
      --self-check     print a short check of the configuration; exit status 1 if something is broken
      --version        print the version and exit
    Neither option connects to the window server, registers hotkeys or launches anything.
    """

    static func parse(_ arguments: [String]) -> HelperCommand {
        // Launch Services may add a -psn_… argument when a process is started from Finder.
        let args = arguments.filter { !$0.hasPrefix("-psn_") }
        guard let first = args.first else { return .agent }
        guard args.count == 1 else { return .usageError("expected at most one option, got \(args.joined(separator: " "))") }
        switch first {
        case "--print-config": return .printConfig
        case "--self-check": return .selfCheck
        case "--version", "-v": return .version
        case "--help", "-h": return .help
        default: return .usageError("unknown option \(first)")
        }
    }
}
