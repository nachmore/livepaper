// RenderProtocol — JSON-lines protocol for the RenderService socket. See ARCHITECTURE §8.
// One request per connection: client writes one JSON line, server replies with one JSON line.
import Foundation

/// A slice of a virtual canvas that spans several displays (runtime span keys, SCENE_API.md §16): the
/// page is `width`×`height` (the viewport) and shows the part at (`x`, `y`) of a `canvasW`×`canvasH`
/// canvas. The clock box (the main display's viewport) defaults to the whole canvas. CSS px.
public struct RenderSpan: Codable, Sendable, Equatable {
    public var canvasW: Double
    public var canvasH: Double
    public var x: Double
    public var y: Double
    public var clockX: Double?
    public var clockY: Double?
    public var clockW: Double?
    public var clockH: Double?

    public init(canvasW: Double, canvasH: Double, x: Double, y: Double,
                clockX: Double? = nil, clockY: Double? = nil, clockW: Double? = nil, clockH: Double? = nil) {
        self.canvasW = canvasW; self.canvasH = canvasH; self.x = x; self.y = y
        self.clockX = clockX; self.clockY = clockY; self.clockW = clockW; self.clockH = clockH
    }

    /// The runtime configuration keys (runtime.js TYPES) that put a page in span mode.
    public var configKeys: [String: Double] {
        var keys: [String: Double] = ["spanW": canvasW, "spanH": canvasH, "spanX": x, "spanY": y]
        if let clockX { keys["spanClockX"] = clockX }
        if let clockY { keys["spanClockY"] = clockY }
        if let clockW { keys["spanClockW"] = clockW }
        if let clockH { keys["spanClockH"] = clockH }
        return keys
    }

    /// `config` with the span keys merged in (nothing changes without a span).
    public static func config(_ config: [String: Any], span: RenderSpan?) -> [String: Any] {
        guard let span else { return config }
        return config.merging(span.configKeys.mapValues { $0 as Any }) { _, new in new }
    }
}

public struct RenderRequest: Codable, Sendable {
    public enum Op: String, Codable, Sendable { case still, bench, live, thumbnail, motion, ping, shutdown }
    public var op: Op
    /// Absolute path of a compiled, self-contained scene HTML file (still/bench/live).
    public var html: String?
    /// Absolute path of a scene package (thumbnail: compiles + renders it).
    public var scene: String?
    public var width: Double?
    public var height: Double?
    public var dpr: Double?
    public var t: Double?
    public var out: String?
    public var frames: Int?
    public var clock: Bool?
    public var fps: Double?
    public var scale: Double?
    public var seconds: Double?
    public var warmup: Double?
    public var timeout: Double?
    /// motion: the sampled moments (s; default MotionAnalysis.defaultTimes), the gaps compared with
    /// each of them (s; default 0.5, 2, 5) and the tile grid [cols, rows] (default ~16 across).
    /// `out` (optional) receives the heat map PNG.
    public var times: [Double]?
    public var gaps: [Double]?
    public var grid: [Int]?
    /// still/bench: render the page as a slice of a spanning canvas (`width`×`height` is the viewport).
    public var span: RenderSpan?

    public init(op: Op, html: String? = nil, scene: String? = nil, width: Double? = nil, height: Double? = nil,
                dpr: Double? = nil, t: Double? = nil, out: String? = nil, frames: Int? = nil, clock: Bool? = nil,
                fps: Double? = nil, scale: Double? = nil, seconds: Double? = nil, warmup: Double? = nil, timeout: Double? = nil,
                times: [Double]? = nil, gaps: [Double]? = nil, grid: [Int]? = nil, span: RenderSpan? = nil) {
        self.op = op; self.html = html; self.scene = scene; self.width = width; self.height = height; self.dpr = dpr
        self.t = t; self.out = out; self.frames = frames; self.clock = clock; self.fps = fps; self.scale = scale
        self.seconds = seconds; self.warmup = warmup; self.timeout = timeout
        self.times = times; self.gaps = gaps; self.grid = grid; self.span = span
    }
}

public struct RenderResponse: Codable, Sendable {
    public var ok: Bool
    public var ready: Bool
    public var errors: [String]
    public var note: String?
    public var out: String?
    /// bench
    public var benchMs: Double?
    /// live
    public var fps: Double?
    public var cpuPct: Double?
    public var cpuMW: Double?
    public var seconds: Double?
    /// still: mean luminance (0–255) of the whole frame and of the clock rect, for budget checks.
    public var meanLuma: Double?
    public var clockLuma: Double?
    /// motion: per-tile change maps (MotionAnalysis.swift).
    public var motion: MotionMeasurement?
    /// still/bench: the page rendered a span slice (nil from servers that predate span: they ignore
    /// `RenderRequest.span` and render the whole scene at the slice's size).
    public var span: Bool?
    /// still/bench: the scene defines update() (state that a span check's stills can't compare).
    public var hasUpdate: Bool?

    public init(ok: Bool, ready: Bool = false, errors: [String] = [], note: String? = nil, out: String? = nil,
                benchMs: Double? = nil, fps: Double? = nil, cpuPct: Double? = nil, cpuMW: Double? = nil,
                seconds: Double? = nil, meanLuma: Double? = nil, clockLuma: Double? = nil, motion: MotionMeasurement? = nil) {
        self.ok = ok; self.ready = ready; self.errors = errors; self.note = note; self.out = out; self.benchMs = benchMs
        self.fps = fps; self.cpuPct = cpuPct; self.cpuMW = cpuMW; self.seconds = seconds; self.meanLuma = meanLuma; self.clockLuma = clockLuma
        self.motion = motion
    }

    enum CodingKeys: String, CodingKey {
        case ok, ready, errors, note, out, fps, seconds, motion, span, hasUpdate
        case benchMs = "bench_ms", cpuPct = "cpu_pct", cpuMW = "cpu_mW", meanLuma = "mean_luma", clockLuma = "clock_luma"
    }
}
