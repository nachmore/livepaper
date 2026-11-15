// FullScreenPreview — shows a scene, or a playlist's scenes, on a whole screen exactly as the screen
// saver would: the same compiled HTML and runtime configuration for web scenes (playlist clock,
// performance profile, real devicePixelRatio, fps cap — Saver/SaverLogic.swift's SaverWebConfig),
// the same AVPlayerLayer and native clock (Saver/ClockOverlay.swift) for video scenes.
//
// The window is borderless and black, covers only the chosen screen (the main window's, or the one
// under the pointer for the menu bar) and sits above normal windows (status-bar level) but far
// below the screen saver and the lock screen's shield. While it is up the menu bar and Dock are
// hidden (presentation options) and the pointer hides after 2 s without movement.
//
// Controls: Esc, a click, ⌘. (and Space, as in Quick Look) close it with a 0.25 s fade; ← → step
// through the library or playlist order; C toggles the clock; L simulates the lock UI
// (LivePaper.host.lockUI) so the clock hand-off can be seen. Every key acts once per press (a held
// key's repeats do nothing), and the press that closed it is swallowed until it is released, so it
// can't reopen the preview from the library card or the menu, or type into the app that gets focus
// back (FullScreenKeys, FullScreenClosingKey). The hint bar fades out after 3 s and returns when the
// pointer moves. A playlist preview also changes scene by itself on the playlist's "Change scene"
// cadence, as the saver does.
//
// Power: the scene runs only while the window can be seen (LiveSceneHostView), and a web scene
// follows AC ⇄ battery and Low Power Mode changes as in the saver (LivePaper.host.power). Closing
// stops it at once (frozen for the fade, released right after). It closes when it loses the
// keyboard — switching to another app, or another LivePaper window becoming key (a click on one on
// another display, the main window brought forward to explain a refused lock) — and at once when
// the app hides, the displays sleep, the session locks or switches, or a screen saver starts: the
// real saver takes over then. Nothing is left running once it is closed: no timer, no observer, no
// web view (only the wait for the closing key's release, which ends with it).
import AppKit
import IOKit.ps
import LivePaperCore
import notify
import SwiftUI

@MainActor
final class FullScreenPreviewController {
    static let shared = FullScreenPreviewController()
    private var session: FullScreenPreviewSession?

    var isPresented: Bool { session != nil }

    /// Opens the preview (replacing one that is already up).
    func present(_ request: FullScreenPreviewRequest, model: AppModel, origin: FullScreenPreviewOrigin) {
        session?.close(.immediately)
        let screens = NSScreen.screens
        guard let index = FullScreenScreenChoice.index(screens: screens.map(\.frame), origin: origin, pointer: NSEvent.mouseLocation)
        else { return }
        let session = FullScreenPreviewSession(request: request, model: model, screen: screens[index])
        session.onEnd = { [weak self, weak session] in
            guard let self, let session, self.session === session else { return }
            self.session = nil
        }
        self.session = session
        session.open()
    }

    func close() { session?.close(.byUser) }
}

// MARK: - One presentation

@MainActor
private final class FullScreenPreviewSession {
    enum CloseReason {
        /// Esc, a click, ⌘., Space: fade out, then give focus back to the app that had it.
        case byUser
        /// Another app became active: fade out.
        case deactivated
        /// Hidden, asleep, locked, replaced: gone at once.
        case immediately
    }

    private enum Phase { case created, open, closing, closed }

    /// What the preview runs on, as the saver resolves it (the profile's fps and render scale).
    private static func currentPower() -> SaverPowerState {
        let power = PowerSource.current()
        return SaverPowerState(onBattery: power.onBattery, lowPowerMode: power.lowPower)
    }

    static let hintTimeout: TimeInterval = 3
    static let pointerTimeout: TimeInterval = 2
    static let fadeIn: TimeInterval = 0.2
    static let fadeOut: TimeInterval = 0.25

    var onEnd: (() -> Void)?

