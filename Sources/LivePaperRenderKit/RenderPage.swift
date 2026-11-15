// RenderPage — one compiled scene loaded into a fresh WKWebView inside the renderer's window.
//
// The runtime (Runtime/runtime.js) reports through `webkit.messageHandlers.livepaper`:
// {type:'error'} for every JS error and {type:'ready'} once the requested frame (still/bench) or the
// first live frame has been drawn. Every wait here has a deadline so a broken scene can never wedge
// the server.
import AppKit
import Foundation
import LivePaperCore
import WebKit

/// A render operation failed; `message` ends up in RenderResponse.note.
struct RenderFailure: Error, CustomStringConvertible {
    var message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// Serves the pages' base URL scheme by refusing every request. Pages get a real origin
/// (`livepaper-render://scene/`) instead of the opaque one `loadHTMLString(baseURL: nil)` gives:
/// WebKit hides the details of errors from opaque-origin scripts ("Script error."), and the whole
/// point of rendering for `livepaper check` is to report syntax errors with their message and line.
/// Nothing can be loaded through the scheme, so scenes stay as offline as in the screen saver.
private final class OfflineSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "livepaper-render"
    static let baseURL = URL(string: "\(scheme)://scene/")

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable, userInfo: [
            NSLocalizedDescriptionKey: "scenes cannot load files; inline them with assets/ and LivePaper.asset(name)"]))
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// Retains the page weakly: WKUserContentController retains its handlers strongly, which would
/// otherwise form a cycle page → web view → configuration → controller → page.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var page: RenderPage?
    init(_ page: RenderPage) { self.page = page }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { page?.received(body) }
    }
}

