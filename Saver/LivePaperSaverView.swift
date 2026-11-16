// LivePaperSaverView — the principal class of LivePaper.saver (ARCHITECTURE §6).
//
// Plays the playlist the app publishes into Contents/Resources/Playlist: web scenes in a WKWebView,
// video scenes with AVPlayerLayer, a static fallback when nothing is published. Scenes change every
// `cycleMinutes` with a crossfade; every display shares the session (see SaverSessionPlanner) and
// picks its scene from it by the display mode (SaverDisplayPlan): the same scene, a different one,
// its assigned one or its slice of a spanning one — or a still or nothing on battery.
//
// macOS 26 host notes (legacyScreenSaver, sandboxed, hosted by WallpaperAgent):
//  * stopAnimation() is often never called and views are not released between runs, so we listen
//    for com.apple.screensaver.willstop and exit(0) the host process — but only in real
//    (non-preview) instances: the System Settings preview lives in a host that must keep running.
//  * isPreview is unreliable there; frames narrower than 500 pt are treated as previews too.
//  * The host window is reported as occluded, so WebKit would never draw (see WebSceneHost).
//  * After every unlock WallpaperAgent prewarms a hidden, never-presented instance. A real instance
//    therefore loads nothing until something says a saver is up — a locked session, loginwindow's
//    didstart or a running ScreenSaverEngine (SaverRunGate / SaverGatePolicy) — never on
//    startAnimation alone and never from viewDidMoveToWindow; and it frees its scenes again a few
//    seconds after its gate closes (unlock, stopAnimation).
//  * Every lifecycle step is logged (os_log category `lifecycle`, notice level, so `log show`
//    keeps it) with this view's id, so real lock cycles show which instance did what.
//  * When the user touches the keyboard/mouse, loginwindow draws its lock UI (with Apple's clock)
//    over the running saver, bracketed by com.apple.screenLockUIIsShown / …IsHidden (LPNotification);
//    we hide our clock meanwhile so there are never two clocks.
//  * Nothing should render while the displays sleep (a locked laptop overnight): we pause on
//    NSWorkspace.screensDidSleep and resume on wake.
import AppKit
import ScreenSaver

@objc(LivePaperSaverView)
final class LivePaperSaverView: ScreenSaverView, SceneHostDelegate {
    private static let firstRevealDuration: TimeInterval = 0.6
    private static let cycleCrossfadeDuration: TimeInterval = 2.0
    /// Keep the scene on screen during loginwindow's fade-out before quitting the host.
    private static let exitDelay: TimeInterval = 0.5
    /// A real instance frees its scenes this long after its gate closed for good (unlock,
    /// stopAnimation), unless the gate reopens or willstop ends the process first. Long enough for
    /// loginwindow's fade-out to keep showing the last frame.
    private static let releaseDelay: TimeInterval = 5

    /// Every view in this host process (weak), for the log's "others running" count.
    private static let registry = NSHashTable<LivePaperSaverView>.weakObjects()
    private static var nextInstanceNumber = 1
    /// didstart/didstop seen by any view of this process (a view created later still knows).
    private static var startLatch = SaverStartLatch()

    private struct Plan {
        var deck: SaverDeck
        var schedule: SaverSchedule
        var session: SaverSession
        var record: SaverSessionRecord
        /// How this display takes part (mode, source, liveness, lead, span).
        var displays: SaverDisplayPlan
    }

    private let bundle = Bundle(for: LivePaperSaverView.self)
    private var gate = SaverRunGate(preview: false, sessionLocked: false)
    private var content: SaverContent?
    private var plan: Plan?
    private var shownStep = 0
    /// What the current (or incoming) scene shows: a step change reloads only when this changes.
    private var shownResolved: SaverResolvedScene?
    /// Dev hosts only: the display key this view pretends to be on (`livepaperSetDisplayKey:`).
    private var devDisplayKey: String?
    /// Scenes skipped after repeated failures (added to the deck step so recovery moves on).
    private var skipOffset = 0
    private var current: SceneHost?
    private var incoming: SceneHost?
    private var incomingCrossfade = LivePaperSaverView.firstRevealDuration
    private var cycleTimer: Timer?
    private var retryWork: DispatchWorkItem?
    /// The playlist has been loaded and a scene installed for this run.
    private var started = false
    private var loggedWaitingForLock = false
    private var lockUI = SaverLockUIState()
    private var recovery = SaverRecoveryPolicy()
    private var power = SaverPowerState(onBattery: false, lowPowerMode: false)
    private var powerMonitor: SaverPowerMonitor?
    private var notifications: SaverNotificationRelay?
    private var windowObservers: [NSObjectProtocol] = []
    private var windowVisibility = SaverWindowVisibility()
    private var releaseWork: DispatchWorkItem?
    private var optionsSheet: OptionsSheetController?
    /// "v1", "v2", … within this host process (logs).
    private let instanceID: String
    private let createdAt = Date()
    private var startedAnimationAt: Date?
    private var lastLoggedRun: Bool?