    private let model: AppModel
    private var sequence: FullScreenPreviewSequence
    /// AI results (not in the library) and per-scene labels, from the request.
    private let request: FullScreenPreviewRequest
    private let performance: LPPerformanceProfile
    /// Playlist previews move on by themselves, like the saver (nil: only ← →).
    private let autoAdvance: TimeInterval?
    private var advanceTimer: Timer?
    private var clockOn: Bool
    private var lockPreview = false
    /// Per scene shown, like a new saver session.
    private var seed = FullScreenSceneConfig.randomSeed()
    /// The power state the scene was configured for; changes reach the running scene.
    private var power = FullScreenPreviewSession.currentPower()
    private var powerToken: Int32 = NOTIFY_TOKEN_INVALID
    /// The key press that closed the preview, until it is released.
    private var closingKey: ClosingKeyWait?
    private let displayID: CGDirectDisplayID?

    private let state = FullScreenPreviewState()
    private var hint = IdleVisibility(timeout: FullScreenPreviewSession.hintTimeout)
    private var pointer = IdleVisibility(timeout: FullScreenPreviewSession.pointerTimeout)
    private var hintTimer: Timer?
    private var pointerTimer: Timer?

    private let window: FullScreenPreviewWindow
    private let contentView = FullScreenPreviewContentView(frame: .zero)
    private let overlay: NSView
    private var host: LiveSceneHostView?
    /// What the host shows: its kind and clock position (for C and L).
    private var shown: (kind: SceneManifest.Kind, clock: LPClockPosition)?
    /// Bumped whenever another scene is requested, so a slow compile can't install a stale one.
    private var loadGeneration = 0

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributedObserver: DistributedObserver?
    private var savedPresentationOptions: NSApplication.PresentationOptions?
    /// The app that was active before (opened from the menu bar): it gets focus back afterwards.
    private var previousApp: NSRunningApplication?
    private var phase = Phase.created

    init(request: FullScreenPreviewRequest, model: AppModel, screen: NSScreen) {
        self.model = model
        sequence = request.sequence
        self.request = request
        performance = request.performance
        autoAdvance = request.autoAdvanceInterval
        clockOn = request.showClock
        displayID = screen.displayID
        window = FullScreenPreviewWindow(frame: screen.frame)
        overlay = PassThroughHostingView(rootView: FullScreenPreviewOverlay(state: state))
    }

    // MARK: open / close

