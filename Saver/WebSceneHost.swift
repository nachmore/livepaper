// WebSceneHost — a compiled web scene (single self-contained HTML, runtime inlined) in a WKWebView.
//
// Bridge (ARCHITECTURE §5): config is injected as `window.LIVEPAPER_CONFIG` before any page script
// runs; the page talks back through `webkit.messageHandlers.livepaper` ({type:'ready'|'error'|'stats'});
// the saver drives it through `LivePaper.host.pause() / resume() / lockUI(bool) / config() / power()`.
// Host→page state (pause, lock UI) is queued until the page reports ready, so notifications that
// arrive while the page is still loading are not lost.
import AppKit
import WebKit

/// A WKWebView that never takes mouse or keyboard events, so the screen-saver engine always
/// receives them (and dismisses the saver / shows the lock UI as usual).
final class PassiveWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

/// Forwards script messages without retaining the host (WKUserContentController retains its
/// handlers strongly, which would otherwise form a cycle through the web view's configuration).
private final class WeakMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WebSceneHost?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.didReceive(message.body)
    }
}

final class WebSceneHost: NSObject, SceneHost, WKNavigationDelegate {
    static let messageHandlerName = "livepaper"
    /// Reveal anyway if the page never reports ready (better a live page than a black screen).
    private static let readyDeadline: TimeInterval = 8
    /// Grace after `didFinish` for runtimes/pages that never post `ready`.
    private static let finishGrace: TimeInterval = 1.5
    /// Scene JS errors logged per scene (the runtime itself stops reporting after 20).
    private static let maxLoggedErrors = 20

    let entryID: String
    let kind = "web"
    weak var delegate: SceneHostDelegate?
    var view: NSView { webView }

    private let fileURL: URL
    private let webView: PassiveWebView
    private var paused: Bool
    private var lockUIShowing: Bool
    private var profile: LPPerformanceProfile.Resolved
    private var isReady = false
    private var failed = false
    private var errorCount = 0
    private var pendingWork: [DispatchWorkItem] = []

    init(entry: LPPlaylistEntry, fileURL: URL, context: SceneContext) {
        entryID = entry.id
        self.fileURL = fileURL
        paused = context.paused
        lockUIShowing = context.lockUIShowing
        profile = context.profile

        let config = WKWebViewConfiguration()
        // Nothing a scene does may persist (no cookies, storage or caches on disk).
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        let webConfig = SaverWebConfig(showClock: context.showClock, clockPosition: context.clockPosition, profile: context.profile,
                                       seed: context.seed, power: context.power, preview: context.preview, lockUI: context.lockUIShowing)
        config.userContentController.addUserScript(
            WKUserScript(source: webConfig.userScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let proxy = WeakMessageProxy()
        config.userContentController.add(proxy, name: Self.messageHandlerName)

        webView = PassiveWebView(frame: .zero, configuration: config)
        super.init()
        proxy.target = self

        // macOS 26 hosts legacy savers in a window AppKit reports as occluded, so WebKit would treat
        // the page as hidden and never draw (black screen). Opt out of occlusion detection; display
        // sleep is handled explicitly by the saver (screensDidSleep → pause) so nothing renders in the dark.
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if webView.responds(to: occlusion) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: occlusion), to: Setter.self)(webView, occlusion, false)
        } else {
            SaverLog.saver.error("WKWebView lacks _setWindowOcclusionDetectionEnabled:; web scenes may stay black")
        }
        // Transparent until the first frame so the crossfade never flashes white.
        if webView.responds(to: NSSelectorFromString("setDrawsBackground:")) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        webView.underPageBackgroundColor = .black
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
    }

    // MARK: SceneHost

    func load() {
        let html: String
        do {
            html = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            after(0) { [weak self] in self?.fail("could not read \(self?.fileURL.lastPathComponent ?? "scene"): \(error.localizedDescription)") }
            return
        }
        // No base URL: the scene is self-contained, and the sandboxed WebContent process could not
        // read files from the saver bundle anyway.
        webView.loadHTMLString(html, baseURL: nil)
        after(Self.readyDeadline) { [weak self] in
            guard let self, !self.isReady, !self.failed else { return }
            SaverLog.scene.info("\(self.entryID, privacy: .public): no ready message after \(Self.readyDeadline, privacy: .public) s; revealing anyway")
            self.markReady()
        }
    }

    func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        if isReady { run(paused ? SaverJS.pause : SaverJS.resume) }
    }

    func setLockUIShowing(_ showing: Bool, animated: Bool) {
        lockUIShowing = showing
        // Harmless before the runtime exists; re-applied on ready. The runtime fades its own clock.
        run(SaverJS.lockUI(showing))
    }

    func powerDidChange(profile: LPPerformanceProfile.Resolved, power: SaverPowerState) {
        self.profile = profile
        guard isReady else { return }
        run(SaverJS.config(profile))
        run(SaverJS.power(power))
    }

    func tearDown() {
        pendingWork.forEach { $0.cancel() }
        pendingWork = []
        delegate = nil
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
        webView.configuration.userContentController.removeAllUserScripts()
        webView.removeFromSuperview()
    }

    var diagnostics: [String: Any] {
        ["kind": kind, "id": entryID, "ready": isReady, "paused": paused, "lockUIShowing": lockUIShowing,
         "errors": errorCount, "fps": profile.fps, "scale": profile.scale]
    }

    // MARK: Page → host

    fileprivate func didReceive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            markReady()
        case "error":
            errorCount += 1
            if errorCount <= Self.maxLoggedErrors {
                let text = message["message"].map { String(describing: $0) } ?? "unknown error"
                SaverLog.scene.error("\(self.entryID, privacy: .public): \(text, privacy: .public)")
            }
        case "stats":
            SaverLog.scene.debug("\(self.entryID, privacy: .public) stats: \(String(describing: message), privacy: .public)")
        default:
            break
        }
    }

    private func markReady() {
        guard !isReady, !failed else { return }
        isReady = true
        // Apply whatever changed while the page was loading.
        run(SaverJS.lockUI(lockUIShowing))
        if paused { run(SaverJS.pause) }
        delegate?.sceneHostDidBecomeReady(self)
    }

    private func fail(_ reason: String) {
        guard !failed else { return }
        failed = true
        delegate?.sceneHost(self, didFail: reason)
    }

    private func run(_ script: String) {
        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error, let self {
                SaverLog.scene.debug("\(self.entryID, privacy: .public): host call failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func after(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        let item = DispatchWorkItem(block: work)
        pendingWork.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        after(Self.finishGrace) { [weak self] in
            guard let self, !self.isReady, !self.failed else { return }
            self.markReady()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail("load failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail("web content process terminated")
    }

    /// Scenes are self-contained and offline: never let one navigate the lock screen somewhere else.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? "about"
        let allowed = navigationAction.navigationType != .linkActivated && ["about", "data", "blob"].contains(scheme)
        decisionHandler(allowed ? .allow : .cancel)
    }
}