@MainActor
final class RenderPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let handlerName = "livepaper"
    /// Prefix of the error recorded when the scene tries to leave its page.
    static let navigationBlockedNote = "the scene tried to navigate to"

    let webView: WKWebView
    let size: CGSize
    let dpr: Double
    /// JS errors reported by the page, in order (deduplicated by the runtime after a few repeats).
    private(set) var errors: [String] = []
    private var readyInfo: [String: Any]?
    private var failure: String?
    private var readyWaiter: ((Result<[String: Any], Error>) -> Void)?
    /// Lets through only the page load started in init (SceneNavigationGate).
    private var navigationGate = SceneNavigationGate()

    /// Loads `html` at `size` CSS px with `dpr` device pixels per CSS px. `config` becomes
    /// `window.LIVEPAPER_CONFIG` (see runtime.js) before any page script runs.
    init(html: String, size: CGSize, dpr: Double, config: [String: Any], window: NSWindow) throws {
        self.size = size
        self.dpr = dpr
        let conf = WKWebViewConfiguration()
        conf.websiteDataStore = .nonPersistent()
        conf.suppressesIncrementalRendering = true
        conf.mediaTypesRequiringUserActionForPlayback = .all
        conf.setURLSchemeHandler(OfflineSchemeHandler(), forURLScheme: OfflineSchemeHandler.scheme)
        let json = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        // devicePixelRatio is also overridden natively below; the JS override keeps the page right
        // should that private setter ever disappear.
        let script = "Object.defineProperty(window,'devicePixelRatio',{get:function(){return \(dpr)},configurable:true});" +
            "window.LIVEPAPER_CONFIG=\(String(decoding: json, as: UTF8.self));"
        conf.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: conf)
        super.init()
        conf.userContentController.add(MessageProxy(self), name: Self.handlerName)
        webView.setValue(false, forKey: "drawsBackground")
        // The window is off-screen, so AppKit reports it occluded and WebKit would stop rendering
        // (no rAF, no compositing). Same private switch the screen saver needs (ARCHITECTURE §1).
        Self.callPrivate(webView, "_setWindowOcclusionDetectionEnabled:", false)
        // Render at the requested density regardless of which display the window happens to be on,
        // so snapshots come back at exactly width×dpr pixels.
        Self.callPrivate(webView, "_setOverrideDeviceScaleFactor:", CGFloat(dpr))
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.setContentSize(size)
        window.setFrameOrigin(SceneRenderer.offscreenOrigin)
        window.contentView = webView
        if let base = OfflineSchemeHandler.baseURL { navigationGate.expect(base) }
        webView.loadHTMLString(html, baseURL: OfflineSchemeHandler.baseURL)
    }

    private static func callPrivate(_ view: WKWebView, _ name: String, _ value: Bool) {
        let sel = NSSelectorFromString(name)
        guard view.responds(to: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(view.method(for: sel), to: Fn.self)(view, sel, value)
    }

    private static func callPrivate(_ view: WKWebView, _ name: String, _ value: CGFloat) {
        let sel = NSSelectorFromString(name)
        guard view.responds(to: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        unsafeBitCast(view.method(for: sel), to: Fn.self)(view, sel, value)
    }

    /// Detaches the web view (its WebContent process is released with it).
    func close() {
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        webView.configuration.userContentController.removeAllUserScripts()
        webView.removeFromSuperview()
        resolve(.failure(RenderFailure("page closed")))
    }

    // MARK: - Messages

    fileprivate func received(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "error":
            errors.append(body["message"] as? String ?? "unknown error")
        case "ready":
            guard readyInfo == nil else { return }
            readyInfo = body
            resolve(.success(body))
        default:
            break // 'stats' etc.
        }
    }

    private func fail(_ message: String) {
        guard failure == nil else { return }
        failure = message
        resolve(.failure(RenderFailure(message)))
    }

    private func resolve(_ result: Result<[String: Any], Error>) {
        guard let waiter = readyWaiter else { return }
        readyWaiter = nil
        waiter(result)
    }

    // MARK: - Navigation policy

    /// Only the load started in init; everything else (the scene setting `location`, links, forms,
    /// subframes, new windows, downloads) is cancelled and reported like a JavaScript error, so
    /// `livepaper check` fails the scene instead of letting it reach the network from this
    /// unsandboxed process.
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                             decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            let request = SceneNavigationGate.Request(
                url: action.request.url, isMainFrame: action.targetFrame?.isMainFrame ?? false,
                opensNewWindow: action.targetFrame == nil, kind: Self.kind(action.navigationType),
                isDownload: action.shouldPerformDownload)
            guard navigationGate.decide(request) else {
                let message = "\(Self.navigationBlockedNote) \(SceneNavigationGate.describe(action.request.url)); scenes must stay offline on their own page"
                if !errors.contains(message) { errors.append(message) }
                if readyInfo == nil { fail(message) }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    /// Nothing but the page itself is shown: no downloads, nothing WebKit can't display.
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                             decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        MainActor.assumeIsolated { decisionHandler(response.isForMainFrame && response.canShowMIMEType ? .allow : .cancel) }
    }

    /// `window.open` never opens anything.
    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    private static func kind(_ type: WKNavigationType) -> SceneNavigationGate.Kind {
        switch type {
        case .linkActivated: return .linkActivated
        case .formSubmitted: return .formSubmitted
        case .backForward: return .backForward
        case .reload: return .reload
        case .formResubmitted: return .formResubmitted
        default: return .other
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { fail("the web content process crashed (out of memory or a WebKit crash)") }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { fail("navigation failed: \(error.localizedDescription)") }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { fail("loading failed: \(error.localizedDescription)") }
    }

    // MARK: - Waiting

    /// The runtime's 'ready' message. Throws on timeout, crash, or navigation failure.
    func waitUntilReady(deadline: Date) async throws -> [String: Any] {
        if let readyInfo { return readyInfo }
        if let failure { throw RenderFailure(failure) }
        return try await withDeadline(deadline, "waiting for the scene to become ready") { done in
            self.readyWaiter = done
        }
    }

    /// evaluateJavaScript with a deadline (the async WebKit variant traps on `undefined` results).
    func evaluate(_ js: String, deadline: Date) async throws -> Any? {
        try await withDeadline(deadline, "running JavaScript in the page") { done in
            self.webView.evaluateJavaScript(js) { value, error in
                if let error { done(.failure(RenderFailure("JavaScript failed: \(error.localizedDescription)"))) }
                else { done(.success(value)) }
            }
        }
    }

    /// Resolves after two animation frames, i.e. once a change made from script has been composited.
    func nextFrames(deadline: Date) async throws {
        let _: Any? = try await withDeadline(deadline, "waiting for an animation frame") { done in
            self.webView.callAsyncJavaScript(
                "await new Promise(function (r) { requestAnimationFrame(function () { requestAnimationFrame(r); }); }); return 1;",
                arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let v): done(.success(v))
                case .failure(let e): done(.failure(RenderFailure("animation frame wait failed: \(e.localizedDescription)")))
                }
            }
        }
    }

    /// Snapshot of the whole page as exactly `size × dpr` pixels.
    func snapshot(deadline: Date) async throws -> Bitmap {
        let image: NSImage = try await withDeadline(deadline, "taking a snapshot") { done in
            let sc = WKSnapshotConfiguration()
            sc.rect = CGRect(origin: .zero, size: self.size)
            sc.snapshotWidth = NSNumber(value: Double(self.size.width))
            sc.afterScreenUpdates = true
            self.webView.takeSnapshot(with: sc) { image, error in
                if let image { done(.success(image)) }
                else { done(.failure(RenderFailure("snapshot failed: \(error?.localizedDescription ?? "no image")"))) }
            }
        }
        let pw = Int((Double(size.width) * dpr).rounded()), ph = Int((Double(size.height) * dpr).rounded())
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let bitmap = Bitmap(image: cg, width: pw, height: ph) else { throw RenderFailure("snapshot could not be decoded") }
        return bitmap
    }
}

/// Bridges a callback API to async/await with a deadline. `start` and the callback run on the main
/// actor; whichever of callback and deadline comes first wins, the other is ignored.
@MainActor
func withDeadline<T>(_ deadline: Date, _ what: String,
                     _ start: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        var finished = false
        let finish: (Result<T, Error>) -> Void = { result in
            guard !finished else { return }
            finished = true
            cont.resume(with: result)
        }
        let seconds = max(0, deadline.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            finish(.failure(RenderFailure("timed out \(what)")))
        }
        start(finish)
    }
}
