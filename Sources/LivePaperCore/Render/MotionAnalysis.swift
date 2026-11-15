// MotionAnalysis — the liveliness metric behind `livepaper check`'s motion budgets (ARCHITECTURE §9).
//
// The render server's `motion` op (RenderProtocol.swift) renders a scene at a few moments t and
// again a few frames, 0.5 s, 2 s and 5 s later, and compares the frames tile by tile
// (`MotionAnalysis.tiles`). From those maps `summarize` derives what an author can act on:
//
//   coverage   how much of the frame visibly changes within 2 s / 5 s
//   spread     whether that change reaches every part of the frame (nine regions: thirds × thirds)
//   busy       how much of the frame changes strongly within half a second (fast, large motion)
//   flicker    how much of the frame changes sharply within a fraction of a second: between the
//              successive frames of a short burst, 1, 2, 4 and 8 frames apart (flashing, strobing,
//              per-frame noise — and fast whole-frame fades or pans)
//
// and `verdict` turns those into actionable problems and warnings. Foundation only: the tile maths
// (and the heat map's pixels) runs in the render server on snapshots and in the self tests on
// synthetic frames.
import Foundation

// MARK: - Measurement (what the render server returns)

/// Change between two frames of the same size, per tile of a `cols`×`rows` grid (row-major, top row
/// first). Per pixel, `d` is the largest of the three colour channels' absolute differences, in
/// sRGB code values (0–255).
public struct MotionTiles: Codable, Sendable, Equatable {
    /// Mean over the tile's pixels of max(0, d − `MotionAnalysis.noiseFloor`): how much the tile changed.
    public var level: [Double]
    /// Fraction of the tile's pixels with d ≥ `MotionAnalysis.pixelThreshold`: how much of it changed visibly.
    public var area: [Double]
    public init(level: [Double], area: [Double]) { self.level = level; self.area = area }
}

/// The frame at a sample's `t` compared with the frame `gap` seconds later.
public struct MotionGap: Codable, Sendable, Equatable {
    public var gap: Double
    public var tiles: MotionTiles
    public init(gap: Double, tiles: MotionTiles) { self.gap = gap; self.tiles = tiles }
}

/// One sampled moment.
public struct MotionSample: Codable, Sendable, Equatable {
    public var t: Double
    public var gaps: [MotionGap]
    /// Per tile, the largest change between successive frames of a short burst after t (frame offsets
    /// `MotionAnalysis.flickerOffsets`, 1–8 frames apart): high across the frame means flashing,
    /// strobing or a fast whole-frame change.
    public var flicker: MotionTiles
    public init(t: Double, gaps: [MotionGap], flicker: MotionTiles) { self.t = t; self.gaps = gaps; self.flicker = flicker }
}

/// RenderResponse.motion: the raw tile maps of a `motion` request.
public struct MotionMeasurement: Codable, Sendable, Equatable {
    /// Size of the analysed frames, in pixels.
    public var width: Int
    public var height: Int
    public var cols: Int
    public var rows: Int
    public var samples: [MotionSample]
    public init(width: Int, height: Int, cols: Int, rows: Int, samples: [MotionSample]) {
        self.width = width; self.height = height; self.cols = cols; self.rows = rows; self.samples = samples
    }
}

// MARK: - Summary (what report.json carries)

/// The motion numbers of one analysed size, as written to report.json (`motion`).
public struct MotionSummary: Codable, Sendable, Equatable {
    /// "1280x720@0.5": the CSS size and pixel density the scene was laid out at.
    public var size: String
    public var cols: Int
    public var rows: Int
    /// The sampled moments (s).
    public var times: [Double]
    /// Share of the frame (tiles, averaged over the sampled moments) that visibly changes within 2 s
    /// (compared with the frames 0.5 s and 2 s later, and frame to frame in between).
    public var coverage2s: Double
    /// …within 5 s.
    public var coverage5s: Double
    /// Share of the nine regions (thirds of the width × thirds of the height) with motion within 5 s.
    public var spread: Double
    /// Per region ("top-left", "top", …, "centre", …, "bottom-right"): the share of its tiles that
    /// move within 5 s, averaged over the sampled moments.
    public var regions: [String: Double]
    /// The regions without motion (share below `MotionBudgets.regionShare`), in reading order.
    public var stillRegions: [String]
    /// Largest share of the frame, over the sampled moments, that changes strongly within 0.5 s.
    public var busy: Double
    /// Largest share of the frame, over the sampled moments, that changes sharply between successive
    /// burst frames (1–8 frames apart).
    public var flicker: Double
    /// The sampled moment `flicker` comes from.
    public var flickerAt: Double?
    /// Where the frame changes within 5 s, one string per tile row (top first): `#` at most sampled
    /// moments, `+` at some, `.` never.
    public var map: [String]
    /// The motion heat map (PNG) the render server wrote, if any.
    public var heatmap: String?

