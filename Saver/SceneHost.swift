// SceneHost — the interface between the saver view and one scene on screen (web, video or the
// built-in fallback). The saver view owns at most two hosts at a time: the current one and the
// incoming one it crossfades to.
import AppKit

/// Everything a scene needs to know when it is created. Later changes arrive through the
/// `SceneHost` methods.
struct SceneContext {
    /// Playlist-level clock switch.
    var showClock: Bool
    /// Where this scene wants the clock (`.none` = the scene draws its own / no clock).
    var clockPosition: LPClockPosition
    /// macOS is currently drawing its lock UI over the saver.
    var lockUIShowing: Bool
    var paused: Bool
    var profile: LPPerformanceProfile.Resolved
    var power: SaverPowerState
    /// Session seed handed to web scenes (identical on every display).
    var seed: Int
    /// Live, or one still frame (battery: displays other than the main one). Black displays get no host.
    var liveness: SaverDisplayLiveness = .live
    /// This display's slice when the scene spans all displays.
    var span: SaverSpan? = nil
    /// False on the displays other than the main one while a scene spans (one clock in all).
    var clockOnThisDisplay = true
    /// Publish generation (shared video players are per file and publish).
    var generation = 0

    /// Whether a native (CATextLayer) clock should exist at all for this scene.
    var wantsNativeClock: Bool { showClock && clockPosition != .none && clockOnThisDisplay }
}

protocol SceneHostDelegate: AnyObject {
    /// The scene has drawn its first frame and can be faded in.
    func sceneHostDidBecomeReady(_ host: SceneHost)
    /// The scene failed to load or crashed; the saver decides how to recover.
    func sceneHost(_ host: SceneHost, didFail reason: String)
}

protocol SceneHost: AnyObject {
    /// The view to add to the saver (sized to its bounds, autoresizing).
    var view: NSView { get }
    /// Playlist entry id ("" for the fallback).
    var entryID: String { get }
    /// "web" | "video" | "fallback" (diagnostics).
    var kind: String { get }
    var delegate: SceneHostDelegate? { get set }

    /// Starts loading. Must eventually call exactly one of the delegate methods (a revealed scene
    /// may still report a later failure, e.g. a WebContent crash).
    func load()
    /// Stops/starts all work (frame loop, video decode, clock ticks). Safe to call before ready —
    /// the state is applied once the scene is ready.
    func setPaused(_ paused: Bool)
    /// Hides (true) or shows the scene's clock while macOS draws its own lock-screen clock.
    func setLockUIShowing(_ showing: Bool, animated: Bool)
    /// The performance profile changed (AC ⇄ battery, Low Power Mode).
    func powerDidChange(profile: LPPerformanceProfile.Resolved, power: SaverPowerState)
    /// Live ⇄ still (one frame, no clock, nothing running). `.off` never reaches a host: the view
    /// removes it instead.
    func setLiveness(_ liveness: SaverDisplayLiveness)
    /// Releases everything and removes the view. The host is unusable afterwards.
    func tearDown()
    /// State for logs and the dev host.
    var diagnostics: [String: Any] { get }
}

/// A layer-backed view that lays out its sublayers itself (video, fallback). Implicit layer
/// animations are disabled during layout so resizing never animates.
final class LayerHostView: NSView {
    var onLayout: ((LayerHostView) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        relayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        relayout()
    }

    func relayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        onLayout?(self)
        CATransaction.commit()
    }
}
