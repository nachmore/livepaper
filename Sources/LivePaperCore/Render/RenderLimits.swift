// RenderLimits — how long the render server lets one request run (ARCHITECTURE §8).
//
// The server renders one request at a time on its main thread, for every client on the Mac (the
// CLI, `livepaper check`, the app's thumbnails, AI sessions through RenderRelay). Each job's deadline
// therefore comes from the server's own per-op limit, never from an unbounded client number: a
// request's `timeout` can only pick a deadline up to `RenderLimits.maxTimeout`, and the live op's
// limit uses the same clamped `seconds`/`warmup` the op itself measures with.
import Foundation

public enum RenderLimits {
    /// The longest any request may hold the render server (the longest default is a 600 s live run:
    /// 690 s).
    public static let maxTimeout: TimeInterval = 900

    static func clamp(_ x: Double?, _ range: ClosedRange<Double>, default d: Double) -> Double {
        guard let x, x.isFinite else { return d }
        return min(max(x, range.lowerBound), range.upperBound)
    }
}

extension RenderRequest {
    /// live: the warm-up before measuring (s), 0–60, default 3.
    public var liveWarmup: Double { RenderLimits.clamp(warmup, 0...60, default: 3) }
    /// live: how long it measures (s), 1–600, default 12.
    public var liveSeconds: Double { RenderLimits.clamp(seconds, 1...600, default: 12) }

    /// The server's own time limit for this request (page load, replaying update() up to t, frames).
    public var serverDefaultTimeout: TimeInterval {
        switch op {
        case .live: return liveSeconds + liveWarmup + 30
        case .bench: return 90
        case .motion: return 150
        default: return 60
        }
    }

    /// The deadline the server gives this request: `timeout` when it is a positive number of seconds
    /// (at most `RenderLimits.maxTimeout`), its own limit otherwise.
    public var serverTimeout: TimeInterval {
        guard let timeout, timeout.isFinite, timeout > 0 else { return serverDefaultTimeout }
        return min(timeout, RenderLimits.maxTimeout)
    }
}