    public init(size: String, cols: Int, rows: Int, times: [Double], coverage2s: Double, coverage5s: Double, spread: Double,
                regions: [String: Double] = [:], stillRegions: [String], busy: Double, flicker: Double, flickerAt: Double? = nil,
                map: [String], heatmap: String? = nil) {
        self.size = size; self.cols = cols; self.rows = rows; self.times = times; self.coverage2s = coverage2s
        self.coverage5s = coverage5s; self.spread = spread; self.regions = regions; self.stillRegions = stillRegions; self.busy = busy
        self.flicker = flicker; self.flickerAt = flickerAt; self.map = map; self.heatmap = heatmap
    }

    /// Regions with motion, out of nine.
    public var movingRegions: Int { MotionAnalysis.regionNames.count - stillRegions.count }
}

/// Thresholds of the motion check (part of `CheckBudgets`), calibrated on the built-in scenes
/// (docs/ARCHITECTURE.md §9): the two the user found too static measure 2–12 % within 5 s in 0–2
/// regions; the others 30–100 % in 6–9 regions. Real scenes' busy/flicker levels (90th percentile
/// of tiles ≤ 3.4, falling rain included) stay far below their limits; strobing and fast pans hit 100 %.
public struct MotionBudgets: Sendable, Equatable {
    /// A tile visibly changes when its `level` reaches this…
    public var tileLevel: Double = 0.5
    /// …or this fraction of its pixels changes visibly.
    public var tileArea: Double = 0.03
    /// Too static: less than this share of the frame changes within 5 s…
    public var minCoverage5s: Double = 0.25
    /// …or fewer than this many of the nine regions have motion.
    public var minRegions: Int = 5
    /// A region has motion when at least this share of its tiles changes within 5 s.
    public var regionShare: Double = 0.2
    /// Advice ("on the subtle side") below these.
    public var goodCoverage5s: Double = 0.5
    public var goodCoverage2s: Double = 0.25
    /// Too busy: tiles whose change within 0.5 s reaches `busyLevel` cover more than `maxBusy` of the frame.
    public var busyLevel: Double = 16
    public var maxBusy: Double = 0.5
    /// Flicker: tiles whose largest change between successive burst frames (1, 2, 4 and 8 frames
    /// apart, `MotionAnalysis.flickerOffsets`) reaches `flickerLevel` cover more than `maxFlicker` of
    /// the frame.
    public var flickerLevel: Double = 10
    public var maxFlicker: Double = 0.3
    public init() {}
}

// MARK: - Analysis

public enum MotionAnalysis {
    /// Scene time advances in fixed steps of 1/frameRate s, exactly as stills replay update().
    public static let frameRate = 30.0
    /// Frame offsets of the flicker burst after each sampled moment. Successive spans of 1, 2, 4 and
    /// 8 frames: a periodic flash can't hide between them (it would have to repeat every frame), and
    /// together they cover the first half second for coverage too. A span is up to 8 frames, so
    /// `flicker` measures sharp change within about a quarter second, not single-frame steps only.
    public static let flickerOffsets = [0, 1, 3, 7, 15]
    /// Differences up to this many code values are ignored by `level` (dithering, resampling noise).
    public static let noiseFloor = 2
    /// A pixel changed visibly when a channel moved by at least this many code values.
    public static let pixelThreshold = 8
    public static let defaultTimes: [Double] = [3, 17, 41, 120]
    public static let defaultGaps: [Double] = [0.5, 2, 5]
    /// The nine regions of the frame, row-major.
    public static let regionNames = ["top-left", "top", "top-right", "left", "centre", "right", "bottom-left", "bottom", "bottom-right"]

