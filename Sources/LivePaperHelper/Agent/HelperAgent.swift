// HelperAgent — the long-running LaunchAgent: lock shortcut, lock flow, "open the app" relay.
// See main.swift for what it does and, importantly, what it must not do.
import AppKit
import CoreGraphics
import LivePaperCore
import os

@MainActor
final class HelperAgent: NSObject, NSApplicationDelegate {
    private let log = HelperLog.main
    private let hotkeys = CarbonHotkeyCenter()
    private let instance: HelperSingleInstance?
    /// nil until the first read of state.json.
    private var config: HelperLockConfig?
    /// The app's hotkey recorder is active: the shortcut is unregistered meanwhile.
    private var recordingActive = false
    /// When the helper last asked Launch Services to start ScreenSaverEngine (cleared on completion).
    private var launchStartedAt: Date?
    private var openAppGate = HelperRequestGate(minimumInterval: 1)
    private var signalSources: [DispatchSourceSignal] = []
    /// Observes app terminations only while recording, to recover if the app quits mid-recording.
    private var terminationObserver: NSObjectProtocol?
    private var stopped = false
    /// Off-main work: the sysadminctl password probe.
    private let probes = DispatchQueue(label: "com.nachmore.livepaper.helper.probes", qos: .utility)

    /// A launch that hasn't completed within this long is assumed lost (checked when the next
    /// request arrives — no timer).
    private static let launchTimeout: TimeInterval = 10

    private init(instance: HelperSingleInstance?) { self.instance = instance }

    /// Runs the agent until SIGTERM/SIGINT or logout.
    static func run() -> Never {
        let log = HelperLog.main
        var instance: HelperSingleInstance?
        switch HelperSingleInstance.acquire(at: HelperProcesses.instanceFile) {
        case .acquired(let acquired):
            instance = acquired
        case .heldByOther(let pid):
            // Exit 0 so launchd (KeepAlive SuccessfulExit = false) doesn't keep retrying.
            log.notice("another LivePaperHelper is already running (pid \(pid.map(String.init) ?? "?", privacy: .public)); exiting")
            exit(0)
        case .unavailable(let why):
            log.error("running without the single-instance guard: \(why, privacy: .public)")
        }

        let agent = HelperAgent(instance: instance)
        let app = NSApplication.shared
        // Accessory = LSUIElement behaviour for this Info.plist-less executable: no Dock icon or menu
        // bar, and the process never activates (takes focus) on its own. It has to be set before
        // run() calls finishLaunching.
        app.setActivationPolicy(.accessory)
        // Not an app the user launched: never put it in loginwindow's "reopen at login" list.
        app.disableRelaunchOnLogin()
        // There are no windows to keep it alive; don't let AppKit's automatic termination quit it.
        ProcessInfo.processInfo.disableAutomaticTermination("LivePaper helper waits for its shortcut and requests")
        app.delegate = agent
        withExtendedLifetime(agent) { app.run() }
        exit(0)
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        observeDistributedNotifications()
        hotkeys.onPressed = { [unowned self] in lock(.hotkey) }
        _ = hotkeys.installHandler()
        reloadState(reason: "launch")
        let version = HelperSystem.appLocator.locate(executable: HelperSystem.executableURL).url.flatMap(HelperAppLocator.infoPlistVersion)
        log.notice("started (pid \(getpid(), privacy: .public), version \(version ?? "unbundled", privacy: .public))")
        checkPasswordPolicy(context: "launch")
    }

    /// Logout sends AppKit apps a quit event rather than SIGTERM.
    func applicationWillTerminate(_ notification: Notification) {
        stop(reason: "terminate")
    }

