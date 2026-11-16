// PreSleepWatcher — "Show your scene when the screens turn off first" (state.json
// `lock.showSceneBeforeDisplaySleep`, off by default; ARCHITECTURE §7, docs/RESEARCH.md §7).
//
// When the displays turn off before the screen saver would start (on battery: screens off after
// 5 min, screen saver after 15), macOS locks at display sleep with no saver running and the lock
// screen shows the desktop picture. With the option on, the helper starts the screen saver through
// its own lock flow (HelperAgent.lock(.beforeDisplaySleep), so the saver locks and its run gate
// opens) LPPreSleepSchedule.lead (8 s) before the displays would dim; macOS then dims them and turns
// them off on its own schedule, and the saver resumes by itself after they wake.
//
// The decisions are LivePaperCore's (LPPreSleepPolicy, LPPreSleepSchedule — tested there); this
// class gathers the facts, keeps one timer and listens for the events after which they change.
//
// Battery: nothing runs while the option is off — no observers, no timer. While it is on there is
// at most one one-shot timer (DispatchSource, strict, 0.5 s leeway), armed for the moment the idle
// time would reach the threshold (display sleep − lead). When it fires the facts are read again
// (sysadminctl, `pmset -g custom`, powerd's assertions, the HID idle time) and, after activity, it is
// armed again: about once per display-sleep period while the Mac is in use, never every second.
// Nothing is armed while the displays or the Mac sleep, while the session is locked or switched
// out, or while the answer is "doesn't apply" (power-source and energy-setting changes, wake,
// unlock and the option itself evaluate again). While something keeps the displays on (a call), it
// looks again after one threshold and when powerd's assertion summary changes.
//
// It never starts a screen saver after the lock (see main.swift): every start goes through the
// lock flow, which skips when the session is locked or a saver runs. A refused start (the password
// isn't required immediately after all) is only logged — no notification, no app.
import AppKit
import LivePaperCore
import notify
import os

@MainActor
final class PreSleepWatcher: NSObject {
    /// One evaluation's facts, read off the main thread.
    struct Facts: Sendable {
        var situation: LPPreSleepSituation
        var password: HelperPasswordPolicy
        /// Seconds since the last HID input when `readAt`.
        var idle: TimeInterval
        var readAt: Date
        var assertionsReadable: Bool
    }

    private let log = HelperLog.main
    private let probes: DispatchQueue
    /// Starts the screen saver through the agent's lock flow, with the password policy just read.
    private let startScreenSaver: @MainActor (HelperPasswordPolicy) -> Void

    private(set) var enabled = false
    private var timer: DispatchSourceTimer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var notifyTokens: [Int32] = []
    /// Registered only while the displays are kept on (`.blocked`).
    private var assertionsToken: Int32?
    private var evaluating = false
    private var pendingReason: String?
    /// Bumped by everything that disarms: an evaluation that started before must not arm or start.
    private var epoch = 0
    /// The last state logged at notice level ("watching: …", "inactive: …"), so routine re-arms log at info.
    private var lastState: String?

    /// kIOPSNotifyPowerSource (IOPowerSources.h): posted when the providing power source changes.
    static let powerSourceNotification = "com.apple.system.powersources.source"
    /// Posted by powerd when the energy settings change (a string in powerd; not observed live).
    static let energySettingsNotification = "com.apple.system.powermanagement.prefschange"
    /// Posted by powerd when an assertion type's summary level changes.
    static let assertionsNotification = "com.apple.system.powermanagement.assertions"

    init(probes: DispatchQueue, startScreenSaver: @escaping @MainActor (HelperPasswordPolicy) -> Void) {
        self.probes = probes
        self.startScreenSaver = startScreenSaver
    }

    // MARK: - On / off

    /// Follows state.json: turning on starts observing and evaluates; turning off removes everything.
    func setEnabled(_ on: Bool, reason: String) {
        guard on != enabled else { return }
        enabled = on
        if on {
            log.notice("before screens off (\(reason, privacy: .public)): on")
            observe()
            evaluate(reason)
        } else {
            disarm(nil)
            unobserve()
            lastState = nil
            log.notice("before screens off (\(reason, privacy: .public)): off; nothing is watched")
        }
    }

    func stop() { setEnabled(false, reason: "helper stopping") }