    /// A grid of about square tiles, 16 across.
    public static func grid(width: Int, height: Int, cols: Int = 16) -> (cols: Int, rows: Int) {
        (cols, max(1, Int((Double(cols) * Double(height) / Double(max(1, width))).rounded())))
    }

    /// Frame offsets (in 1/frameRate s steps after t) a sample needs: the flicker burst and every gap.
    public static func offsets(gaps: [Double]) -> [Int] {
        Array(Set(flickerOffsets + gaps.map(frames))).sorted()
    }

    /// Whole frames in `seconds` (at least one).
    public static func frames(_ seconds: Double) -> Int { max(1, Int((seconds * frameRate).rounded())) }

    /// Tile maps of the change from frame `a` to frame `b`: premultiplied 8-bit RGBA, `width * 4`
    /// bytes per row (alpha is ignored).
    public static func tiles(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int, cols: Int, rows: Int) -> MotionTiles {
        let n = cols * rows
        guard width > 0, height > 0, cols > 0, rows > 0, a.count >= width * height * 4, b.count >= width * height * 4 else {
            return MotionTiles(level: Array(repeating: 0, count: max(0, n)), area: Array(repeating: 0, count: max(0, n)))
        }
        var levelSum = [Int](repeating: 0, count: n), changed = [Int](repeating: 0, count: n), pixels = [Int](repeating: 0, count: n)
        let colOf = (0..<width).map { $0 * cols / width }
        let floor = noiseFloor, threshold = pixelThreshold
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                colOf.withUnsafeBufferPointer { cx in
                    levelSum.withUnsafeMutableBufferPointer { sum in
                        changed.withUnsafeMutableBufferPointer { ch in
                            for y in 0..<height {
                                let rowBase = (y * rows / height) * cols
                                var i = y * width * 4
                                for x in 0..<width {
                                    let dr = abs(Int(pa[i]) - Int(pb[i]))
                                    let dg = abs(Int(pa[i + 1]) - Int(pb[i + 1]))
                                    let db = abs(Int(pa[i + 2]) - Int(pb[i + 2]))
                                    let d = max(dr, max(dg, db))
                                    if d > floor {
                                        let tile = rowBase + cx[x]
                                        sum[tile] += d - floor
                                        if d >= threshold { ch[tile] += 1 }
                                    }
                                    i += 4
                                }
                            }
                        }
                    }
                }
            }
        }
        // Pixels per tile, from the column and row extents.
        var colWidth = [Int](repeating: 0, count: cols), rowHeight = [Int](repeating: 0, count: rows)
        for c in colOf { colWidth[c] += 1 }
        for y in 0..<height { rowHeight[y * rows / height] += 1 }
        for r in 0..<rows { for c in 0..<cols { pixels[r * cols + c] = colWidth[c] * rowHeight[r] } }
        var level = [Double](repeating: 0, count: n), area = [Double](repeating: 0, count: n)
        for i in 0..<n where pixels[i] > 0 {
            level[i] = round(Double(levelSum[i]) / Double(pixels[i]), 2)
            area[i] = round(Double(changed[i]) / Double(pixels[i]), 3)
        }
        return MotionTiles(level: level, area: area)
    }

    /// One sample from the frames rendered at `offsets(gaps:)` frames after `t` (missing frames are
    /// skipped). `frames[0]` is the frame at t.
    public static func sample(t: Double, gaps: [Double], frames: [Int: [UInt8]], width: Int, height: Int,
                              cols: Int, rows: Int) -> MotionSample {
        var builder = SampleBuilder(t: t, gaps: gaps, width: width, height: height, cols: cols, rows: rows)
        for offset in frames.keys.sorted() { builder.add(offset: offset, frame: frames[offset]!) }
        return builder.finish()
    }

    /// Builds one sample from frames fed in ascending offset order, as the render server snapshots
    /// them: each frame is compared as it arrives, so only the frame at t and the previous burst
    /// frame are kept (not every snapshot of the sample). Same result as `sample`.
    public struct SampleBuilder {
        public let t: Double
        public let gaps: [Double]
        let width: Int, height: Int, cols: Int, rows: Int
        private var base: [UInt8]?
        private var previous: (offset: Int, frame: [UInt8])?
        private var gapTiles: [Int: MotionTiles] = [:]
        private var flicker: MotionTiles

        public init(t: Double, gaps: [Double], width: Int, height: Int, cols: Int, rows: Int) {
            self.t = t; self.gaps = gaps; self.width = width; self.height = height; self.cols = cols; self.rows = rows
            let n = max(0, cols * rows)
            flicker = MotionTiles(level: Array(repeating: 0, count: n), area: Array(repeating: 0, count: n))
        }

        /// The frame `offset` frames (1/frameRate s each) after t; offsets must ascend.
        public mutating func add(offset: Int, frame: [UInt8]) {
            if offset == 0 { base = frame }
            guard let base else { return }
            if gaps.contains(where: { MotionAnalysis.frames($0) == offset }) {
                gapTiles[offset] = MotionAnalysis.tiles(base, frame, width: width, height: height, cols: cols, rows: rows)
            }
            guard let k = flickerOffsets.firstIndex(of: offset) else { return }
            // Only successive burst offsets are compared (a missing one leaves its spans out).
            if k > 0, let previous, previous.offset == flickerOffsets[k - 1] {
                let step = MotionAnalysis.tiles(previous.frame, frame, width: width, height: height, cols: cols, rows: rows)
                for i in flicker.level.indices {
                    flicker.level[i] = max(flicker.level[i], step.level[i])
                    flicker.area[i] = max(flicker.area[i], step.area[i])
                }
            }
            previous = k + 1 < flickerOffsets.count ? (offset, frame) : nil
        }

        public func finish() -> MotionSample {
            guard base != nil else {
                let n = max(0, cols * rows)
                return MotionSample(t: t, gaps: [], flicker: MotionTiles(level: Array(repeating: 0, count: n), area: Array(repeating: 0, count: n)))
            }
            let result = gaps.compactMap { gap in gapTiles[MotionAnalysis.frames(gap)].map { MotionGap(gap: gap, tiles: $0) } }
            return MotionSample(t: t, gaps: result, flicker: flicker)
        }
    }

    /// At most this many tiles × sampled moments × (gaps + 1) per motion request: each carries a
    /// `level` and an `area` number, and the whole response must fit in one line a client reads
    /// (LineSocket.maxLineBytes, 1 MiB; at most ~13 bytes per tile-pair, so ≤ 0.85 MiB). The
    /// default request (16×9 tiles, 4 moments, 3 gaps) needs 2,304.
    public static let maxTileValues = 65_536

    /// Whether a motion response for this grid and sampling stays within `maxTileValues`.
    public static func responseFits(cols: Int, rows: Int, times: Int, gaps: Int) -> Bool {
        let (g, o0) = gaps.addingReportingOverflow(1)
        let (a, o1) = cols.multipliedReportingOverflow(by: rows)
        let (b, o2) = a.multipliedReportingOverflow(by: times)
        let (c, o3) = b.multipliedReportingOverflow(by: g)
        return !o0 && !o1 && !o2 && !o3 && c >= 0 && c <= maxTileValues
    }

    // MARK: Summary

    /// The report.json numbers for one size (`size` is its label, e.g. "1280x720@0.5").
    public static func summarize(_ m: MotionMeasurement, size: String, budgets b: MotionBudgets = MotionBudgets(),
                                 heatmap: String? = nil) -> MotionSummary {
        let n = m.cols * m.rows
        let alive = aliveShare(m, budgets: b)
        let mid = movingShare(m, within: 2, budgets: b)
        let coverage5 = n > 0 ? alive.reduce(0, +) / Double(n) : 0
        let shares = regionNames.indices.map { regionShare(alive, region: $0, cols: m.cols, rows: m.rows) }
        let still = regionNames.indices.filter { shares[$0] < b.regionShare }
        var busy = 0.0, flicker = 0.0, flickerAt: Double?
        for s in m.samples {
            if let short = closest(s.gaps, to: 0.5), n > 0 {
                busy = max(busy, Double(short.tiles.level.filter { $0 >= b.busyLevel }.count) / Double(n))
            }
            if n > 0 {
                let f = Double(s.flicker.level.filter { $0 >= b.flickerLevel }.count) / Double(n)
                if f > flicker { flicker = f; flickerAt = s.t }
            }
        }
        let map = (0..<m.rows).map { r in
            String((0..<m.cols).map { c -> Character in
                let a = alive[r * m.cols + c]
                return a >= 0.5 ? "#" : a > 0 ? "+" : "."
            })
        }
        return MotionSummary(size: size, cols: m.cols, rows: m.rows, times: m.samples.map(\.t), coverage2s: round(mid, 3),
                             coverage5s: round(coverage5, 3), spread: round(Double(regionNames.count - still.count) / Double(regionNames.count), 3),
                             regions: Dictionary(uniqueKeysWithValues: zip(regionNames, shares.map { round($0, 3) })),
                             stillRegions: still.map { regionNames[$0] }, busy: round(busy, 3), flicker: round(flicker, 3),
                             flickerAt: flicker > 0 ? flickerAt : nil, map: map, heatmap: heatmap)
    }

    /// Per tile, the share of sampled moments at which it visibly changed within the longest gap.
    public static func aliveShare(_ m: MotionMeasurement, budgets b: MotionBudgets = MotionBudgets()) -> [Double] {
        let n = m.cols * m.rows
        let longest = m.samples.flatMap { $0.gaps.map(\.gap) }.max() ?? 0
        var counts = [Double](repeating: 0, count: n)
        var samples = 0
        for s in m.samples where valid(s, n) {
            samples += 1
            for i in 0..<n where movesWithin(s, longest, i, b) { counts[i] += 1 }
        }
        return samples > 0 ? counts.map { $0 / Double(samples) } : counts
    }

    /// Share of the frame that visibly changes within `seconds`, averaged over the samples.
    static func movingShare(_ m: MotionMeasurement, within seconds: Double, budgets b: MotionBudgets) -> Double {
        let n = m.cols * m.rows
        let shares = m.samples.filter { valid($0, n) && n > 0 }.map { s in
            Double((0..<n).filter { movesWithin(s, seconds, $0, b) }.count) / Double(n)
        }
        return shares.isEmpty ? 0 : shares.reduce(0, +) / Double(shares.count)
    }

    /// Whether tile `i` visibly changed within `seconds` of the sample's moment: compared with any
    /// frame up to that gap, or between successive frames of the flicker burst. ("Within", not "after":
    /// a sway or a flash whose period divides a gap looks unchanged at exactly that gap.)
    static func movesWithin(_ s: MotionSample, _ seconds: Double, _ i: Int, _ b: MotionBudgets) -> Bool {
        s.gaps.contains { $0.gap <= seconds + 1e-6 && moves($0.tiles, i, b) } || moves(s.flicker, i, b)
    }

    static func valid(_ s: MotionSample, _ n: Int) -> Bool {
        !s.gaps.isEmpty && s.gaps.allSatisfy { $0.tiles.level.count == n && $0.tiles.area.count == n } &&
            s.flicker.level.count == n && s.flicker.area.count == n
    }

    static func moves(_ t: MotionTiles, _ i: Int, _ b: MotionBudgets) -> Bool {
        t.level[i] >= b.tileLevel || t.area[i] >= b.tileArea
    }

    static func closest(_ gaps: [MotionGap], to gap: Double) -> MotionGap? {
        gaps.min { abs($0.gap - gap) < abs($1.gap - gap) }
    }

    /// Region (0–8, row-major thirds) of a tile, by its centre.
    public static func region(col: Int, row: Int, cols: Int, rows: Int) -> Int {
        let rx = min(2, Int((Double(col) + 0.5) / Double(cols) * 3)), ry = min(2, Int((Double(row) + 0.5) / Double(rows) * 3))
        return ry * 3 + rx
    }

    static func regionShare(_ alive: [Double], region: Int, cols: Int, rows: Int) -> Double {
        var sum = 0.0, count = 0
        for r in 0..<rows { for c in 0..<cols where Self.region(col: c, row: r, cols: cols, rows: rows) == region {
            sum += alive[r * cols + c]; count += 1
        } }
        return count > 0 ? sum / Double(count) : 0
    }

    static func round(_ x: Double, _ digits: Int) -> Double {
        let p = pow(10, Double(digits))
        return (x * p).rounded() / p
    }
}

