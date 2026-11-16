// FallbackSceneHost — the built-in static scene shown when nothing is published or every scene
// failed: a dark gradient, a short hint, and the native clock. Costs nothing once drawn.
import AppKit
import QuartzCore

final class FallbackSceneHost: SceneHost {
    enum Reason {
        case noScenes, scenesFailed

        var message: String {
            switch self {
            case .noScenes: return "Open LivePaper to choose a scene"
            case .scenesFailed: return "This scene couldn’t be shown. Open LivePaper to choose another."
            }
        }
    }

    let entryID = ""
    let kind = "fallback"
    weak var delegate: SceneHostDelegate?
    var view: NSView { hostView }

    private let reason: Reason
    private let hostView = LayerHostView(frame: .zero)
    private let gradient = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let message = CATextLayer()
    private let clock: ClockOverlay?
    private var paused: Bool
    private var lockUIShowing: Bool
    /// `.still`: no clock (it wouldn't tick) and no hint, nothing running.
    private var still: Bool
    private var readyWork: DispatchWorkItem?

    init(reason: Reason, context: SceneContext) {
        self.reason = reason
        paused = context.paused
        lockUIShowing = context.lockUIShowing
        still = context.liveness == .still
        clock = context.wantsNativeClock ? ClockOverlay(position: context.clockPosition) : nil

        // Deep indigo fading to near-black: calm under the lock UI and kind to OLED/mini-LED panels.
        gradient.colors = [CGColor(srgbRed: 0.09, green: 0.10, blue: 0.20, alpha: 1),
                           CGColor(srgbRed: 0.04, green: 0.05, blue: 0.10, alpha: 1),
                           CGColor(srgbRed: 0.01, green: 0.01, blue: 0.02, alpha: 1)]
        gradient.locations = [0, 0.55, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        glow.type = .radial
        glow.colors = [CGColor(srgbRed: 0.35, green: 0.42, blue: 1, alpha: 0.16), CGColor(srgbRed: 0.35, green: 0.42, blue: 1, alpha: 0)]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)

        message.string = reason.message
        message.alignmentMode = .center
        message.isWrapped = true
        message.foregroundColor = CGColor(gray: 1, alpha: 0.55)

        for layer in [gradient, glow, message] as [CALayer] { hostView.layer?.addSublayer(layer) }
        if let clock { hostView.layer?.addSublayer(clock.layer) }
        applyLockUI(animated: false)

        hostView.onLayout = { [weak self] view in self?.layout(view) }
    }

    private func layout(_ view: LayerHostView) {
        let b = view.bounds, scale = view.saverBackingScale
        gradient.frame = b
        let glowSize = max(b.width, b.height) * 0.9
        glow.frame = CGRect(x: b.midX - glowSize / 2, y: b.height * 0.25 - glowSize / 2, width: glowSize, height: glowSize)
        let fontSize = max(11, min(b.width, b.height) * 0.024)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        message.font = font
        message.fontSize = fontSize
        message.contentsScale = scale
        let width = min(b.width - 2 * fontSize, fontSize * 30)
        let height = ceil((font.ascender - font.descender) * 2.6)
        message.frame = CGRect(x: b.midX - width / 2, y: b.midY - height / 2, width: width, height: height)
        clock?.layout(in: b, scale: scale)
    }

    // MARK: SceneHost

    func load() {
        // Report asynchronously so the saver's install/reveal sequence is the same for every host.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.clock?.setRunning(!self.paused && !self.still)
            self.delegate?.sceneHostDidBecomeReady(self)
        }
        readyWork = work
        DispatchQueue.main.async(execute: work)
    }

    func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        clock?.setRunning(!paused && !still)
    }

    func setLiveness(_ liveness: SaverDisplayLiveness) {
        let still = liveness == .still
        guard still != self.still else { return }
        self.still = still
        clock?.setRunning(!paused && !still)
        applyLockUI(animated: true)
    }

    func setLockUIShowing(_ showing: Bool, animated: Bool) {
        lockUIShowing = showing
        applyLockUI(animated: animated)
    }

    /// macOS draws its own clock and password field over the saver: hide ours and the hint.
    private func applyLockUI(animated: Bool) {
        let hidden = lockUIShowing || still
        clock?.setVisible(!hidden, animated: animated)
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? ClockOverlay.fadeDuration : 0)
        CATransaction.setDisableActions(!animated)
        message.opacity = hidden ? 0 : 1
        CATransaction.commit()
    }

    func powerDidChange(profile: LPPerformanceProfile.Resolved, power: SaverPowerState) {}

    func tearDown() {
        delegate = nil
        readyWork?.cancel()
        clock?.setRunning(false)
        hostView.removeFromSuperview()
    }

    var diagnostics: [String: Any] {
        var d: [String: Any] = ["kind": kind, "reason": reason == .noScenes ? "noScenes" : "scenesFailed",
                                "paused": paused, "lockUIShowing": lockUIShowing, "messageOpacity": message.opacity,
                                "liveness": still ? "still" : "live"]
        if let clock { d["clockOpacity"] = clock.opacity }
        return d
    }
}
