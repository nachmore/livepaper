// SaverSupport — small platform services used by the saver: logging, power source, notifications,
// session lock state, display sleep, and the persistent session store.
import AppKit
import IOKit.ps
import notify
import os
import ScreenSaver

enum SaverLog {
    static let subsystem = Bundle(for: LivePaperSaverView.self).bundleIdentifier ?? "com.nachmore.livepaper.saver"
    /// Lifecycle, playlist and scene selection.
    static let saver = Logger(subsystem: subsystem, category: "saver")
    /// Messages from scenes (JS errors, video failures).
    static let scene = Logger(subsystem: subsystem, category: "scene")
    /// One structured line per lifecycle step (init, window, start/stop, lock, didstart, sleep,
    /// willstop, load/run/pause/release), notice level so it is persisted:
    /// `log show --last 1h --predicate 'subsystem == "com.nachmore.livepaper.saver" && category == "lifecycle"'`
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
}

// MARK: - Power

enum SaverPowerSource {
    /// Battery vs AC (IOPS) and Low Power Mode, read fresh each time (cheap, no polling).
    static func current() -> SaverPowerState {
        var onBattery = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            onBattery = (type as String) == kIOPSBatteryPowerValue
        }
        return SaverPowerState(onBattery: onBattery, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}

/// Calls `onChange` (on the main queue) when the providing power source or Low Power Mode changes.
/// Event-driven only: `kIOPSNotifyPowerSource` fires on AC ⇄ battery switches, not on every percent.
final class SaverPowerMonitor {
    private var token: Int32 = NOTIFY_TOKEN_INVALID
    private var lowPowerObserver: NSObjectProtocol?

    init(onChange: @escaping () -> Void) {
        let status = notify_register_dispatch(kIOPSNotifyPowerSource, &token, DispatchQueue.main) { _ in onChange() }
        if status != UInt32(NOTIFY_STATUS_OK) { token = NOTIFY_TOKEN_INVALID }
        lowPowerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                                                  queue: .main) { _ in onChange() }
    }

    deinit {
        if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
        if let lowPowerObserver { NotificationCenter.default.removeObserver(lowPowerObserver) }
    }
}

// MARK: - Notifications

/// Subscribes to the distributed and workspace notifications the saver reacts to and forwards their
/// names on the main queue.
///
/// Distributed observers use `.deliverImmediately`: AppKit suspends distributed-notification delivery
/// while an app is inactive — and a screen-saver host never becomes active — so with the default
/// suspension behaviour (coalesce) a notification the poster didn't flag as immediate would be held
/// back until it no longer matters (lock UI hand-off, willstop).
///
/// NSWorkspace's app notifications are filtered here and forwarded under the saver's own names
/// (SaverSystemEvent): ScreenSaverEngine launching/quitting, and the preview host (System Settings)
/// becoming or ceasing to be the frontmost app.
final class SaverNotificationRelay: NSObject {
    private let handler: (String) -> Void