    private func installSignalHandlers() {
        let handlers: [(Int32, @MainActor (HelperAgent) -> Void)] = [
            (SIGTERM, { $0.stop(reason: "SIGTERM"); exit(0) }),
            (SIGINT, { $0.stop(reason: "SIGINT"); exit(0) }),
            (SIGHUP, { $0.reloadState(reason: "SIGHUP") }),
        ]
        for (number, handler) in handlers {
            // Ignore the default action (terminate) so the dispatch source sees the signal instead.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [unowned self] in MainActor.assumeIsolated { handler(self) } }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Unregisters everything; idempotent.
    private func stop(reason: String) {
        guard !stopped else { return }
        stopped = true
        hotkeys.uninstall()
        DistributedNotificationCenter.default().removeObserver(self)
        watchAppTermination(false)
        instance?.release()
        log.notice("stopped (\(reason, privacy: .public))")
    }

    // MARK: - Notifications

    private func observeDistributedNotifications() {
        let center = DistributedNotificationCenter.default()
        let observed: [(String, Selector)] = [
            (LPNotification.stateChanged, #selector(stateChangedNotification(_:))),
            (LPNotification.hotkeyRecording, #selector(hotkeyRecordingNotification(_:))),
            (LPNotification.lockNow, #selector(lockNowNotification(_:))),
            (LPNotification.openApp, #selector(openAppNotification(_:))),
        ]
        for (name, selector) in observed {
            // NSApplication suspends distributed-notification delivery while the app is inactive —
            // and this accessory process is never active. `.deliverImmediately` exempts these
            // observers, whatever the poster passed as deliverImmediately.
            center.addObserver(self, selector: selector, name: .init(name), object: nil, suspensionBehavior: .deliverImmediately)
        }
    }

    // Distributed notifications arrive on the main thread; `onMain` makes that an explicit guarantee.
    @objc nonisolated private func stateChangedNotification(_ note: Notification) {
        onMain { $0.reloadState(reason: "stateChanged") }
    }

    @objc nonisolated private func hotkeyRecordingNotification(_ note: Notification) {
        let active = HelperRecordingSignal.isActive(userInfo: note.userInfo)
        onMain { $0.recordingChanged(active: active) }
    }

    @objc nonisolated private func lockNowNotification(_ note: Notification) {
        let requestID = HelperLockNowReply.requestID(from: note.userInfo)
        onMain { agent in
            // Answer first, so the app never starts a second screen saver after its 1 s timeout.
            agent.acceptLockNow(requestID: requestID)
            agent.lock(.lockNowNotification)
        }
    }

    private func acceptLockNow(requestID: String?) {
        DistributedNotificationCenter.default().postNotificationName(
            .init(LPNotification.lockNowAccepted), object: nil,
            userInfo: HelperLockNowReply.acceptedUserInfo(requestID: requestID), deliverImmediately: true)
        log.info("lockNow \(requestID ?? "(no id)", privacy: .public) accepted")
    }

    @objc nonisolated private func openAppNotification(_ note: Notification) {
        onMain { $0.openApp() }
    }

    nonisolated private func onMain(_ body: @escaping @MainActor (HelperAgent) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(self) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body(self) } }
        }
    }

    // MARK: - State and shortcut

    private func reloadState(reason: String) {
        let new = HelperStateReader.load(from: LPPaths.stateFile, previous: config)
        if new != config {
            // Logged once per change, not on every stateChanged.
            for problem in new.problems { log.error("state.json: \(problem, privacy: .public)") }
            log.info("""
                state (\(reason, privacy: .public)): shortcut \(new.hotkey?.displayString ?? "off", privacy: .public) \
                [\(new.source.rawValue, privacy: .public)]
                """)
            if let hotkey = new.hotkey, let problem = HelperHotkeyMapping.problem(with: hotkey) {
                log.error("not registering the shortcut \(hotkey.displayString, privacy: .public): \(problem.description, privacy: .public)")
            }
        }
        config = new
        applyHotkey()
    }

    private func recordingChanged(active: Bool?) {
        guard let active else {
            log.error("\(LPNotification.hotkeyRecording, privacy: .public) without userInfo[\"active\"]; ignored")
            return
        }
        guard active != recordingActive else { return }
        recordingActive = active
        watchAppTermination(active)
        if active {
            log.info("the app is recording a new shortcut; suspending the current one")
            applyHotkey()
        } else {
            log.info("shortcut recording ended")
            // The app saves state.json before it announces the end of recording; read it again in
            // case that stateChanged was missed.
            reloadState(reason: "recording ended")
        }
    }

    /// If the app quits (or crashes) while recording, it never posts active=false; resume then.
    private func watchAppTermination(_ watch: Bool) {
        let center = NSWorkspace.shared.notificationCenter
        if !watch {
            if let terminationObserver { center.removeObserver(terminationObserver) }
            terminationObserver = nil
            return
        }
        guard terminationObserver == nil else { return }
        terminationObserver = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                                 queue: .main) { [unowned self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == LPPaths.bundleID else { return }
            MainActor.assumeIsolated {
                log.notice("the app quit while recording a shortcut; resuming the shortcut")
                recordingChanged(active: false)
            }
        }
    }

    private func applyHotkey() {
        guard let config, !stopped else { return }
        let desired = HelperHotkeyPlan.desired(config: config, suspended: recordingActive)
        for action in HelperHotkeyPlan.actions(registered: hotkeys.registered, desired: desired) {
            switch action {
            case .unregister:
                let old = hotkeys.registered?.displayString ?? "?"
                hotkeys.unregister()
                log.info("shortcut \(old, privacy: .public) unregistered")
            case .register(let hotkey):
                guard case .success(let carbon) = HelperHotkeyMapping.carbon(for: hotkey) else { continue }
                let status = hotkeys.register(hotkey, as: carbon)
                if status == noErr {
                    log.notice("shortcut \(hotkey.displayString, privacy: .public) registered")
                } else {
                    log.error("""
                        couldn't register the shortcut \(hotkey.displayString, privacy: .public): \
                        \(CarbonHotkeyCenter.describe(status), privacy: .public)
                        """)
                }
            }
        }
    }

    // MARK: - Lock flow

    private func lock(_ trigger: HelperLockTrigger) {
        let now = Date()
        let situation = HelperLockSituation(
            engineExists: FileManager.default.fileExists(atPath: HelperProcesses.screenSaverEngineApp.path),
            screenSaverRunning: HelperProcesses.isScreenSaverEngineRunning,
            sessionLocked: Self.sessionLocked,
            launchInFlight: launchStartedAt.map { now.timeIntervalSince($0) < Self.launchTimeout } ?? false)
        switch HelperLockPolicy.decide(situation) {
        case .skip(let why):
            log.info("lock (\(trigger.rawValue, privacy: .public)): \(why, privacy: .public); nothing to do")
        case .fail(let why):
            log.error("lock (\(trigger.rawValue, privacy: .public)) failed: \(why, privacy: .public)")
        case .startScreenSaver:
            log.notice("lock (\(trigger.rawValue, privacy: .public)): starting the screen saver")
            launchStartedAt = now
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: HelperProcesses.screenSaverEngineApp, configuration: configuration) { _, error in
                let failure = error?.localizedDescription
                self.onMain { agent in
                    agent.launchStartedAt = nil
                    if let failure { agent.log.error("couldn't start ScreenSaverEngine: \(failure, privacy: .public)") }
                }
            }
            // Only the saver locks the Mac, and only with "require password immediately".
            checkPasswordPolicy(context: "lock")
        }
    }

    /// `CGSSessionScreenIsLocked` is present (true) in the session dictionary only while locked.
    private static var sessionLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    /// Logs a warning when the LivePaper lock wouldn't lock (password not required immediately).
    private func checkPasswordPolicy(context: String) {
        probes.async {
            let policy = HelperSystem.passwordPolicy()
            let log = HelperLog.main
            if let warning = policy.warning {
                log.warning("\(context, privacy: .public): \(warning, privacy: .public) [\(policy.source.rawValue, privacy: .public)]")
            } else if policy.requirement == .unknown {
                log.info("\(context, privacy: .public): couldn't determine whether a password is required immediately")
            }
        }
    }

    // MARK: - Open the app

    private func openApp() {
        guard openAppGate.accept(at: Date()) else {
            log.info("openApp repeated within a second; ignored")
            return
        }
        let location = HelperSystem.appLocator.locate(executable: HelperSystem.executableURL)
        guard let url = location.url else {
            log.error("openApp: LivePaper.app not found (the helper isn't inside it and Launch Services doesn't know \(LPPaths.bundleID, privacy: .public))")
            return
        }
        log.notice("opening LivePaper [\(location.source.rawValue, privacy: .public)]")
        let configuration = NSWorkspace.OpenConfiguration()
        // Already running: Launch Services sends a reopen event and the app shows its main window.
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            guard let failure = error?.localizedDescription else { return }
            HelperLog.main.error("couldn't open LivePaper: \(failure, privacy: .public)")
        }
    }
}
