// ScenePreview — a live, battery-conscious preview of a scene: the compiled HTML in a WKWebView for
// web scenes, a looping muted AVPlayerLayer for video scenes, and the thumbnail as a poster
// underneath while either loads.
//
// Battery rule: a preview only runs while somebody can see it. `LivePreviewHostView` tears the web
// view down (and pauses video) whenever its window is occluded or miniaturised, the app is hidden,
// the displays sleep, the session is switched away, or the view is scrolled out of sight, and
// rebuilds it when it becomes visible again. SwiftUI's lazy grids additionally dismantle previews
// that leave the viewport, which releases everything.
import AVFoundation
import AppKit
import IOKit.ps
import LivePaperCore
import SwiftUI
import WebKit

/// How hard a preview may work.
enum PreviewQuality: Equatable {
    /// Library card hover: 30 fps at half resolution, no clock.
    case hover
    /// Scene detail / AI result: the user's playlist profile, with the clock if enabled.
    case full
}

struct ScenePreview: View {
    let item: SceneItem
    var quality: PreviewQuality = .full
    /// Shows the scene's clock overlay (web scenes; the saver draws it for video scenes).
    var showClock = true
    /// Matches the container's rounded corners. SwiftUI's clipShape doesn't reliably clip AppKit
    /// views (WKWebView, AVPlayerLayer), so the host layer masks them itself.
    var cornerRadius: CGFloat = 0
    /// Reports runtime errors from the scene (e.g. to show a hint in the detail view).
    var onError: ((String) -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.livePreviewsEnabled) private var livePreviewsEnabled
    @State private var compiledHTML: URL?
    @State private var compileError: String?