// MARK: - Verdict

extension MotionAnalysis {
    /// Where scene authors (and agents) read how to fix motion problems.
    public static let guide = "\"Make it feel alive\" in SCENE_API.md"

    /// Problems (blocking) and warnings (advice) for the measured sizes, one sentence per kind of
    /// finding, each naming the numbers, where in the frame, and what to do.
    public static func verdict(_ summaries: [MotionSummary], budgets b: MotionBudgets) -> (problems: [String], warnings: [String]) {
        var problems: [String] = [], warnings: [String] = []
        func tooStatic(_ s: MotionSummary) -> Bool { s.coverage5s < b.minCoverage5s || s.movingRegions < b.minRegions }
        let stat = summaries.filter(tooStatic)
        // The worst size speaks for all of them; the others are named in passing.
        if let worst = stat.min(by: { ($0.coverage5s, $0.movingRegions) < ($1.coverage5s, $1.movingRegions) }) {
            let others = stat.filter { $0.size != worst.size }.map {
                "\($0.size): \(percent($0.coverage5s, limit: b.minCoverage5s)), \($0.movingRegions) of 9 regions"
            }
            problems.append(staticProblem(worst, others: others, b))
        }
        if let worst = summaries.filter({ $0.busy > b.maxBusy }).max(by: { $0.busy < $1.busy }) {
            problems.append("Too busy at \(worst.size): \(percent(worst.busy, limit: b.maxBusy)) of the frame changes strongly within half a second (at most " +
                            "\(percent(b.maxBusy))). Fast or large motion across the whole frame is tiring on a lock screen: slow it " +
                            "down — drift layers by a few pixels per second, use cycles of 10–60 s, move big layers only slightly and keep " +
                            "quick motion to small accents.")
        }
        if let worst = summaries.filter({ $0.flicker > b.maxFlicker }).max(by: { $0.flicker < $1.flicker }) {
            let when = worst.flickerAt.map { " (t = \(num($0)) s)" } ?? ""
            // Measured over burst spans of up to 8 frames (flickerOffsets), so a fast whole-frame fade
            // or pan counts as well as a flash: the advice covers both (SCENE_API §7, principle 6).
            problems.append("Flickers at \(worst.size)\(when): \(percent(worst.flicker, limit: b.maxFlicker)) of the frame changes sharply in " +
                            "brightness or colour within a fraction of a second (at most \(percent(b.maxFlicker))), which reads as " +
                            "flashing or strobing. Change large areas only gradually: fade whole-frame brightness and colour over a " +
                            "couple of seconds or more, move large high-contrast shapes slowly, never pick per-frame random values " +
                            "(Math.random() or lp.rand() inside draw) for big shapes or the background, and derive shimmer from smooth " +
                            "noise of lp.t (LivePaper.util.noise2/fbm2).")
        }
        if stat.isEmpty {
            // Each advice threshold is checked at every size: the lowest 5 s and 2 s coverages may come
            // from different sizes.
            if let low5 = summaries.min(by: { $0.coverage5s < $1.coverage5s }), let low2 = summaries.min(by: { $0.coverage2s < $1.coverage2s }),
               low5.coverage5s < b.goodCoverage5s || low2.coverage2s < b.goodCoverage2s {
                let five = percent(low5.coverage5s, limit: b.goodCoverage5s), two = percent(low2.coverage2s, limit: b.goodCoverage2s)
                let numbers = low5.size == low2.size
                    ? " at \(low5.size): \(five) of the frame changes within 5 s and \(two) within 2 s"
                    : ": \(five) of the frame changes within 5 s at \(low5.size), and \(two) within 2 s at \(low2.size)"
                warnings.append("Motion is on the subtle side\(numbers). Aim for at least \(percent(b.goodCoverage5s)) within 5 s and " +
                                "motion visible within 1–2 s wherever you look (see \(guide)).")
            }
            if let s = summaries.max(by: { $0.stillRegions.count < $1.stillRegions.count }), !s.stillRegions.isEmpty {
                let clock = s.stillRegions.contains("top") ? " Behind the clock (top centre) keep it dark and low-contrast." : ""
                warnings.append("Nothing moves in the \(list(s.stillRegions)) of the frame at \(s.size): give \(s.stillRegions.count == 1 ? "it" : "them") " +
                                "gentle motion too (drifting mist or light, shimmer, sway, a few slow particles) so the whole frame feels alive.\(clock)")
            }
        }
        return (problems, warnings)
    }

