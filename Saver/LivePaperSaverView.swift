// LivePaperSaverView — the principal class of LivePaper.saver (ARCHITECTURE §6).
//
// Plays the playlist the app publishes into Contents/Resources/Playlist: web scenes in a WKWebView,
// video scenes with AVPlayerLayer, a static fallback when nothing is published. Scenes change every
// `cycleMinutes` with a crossfade; every display agrees on the scene (see SaverSessionPlanner).
//
// macOS 26 host notes (legacyScreenSaver, sandboxed, hosted by WallpaperAgent):
//  * stopAnimation() is often never called and views are not released between runs, so we listen
//    for com.apple.screensaver.willstop and exit(0) the host process — but only in real
//    (non-preview) instances: the System Settings preview lives in a host that must keep running.
//  * isPreview is unreliable there; frames narrower than 500 pt are treated as previews too.
//  * The host window is reported as occluded, so WebKit would never draw (see WebSceneHost).
//  * When the user touches the keyboard/mouse, loginwindow draws its lock UI (with Apple's clock)
//    over the running saver, bracketed by com.apple.sessionagent.screenLockUIIs{Showing,Shown,Hidden};
//    we hide our clock meanwhile so there are never two clocks.
//  * Nothing should render while the displays sleep (a locked laptop overnight): we pause on
//    NSWorkspace.screensDidSleep and resume on wake.
import AppKit
import ScreenSaver

@objc(LivePaperSaverView)
final class LivePaperSaverView: ScreenSaverView, SceneHostDelegate {
    private static let firstRevealDuration: TimeInterval = 0.6
    private static let cycleCrossfadeDuration: TimeInterval = 2.0
    /// Some hosts add the view to a window but never call startAnimation; start anyway after this.
    private static let unstartedGrace: TimeInterval = 0.5
    /// Keep the scene on screen during loginwindow's fade-out before quitting the host.
    private static let exitDelay: TimeInterval = 0.5

    private struct Plan {
        var deck: SaverDeck
        var schedule: SaverSchedule
        var session: SaverSession
        var record: SaverSessionRecord
    }

    private let bundle = Bundle(for: LivePaperSaverView.self)
    private var content: SaverContent?
    private var plan: Plan?
    private var shownStep = 0
    /// Scenes skipped after repeated failures (added to the deck step so recovery moves on).
    private var skipOffset = 0
    private var current: SceneHost?
    private var incoming: SceneHost?
    private var incomingCrossfade = LivePaperSaverView.firstRevealDuration
    private var cycleTimer: Timer?
    private var retryWork: DispatchWorkItem?
    private var started = false
    private var exiting = false
    private var displaysAsleep = false
    private var lockUI = SaverLockUIState()
    private var recovery = SaverRecoveryPolicy()
    private var power = SaverPowerState(onBattery: false, lowPowerMode: false)
    private var powerMonitor: SaverPowerMonitor?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var optionsSheet: OptionsSheetController?

