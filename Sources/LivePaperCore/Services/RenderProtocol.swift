// RenderProtocol — JSON-lines protocol for the RenderService socket. See ARCHITECTURE §8.
// One request per connection: client writes one JSON line, server replies with one JSON line.
import Foundation

public struct RenderRequest: Codable, Sendable {
    public enum Op: String, Codable, Sendable { case still, bench, live, thumbnail, ping, shutdown }
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

    public init(op: Op, html: String? = nil, scene: String? = nil, width: Double? = nil, height: Double? = nil,
                dpr: Double? = nil, t: Double? = nil, out: String? = nil, frames: Int? = nil, clock: Bool? = nil,
                fps: Double? = nil, scale: Double? = nil, seconds: Double? = nil, warmup: Double? = nil, timeout: Double? = nil) {
        self.op = op; self.html = html; self.scene = scene; self.width = width; self.height = height; self.dpr = dpr
        self.t = t; self.out = out; self.frames = frames; self.clock = clock; self.fps = fps; self.scale = scale
        self.seconds = seconds; self.warmup = warmup; self.timeout = timeout
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

    public init(ok: Bool, ready: Bool = false, errors: [String] = [], note: String? = nil, out: String? = nil,
                benchMs: Double? = nil, fps: Double? = nil, cpuPct: Double? = nil, cpuMW: Double? = nil,
                seconds: Double? = nil, meanLuma: Double? = nil, clockLuma: Double? = nil) {
        self.ok = ok; self.ready = ready; self.errors = errors; self.note = note; self.out = out; self.benchMs = benchMs
        self.fps = fps; self.cpuPct = cpuPct; self.cpuMW = cpuMW; self.seconds = seconds; self.meanLuma = meanLuma; self.clockLuma = clockLuma
    }

    enum CodingKeys: String, CodingKey {
        case ok, ready, errors, note, out, fps, seconds
        case benchMs = "bench_ms", cpuPct = "cpu_pct", cpuMW = "cpu_mW", meanLuma = "mean_luma", clockLuma = "clock_luma"
    }
}