    static func staticProblem(_ s: MotionSummary, others: [String], _ b: MotionBudgets) -> String {
        let moving = regionNames.filter { !s.stillRegions.contains($0) }
        let lowCoverage = s.coverage5s < b.minCoverage5s, fewRegions = s.movingRegions < b.minRegions
        var head: String
        if s.coverage5s == 0 {
            head = "Too static at \(s.size): nothing in the frame changes within 5 s at any sampled moment (\(timeList(s.times)))."
        } else if lowCoverage && fewRegions {
            // Concentrated (a sun, one moon) or thinly scattered (a few small movers everywhere)?
            let total = s.regions.values.reduce(0, +), inMoving = moving.compactMap { s.regions[$0] }.reduce(0, +)
            let concentrated = !moving.isEmpty && (total == 0 || inMoving >= 0.7 * total)
            head = "Too static at \(s.size): only \(percent(s.coverage5s, limit: b.minCoverage5s)) of the frame visibly changes within 5 s (needs at least " +
                   "\(percent(b.minCoverage5s))), " +
                   (concentrated ? "almost all of it in the \(list(moving)) — the other \(s.stillRegions.count) of 9 regions " +
                                   "(\(s.stillRegions.joined(separator: ", "))) stay still."
                                 : "in small, scattered spots: \(s.stillRegions.count) of 9 regions (\(s.stillRegions.joined(separator: ", "))) " +
                                   "are still or nearly so.")
        } else if lowCoverage {
            head = "Too static at \(s.size): only \(percent(s.coverage5s, limit: b.minCoverage5s)) of the frame visibly changes within 5 s (needs at least " +
                   "\(percent(b.minCoverage5s))); the motion reaches most of the frame but is sparse (small, isolated movers)."
        } else {
            head = "Motion is confined to part of the frame at \(s.size): \(percent(s.coverage5s)) of the frame changes within 5 s, but " +
                   "only in the \(list(moving)) — the other \(s.stillRegions.count) of 9 regions (\(s.stillRegions.joined(separator: ", "))) " +
                   "stay still (needs motion in at least \(b.minRegions))."
        }
        if !others.isEmpty { head = String(head.dropLast()) + " (also at " + others.joined(separator: "; ") + ")." }
        let map = s.heatmap.map { " and the heat map .check/\(URL(fileURLWithPath: $0).lastPathComponent)" } ?? ""
        return head + " A LivePaper scene is a live wallpaper and should feel gently alive everywhere: give every part of the frame " +
            "slow ambient motion — drifting fog, mist or cloud layers, swaying foliage or grass, water shimmer and ripples, slow " +
            "parallax between depth layers or a gentle camera drift, floating dust, snow or embers, softly moving light — so " +
            "something changes within 1–2 s wherever you look, while staying calm (see \(guide)). What moves now: motion[].map " +
            "in report.json\(map)."
    }