    // MARK: - Events

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, Bool, String)] = [
            (NSWorkspace.screensDidSleepNotification, false, "the screens slept"),
            (NSWorkspace.screensDidWakeNotification, true, "the screens woke"),
            (NSWorkspace.willSleepNotification, false, "the Mac is going to sleep"),
            (NSWorkspace.didWakeNotification, true, "the Mac woke"),
            (NSWorkspace.sessionDidResignActiveNotification, false, "the session was switched out"),
            (NSWorkspace.sessionDidBecomeActiveNotification, true, "the session was switched in"),
        ]
        for (name, evaluates, why) in events {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if evaluates { self.evaluate(why) } else { self.disarm(why) }
                }
            })
        }
        // Distributed (object = the uid string); this accessory process is never active, hence
        // .deliverImmediately. Observed only to pause and resume the timer — never to start a saver.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(sessionLocked(_:)), name: .init("com.apple.screenIsLocked"),
                                object: nil, suspensionBehavior: .deliverImmediately)
        distributed.addObserver(self, selector: #selector(sessionUnlocked(_:)), name: .init("com.apple.screenIsUnlocked"),
                                object: nil, suspensionBehavior: .deliverImmediately)
        for (name, why) in [(Self.powerSourceNotification, "the power source changed"),
                            (Self.energySettingsNotification, "the energy settings changed")] {
            if let token = register(name, { [weak self] in self?.evaluate(why) }) { notifyTokens.append(token) }
        }
    }

    private func unobserve() {
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { workspace.removeObserver(observer) }
        workspaceObservers.removeAll()
        DistributedNotificationCenter.default().removeObserver(self)
        for token in notifyTokens { notify_cancel(token) }
        notifyTokens.removeAll()
        watchAssertions(false)
    }

    @objc nonisolated private func sessionLocked(_ note: Notification) {
        onMain { $0.disarm("the session locked") }
    }

    @objc nonisolated private func sessionUnlocked(_ note: Notification) {
        onMain { $0.evaluate("the session unlocked") }
    }

    nonisolated private func onMain(_ body: @escaping @MainActor (PreSleepWatcher) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(self) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body(self) } }
        }
    }

    /// notify(3) on the main queue; nil when the name can't be registered.
    private func register(_ name: String, _ handler: @escaping @MainActor () -> Void) -> Int32? {
        var token: Int32 = 0
        let status = notify_register_dispatch(name, &token, DispatchQueue.main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        guard status == UInt32(NOTIFY_STATUS_OK) else {
            log.error("before screens off: couldn't observe \(name, privacy: .public) (notify status \(status, privacy: .public))")
            return nil
        }
        return token
    }

    /// While the displays are kept on: when powerd's summary changes, a cheap look at the assertions
    /// (an IPC, no subprocess) decides whether a full evaluation is worth it.
    private func watchAssertions(_ watch: Bool) {
        if !watch {
            if let assertionsToken { notify_cancel(assertionsToken) }
            assertionsToken = nil
            return
        }
        guard assertionsToken == nil else { return }
        assertionsToken = register(Self.assertionsNotification) { [weak self] in
            guard let self, self.enabled, let assertions = LPPowerProbe.assertions(),
                  assertions.preventingDisplaySleep.isEmpty else { return }
            self.evaluate("the screens are no longer kept on")
        }
    }

    // MARK: - Evaluation

    /// Reads the facts off the main thread, then decides. Requests that arrive meanwhile are merged
    /// into one more evaluation afterwards.
    private func evaluate(_ reason: String) {
        guard enabled else { return }
        if evaluating {
            pendingReason = reason
            return
        }
        evaluating = true
        let started = epoch
        probes.async {
            let facts = Self.readFacts()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(facts, reason: reason, epoch: started) }
            }
        }
    }

    private func finish(_ facts: Facts, reason: String, epoch started: Int) {
        evaluating = false
        if let pending = pendingReason {
            // Something happened while these facts were read: read them again.
            pendingReason = nil
            evaluate(pending)
            return
        }
        guard enabled, started == epoch else { return }
        act(on: facts, reason: reason)
    }

    /// Everything the decision looks at; blocking (sysadminctl, pmset: ~40 ms together).
    nonisolated static func readFacts() -> Facts {
        let password = HelperSystem.passwordPolicy()
        let timers = HelperSystem.screenTimers()
        let assertions = LPPowerProbe.assertions()
        let situation = LPPreSleepSituation(enabled: true, passwordImmediately: password.immediately, timers: timers,
                                            sessionLocked: HelperSession.isLocked,
                                            screenSaverRunning: HelperProcesses.isScreenSaverEngineRunning,
                                            assertions: assertions ?? LPPowerAssertions())
        // Last, so it is as fresh as possible when the decision is made.
        let idle = HelperSession.idleSeconds
        return Facts(situation: situation, password: password, idle: idle, readAt: Date(), assertionsReadable: assertions != nil)
    }

    private func act(on facts: Facts, reason: String) {
        let timers = facts.situation.timers
        switch LPPreSleepPolicy.decide(facts.situation) {
        case .inactive(let why):
            cancelTimer()
            watchAssertions(false)
            report("inactive: \(why)", reason: reason, detail: "nothing is timed until something changes")
        case .blocked(let why):
            watchAssertions(true)
            let after = LPPreSleepSchedule.recheck(displaySleep: TimeInterval(timers.currentDisplaySleep ?? 300))
            arm(after: after)
            report("blocked: \(why)", reason: reason, detail: "looking again in \(Self.seconds(after)) s or when that ends")
        case .watch(let displaySleep, let screenSaverIdle):
            watchAssertions(false)
            let now = Date()
            let idle = facts.idle + max(0, now.timeIntervalSince(facts.readAt))
            let assertions = facts.situation.assertions
            let userActivityEndsIn = assertions.userActivityEnds?.timeIntervalSince(now)
            let preventionEndsIn = assertions.preventionEnds?.timeIntervalSince(now)
            let state = """
                watching \(timers.currentSource?.phrase ?? "?"): screens off after \(displaySleep) s, screen saver after \
                \(screenSaverIdle == 0 ? "never" : "\(screenSaverIdle) s") [\(timers.screenSaverIdle?.source.rawValue ?? "?")]
                """
            var numbers = "idle \(Self.seconds(idle)) s"
            if let userActivityEndsIn { numbers += ", user activity ends in \(Self.seconds(userActivityEndsIn)) s" }
            if let preventionEndsIn { numbers += ", kept on for \(Self.seconds(preventionEndsIn)) s more" }
            if !facts.assertionsReadable { numbers += ", assertions unreadable" }
            switch LPPreSleepSchedule.next(displaySleep: TimeInterval(displaySleep), idle: idle,
                                           userActivityEndsIn: userActivityEndsIn, preventionEndsIn: preventionEndsIn) {
            case .check(let after):
                arm(after: after)
                report(state, reason: reason, detail: "\(numbers); next check in \(Self.seconds(after)) s")
            case .start(let dimsIn):
                lastState = state
                log.notice("""
                    before screens off (\(reason, privacy: .public)): \(state, privacy: .public); \(numbers, privacy: .public): \
                    the screens dim in \(Self.seconds(dimsIn), privacy: .public) s; starting the screen saver
                    """)
                startScreenSaver(facts.password)
                // Normally the lock that follows disarms this; it only matters if the start didn't lock.
                arm(after: LPPreSleepSchedule.recheck(displaySleep: TimeInterval(displaySleep)))
            case .missed(let checkAfter):
                arm(after: checkAfter)
                lastState = state
                log.notice("""
                    before screens off (\(reason, privacy: .public)): \(state, privacy: .public); \(numbers, privacy: .public): \
                    past the moment (the screens may already be off), not starting; next check in \
                    \(Self.seconds(checkAfter), privacy: .public) s
                    """)
            }
        }
    }

    /// Notice when the state changes, info for the routine re-arm (always with the numbers).
    private func report(_ state: String, reason: String, detail: String) {
        if state != lastState {
            lastState = state
            log.notice("before screens off (\(reason, privacy: .public)): \(state, privacy: .public); \(detail, privacy: .public)")
        } else {
            log.info("before screens off (\(reason, privacy: .public)): \(detail, privacy: .public)")
        }
    }

    private static func seconds(_ value: TimeInterval) -> String { String(format: "%.1f", value) }

    // MARK: - Timer

    private func arm(after seconds: TimeInterval) {
        cancelTimer()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + max(1, seconds), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.evaluate("timer") }
        }
        timer.resume()
        self.timer = timer
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    /// Stops the timer and drops evaluations in flight (the displays slept, the session locked, …).
    /// nil `why`: turned off (logged by the caller).
    private func disarm(_ why: String?) {
        epoch += 1
        pendingReason = nil
        let wasArmed = timer != nil
        cancelTimer()
        watchAssertions(false)
        if let why, enabled {
            lastState = nil
            log.info("before screens off (\(why, privacy: .public)): paused\(wasArmed ? " (timer cancelled)" : "", privacy: .public)")
        }
    }
}