    init(distributedNames: [String], handler: @escaping (String) -> Void) {
        self.handler = handler
        super.init()
        // A dev host scripts every event through the test hook; the real Mac's lock, sleep and app
        // switches must not leak into its scenario.
        guard !SaverDevOverrides.simulatedSystem else { return }
        let distributed = DistributedNotificationCenter.default()
        for name in distributedNames {
            distributed.addObserver(self, selector: #selector(received(_:)), name: NSNotification.Name(name), object: nil,
                                    suspensionBehavior: .deliverImmediately)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(self, selector: #selector(received(_:)), name: name, object: nil)
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(self, selector: #selector(receivedApp(_:)), name: name, object: nil)
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func received(_ note: Notification) {
        forward(note.name.rawValue)
    }

    @objc private func receivedApp(_ note: Notification) {
        let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
        switch note.name {
        case NSWorkspace.didLaunchApplicationNotification where bundleID == SaverEngineProbe.bundleIdentifier:
            forward(SaverSystemEvent.engineLaunchedName)
        case NSWorkspace.didTerminateApplicationNotification where bundleID == SaverEngineProbe.bundleIdentifier:
            forward(SaverSystemEvent.engineTerminatedName)
        case NSWorkspace.didActivateApplicationNotification:
            forward(SaverPreviewHost.isActive(frontmostBundleIdentifier: bundleID)
                    ? SaverSystemEvent.previewHostActivatedName : SaverSystemEvent.previewHostDeactivatedName)
        default:
            break
        }
    }

    private func forward(_ name: String) {
        if Thread.isMainThread { handler(name) } else { DispatchQueue.main.async { [handler] in handler(name) } }
    }
}

// MARK: - Screen saver engine, frontmost app

enum SaverEngineProbe {
    /// /System/Library/CoreServices/ScreenSaverEngine.app (LSUIElement). On macOS 26 it draws
    /// nothing: it asks loginwindow to start the saver and quits on com.apple.screensaver.didstop.
    static let bundleIdentifier = "com.apple.ScreenSaver.Engine"

    /// A Launch Services query (no polling: read at startAnimation and on lifecycle events).
    static var isRunning: Bool {
        if SaverDevOverrides.simulatedSystem { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    static var frontmostBundleIdentifier: String? {
        if SaverDevOverrides.simulatedSystem { return "dev.livepaper.saverhost" }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}

// MARK: - Dev hosts

enum SaverDevOverrides {
    /// Set by scripts/dev/saverhost-lp.swift for itself (the real, sandboxed host never has it): the
    /// polled system facts (session lock, display sleep, ScreenSaverEngine, frontmost app) read as
    /// "unlocked, awake, no engine, another app in front", and system notifications are not observed,
    /// so a scripted scenario doesn't depend on the state of the Mac it runs on. Events arrive only
    /// through the test hook (`livepaperHandleNotificationNamed:`).
    static let simulatedSystemKey = "LIVEPAPER_SAVER_SIMULATED_SYSTEM"
    static let simulatedSystem: Bool = getenv(simulatedSystemKey) != nil
}

// MARK: - Session lock

enum SaverSessionLock {
    /// Whether the login session is locked right now. `CGSSessionScreenIsLocked` is only present in
    /// the session dictionary while the screen is locked.
    static var isLocked: Bool {
        if SaverDevOverrides.simulatedSystem { return false }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }
}

// MARK: - Displays

extension NSView {
    /// True when the display showing this view is asleep (falls back to the main display while the
    /// view isn't on a screen yet).
    var saverDisplayIsAsleep: Bool {
        if SaverDevOverrides.simulatedSystem { return false }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let id = (window?.screen?.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        return CGDisplayIsAsleep(id) != 0
    }

    /// Backing scale for layer contents (CATextLayer is blurry unless contentsScale matches).
    var saverBackingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
}

// MARK: - Session store

/// ScreenSaverDefaults-backed store, used only for bookkeeping (which scene was shown last) —
/// everything configurable is published into the bundle by the app (ARCHITECTURE §4.3).
/// Pitfalls this works around:
///  * In the sandboxed host, writes are silently dropped until the container's
///    Library/Preferences/ByHost directory exists (seen with the prototype on macOS 26), so it is
///    created first. ScreenSaverDefaults are per-host (ByHost) preferences.
///  * Writes must be followed by `synchronize()`: the host process is killed (or we exit(0) on
///    willstop) long before an automatic flush would happen, and the other displays' hosts read
///    the record through cfprefsd.
///  * `integer(forKey:)` & co. return 0 for missing keys, so the record is stored as one encoded
///    blob — never half-written, never confused with a real value.
///  * `ScreenSaverDefaults(forModuleWithName:)` can return nil; we then keep the record in memory
///    rather than writing into the host's own `UserDefaults.standard` domain.
final class SaverDefaultsSessionStore: SaverSessionStore {
    private static let key = "session"
    private let defaults: ScreenSaverDefaults

    init?(moduleName: String) {
        // Inside the sandbox the user Library directory is the host's container, never ~/Library.
        if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let byHost = library.appendingPathComponent("Preferences/ByHost", isDirectory: true)
            try? FileManager.default.createDirectory(at: byHost, withIntermediateDirectories: true)
        }
        guard let defaults = ScreenSaverDefaults(forModuleWithName: moduleName) else { return nil }
        self.defaults = defaults
    }

    func load() -> SaverSessionRecord? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(SaverSessionRecord.self, from: data)
    }

    func save(_ record: SaverSessionRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.key)
        defaults.synchronize()
    }
}

enum SaverSessionStores {
    /// Environment variable that redirects bookkeeping to a JSON file (dev hosts and tests, so they
    /// never touch the user's real screen-saver preferences).
    static let stateFileEnvironmentKey = "LIVEPAPER_SAVER_STATE_FILE"

    /// One store per process: every display's view in the host shares it, so displays starting
    /// together see each other's session immediately.
    static let shared: SaverSessionStore = {
        if let path = ProcessInfo.processInfo.environment[stateFileEnvironmentKey], !path.isEmpty {
            return SaverFileSessionStore(url: URL(fileURLWithPath: path))
        }
        if let store = SaverDefaultsSessionStore(moduleName: SaverLog.subsystem) { return store }
        SaverLog.saver.error("ScreenSaverDefaults unavailable; scene history is not persisted")
        return SaverMemorySessionStore()
    }()
}