    /// "9 %", "<1 %", "100 %".
    public static func percent(_ x: Double) -> String {
        if x > 0 && x < 0.005 { return "<1 %" }
        return "\(Int((x * 100).rounded())) %"
    }

    /// `x` as a percentage that stays on its side of `limit`: whole percent, or one decimal when
    /// rounding would make it read as the limit itself or cross it (0.247 against 25 % is "24.7 %",
    /// not "25 %"; 0.503 against 50 % is "50.3 %").
    public static func percent(_ x: Double, limit: Double) -> String {
        let whole = (x * 100).rounded(), edge = (limit * 100).rounded()
        guard (x < limit && whole >= edge) || (x > limit && whole <= edge) else { return percent(x) }
        var tenths = (x * 1000).rounded()
        if x < limit { tenths = min(tenths, edge * 10 - 1) } else { tenths = max(tenths, edge * 10 + 1) }
        return String(format: "%.1f %%", max(0, tenths) / 10)
    }

    /// "top-left", "top-left and top", "top-left, top and centre".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    /// "t = 3, 17, 41 and 120 s"
    static func timeList(_ times: [Double]) -> String { "t = " + list(times.map(num)) + " s" }

    static func num(_ x: Double) -> String { CheckFrame.num(x) }
}

// MARK: - Heat map