    var body: some View {
        ZStack {
            ThumbnailImage(url: item.thumbnailURL, revision: model.thumbnailRevision[item.id] ?? 0,
                           placeholderSymbol: item.manifest.kind == .video ? "film" : "sparkles")
            if livePreviewsEnabled {
                live
            }
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of \(item.manifest.name)")
        .accessibilityAddTraits(.isImage)
        .task(id: compileKey) { await compileIfNeeded() }
    }

    @ViewBuilder
    private var live: some View {
        switch item.manifest.kind {
        case .video:
            if let video = videoURL {
                LivePreviewRepresentable(content: .video(video, fit: item.manifest.video?.fit ?? .fill), cornerRadius: cornerRadius)
            }
        case .web:
            if let compiledHTML {
                LivePreviewRepresentable(content: .web(compiledHTML, config: runtimeConfig, onError: onError), cornerRadius: cornerRadius)
            } else if compileError != nil {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(8)
                    .background(.black.opacity(0.4), in: Circle())
                    .help(compileError ?? "")
            }
        }
    }

    private var compileKey: String { "\(item.id)#\(item.manifest.updated?.timeIntervalSince1970 ?? 0)#\(livePreviewsEnabled)" }

    private var videoURL: URL? {
        guard let file = item.manifest.video?.file else { return nil }
        return item.packageURL.appendingPathComponent(file)
    }

    /// `window.LIVEPAPER_CONFIG` for the runtime (see Runtime/runtime.js, "Configuration").
    private var runtimeConfig: [String: Any] {
        let power = PowerSource.current()
        var cfg: [String: Any] = [
            "performance": model.playlist.performance.rawValue,
            "power": power.onBattery ? "battery" : "ac",
            "lowPower": power.lowPower,
            "clock": showClock && quality == .full && model.playlist.showClock,
            "reducedMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            // lp.env.preview: scenes may simplify for the app's small, short-lived previews.
            "preview": true,
        ]
        if quality == .hover {
            cfg["fps"] = 30
            cfg["scale"] = 0.5
        }
        return cfg
    }

    private func compileIfNeeded() async {
        guard livePreviewsEnabled, item.manifest.kind == .web else { return }
        do {
            compiledHTML = try await model.previewHTML(for: item)
            compileError = nil
        } catch {
            compiledHTML = nil
            compileError = error.localizedDescription
            onError?(error.localizedDescription)
        }
    }
}

/// Power facts the runtime adapts to (lp.env).
enum PowerSource {
    static func current() -> (onBattery: Bool, lowPower: Bool) {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else {
            return (false, lowPower)
        }
        return (type == kIOPSBatteryPowerValue, lowPower)
    }
}

// MARK: - AppKit host

fileprivate struct LivePreviewRepresentable: NSViewRepresentable {
    enum Content {
        case web(URL, config: [String: Any], onError: ((String) -> Void)?)
        case video(URL, fit: LPVideoFit)

        var identity: URL {
            switch self {
            case .web(let u, _, _), .video(let u, _): return u
            }
        }
    }

    let content: Content
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> LivePreviewHostView {
        let view = LivePreviewHostView(content: content)
        view.setCornerRadius(cornerRadius)
        return view
    }

    func updateNSView(_ view: LivePreviewHostView, context: Context) {
        view.setCornerRadius(cornerRadius)
        if view.content.identity != content.identity { view.replace(content) }
    }

    static func dismantleNSView(_ view: LivePreviewHostView, coordinator: ()) {
        view.tearDown()
    }
}

/// Owns the live content and starts/stops it as the view's visibility changes.
fileprivate final class LivePreviewHostView: NSView {
    private(set) var content: LivePreviewRepresentable.Content
    private var web: PassiveWebView?
    private var webRelay: ScriptMessageRelay?
    private var video: VideoLoop?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var displaysAsleep = false
    private var sessionInactive = false

    init(content: LivePreviewRepresentable.Content) {
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

    /// Previews never take clicks or hovers; the card or detail view around them does.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func replace(_ new: LivePreviewRepresentable.Content) {
        stop()
        content = new
        updateActivity()
    }

    func tearDown() {
        stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
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
        video?.layer.frame = bounds
    }

    private var canBeSeen: Bool {
        guard let window, !displaysAsleep, !sessionInactive, !NSApp.isHidden else { return false }
        return window.occlusionState.contains(.visible) && !window.isMiniaturized && !isHiddenOrHasHiddenAncestor
            && !visibleRect.isEmpty
    }

    private func updateActivity() {
        canBeSeen ? start() : pause()
    }

    private func start() {
        switch content {
        case .web(let url, let config, let onError):
            guard web == nil else { return }
            let relay = ScriptMessageRelay(onError: onError)
            let view = PassiveWebView.make(config: config, relay: relay)
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            view.loadScene(url)
            web = view
            webRelay = relay
        case .video(let url, let fit):
            if video == nil {
                let loop = VideoLoop(url: url, fit: fit)
                loop.layer.frame = bounds
                layer?.addSublayer(loop.layer)
                video = loop
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
        video?.layer.removeFromSuperlayer()
        video = nil
    }

    private func stopWeb() {
        guard let web else { return }
        web.stopLoading()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.removeFromSuperview()
        self.web = nil
        webRelay = nil
    }
}

/// A WKWebView that never takes mouse events and only shows the one compiled scene it was given.
private final class PassiveWebView: WKWebView, WKNavigationDelegate, WKUIDelegate {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    /// Lets through only the load `loadScene` starts (SceneNavigationGate).
    private var navigationGate = SceneNavigationGate()

    func loadScene(_ url: URL) {
        navigationGate.expect(url)
        loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    static func make(config: [String: Any], relay: ScriptMessageRelay) -> PassiveWebView {
        let configuration = WKWebViewConfiguration()
        // No cookies, caches or storage survive a preview.
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.suppressesIncrementalRendering = true
        let controller = WKUserContentController()
        let json = (try? JSONSerialization.data(withJSONObject: config)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        controller.addUserScript(WKUserScript(source: "window.LIVEPAPER_CONFIG = \(json);",
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(relay, name: "livepaper")
        configuration.userContentController = controller
        let view = PassiveWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = view
        view.uiDelegate = view
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
private final class ScriptMessageRelay: NSObject, WKScriptMessageHandler {
    let onError: ((String) -> Void)?
    init(onError: ((String) -> Void)?) { self.onError = onError }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["type"] as? String == "error" else { return }
        let text = (body["message"] as? String) ?? (body["error"] as? String) ?? "The scene reported an error."
        onError?(text)
    }
}

/// A muted, endlessly looping video that never keeps the display awake.
private final class VideoLoop {
    let layer: AVPlayerLayer
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(url: URL, fit: LPVideoFit) {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        layer = AVPlayerLayer(player: player)
        layer.videoGravity = fit == .fit ? .resizeAspect : .resizeAspectFill
        layer.backgroundColor = NSColor.black.cgColor
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func tearDown() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }
}
