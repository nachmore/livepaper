// LiveSceneHost — the AppKit side of every live scene in the app: the compiled HTML in a passive
// WKWebView for web scenes, a looping muted AVPlayerLayer (optionally with the saver's native clock)
// for video scenes. Used by ScenePreview (library, detail and AI previews) and by the full-screen
// preview.
//
// Battery rule: a scene only runs while somebody can see it. `LiveSceneHostView` tears the web view
// down (and pauses video) whenever its window is occluded or miniaturised, the app is hidden, the
// displays sleep, the session is switched away, or the view is scrolled out of sight, and rebuilds
// it when it becomes visible again.
import AVFoundation
import AppKit
import LivePaperCore
import WebKit

/// What a `LiveSceneHostView` shows.
enum LiveSceneContent {
    /// A compiled scene. `configScript` defines `window.LIVEPAPER_CONFIG` at document start.
    case web(URL, configScript: String, onError: ((String) -> Void)?)
    /// A video file; `clock` adds the saver's native clock (ClockOverlay) at that position.
    case video(URL, fit: LPVideoFit, clock: LPClockPosition? = nil, clockVisible: Bool = true)

    var identity: URL {
        switch self {
        case .web(let u, _, _), .video(let u, _, _, _): return u
        }
    }

    /// The document-start script for a configuration dictionary (keys: Runtime/runtime.js `TYPES`).
    static func configScript(_ config: [String: Any]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "window.LIVEPAPER_CONFIG = \(json);"
    }
}

/// Owns the live content and starts/stops it as the view's visibility changes.
final class LiveSceneHostView: NSView {
    private(set) var content: LiveSceneContent
    private var web: PassiveWebView?
    private var webRelay: ScriptMessageRelay?
    private var webReady = false
    /// Host → page state that changed after the page's config was injected (re-applied on ready).
    private var pendingStateScript: String?
    private var video: VideoLoop?
    /// Set by `freeze()`: the content stays on screen, paused, until `tearDown()`.
    private var frozen = false
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var displaysAsleep = false
    private var sessionInactive = false

    init(content: LiveSceneContent) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let ws = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.displaysAsleep = true; self?.updateActivity() }
            },
            ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.displaysAsleep = false; self?.updateActivity() }
            },
            ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionInactive = true; self?.updateActivity() }
            },
            ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionInactive = false; self?.updateActivity() }
            },
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    func setCornerRadius(_ radius: CGFloat) {
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = radius > 0
    }

    /// Live scenes never take clicks or hovers; the view around them does.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func replace(_ new: LiveSceneContent) {
        stop()
        content = new
        updateActivity()
    }

    /// Releases everything (web view, player, clock timer). The view may be reused with `replace`.
    func tearDown() {
        stop()
        frozen = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// Stops all work at once but keeps the last frame on screen (a closing fade); `tearDown()`
    /// follows. Nothing restarts while frozen.
    func freeze() {
        frozen = true
        if web != nil { run(SaverJS.pause) }
        video?.pause()
    }

    /// Changes a web scene's state without reloading it: `configScript` is what a rebuilt page will
    /// start with, `stateScript` brings the running page there (now if it is ready, else on ready).
    func updateWeb(configScript: String, stateScript: String) {
        guard case .web(let url, _, let onError) = content else { return }
        content = .web(url, configScript: configScript, onError: onError)
        guard web != nil else { return }
        if webReady { run(stateScript) } else { pendingStateScript = stateScript }
    }

    /// Shows or hides a video scene's native clock (fading like the saver's lock-UI hand-off).
    func setVideoClockVisible(_ visible: Bool, animated: Bool) {
        guard case .video(let url, let fit, let clock, _) = content else { return }
        content = .video(url, fit: fit, clock: clock, clockVisible: visible)
        video?.setClockVisible(visible, animated: animated)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let window {
            let nc = NotificationCenter.default
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                              NSWindow.didDeminiaturizeNotification]
            for name in names {
                observers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateActivity() }
                })
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateActivity() }
                })
            }
            // Scrolling the detail view can move the preview out of sight without any window event.
            if let clip = enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateActivity() }
                })
            }
        }
        updateActivity()
    }

    override func viewDidHide() { super.viewDidHide(); updateActivity() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateActivity() }

    override func layout() {
        super.layout()
        web?.frame = bounds
        layoutVideo()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutVideo()
    }

    private func layoutVideo() {
        guard let video else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.layout(in: bounds, scale: window?.backingScaleFactor ?? 2)
        CATransaction.commit()
    }

    private var canBeSeen: Bool {
        guard !frozen, let window, !displaysAsleep, !sessionInactive, !NSApp.isHidden else { return false }
        return window.occlusionState.contains(.visible) && !window.isMiniaturized && !isHiddenOrHasHiddenAncestor
            && !visibleRect.isEmpty
    }

    private func updateActivity() {
        guard !frozen else { return }
        canBeSeen ? start() : pause()
    }

    private func start() {
        switch content {
        case .web(let url, let configScript, let onError):
            guard web == nil else { return }
            let relay = ScriptMessageRelay(onError: onError) { [weak self] in self?.webDidBecomeReady() }
            let view = PassiveWebView.make(configScript: configScript, relay: relay)
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            webReady = false
            pendingStateScript = nil   // a new page starts from the current configScript
            view.loadScene(url)
            web = view
            webRelay = relay
        case .video(let url, let fit, let clock, let clockVisible):
            if video == nil {
                let loop = VideoLoop(url: url, fit: fit, clock: clock)
                loop.setClockVisible(clockVisible, animated: false)
                layer?.addSublayer(loop.layer)
                if let clockLayer = loop.clockLayer { layer?.addSublayer(clockLayer) }
                video = loop
                layoutVideo()
            }
            video?.play()
        }
    }

    /// Web scenes are torn down (a paused WKWebView still holds its web-content process and GPU
    /// memory); video is only paused because resuming a decoder is cheap.
    private func pause() {
        if case .web = content { stopWeb() } else { video?.pause() }
    }

    private func stop() {
        stopWeb()
        video?.tearDown()
        video = nil
    }

    private func stopWeb() {
        guard let web else { return }
        web.stopLoading()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.removeFromSuperview()
        self.web = nil
        webRelay = nil
        webReady = false
        pendingStateScript = nil
    }

    private func webDidBecomeReady() {
        webReady = true
        if let script = pendingStateScript {
            pendingStateScript = nil
            run(script)
        }
        if frozen { run(SaverJS.pause) }
    }

    private func run(_ script: String) {
        web?.evaluateJavaScript(script, completionHandler: nil)
    }
}