    /// System Settings thumbnails and other small hosts: no lock gate, no cycling, no bookkeeping, no exit.
    private var previewLike: Bool { isPreview || bounds.width < 500 }

    override init?(frame: NSRect, isPreview: Bool) {
        instanceID = Self.takeInstanceID()
        super.init(frame: frame, isPreview: isPreview)
        commonInit(isPreview: isPreview)
    }

    required init?(coder: NSCoder) {
        instanceID = Self.takeInstanceID()
        super.init(coder: coder)
        commonInit(isPreview: isPreview)
    }

    private static func takeInstanceID() -> String {
        defer { nextInstanceNumber += 1 }
        return "v\(nextInstanceNumber)"
    }

    private func commonInit(isPreview: Bool) {
        // We never draw per frame (WebKit and AVFoundation drive their own frames); a long interval
        // keeps ScreenSaverView's own animation timer from waking the CPU for nothing.
        animationTimeInterval = 3600
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        gate.preview = previewLike
        gate.saverStarted = Self.startLatch.started
        Self.registry.add(self)
        notifications = SaverNotificationRelay(distributedNames: SaverSystemEvent.distributedNames) { [weak self] name in
            self?.handleNotification(named: name)
        }
        logLifecycle("init", "isPreview=\(isPreview ? 1 : 0) previewLike=\(previewLike ? 1 : 0) frame=\(Self.describe(frame.size))")
    }

    deinit {
        cycleTimer?.invalidate()
        retryWork?.cancel()
        releaseWork?.cancel()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        SaverLog.lifecycle.notice("event=deinit view=\(self.instanceID, privacy: .public)")
    }

    override var isOpaque: Bool { true }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    override func animateOneFrame() {}

