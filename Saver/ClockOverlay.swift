// ClockOverlay — the native lock-screen-style clock used by video scenes and the fallback.
//
// Geometry and typography mirror the runtime's web clock (SaverClockLayout and runtime.js
// `drawClock`): the date in SF semibold above a large SF bold time, white at 90 %, with a soft dark
// shadow (like Apple's lock-screen clock) so it stays legible over arbitrary video. It redraws once
// a minute on a one-shot timer re-armed for the next minute boundary, which also realigns itself
// after sleep or clock changes.
import AppKit
import QuartzCore

final class ClockOverlay {
    /// Duration of the lock-UI hand-off fade (same as the runtime's).
    static let fadeDuration: CFTimeInterval = 0.3

    /// Container layer; add it above the scene content and call `layout(in:scale:)` on resize.
    let layer = CALayer()
    private let dateLayer = CATextLayer()
    private let timeLayer = CATextLayer()
    private let position: LPClockPosition
    private let formatter = DateFormatter()
    private var ticker: Timer?
    private var size: CGSize = .zero
    private var scale: CGFloat = 2

    private static let textColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9)
    /// runtime.js: shadowColor rgba(0,0,0,0.28).
    private static let shadowOpacity: Float = 0.28

    init(position: LPClockPosition) {
        self.position = position
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        for text in [dateLayer, timeLayer] {
            text.foregroundColor = Self.textColor
            text.isWrapped = false
            text.truncationMode = .none
            text.shadowColor = CGColor(gray: 0, alpha: 1)
            text.shadowOpacity = Self.shadowOpacity
            text.shadowOffset = .zero
            // Text layers are re-laid out by hand; never animate their geometry or content.
            text.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "string": NSNull()]
            layer.addSublayer(text)
        }
        refresh()
    }

    deinit { ticker?.invalidate() }

    /// Positions the clock for a container of `bounds` (bottom-left origin, like the hosting layer).
    func layout(in bounds: CGRect, scale: CGFloat) {
        size = bounds.size
        self.scale = scale
        layer.frame = bounds
        guard let metrics = SaverClockLayout.make(width: Double(bounds.width), height: Double(bounds.height), position: position) else {
            layer.isHidden = true
            return
        }
        layer.isHidden = false
        let dateFont = NSFont.systemFont(ofSize: CGFloat(metrics.dateSize), weight: .semibold)
        let timeFont = NSFont.systemFont(ofSize: CGFloat(metrics.timeSize), weight: .bold)
        // Canvas shadowBlur is roughly twice a CALayer shadowRadius (runtime: date × 0.5, time × 0.08).
        place(dateLayer, font: dateFont, baseline: metrics.dateBaseline, metrics: metrics, shadowRadius: metrics.dateSize * 0.25)
        place(timeLayer, font: timeFont, baseline: metrics.timeBaseline, metrics: metrics, shadowRadius: metrics.timeSize * 0.04)
    }

    private func place(_ text: CATextLayer, font: NSFont, baseline: Double, metrics: SaverClockLayout, shadowRadius: Double) {
        text.font = font
        text.fontSize = font.pointSize
        text.contentsScale = scale
        text.shadowRadius = CGFloat(shadowRadius)
        // CATextLayer puts the first line's ascent at the top of its bounds, so the frame's top is
        // baseline − ascender. A little slack keeps descenders and the shadow from being clipped.
        let slack = ceil(font.pointSize * 0.1)
        let height = ceil(font.ascender - font.descender) + slack * 2
        let topFromTop = CGFloat(baseline) - font.ascender - slack
        let y = size.height - topFromTop - height
        switch metrics.alignment {
        case .center:
            text.alignmentMode = .center
            text.frame = CGRect(x: 0, y: y, width: size.width, height: height)
        case .left:
            text.alignmentMode = .left
            text.frame = CGRect(x: CGFloat(metrics.anchorX), y: y, width: max(0, size.width - CGFloat(metrics.anchorX)), height: height)
        case .right:
            text.alignmentMode = .right
            text.frame = CGRect(x: 0, y: y, width: CGFloat(metrics.anchorX), height: height)
        }
    }

    /// Updates the text for `now`.
    func refresh(now: Date = Date()) {
        let locale = Locale.autoupdatingCurrent
        formatter.dateFormat = SaverClockFormat.datePattern(locale: locale)
        let date = formatter.string(from: now)
        formatter.dateFormat = SaverClockFormat.timePattern(locale: locale)
        let time = formatter.string(from: now)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dateLayer.string = date
        timeLayer.string = time
        CATransaction.commit()
    }

    /// Starts or stops the once-a-minute updates (stopped = no timers at all).
    func setRunning(_ running: Bool) {
        ticker?.invalidate()
        ticker = nil
        guard running else { return }
        refresh()
        armTicker()
    }

    private func armTicker() {
        let fire = SaverClockFormat.nextMinuteBoundary(after: Date()).addingTimeInterval(0.05)
        let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.refresh()
            self.armTicker()
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    /// Fades the clock in or out (the lock-UI hand-off).
    func setVisible(_ visible: Bool, animated: Bool) {
        let target: Float = visible ? 1 : 0
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        // Explicit animation only; the implicit "opacity" action would use the default 0.25 s.
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "fade")
        layer.opacity = target
        if animated, from != target {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = target
            fade.duration = Self.fadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "fade")
        }
        CATransaction.commit()
    }

    var opacity: Float { layer.opacity }
}
