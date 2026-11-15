// SceneNavigationGate — which navigations a web view showing a scene may perform: the one load its
// host started, nothing else.
//
// Scenes are offline by contract, but neither the CSP (it has no navigation directive; WebKit has
// no `navigate-to`) nor the compile-time source scanner (it only sees literal URLs) stops a script
// from setting `location`. Without a policy, a scene rendered by LivePaper's unsandboxed render
// server, or previewed in the app, could navigate to any web address and send data with it. So
// every scene web view (RenderKit's RenderPage, the app's previews, the saver) asks this gate:
// the host arms it right before it loads the scene itself, the gate lets exactly that one
// main-frame load through, and cancels everything else — later navigations, links and forms,
// subframes, new windows and downloads.
//
// Foundation only and self-contained: it is also compiled into the saver (scripts/build-saver.sh),
// which can't link LivePaperCore.
import Foundation

public struct SceneNavigationGate: Sendable {
    /// WKNavigationType, without WebKit.
    public enum Kind: Sendable, Equatable { case other, linkActivated, formSubmitted, backForward, reload, formResubmitted }

    /// What WebKit asks about (WKNavigationAction), without WebKit.
    public struct Request: Sendable, Equatable {
        public var url: URL?
        /// False for subframes and for navigations that would open a new window (no target frame).
        public var isMainFrame: Bool
        public var opensNewWindow: Bool
        public var kind: Kind
        public var isDownload: Bool
        public init(url: URL?, isMainFrame: Bool, opensNewWindow: Bool = false, kind: Kind = .other, isDownload: Bool = false) {
            self.url = url; self.isMainFrame = isMainFrame; self.opensNewWindow = opensNewWindow; self.kind = kind; self.isDownload = isDownload
        }
    }

    private var armed: [URL] = []

    public init() {}

    /// Call right before the host itself loads `url` (the base URL of `loadHTMLString`, or
    /// `about:blank` when it has none; the file of `loadFileURL`). Allows that one navigation.
    public mutating func expect(_ url: URL) { armed.append(url) }

    /// True to allow the navigation, false to cancel it.
    public mutating func decide(_ request: Request) -> Bool {
        guard request.isMainFrame, !request.opensNewWindow, !request.isDownload, request.kind == .other,
              let url = request.url, let i = armed.firstIndex(where: { Self.sameDocument($0, url) }) else { return false }
        armed.remove(at: i)
        return true
    }

    /// A short description of a refused navigation's target for logs and check reports (no query
    /// string, which may carry whatever the scene tried to send).
    public static func describe(_ url: URL?) -> String {
        guard let url else { return "(no address)" }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return String(url.absoluteString.prefix(80)) }
        parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
        return String((parts.string ?? url.scheme ?? "?").prefix(80))
    }

    /// Same scheme, host and path (`about:blank` has only a scheme and a path).
    static func sameDocument(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && (a.host ?? "") == (b.host ?? "")
            && normalisedPath(a) == normalisedPath(b)
    }

    private static func normalisedPath(_ url: URL) -> String {
        let path = url.isFileURL ? url.standardizedFileURL.path : (URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? "")
        return path.isEmpty ? "/" : path
    }
}