/// A WKWebView that never takes mouse or keyboard input and only shows the one compiled scene it was
/// given. It also drops WebKit's tracking areas: the page never sees the pointer (scenes have no
/// input by contract), so it can't change the cursor either (the runtime's page style hides it,
/// which is right in the screen saver but not in a window).
final class PassiveWebView: WKWebView, WKNavigationDelegate, WKUIDelegate {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func addTrackingArea(_ trackingArea: NSTrackingArea) {}

    /// Lets through only the load `loadScene` starts (SceneNavigationGate).
    private var navigationGate = SceneNavigationGate()

    func loadScene(_ url: URL) {
        navigationGate.expect(url)
        loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    static func make(configScript: String, relay: ScriptMessageRelay) -> PassiveWebView {
        let configuration = WKWebViewConfiguration()
        // No cookies, caches or storage survive a preview.
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.suppressesIncrementalRendering = true
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: configScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(relay, name: "livepaper")
        configuration.userContentController = controller
        let view = PassiveWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = view
        view.uiDelegate = view
        // Transparent until the first frame (as in the saver): the poster or the black backdrop
        // shows instead of a white flash.
        if view.responds(to: NSSelectorFromString("setDrawsBackground:")) {
            view.setValue(false, forKey: "drawsBackground")
        }
        view.underPageBackgroundColor = .black
        view.allowsMagnification = false
        view.allowsBackForwardNavigationGestures = false
        return view
    }

    /// Scenes are offline by contract: only the scene's own load goes through; the scene navigating
    /// anywhere (another page, a file, the web), links, forms, subframes and new windows are refused.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let kind: SceneNavigationGate.Kind
        switch action.navigationType {
        case .linkActivated: kind = .linkActivated
        case .formSubmitted: kind = .formSubmitted
        case .backForward: kind = .backForward
        case .reload: kind = .reload
        case .formResubmitted: kind = .formResubmitted
        default: kind = .other
        }
        let allowed = navigationGate.decide(SceneNavigationGate.Request(
            url: action.request.url, isMainFrame: action.targetFrame?.isMainFrame ?? false, opensNewWindow: action.targetFrame == nil,
            kind: kind, isDownload: action.shouldPerformDownload))
        decisionHandler(allowed ? .allow : .cancel)
    }

    /// No downloads, nothing WebKit can't display.
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.isForMainFrame && response.canShowMIMEType ? .allow : .cancel)
    }

    /// `window.open` never opens anything.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
}

/// Receives `webkit.messageHandlers.livepaper` messages. The content controller retains the relay;
/// the relay holds no reference back to the web view, so there is no retain cycle.
final class ScriptMessageRelay: NSObject, WKScriptMessageHandler {
    let onError: ((String) -> Void)?
    let onReady: (() -> Void)?

    init(onError: ((String) -> Void)?, onReady: (() -> Void)? = nil) {
        self.onError = onError
        self.onReady = onReady
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "error":
            let text = (body["message"] as? String) ?? (body["error"] as? String) ?? "The scene reported an error."
            onError?(text)
        case "ready":
            onReady?()
        default:
            break
        }
    }
}

/// A muted, endlessly looping video that never keeps the display awake, with the saver's native
/// clock (Saver/ClockOverlay.swift) when asked for one.
private final class VideoLoop {
    let layer: AVPlayerLayer
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let clock: ClockOverlay?
    var clockLayer: CALayer? { clock?.layer }

    init(url: URL, fit: LPVideoFit, clock position: LPClockPosition?) {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        layer = AVPlayerLayer(player: player)
        layer.videoGravity = fit == .fit ? .resizeAspect : .resizeAspectFill
        layer.backgroundColor = NSColor.black.cgColor
        clock = position.flatMap { $0 == .none ? nil : ClockOverlay(position: $0) }
    }

    func layout(in bounds: CGRect, scale: CGFloat) {
        layer.frame = bounds
        clock?.layout(in: bounds, scale: scale)
    }

    private var playing = false

    /// The clock ticks (once a minute) only while the video plays.
    func play() {
        guard !playing else { return }
        playing = true
        player.play()
        clock?.setRunning(true)
    }

    func pause() {
        playing = false
        player.pause()
        clock?.setRunning(false)
    }

    func setClockVisible(_ visible: Bool, animated: Bool) { clock?.setVisible(visible, animated: animated) }

    func tearDown() {
        pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        layer.removeFromSuperlayer()
        clock?.layer.removeFromSuperlayer()
    }
}