    /// System Settings thumbnails and other small hosts: no cycling, no bookkeeping, no exit.
    private var previewLike: Bool { isPreview || bounds.width < 500 }
    private var shouldRun: Bool { isAnimating && !displaysAsleep && !exiting }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // We never draw per frame (WebKit and AVFoundation drive their own frames); a long interval
        // keeps ScreenSaverView's own animation timer from waking the CPU for nothing.
        animationTimeInterval = 3600
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        let distributed = DistributedNotificationCenter.default()
        for name in SaverSystemEvent.distributedNames {
            let token = distributed.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] note in
                self?.handleNotification(named: note.name.rawValue)
            }
            observers.append((distributed, token))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.handleNotification(named: note.name.rawValue)
            }
            observers.append((workspace, token))
        }
    }

    deinit {
        for observer in observers { observer.center.removeObserver(observer.token) }
        cycleTimer?.invalidate()
        retryWork?.cancel()
    }

    override var isOpaque: Bool { true }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    override func animateOneFrame() {}

    // MARK: Lifecycle

    override func startAnimation() {
        super.startAnimation()
        if started { applyRunState() } else { begin() }
    }

    override func stopAnimation() {
        super.stopAnimation()
        applyRunState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !started else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.unstartedGrace) { [weak self] in
            guard let self, !self.started, self.window != nil else { return }
            self.begin()
        }
    }

    private func begin() {
        started = true
        recovery.reset()
        skipOffset = 0
        displaysAsleep = saverDisplayIsAsleep
        power = SaverPowerSource.current()
        if powerMonitor == nil { powerMonitor = SaverPowerMonitor { [weak self] in self?.powerChanged() } }

        let content = loadContent()
        self.content = content
        for problem in content.problems { SaverLog.saver.error("playlist: \(problem, privacy: .public)") }
        guard let playlist = content.playlist, !content.isEmpty else {
            SaverLog.saver.info("no playable scenes; showing the fallback")
            install(FallbackSceneHost(reason: .noScenes, context: fallbackContext()), crossfade: Self.firstRevealDuration)
            applyRunState()
            return
        }

        let store = SaverSessionStores.shared
        let planned = SaverSessionPlanner.plan(now: Date(), stored: store.load())
        let deck = SaverDeck(ids: content.entries.map(\.id), mode: playlist.mode, seed: planned.session.shuffleSeed,
                             avoid: planned.session.avoid)
        let schedule = SaverSchedule(startedAt: planned.session.startedAt, cycleMinutes: playlist.cycleMinutes,
                                     deckCount: deck.count, mode: playlist.mode, cycles: !previewLike)
        plan = Plan(deck: deck, schedule: schedule, session: planned.session, record: planned.record)
        SaverLog.saver.info("""
            start: publish \(playlist.generation, privacy: .public), \(deck.count, privacy: .public) scenes, \
            \(playlist.mode.rawValue, privacy: .public), \(planned.joined ? "joined" : "new", privacy: .public) session \
            \(planned.session.epoch, privacy: .public), preview \(self.previewLike, privacy: .public)
            """)
        show(step: schedule.step(at: Date()), crossfade: Self.firstRevealDuration)
        applyRunState()
    }

    private func loadContent() -> SaverContent {
        guard let resources = bundle.resourceURL else {
            return .empty(directory: URL(fileURLWithPath: "/"), problem: "the saver bundle has no Resources folder")
        }
        return SaverPlaylistLoader.load(from: resources.appendingPathComponent(LPPlaylist.directoryName, isDirectory: true))
    }

    /// Pauses or resumes everything and (re)arms the cycle timer. Stopped = no timers, no frames.
    private func applyRunState() {
        let run = shouldRun
        current?.setPaused(!run)
        incoming?.setPaused(!run)
        cycleTimer?.invalidate()
        cycleTimer = nil
        if run { catchUpAndScheduleCycle() }
    }

    private func catchUpAndScheduleCycle() {
        guard let plan, let next = plan.schedule.nextChange(after: Date()) else { return }
        let step = plan.schedule.step(at: Date())
        if step != shownStep { show(step: step, crossfade: Self.cycleCrossfadeDuration) }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            guard let self, self.shouldRun else { return }
            self.catchUpAndScheduleCycle()
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        cycleTimer = timer
    }

    private func prepareToExit() {
        guard !exiting else { return }
        exiting = true
        cycleTimer?.invalidate()
        cycleTimer = nil
        retryWork?.cancel()
        SaverLog.saver.info("screen saver stopping; quitting the host")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitDelay) { exit(0) }
    }

    private func restart() {
        tearDownScenes()
        plan = nil
        started = false
        begin()
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
    /// hook scripts/dev/saverhost-lp.swift uses to simulate lock-UI / sleep events in-process, so
    /// tests never broadcast system notifications.
    @objc(livepaperHandleNotificationNamed:)
    func handleNotification(named name: String) {
        guard let event = SaverSystemEvent(notificationName: name) else { return }
        switch event {
        case .lockUIShowing, .lockUIShown, .lockUIHidden, .screenUnlocked:
            // Unlocking ends the saver through willstop; here it only guarantees the clock comes back
            // if the lock UI's IsHidden notification was missed.
            guard lockUI.apply(event) else { return }
            SaverLog.saver.debug("lock UI \(self.lockUI.isShowing ? "showing" : "hidden", privacy: .public)")
            current?.setLockUIShowing(lockUI.isShowing, animated: true)
            incoming?.setLockUIShowing(lockUI.isShowing, animated: false)
        case .willStop:
            if !previewLike { prepareToExit() }
        case .screensDidSleep:
            displaysAsleep = true
            applyRunState()
        case .screensDidWake:
            displaysAsleep = false
            applyRunState()
        case .published:
            // Real sessions read the playlist once at start; previews follow the app live.
            if previewLike && started { restart() }
        }
    }

    private func powerChanged() {
        let now = SaverPowerSource.current()
        guard now != power else { return }
        power = now
        let profile = resolvedProfile
        SaverLog.saver.info("power changed: battery saver \(now.prefersBatterySaver, privacy: .public) → \(profile.fps, privacy: .public) fps")
        current?.powerDidChange(profile: profile, power: now)
        incoming?.powerDidChange(profile: profile, power: now)
    }

    private var resolvedProfile: LPPerformanceProfile.Resolved {
        SaverPerformance.resolve(content?.playlist?.performance ?? .automatic, power: power, preview: previewLike)
    }

    // MARK: Scenes

    private func show(step: Int, crossfade: TimeInterval) {
        guard let plan, let content, !content.isEmpty else { return }
        shownStep = step
        let entry = content.entries[plan.deck.entryIndex(atStep: step + skipOffset)]
        rememberShown(entry.id)
        let context = SceneContext(showClock: content.playlist?.showClock ?? true, clockPosition: entry.clock,
                                   lockUIShowing: lockUI.isShowing, paused: !shouldRun, profile: resolvedProfile,
                                   power: power, seed: plan.session.sceneSeed, preview: previewLike)
        let url = content.fileURL(for: entry)
        let host: SceneHost
        switch entry.kind {
        case .web: host = WebSceneHost(entry: entry, fileURL: url, context: context)
        case .video: host = VideoSceneHost(entry: entry, fileURL: url, context: context)
        }
        SaverLog.saver.info("showing \(entry.id, privacy: .public) (\(entry.kind.rawValue, privacy: .public)), step \(step, privacy: .public)")
        install(host, crossfade: crossfade)
    }

    /// Bookkeeping for no-repeat: the next session avoids the scene shown last. Previews never write.
    private func rememberShown(_ id: String) {
        guard !previewLike, var plan, plan.record.lastShown != id else { return }
        plan.record.lastShown = id
        self.plan = plan
        SaverSessionStores.shared.save(plan.record)
    }

    private func fallbackContext() -> SceneContext {
        SceneContext(showClock: content?.playlist?.showClock ?? true, clockPosition: .top, lockUIShowing: lockUI.isShowing,
                     paused: !shouldRun, profile: resolvedProfile, power: power, seed: 1, preview: previewLike)
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
        host.setPaused(!shouldRun)
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
            if skip, let plan, plan.deck.count > 1 { skipOffset += 1 }
            retryWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.started, !self.exiting else { return }
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
            "preview": previewLike, "started": started, "running": shouldRun, "displaysAsleep": displaysAsleep,
            "lockUIShowing": lockUI.isShowing, "generation": content?.playlist?.generation ?? -1,
            "scene": current?.entryID ?? "", "kind": current?.kind ?? "none", "loading": incoming?.entryID ?? NSNull(),
            "problems": content?.problems ?? [], "step": shownStep, "skipOffset": skipOffset,
        ]
        if let plan {
            d["deck"] = (0..<plan.deck.count).map { plan.deck.ids[plan.deck.entryIndex(atStep: $0)] }
            d["session"] = plan.session.epoch
            d["cycleSeconds"] = plan.schedule.cycle ?? 0
        }
        if let current { d["current"] = current.diagnostics }
        return d as NSDictionary
    }
}