    func open() {
        guard phase == .created else { return }
        phase = .open
        previousApp = NSApp.isActive ? nil : NSWorkspace.shared.frontmostApplication

        contentView.onKey = { [weak self] in self?.handleKey($0) ?? false }
        contentView.onKeyEquivalent = { [weak self] in self?.handleKeyEquivalent($0) ?? false }
        contentView.onClick = { [weak self] in self?.close(.byUser) }
        contentView.onActivity = { [weak self] in self?.pointerMoved() }
        overlay.frame = contentView.bounds
        overlay.autoresizingMask = [.width, .height]
        contentView.addSubview(overlay)
        window.contentView = contentView
        window.onClose = { [weak self] in self?.close(.byUser) }

        refreshHint()
        showCurrent()

        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(contentView)
        // An explicit user action: the preview takes the keyboard so Esc and the arrows work.
        NSApp.activate()
        hideMenuBarAndDock()
        observe()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeIn
            window.animator().alphaValue = 1
        }
        let now = Date()
        applyHint(hint.noteActivity(at: now))
        applyPointer(pointer.noteActivity(at: now))
    }

    /// `key`: the key whose press closed it (its repeats are swallowed until it is released).
    func close(_ reason: CloseReason, key: UInt16? = nil) {
        switch phase {
        case .created, .closed:
            return
        case .closing:
            if reason == .immediately { finish(restoringFocusTo: nil) }
            return
        case .open:
            break
        }
        phase = .closing
        if let key { closingKey = ClosingKeyWait(keyCode: key) }
        loadGeneration += 1
        hintTimer?.invalidate(); hintTimer = nil
        pointerTimer?.invalidate(); pointerTimer = nil
        advanceTimer?.invalidate(); advanceTimer = nil
        hint.reset()
        pointer.reset()
        removeObservers()
        NSCursor.setHiddenUntilMouseMoves(false)
        restoreMenuBarAndDock()
        // Stop rendering now; the last frame stays for the fade and is released right after it.
        host?.freeze()
        let focus = reason == .byUser ? previousApp : nil
        guard reason != .immediately else {
            finish(restoringFocusTo: nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOut
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finish(restoringFocusTo: focus) }
        })
    }

    private func finish(restoringFocusTo app: NSRunningApplication?) {
        guard phase == .closing else { return }
        phase = .closed
        host?.tearDown()
        host?.removeFromSuperview()
        host = nil
        window.orderOut(nil)
        window.onClose = nil
        window.contentView = nil
        if let app {
            // Not while the closing key is still held: the other app would get its repeats.
            let giveBack: @MainActor () -> Void = {
                guard !app.isTerminated, NSApp.isActive else { return }
                NSApp.yieldActivation(to: app)
                app.activate(from: .current, options: [])
            }
            if let closingKey { closingKey.whenReleased(giveBack) } else { giveBack() }
        }
        // A wait that is still on keeps itself until the key is up.
        closingKey = nil
        onEnd?()
        onEnd = nil
    }

    /// The menu bar and Dock stay hidden while the preview is up. (Left alone when a window of the
    /// app is in native full screen, which manages them itself; the window's level covers them anyway.)
    private func hideMenuBarAndDock() {
        let current = NSApp.presentationOptions
        guard !current.contains(.fullScreen) else { return }
        savedPresentationOptions = current
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
    }

    private func restoreMenuBarAndDock() {
        guard let saved = savedPresentationOptions else { return }
        savedPresentationOptions = nil
        NSApp.presentationOptions = saved
    }

    /// Registered after open() made the window key (or, opened from the menu bar, asked for it to
    /// become key as the app activates), so a resign only ever means the preview lost the keyboard.
    private func observe() {
        let nc = NotificationCenter.default
        func add(_ center: NotificationCenter, _ name: Notification.Name, object: AnyObject? = nil,
                 _ action: @escaping @MainActor (FullScreenPreviewSession) -> Void) {
            observers.append((center, center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }))
        }
        add(nc, NSApplication.didResignActiveNotification) { $0.close(.deactivated) }
        // Another LivePaper window became key (clicked on another display, or the main window
        // brought forward to explain a refused lock): the preview's keys would reach that window,
        // and the preview would hide what it shows. (No focus to give back: the user is still here.)
        add(nc, NSWindow.didResignKeyNotification, object: window) { $0.close(.deactivated) }
        add(nc, NSApplication.didHideNotification) { $0.close(.immediately) }
        add(nc, NSApplication.willTerminateNotification) { $0.close(.immediately) }
        add(nc, NSApplication.didChangeScreenParametersNotification) { $0.screensChanged() }
        // AC ⇄ battery (kIOPSNotifyPowerSource fires on switches, not on every percent) and Low Power Mode.
        add(nc, .NSProcessInfoPowerStateDidChange) { $0.powerChanged() }
        var token: Int32 = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(kIOPSNotifyPowerSource, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.powerChanged() }
        }
        if status == UInt32(NOTIFY_STATUS_OK) { powerToken = token }
        let ws = NSWorkspace.shared.notificationCenter
        add(ws, NSWorkspace.screensDidSleepNotification) { $0.close(.immediately) }
        add(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.close(.immediately) }
        // The real saver takes over: the session locked, or a screen saver started.
        distributedObserver = DistributedObserver(names: ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"]) { [weak self] in
            self?.close(.immediately)
        }
    }

    private func removeObservers() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        if powerToken != NOTIFY_TOKEN_INVALID { notify_cancel(powerToken) }
        powerToken = NOTIFY_TOKEN_INVALID
        distributedObserver?.invalidate()
        distributedObserver = nil
    }

    /// A display was added, removed or rearranged: follow ours, or close when it is gone.
    private func screensChanged() {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
            close(.immediately)
            return
        }
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
    }

    // MARK: scenes

    /// What ← → may show: the library's scenes and the request's AI results.
    private var availableIDs: Set<String> { request.available(library: model.availableSceneIDs) }

    /// The scene a sequence id stands for: an AI result from the request, else a library scene.
    private func item(for id: String) -> SceneItem? {
        request.candidate(for: id)?.item ?? model.entry(id: id)?.item
    }

    private func showCurrent() {
        loadGeneration += 1
        let generation = loadGeneration
        guard sequence.retain(available: availableIDs), let item = item(for: sequence.current) else {
            removeHost()
            state.sceneName = ""
            state.position = nil
            state.message = "This scene is no longer in the library."
            return
        }
        let manifest = item.manifest
        state.sceneName = manifest.name
        state.position = request.caption(for: sequence.current, in: sequence)
        state.message = nil
        power = Self.currentPower()
        refreshHint()
        scheduleAutoAdvance()
        switch manifest.kind {
        case .video:
            guard let url = FullScreenSceneConfig.videoFile(manifest.video?.file, in: item.packageURL) else {
                removeHost()
                state.message = "\u{201C}\(manifest.name)\u{201D} has no video file the screen saver can play."
                return
            }
            let clock = manifest.clock.position
            shown = (.video, clock)
            install(.video(url, fit: manifest.video?.fit ?? .fill,
                           clock: clock == .none ? nil : clock,
                           clockVisible: FullScreenSceneConfig.nativeClockVisible(showClock: clockOn, lockUI: lockPreview)))
        case .web:
            Task { [weak self, model] in
                do {
                    let url = try await model.previewHTML(for: item)
                    guard let self, generation == self.loadGeneration, self.phase == .open else { return }
                    self.shown = (.web, manifest.clock.position)
                    self.install(.web(url, configScript: self.webConfigScript(clock: manifest.clock.position), onError: nil))
                } catch {
                    guard let self, generation == self.loadGeneration, self.phase == .open else { return }
                    self.removeHost()
                    self.state.message = "\u{201C}\(manifest.name)\u{201D} can\u{2019}t be shown: \(error.localizedDescription)"
                }
            }
        }
    }

    private func install(_ content: LiveSceneContent) {
        if let host {
            host.replace(content)
            return
        }
        let host = LiveSceneHostView(content: content)
        host.frame = contentView.bounds
        host.autoresizingMask = [.width, .height]
        contentView.addSubview(host, positioned: .below, relativeTo: overlay)
        self.host = host
    }

    private func removeHost() {
        host?.tearDown()
        host?.removeFromSuperview()
        host = nil
        shown = nil
    }

    /// The saver's configuration for this scene, with the preview's clock and lock-UI state.
    private func webConfigScript(clock position: LPClockPosition) -> String {
        FullScreenSceneConfig.webConfigScript(showClock: clockOn, clockPosition: position, performance: performance,
                                              power: power, seed: seed, lockUI: lockPreview)
    }

    /// C and L: the running scene follows without reloading.
    private func applySceneState() {
        guard let shown, let host else { return }
        switch shown.kind {
        case .web:
            updateWebScene()
        case .video:
            host.setVideoClockVisible(FullScreenSceneConfig.nativeClockVisible(showClock: clockOn, lockUI: lockPreview), animated: true)
        }
    }

    /// Brings a running web scene to the preview's state (and what a rebuilt page starts with).
    private func updateWebScene() {
        guard let shown, shown.kind == .web, let host else { return }
        host.updateWeb(configScript: webConfigScript(clock: shown.clock),
                       stateScript: FullScreenSceneConfig.stateScript(showClock: clockOn, lockUI: lockPreview,
                                                                      performance: performance, power: power))
    }

    /// AC ⇄ battery or Low Power Mode: a web scene retargets its fps and render scale, as in the saver.
    private func powerChanged() {
        guard phase == .open else { return }
        let now = Self.currentPower()
        guard now != power else { return }
        power = now
        updateWebScene()
    }

    /// The next scene after the playlist's "Change scene" time (restarted by every change).
    private func scheduleAutoAdvance() {
        advanceTimer?.invalidate()
        advanceTimer = nil
        guard let interval = autoAdvance, phase == .open, sequence.canStep else { return }
        advanceTimer = Self.oneShot(at: Date().addingTimeInterval(interval)) { [weak self] in
            guard let self, self.phase == .open else { return }
            self.advanceTimer = nil
            self.move(1)
        }
    }

    private func step(_ delta: Int) {
        move(delta)
        showHint()
    }

    /// The next or previous scene, leaving out the ones deleted meanwhile (`advance`).
    private func move(_ delta: Int) {
        let before = sequence
        guard sequence.advance(delta, available: availableIDs) else {
            showCurrent()   // nothing left: says so
            return
        }
        if sequence.current != before.current {
            seed = FullScreenSceneConfig.randomSeed()
            showCurrent()
        } else if sequence != before {
            // Only other scenes went: the same one stays, its caption ("2 of 5") and hint follow.
            state.position = request.caption(for: sequence.current, in: sequence)
            refreshHint()
        }
    }

    // MARK: input

    private func handleKey(_ event: NSEvent) -> Bool {
        guard phase == .open else { return false }
        return perform(FullScreenKeys.keyDown(Self.press(event)), keyCode: event.keyCode)
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard phase == .open else { return false }
        return perform(FullScreenKeys.keyEquivalent(Self.press(event)), keyCode: event.keyCode)
    }

    /// Whether the key was the preview's.
    private func perform(_ action: FullScreenKeyAction, keyCode: UInt16) -> Bool {
        switch action {
        case .pass:
            return false
        case .swallow:
            return true
        case .close:
            close(.byUser, key: keyCode)
            return true
        case .step(let delta):
            step(delta)
            return true
        case .toggleClock:
            clockOn.toggle()
        case .toggleLockUI:
            lockPreview.toggle()
        }
        applySceneState()
        refreshHint()
        showHint()
        return true
    }

    private static func press(_ event: NSEvent) -> FullScreenKeyPress {
        let flags = event.modifierFlags
        return FullScreenKeyPress(keyCode: event.keyCode, key: event.charactersIgnoringModifiers?.lowercased() ?? "",
                                  command: flags.contains(.command), shift: flags.contains(.shift),
                                  control: flags.contains(.control), option: flags.contains(.option),
                                  isRepeat: event.isARepeat)
    }

    private func pointerMoved() {
        guard phase == .open else { return }
        let now = Date()
        applyPointer(pointer.noteActivity(at: now))
        applyHint(hint.noteActivity(at: now))
    }

    // MARK: hint bar and pointer

    private func refreshHint() {
        state.hintItems = FullScreenHint.items(canStep: sequence.canStep, clockOn: clockOn, lockPreview: lockPreview,
                                               source: sequence.source)
    }

    private func showHint() {
        guard phase == .open else { return }
        applyHint(hint.noteActivity(at: Date()))
    }

    private func applyHint(_ update: IdleVisibility.Update) {
        if let visible = update.visible { state.hintVisible = visible }
        if let date = update.armTimer {
            hintTimer?.invalidate()
            hintTimer = Self.oneShot(at: date) { [weak self] in
                guard let self else { return }
                self.hintTimer = nil
                self.applyHint(self.hint.timerFired(at: Date()))
            }
        }
    }

    private func applyPointer(_ update: IdleVisibility.Update) {
        // Only a pointer resting on the preview hides (it may be on another display).
        if let visible = update.visible, visible || window.frame.contains(NSEvent.mouseLocation) {
            NSCursor.setHiddenUntilMouseMoves(!visible)
        }
        if let date = update.armTimer {
            pointerTimer?.invalidate()
            pointerTimer = Self.oneShot(at: date) { [weak self] in
                guard let self else { return }
                self.pointerTimer = nil
                self.applyPointer(self.pointer.timerFired(at: Date()))
            }
        }
    }

    private static func oneShot(at date: Date, _ fire: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(fire: date, interval: 0, repeats: false) { _ in MainActor.assumeIsolated { fire() } }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

// MARK: - Window and views

/// Borderless, black, one screen, above normal windows (and the menu bar and Dock) but far below the
/// screen saver (1000) and the lock screen's shield (2001).
private final class FullScreenPreviewWindow: NSWindow {
    var onClose: (() -> Void)?

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
        isMovable = false
        title = "LivePaper Full-Screen Preview"
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Borderless and exactly the screen's frame, menu bar area included.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func performClose(_ sender: Any?) { onClose?() }
    override func cancelOperation(_ sender: Any?) { onClose?() }
}

/// Takes the keyboard, clicks and pointer movement for the preview (the scene and the overlay
/// above it never take events).
private final class FullScreenPreviewContentView: NSView {
    var onKey: ((NSEvent) -> Bool)?
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    var onClick: (() -> Void)?
    var onActivity: (() -> Void)?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Full-screen preview. Escape closes, arrow keys change the scene, C toggles the clock, L previews the lock screen.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Keys the preview doesn't use are ignored quietly (no beep).
    override func keyDown(with event: NSEvent) { _ = onKey?(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        event.type == .keyDown && (onKeyEquivalent?(event) ?? false)
    }
    override func cancelOperation(_ sender: Any?) { onClick?() }

    /// A single click closes. The second click of a double-click doesn't: that is the one that
    /// lands here when the preview was opened by double-clicking (or double-clicking a button).
    override func mouseDown(with event: NSEvent) {
        if event.clickCount <= 1 { onClick?() } else { onActivity?() }
    }
    override func mouseMoved(with event: NSEvent) { onActivity?() }
    override func mouseDragged(with event: NSEvent) { onActivity?() }
    override func rightMouseDown(with event: NSEvent) { onActivity?() }
    override func scrollWheel(with event: NSEvent) { onActivity?() }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
}

/// An NSHostingView that lets every event through to the view below.
private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

/// Swallows the repeats of the key whose press closed the preview until it is released
/// (FullScreenClosingKey), then runs what waited for that (giving focus back to the previous app).
/// A local monitor sees key events before the window and the menu do. The monitor keeps the wait
/// alive; it ends at the key-up, at the next key press, or when the app is deactivated (the key-up
/// then goes elsewhere, and nobody is waiting for focus any more).
@MainActor
private final class ClosingKeyWait {
    private let rule: FullScreenClosingKey
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var onRelease: (@MainActor () -> Void)?

    init(keyCode: UInt16) {
        rule = FullScreenClosingKey(keyCode: keyCode)
        // Strong on purpose: the monitor holds the wait until it ends (end() removes it).
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [self] event in
            let keyUp = event.type == .keyUp, keyCode = event.keyCode, isRepeat = !keyUp && event.isARepeat
            let verdict = MainActor.assumeIsolated { () -> FullScreenClosingKey.Verdict in
                let verdict = self.rule.verdict(keyUp: keyUp, keyCode: keyCode, isRepeat: isRepeat)
                if verdict == .released { self.end(released: true) }
                return verdict
            }
            return verdict == .drop ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                                queue: .main) { [self] _ in
            MainActor.assumeIsolated { self.end(released: false) }
        }
    }

    /// Runs `action` once the key is released (now, when it already is).
    func whenReleased(_ action: @escaping @MainActor () -> Void) {
        if monitor == nil { action() } else { onRelease = action }
    }

    private func end(released: Bool) {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        let action = onRelease
        onRelease = nil
        // After the key-up has been delivered here, not from inside the monitor.
        if released, let action { DispatchQueue.main.async { MainActor.assumeIsolated { action() } } }
    }
}

/// Distributed notifications delivered even while the app is inactive (ARCHITECTURE §1).
private final class DistributedObserver: NSObject {
    private let handler: @MainActor () -> Void

    init(names: [String], handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init()
        let center = DistributedNotificationCenter.default()
        for name in names {
            center.addObserver(self, selector: #selector(received(_:)), name: Notification.Name(name), object: nil,
                               suspensionBehavior: .deliverImmediately)
        }
    }

    @objc private func received(_ note: Notification) {
        DispatchQueue.main.async { [handler] in MainActor.assumeIsolated { handler() } }
    }

    func invalidate() { DistributedNotificationCenter.default().removeObserver(self) }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
