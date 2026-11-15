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
// (LivePaper.host.lockUI) so the clock hand-off can be seen. The hint bar fades out after 3 s and
// returns when the pointer moves.
//
// Power: the scene runs only while the window can be seen (LiveSceneHostView). Closing stops it at
// once (frozen for the fade, released right after); hiding the app, switching to another app, the
// displays sleeping, the session locking or switching, and a screen saver starting close it
// immediately — the real saver takes over then. Nothing is left running once it is closed: no
// timer, no observer, no web view.
import AppKit
import LivePaperCore
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

    static let hintTimeout: TimeInterval = 3
    static let pointerTimeout: TimeInterval = 2
    static let fadeIn: TimeInterval = 0.2
    static let fadeOut: TimeInterval = 0.25

    var onEnd: (() -> Void)?

    private let model: AppModel
    private var sequence: FullScreenPreviewSequence
    private let performance: LPPerformanceProfile
    private var clockOn: Bool
    private var lockPreview = false
    /// Per scene shown, like a new saver session.
    private var seed = FullScreenSceneConfig.randomSeed()
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
        performance = request.performance
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

    func close(_ reason: CloseReason) {
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
        loadGeneration += 1
        hintTimer?.invalidate(); hintTimer = nil
        pointerTimer?.invalidate(); pointerTimer = nil
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
        if let app, !app.isTerminated, NSApp.isActive {
            NSApp.yieldActivation(to: app)
            app.activate(from: .current, options: [])
        }
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

    private func observe() {
        let nc = NotificationCenter.default
        func add(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (FullScreenPreviewSession) -> Void) {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }))
        }
        add(nc, NSApplication.didResignActiveNotification) { $0.close(.deactivated) }
        add(nc, NSApplication.didHideNotification) { $0.close(.immediately) }
        add(nc, NSApplication.willTerminateNotification) { $0.close(.immediately) }
        add(nc, NSApplication.didChangeScreenParametersNotification) { $0.screensChanged() }
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

    private func showCurrent() {
        loadGeneration += 1
        let generation = loadGeneration
        guard sequence.retain(available: Set(model.availableSceneIDs)), let entry = model.entry(id: sequence.current) else {
            removeHost()
            state.sceneName = ""
            state.position = nil
            state.message = "This scene is no longer in the library."
            return
        }
        let manifest = entry.manifest
        state.sceneName = manifest.name
        state.position = sequence.positionText
        state.message = nil
        refreshHint()
        switch manifest.kind {
        case .video:
            guard let file = manifest.video?.file else {
                removeHost()
                state.message = "\u{201C}\(manifest.name)\u{201D} has no video file."
                return
            }
            let clock = manifest.clock.position
            shown = (.video, clock)
            install(.video(entry.item.packageURL.appendingPathComponent(file), fit: manifest.video?.fit ?? .fill,
                           clock: clock == .none ? nil : clock,
                           clockVisible: FullScreenSceneConfig.nativeClockVisible(showClock: clockOn, lockUI: lockPreview)))
        case .web:
            let item = entry.item
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
        let power = PowerSource.current()
        return FullScreenSceneConfig.webConfigScript(showClock: clockOn, clockPosition: position, performance: performance,
                                                     power: SaverPowerState(onBattery: power.onBattery, lowPowerMode: power.lowPower),
                                                     seed: seed, lockUI: lockPreview)
    }

    /// C and L: the running scene follows without reloading.
    private func applySceneState() {
        guard let shown, let host else { return }
        switch shown.kind {
        case .web:
            host.updateWeb(configScript: webConfigScript(clock: shown.clock),
                           stateScript: FullScreenSceneConfig.stateScript(showClock: clockOn, lockUI: lockPreview))
        case .video:
            host.setVideoClockVisible(FullScreenSceneConfig.nativeClockVisible(showClock: clockOn, lockUI: lockPreview), animated: true)
        }
    }

    private func step(_ delta: Int) {
        guard sequence.retain(available: Set(model.availableSceneIDs)), sequence.step(delta) else {
            showHint()
            return
        }
        seed = FullScreenSceneConfig.randomSeed()
        showCurrent()
        showHint()
    }

    // MARK: input

    private func handleKey(_ event: NSEvent) -> Bool {
        guard phase == .open else { return false }
        switch event.keyCode {
        case 53, 49:   // Esc; Space closes too, as in Quick Look
            // A held Space (the press that opened the preview, repeating) must not close it again.
            if !event.isARepeat { close(.byUser) }
            return true
        case 123, 124: // ← →
            if !event.isARepeat { step(event.keyCode == 123 ? -1 : 1) }
            return true
        default:
            break
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "c":
            clockOn.toggle()
        case "l":
            lockPreview.toggle()
        default:
            return false
        }
        applySceneState()
        refreshHint()
        showHint()
        return true
    }

    /// ⌘ shortcuts: ⌘. and ⌘W close (so does ⇧⌘F, which opened it); Quit and Hide go to the menu;
    /// everything else is swallowed so nothing acts on the window behind the preview.
    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard phase == .open else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard modifiers.contains(.command) else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (modifiers, key) {
        case ([.command], "."), ([.command], "w"), ([.command, .shift], "f"):
            if !event.isARepeat { close(.byUser) }
            return true
        case ([.command], "q"), ([.command], "h"), ([.command, .option], "h"):
            return false
        default:
            return true
        }
    }

    private func pointerMoved() {
        guard phase == .open else { return }
        let now = Date()
        applyPointer(pointer.noteActivity(at: now))
        applyHint(hint.noteActivity(at: now))
    }

    // MARK: hint bar and pointer

    private func refreshHint() {
        state.hintItems = FullScreenHint.items(canStep: sequence.canStep, clockOn: clockOn, lockPreview: lockPreview)
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
        if let visible = update.visible { NSCursor.setHiddenUntilMouseMoves(!visible) }
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