extension MotionAnalysis {
    /// The pixels of the motion heat map of `livepaper check` (RenderKit's Bitmap.motionHeatmap
    /// encodes them): the frame `pixels` (premultiplied RGBA, `width * 4` bytes per row) dimmed to
    /// grey, each tile of a `cols`×`rows` grid tinted by how often it changed within 5 s (`alive`,
    /// 0–1: blue at some sampled moments, amber at most of them, plain grey never), thin borders
    /// around every tile (the frame's outer edge included), and tiles that flicker outlined in red —
    /// a 2 px box on all four sides, inside the tile itself.
    public static func heatmap(_ pixels: [UInt8], width: Int, height: Int, alive: [Double], flicker: [Bool],
                               cols: Int, rows: Int) -> [UInt8] {
        guard width > 0, height > 0, cols > 0, rows > 0, pixels.count >= width * height * 4 else { return pixels }
        var out = pixels
        let colOf = (0..<width).map { $0 * cols / width }, rowOf = (0..<height).map { $0 * rows / height }
        // Per pixel row/column: first (or last) one of its tile, and within two of that edge.
        func edges(_ i: Int, _ tileOf: [Int]) -> (start: Bool, near: Bool, end: Bool) {
            let n = tileOf.count, t = tileOf[i]
            let start = i == 0 || tileOf[i - 1] != t
            let end = i == n - 1 || tileOf[i + 1] != t
            let nearStart = start || i == 1 || tileOf[i - 2] != t
            let nearEnd = end || i == n - 2 || tileOf[i + 2] != t
            return (start, nearStart || nearEnd, end)
        }
        let colEdges = (0..<width).map { edges($0, colOf) }
        for y in 0..<height {
            let r = rowOf[y], rowEdge = edges(y, rowOf)
            for x in 0..<width {
                let c = colOf[x], tile = r * cols + c, i = (y * width + x) * 4, colEdge = colEdges[x]
                let luma = 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
                // Lifted and stretched so even a dark scene stays recognisable under the tint.
                let grey = 40 + 0.8 * luma
                var rgb = (grey, grey, grey)
                let a = tile < alive.count ? alive[tile] : 0
                if a > 0 {
                    let (tint, k): ((Double, Double, Double), Double) = a >= 0.5 ? ((255, 165, 30), 0.22 + 0.2 * a) : ((70, 150, 255), 0.3)
                    rgb = (rgb.0 + (tint.0 - rgb.0) * k, rgb.1 + (tint.1 - rgb.1) * k, rgb.2 + (tint.2 - rgb.2) * k)
                }
                if tile < flicker.count, flicker[tile], rowEdge.near || colEdge.near {
                    rgb = (235, 40, 40)
                } else if rowEdge.start || colEdge.start || y == height - 1 || x == width - 1 {
                    // Grid lines at each tile's top and left, and closing the frame at the right and bottom.
                    rgb = (rgb.0 * 0.55, rgb.1 * 0.55, rgb.2 * 0.55)
                }
                out[i] = UInt8(max(0, min(255, rgb.0.rounded())))
                out[i + 1] = UInt8(max(0, min(255, rgb.1.rounded())))
                out[i + 2] = UInt8(max(0, min(255, rgb.2.rounded())))
                out[i + 3] = 255
            }
        }
        return out
    }
}