    // MARK: Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
        // Never starts anything for a real instance: only a preview's visibility is re-read.
        refreshWindowVisibility()
        logLifecycle("viewDidMoveToWindow")
        if gate.preview { update() }
    }

    override func startAnimation() {
        super.startAnimation()
        startedAnimationAt = Date()
        gate.animating = true
        gate.preview = previewLike
        // Authoritative at start; the notifications keep them current afterwards.
        gate.sessionLocked = SaverSessionLock.isLocked
        gate.displaysAsleep = saverDisplayIsAsleep
        gate.saverStarted = Self.startLatch.started
        gate.engineRunning = SaverEngineProbe.isRunning
        if gate.preview { gate.previewHostActive = SaverPreviewHost.isActive(frontmostBundleIdentifier: SaverEngineProbe.frontmostBundleIdentifier) }
        refreshWindowVisibility()
        logLifecycle("startAnimation")
        update()
    }

    override func stopAnimation() {
        super.stopAnimation()
        // The sleep notification may arrive just after the host's stopAnimation: ask the displays.
        if !gate.displaysAsleep { gate.displaysAsleep = saverDisplayIsAsleep }
        gate.noteStopAnimation()
        logLifecycle("stopAnimation", gate.resumeOnWake ? "for display sleep; resumes on wake" : "")
        update()
    }

    /// Brings the saver in line with the run gate: loads the playlist the first moment it may,
    /// otherwise pauses or resumes what is on screen, and schedules or cancels the release.
    private func update() {
        if !started {
            if gate.mayLoad {
                begin()
            } else if gate.animating && !loggedWaitingForLock {
                loggedWaitingForLock = true
                SaverLog.saver.info("view \(self.instanceID, privacy: .public) waiting for \(self.gate.waitingFor ?? "?", privacy: .public)")
            }
        } else {
            applyRunState()
        }
        scheduleReleaseIfNeeded()
        let run = gate.shouldRun
        if lastLoggedRun != run {
            if lastLoggedRun != nil || run { logLifecycle(run ? "run" : "pause") }
            lastLoggedRun = run
        }
    }

    /// A real instance whose gate closed for good frees its web view / player (and its WebContent
    /// process) after `releaseDelay`; the next run loads the playlist afresh.
    private func scheduleReleaseIfNeeded() {
        guard started, gate.shouldRelease else {
            releaseWork?.cancel()
            releaseWork = nil
            return
        }
        guard releaseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.releaseWork = nil
            guard self.started, self.gate.shouldRelease else { return }
            self.release()
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseDelay, execute: work)
    }

    private func release() {
        tearDownScenes()
        plan = nil
        shownResolved = nil
        content = nil
        started = false
        shownStep = 0
        skipOffset = 0
        loggedWaitingForLock = false
        logLifecycle("release", "scenes freed; the next run reloads the playlist")
    }

    private func begin() {
        started = true
        loggedWaitingForLock = false
        recovery.reset()
        skipOffset = 0
        // A prewarmed instance may have waited for a long time; re-read what may have gone stale.
        gate.displaysAsleep = saverDisplayIsAsleep
        power = SaverPowerSource.current()
        if powerMonitor == nil { powerMonitor = SaverPowerMonitor { [weak self] in self?.powerChanged() } }

        let content = loadContent()
        self.content = content
        for problem in content.problems { SaverLog.saver.error("playlist: \(problem, privacy: .public)") }
        guard let playlist = content.playlist, !content.isEmpty else {
            SaverLog.saver.info("no playable scenes; showing the fallback")
            logLifecycle("load", "fallback")
            install(FallbackSceneHost(reason: .noScenes, context: fallbackContext()), crossfade: Self.firstRevealDuration)
            applyRunState()
            return
        }

        // A display that starts while another display of this process runs joins that display's
        // session whatever its age (a display connected mid-run must share the time origin); the
        // shared store is the fallback across processes.
        let store = SaverSessionStores.shared
        let planned = inProcessSession() ?? SaverSessionPlanner.plan(now: Date(), stored: store.load())
        let displays = currentDisplayPlan(content)
        let deck = SaverDeck(ids: content.entries.map(\.id), mode: playlist.mode, session: planned.session,
                             spread: displays.spread, previous: displays.previous(for: planned.session))
        let schedule = SaverSchedule(startedAt: planned.session.startedAt, cycleMinutes: playlist.cycleMinutes,
                                     deckCount: deck.count, mode: playlist.mode, cycles: !gate.preview)
        plan = Plan(deck: deck, schedule: schedule, session: planned.session, record: planned.record, displays: displays)
        SaverLog.saver.notice("""
            start: publish \(playlist.generation, privacy: .public), \(deck.count, privacy: .public) scenes, \
            \(playlist.mode.rawValue, privacy: .public), \(planned.joined ? "joined" : "new", privacy: .public) session \
            \(planned.session.epoch, privacy: .public), preview \(self.gate.preview, privacy: .public), \
            \(displays.summary, privacy: .public)
            """)
        logLifecycle("load", "publish=\(playlist.generation) scenes=\(deck.count) \(displays.summary) displays=[\(Self.describe(displays.layout))]")
        if displays.liveness == .off {
            // Battery, "other displays show nothing": no scene, no timers — black.
            logLifecycle("display-off", "on battery or in Low Power Mode; this display stays black")
        } else {
            show(step: schedule.step(at: Date()), crossfade: Self.firstRevealDuration)
        }
        applyRunState()
    }

    /// The session of the running view of this process that started it most recently, if any.
    private func inProcessSession() -> (session: SaverSession, record: SaverSessionRecord, joined: Bool)? {
        guard !gate.preview else { return nil }
        let running = Self.registry.allObjects.filter { $0 !== self && $0.started && $0.gate.shouldRun && !$0.gate.preview && $0.plan != nil }
        guard let other = running.max(by: { ($0.plan?.session.epoch ?? 0) < ($1.plan?.session.epoch ?? 0) }), let p = other.plan else { return nil }
        return (p.session, p.record, true)
    }

    /// This view's display: its key (dev hosts may set one), read fresh.
    private var saverDisplayKey: String? { devDisplayKey ?? saverScreenDisplayKey }

    /// The display plan for the arrangement and power state right now.
    private func currentDisplayPlan(_ content: SaverContent) -> SaverDisplayPlan {
        SaverDisplayPlan.make(settings: content.playlist?.displays ?? .standard, layout: SaverDisplays.current(), key: saverDisplayKey,
                              content: content, power: power, preview: gate.preview)
    }

    /// Displays changed (connected, rearranged, this window moved) or the power state did: follow
    /// them — another slice or scene, live ⇄ still, or black.
    private func refreshDisplayPlan(reason: String) {
        guard started, let content, content.playlist != nil, !content.isEmpty, var plan else { return }
        let displays = currentDisplayPlan(content)
        guard displays != plan.displays else { return }
        let old = plan.displays
        plan.displays = displays
        plan.deck = SaverDeck(ids: content.entries.map(\.id), mode: plan.deck.mode, session: plan.session,
                              spread: displays.spread, previous: displays.previous(for: plan.session))
        self.plan = plan
        logLifecycle("displays", "reason=\(reason) \(displays.summary) displays=[\(Self.describe(displays.layout))]")
        if displays.liveness == .off {
            tearDownScenes()
            shownResolved = nil
        } else {
            let step = plan.schedule.step(at: Date())
            let next = displays.resolve(step: step, skipOffset: skipOffset, deck: plan.deck, content: content, session: plan.session,
                                        schedule: plan.schedule)
            if next != shownResolved || old.liveness == .off || (current == nil && incoming == nil) {
                show(step: step, crossfade: Self.firstRevealDuration)
            } else {
                current?.setLiveness(displays.liveness)
                incoming?.setLiveness(displays.liveness)
            }
        }
        applyRunState()
    }

    /// "37D8832A 0,0 1512x982 2x built-in; …" (the log keeps only a key prefix).
    private static func describe(_ layout: LPDisplayLayout) -> String {
        layout.displays.map { d in
            "\(d.id.prefix(8)) \(Int(d.frame.x)),\(Int(d.frame.y)) \(Int(d.frame.width))x\(Int(d.frame.height)) \(String(format: "%g", d.scale))x"
                + (d.isBuiltin ? " built-in" : "") + (d.isMenuBar ? " menu-bar" : "")
        }.joined(separator: "; ")
    }

    private func loadContent() -> SaverContent {
        guard let resources = bundle.resourceURL else {
            return .empty(directory: URL(fileURLWithPath: "/"), problem: "the saver bundle has no Resources folder")
        }
        return SaverPlaylistLoader.load(from: resources.appendingPathComponent(LPPlaylist.directoryName, isDirectory: true))
    }

    /// Pauses or resumes everything and (re)arms the cycle timer. Paused = no timers, no frames.
    private func applyRunState() {
        let run = gate.shouldRun
        current?.setPaused(!run)
        incoming?.setPaused(!run)
        cycleTimer?.invalidate()
        cycleTimer = nil
        if run { catchUpAndScheduleCycle() }
    }

    /// Shows the scene for the current schedule step (after sleep or a pause the step may have moved
    /// on) and arms a one-shot timer for the next change.
    private func catchUpAndScheduleCycle() {
        guard let plan, plan.displays.liveness != .off, let next = plan.schedule.nextChange(after: Date()) else { return }
        let step = plan.schedule.step(at: Date())
        if step != shownStep {
            // An assigned scene (or a deck too small for every display) doesn't change: no reload.
            if let content, let r = plan.displays.resolve(step: step, skipOffset: skipOffset, deck: plan.deck, content: content,
                                                          session: plan.session, schedule: plan.schedule), r == shownResolved {
                shownStep = step
            } else {
                show(step: step, crossfade: Self.cycleCrossfadeDuration)
            }
        }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            guard let self, self.gate.shouldRun else { return }
            self.catchUpAndScheduleCycle()
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        cycleTimer = timer
    }

    private func prepareToExit() {
        guard !gate.exiting else { return }
        gate.exiting = true
        cycleTimer?.invalidate()
        cycleTimer = nil
        retryWork?.cancel()
        releaseWork?.cancel()
        releaseWork = nil
        SaverLog.saver.info("screen saver stopping; quitting the host")
        logLifecycle("exit", "in \(Self.exitDelay) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitDelay) { exit(0) }
    }

    private func restart() {
        tearDownScenes()
        plan = nil
        shownResolved = nil
        started = false
        update()
    }

    private func tearDownScenes() {
        cycleTimer?.invalidate()
        cycleTimer = nil
        retryWork?.cancel()
        retryWork = nil
        incoming?.tearDown()
        current?.tearDown()
        incoming = nil
        current = nil
    }

    // MARK: System events

    /// Routes a system notification by name. Every observer funnels through here; it is also the
    /// hook scripts/dev/saverhost-lp.swift uses to simulate lock, lock-UI and sleep events
    /// in-process, so tests never broadcast system notifications.
    @objc(livepaperHandleNotificationNamed:)
    func handleNotification(named name: String) {
        guard let event = SaverSystemEvent(notificationName: name) else { return }
        Self.startLatch.apply(event)
        switch event {
        case .lockUIShown, .lockUIHidden:
            applyLockUI(event)
            logLifecycle(event.rawValue)
        case .previewHostActivated, .previewHostDeactivated:
            // Posted on every app switch: only a preview cares, and only about a change.
            let before = gate.previewHostActive
            gate.apply(event)
            guard gate.preview, gate.previewHostActive != before else { return }
            logLifecycle(event.rawValue)
            update()
        case .screenLocked, .screenUnlocked, .screensDidSleep, .screensDidWake, .saverDidStart, .saverDidStop,
             .engineLaunched, .engineTerminated:
            gate.apply(event)
            // Re-read on the moments that matter (the launch notification may not be posted for
            // the background-only engine); the engine events themselves are authoritative.
            if event != .engineLaunched && event != .engineTerminated { gate.engineRunning = SaverEngineProbe.isRunning }
            // Unlocking removes the lock UI even if its IsHidden notification was missed.
            if event == .screenUnlocked { applyLockUI(event) }
            logLifecycle(event.rawValue)
            update()
        case .windowChanged:
            refreshWindowVisibility()
            logLifecycle(event.rawValue)
            update()
            // The window may have moved to another display.
            refreshDisplayPlan(reason: "window")
        case .screensChanged:
            logLifecycle(event.rawValue, "displays=[\(Self.describe(SaverDisplays.current()))]")
            refreshDisplayPlan(reason: "screens")
        case .willStop:
            gate.apply(event)
            logLifecycle(event.rawValue, previewLike ? "ignored by previews" : "")
            if !previewLike {
                // Mark the session ended so a quick re-lock starts a new one (different scene). Every
                // display's view gets here; the first marks the stored record, the rest find it marked.
                if let plan {
                    let store = SaverSessionStores.shared
                    if let ended = SaverSessionPlanner.recordEnded(at: Date().timeIntervalSince1970, own: plan.record,
                                                                   stored: store.load()) {
                        store.save(ended)
                    }
                }
                prepareToExit()
            }
        case .published:
            // Real sessions read the playlist once at start; previews follow the app live.
            if previewLike && started { restart() }
        }
    }

    /// Dev hosts only (LIVEPAPER_SAVER_SIMULATED_SYSTEM): the display this view is on, by key, since
    /// their off-screen windows aren't on the simulated displays. Ignored in the real host.
    @objc(livepaperSetDisplayKey:)
    func setDevDisplayKey(_ key: NSString?) {
        guard SaverDevOverrides.simulatedSystem else { return }
        devDisplayKey = key.map { LPDisplay.normalizedID($0 as String) }
        refreshDisplayPlan(reason: "dev")
    }

    // MARK: Window (previews' visibility; logs)

    private func observeWindow() {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
        guard let window else { return }
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                                          NSWindow.didChangeScreenNotification]
        for name in names {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.handleNotification(named: SaverSystemEvent.windowChangedName)
            })
        }
    }

    private func refreshWindowVisibility() {
        guard let window else { gate.windowVisible = false; return }
        gate.windowVisible = windowVisibility.isVisible(orderedIn: window.isVisible, miniaturized: window.isMiniaturized,
                                                        occlusionVisible: window.occlusionState.contains(.visible))
    }

    // MARK: Lifecycle log

    private static func describe(_ size: NSSize) -> String { "\(Int(size.width))x\(Int(size.height))" }

    private var windowSummary: String {
        guard let window else { return "none" }
        let screen = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "?"
        return "#\(window.windowNumber) visible=\(window.isVisible ? 1 : 0) occlusionVisible=\(window.occlusionState.contains(.visible) ? 1 : 0) "
            + "level=\(window.level.rawValue) screen=\(screen) size=\(Self.describe(window.frame.size))"
    }

    /// One structured line per lifecycle step: `event=… view=… <gate> started=… window=…`. The
    /// process id is part of every os_log entry. Notice level, so the lines are persisted.
    private func logLifecycle(_ event: String, _ detail: String = "") {
        let others = Self.registry.allObjects.filter { $0 !== self && $0.gate.shouldRun }.count
        let sinceStart = startedAnimationAt.map { String(format: "%.1f", Date().timeIntervalSince($0)) } ?? "-"
        let line = "event=\(event) view=\(instanceID) preview=\(gate.preview ? 1 : 0) \(gate.summary) started=\(started ? 1 : 0) "
            + "othersRunning=\(others) age=\(String(format: "%.1f", Date().timeIntervalSince(createdAt))) sinceStart=\(sinceStart) "
            + "window=[\(windowSummary)]" + (detail.isEmpty ? "" : " \(detail)")
        SaverLog.lifecycle.notice("\(line, privacy: .public)")
    }

    private func applyLockUI(_ event: SaverSystemEvent) {
        guard lockUI.apply(event) else { return }
        SaverLog.saver.debug("lock UI \(self.lockUI.isShowing ? "showing" : "hidden", privacy: .public)")
        current?.setLockUIShowing(lockUI.isShowing, animated: true)
        incoming?.setLockUIShowing(lockUI.isShowing, animated: false)
    }

    private func powerChanged() {
        let now = SaverPowerSource.current()
        guard now != power else { return }
        power = now
        let profile = resolvedProfile
        SaverLog.saver.info("power changed: battery saver \(now.prefersBatterySaver, privacy: .public) → \(profile.fps, privacy: .public) fps")
        current?.powerDidChange(profile: profile, power: now)
        incoming?.powerDidChange(profile: profile, power: now)
        // Other displays may switch to a still or to black on battery (and back).
        refreshDisplayPlan(reason: "power")
    }

    private var resolvedProfile: LPPerformanceProfile.Resolved {
        SaverPerformance.resolve(content?.playlist?.performance ?? .automatic, power: power, preview: gate.preview, policy: gate.policy)
    }

    // MARK: Scenes

    private func show(step: Int, crossfade: TimeInterval) {
        guard let plan, let content, !content.isEmpty, plan.displays.liveness != .off else { return }
        shownStep = step
        guard let resolved = plan.displays.resolve(step: step, skipOffset: skipOffset, deck: plan.deck, content: content,
                                                   session: plan.session, schedule: plan.schedule) else { return }
        let entry = resolved.entry
        if plan.displays.recordsHistory { rememberShown(entry.id) }
        var context = SceneContext(showClock: content.playlist?.showClock ?? true, clockPosition: entry.clock,
                                   lockUIShowing: lockUI.isShowing, paused: !gate.shouldRun, profile: resolvedProfile,
                                   power: power, seed: plan.session.sceneSeed)
        context.liveness = plan.displays.liveness
        context.span = resolved.span
        // A spanning scene has one clock, on the main display.
        context.clockOnThisDisplay = resolved.span == nil || plan.displays.isMain
        context.generation = content.playlist?.generation ?? 0
        let url = content.fileURL(for: entry)
        let host: SceneHost
        switch entry.kind {
        case .web: host = WebSceneHost(entry: entry, fileURL: url, context: context)
        case .video: host = VideoSceneHost(entry: entry, fileURL: url, context: context)
        }
        shownResolved = resolved
        SaverLog.saver.notice("""
            showing \(entry.id, privacy: .public) (\(entry.kind.rawValue, privacy: .public)), step \(step, privacy: .public), \
            \(plan.displays.liveness.rawValue, privacy: .public)\(resolved.span == nil ? "" : " span", privacy: .public)\
            \(plan.displays.isAssigned ? " assigned" : "", privacy: .public)
            """)
        install(host, crossfade: crossfade)
    }

    /// Bookkeeping for no-repeat: adds the scene to the recent history the next session's first scene
    /// avoids (never to this session's deck: see `SaverSessionRecord.startRecent`), and to what this
    /// display showed last. Only the lead display writes `lastShown` (all of them but in "Different").
    /// Previews never write.
    private func rememberShown(_ id: String) {
        guard !gate.preview, var plan else { return }
        let store = SaverSessionStores.shared
        let display = plan.displays.key, lead = plan.displays.isLead
        let update = SaverSessionPlanner.recordShown(id, own: plan.record, stored: store.load(), now: Date(),
                                                     display: display, updatesLastShown: lead)
        plan.record.noteShown(id, display: display, updatesLastShown: lead)
        self.plan = plan
        if let update { store.save(update) }
    }

    private func fallbackContext() -> SceneContext {
        var context = SceneContext(showClock: content?.playlist?.showClock ?? true, clockPosition: .top, lockUIShowing: lockUI.isShowing,
                                   paused: !gate.shouldRun, profile: resolvedProfile, power: power, seed: 1)
        context.liveness = plan?.displays.liveness == .still ? .still : .live
        return context
    }

    /// Adds a scene invisibly above the current one and starts loading it; it fades in when ready.
    private func install(_ host: SceneHost, crossfade: TimeInterval) {
        incoming?.tearDown()
        host.delegate = self
        host.view.frame = bounds
        host.view.autoresizingMask = [.width, .height]
        host.view.alphaValue = 0
        addSubview(host.view, positioned: .above, relativeTo: current?.view)
        incoming = host
        incomingCrossfade = crossfade
        host.load()
    }

    func sceneHostDidBecomeReady(_ host: SceneHost) {
        guard host === incoming else { return }
        let old = current
        current = host
        incoming = nil
        host.setPaused(!gate.shouldRun)
        // A true crossfade: the new scene fades in on top, then the old one is released.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = incomingCrossfade
            host.view.animator().alphaValue = 1
        }, completionHandler: {
            old?.tearDown()
        })
    }

    func sceneHost(_ host: SceneHost, didFail reason: String) {
        guard host === incoming || host === current else { return }
        SaverLog.saver.error("scene \(host.entryID, privacy: .public) failed: \(reason, privacy: .public)")
        switch recovery.recordFailure(at: Date()) {
        case .giveUp:
            // Rather than crash-looping all night, show the static fallback; the next cycle tries again.
            SaverLog.saver.error("too many scene failures; showing the fallback")
            retryWork?.cancel()
            install(FallbackSceneHost(reason: .scenesFailed, context: fallbackContext()), crossfade: Self.firstRevealDuration)
        case .retry(let delay, let skip):
            // An assigned scene gives way to the playlist; the playlist skips ahead when it can.
            if skip, let plan, plan.deck.count > 1 || (plan.displays.isAssigned && skipOffset == 0) { skipOffset += 1 }
            retryWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.started, !self.gate.exiting else { return }
                self.show(step: self.shownStep, crossfade: Self.firstRevealDuration)
            }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    // MARK: Options sheet

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let sheet = OptionsSheetController(summary: SaverSummary.make(content: content ?? loadContent(), version: version))
        optionsSheet = sheet
        return sheet.window
    }

    // MARK: Diagnostics

    /// Current state, for the dev host (scripts/dev/saverhost-lp.swift) and bug reports.
    @objc(livepaperDiagnostics)
    var diagnostics: NSDictionary {
        var d: [String: Any] = [
            "view": instanceID, "preview": gate.preview, "sessionLocked": gate.sessionLocked, "animating": gate.animating,
            "started": started, "running": gate.shouldRun, "displaysAsleep": gate.displaysAsleep,
            "saverStarted": gate.saverStarted, "engineRunning": gate.engineRunning, "windowVisible": gate.windowVisible,
            "previewHostActive": gate.previewHostActive, "releasePending": releaseWork != nil, "gate": gate.summary,
            "lockUIShowing": lockUI.isShowing, "generation": content?.playlist?.generation ?? -1,
            "scene": current?.entryID ?? "", "kind": current?.kind ?? "none", "loading": incoming?.entryID ?? NSNull(),
            "problems": content?.problems ?? [], "step": shownStep, "skipOffset": skipOffset,
        ]
        if let plan {
            d["deck"] = (0..<plan.deck.count).map { plan.deck.ids[plan.deck.entryIndex(atStep: $0)] }
            d["session"] = plan.session.epoch
            d["cycleSeconds"] = plan.schedule.cycle ?? 0
            let p = plan.displays
            d["display"] = p.key ?? NSNull(); d["displayIndex"] = p.index; d["displayCount"] = p.layout.count
            d["displayMode"] = p.mode.rawValue; d["liveness"] = p.liveness.rawValue; d["isMain"] = p.isMain; d["isLead"] = p.isLead
            d["assigned"] = p.isAssigned; d["span"] = shownResolved?.span != nil
        }
        if let current { d["current"] = current.diagnostics }
        return d as NSDictionary
    }
}
