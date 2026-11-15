// ReferenceSummary — the machine-readable facts written next to each reference image in a session
// workspace (`references/ref-01.json`), so an agent without vision still has something concrete:
// size and aspect, brightness against check's budgets, the dominant palette and a coarse colour grid.
// It never names the original file.
import CoreGraphics
import Foundation

public struct ReferenceSummary: Codable, Sendable, Equatable {
    public struct Original: Codable, Sendable, Equatable {
        public var width: Int
        public var height: Int
        /// "JPEG", "HEIC", "PNG", …
        public var format: String
        public var frames: Int
        public var transparent: Bool
    }

    public struct Brightness: Codable, Sendable, Equatable {
        public struct Limits: Codable, Sendable, Equatable {
            public var mean: Double
            public var behindClock: Double
        }
        /// Mean Rec. 709 luma (0–255) of the whole picture.
        public var mean: Double
        /// …inside the top clock rect when the picture is cover-fit at 1512×982.
        public var behindClock: Double
        /// `livepaper check`'s budgets.
        public var limits: Limits
        /// Multiply the picture by this (e.g. black at alpha 1 − k over it) to meet both budgets
        /// with 10 % headroom; only present when the picture is too bright as it is.
        public var darkenTo: Double?
    }

    public struct Swatch: Codable, Sendable, Equatable {
        public var hex: String
        /// Share of the picture's pixels (0–1).
        public var share: Double
    }

    public struct Grid: Codable, Sendable, Equatable {
        public var cols: Int
        public var rows: Int
        /// Mean colour per cell, top row first.
        public var colors: [[String]]
    }

    /// The full-resolution copy in the scene package (animate only).
    public struct Asset: Codable, Sendable, Equatable {
        public var path: String
        public var width: Int
        public var height: Int
        public var bytes: Int
    }

    public var schema = 1
    /// "ref-01.jpg" (set when the workspace is written).
    public var file: String
    public var role: AIReferenceRole
    /// Size of the vision copy (the file next to this summary).
    public var width: Int
    public var height: Int
    /// "16:9", "4:5", … or "1.52:1".
    public var aspect: String
    public var aspectRatio: Double
    /// landscape | portrait | square
    public var orientation: String
    public var original: Original
    public var brightness: Brightness
    public var palette: [Swatch]
    public var grid: Grid
    public var asset: Asset?

    /// JSON as written to the workspace: pretty, sorted keys, no escaped slashes.
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

// MARK: - Computing it

enum ReferenceAnalysis {
    /// Long edge of the bitmap the summary is computed from.
    static let analysisPixels = 96
    static let paletteSize = 6
    static let minSwatchShare = 0.02
    static let gridColumns = 12

    /// Ratios aspect names are snapped to (within 2 %), landscape first; portrait ones are their inverses.
    static let aspectNames: [(name: String, ratio: Double)] = {
        let landscape: [(String, Double, Double)] = [("1:1", 1, 1), ("5:4", 5, 4), ("4:3", 4, 3), ("3:2", 3, 2), ("16:10", 16, 10),
                                                     ("16:9", 16, 9), ("2:1", 2, 1), ("21:9", 21, 9), ("32:9", 32, 9), ("3:1", 3, 1)]
        var out = landscape.map { ($0.0, $0.1 / $0.2) }
        for (name, a, b) in landscape.dropFirst() {
            let parts = name.split(separator: ":")
            out.append(("\(parts[1]):\(parts[0])", b / a))
        }
        return out
    }()

    static func aspectName(width: Int, height: Int) -> String {
        let ratio = Double(width) / Double(max(height, 1))
        if let best = aspectNames.min(by: { abs($0.ratio / ratio - 1) < abs($1.ratio / ratio - 1) }), abs(best.ratio / ratio - 1) <= 0.02 {
            return best.name
        }
        return ratio >= 1 ? String(format: "%.2f:1", ratio) : String(format: "1:%.2f", 1 / ratio)
    }

    static func orientation(width: Int, height: Int) -> String {
        if aspectName(width: width, height: height) == "1:1" { return "square" }
        return width > height ? "landscape" : "portrait"
    }

    static func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
        func c(_ v: Double) -> Int { Int(min(max(v.rounded(), 0), 255)) }
        return String(format: "#%02x%02x%02x", c(r), c(g), c(b))
    }

    static func round(_ x: Double, _ digits: Int) -> Double {
        let p = pow(10.0, Double(digits))
        return (x * p).rounded() / p
    }

    /// The summary of `master` (sRGB pixels at full master size). `vision` gives the reported size.
    static func summary(master: CGImage, vision: EncodedReferenceImage, original: ReferenceProbe, transparent: Bool,
                        role: AIReferenceRole) -> ReferenceSummary? {
        guard let bmp = SRGBBitmap(image: master, maxPixel: analysisPixels) else { return nil }
        let budgets = CheckBudgets()
        let (mean, behind) = brightness(bmp)
        var k = min(1, 0.9 * budgets.maxMeanLuma / max(mean, 1), 0.9 * budgets.maxClockLuma / max(behind, 1))
        k = max(0.05, (k * 100).rounded(.down) / 100)
        return ReferenceSummary(
            file: "", role: role, width: vision.width, height: vision.height,
            aspect: aspectName(width: vision.width, height: vision.height),
            aspectRatio: round(Double(vision.width) / Double(max(vision.height, 1)), 3),
            orientation: orientation(width: vision.width, height: vision.height),
            original: .init(width: original.width, height: original.height, format: original.formatName,
                            frames: original.frameCount, transparent: transparent),
            brightness: .init(mean: round(mean, 1), behindClock: round(behind, 1),
                              limits: .init(mean: budgets.maxMeanLuma, behindClock: budgets.maxClockLuma), darkenTo: k < 1 ? k : nil),
            palette: palette(bmp), grid: grid(bmp), asset: nil)
    }

    /// Mean luma of the picture, and inside the runtime's top clock rect when it is cover-fit at
    /// the primary check size.
    static func brightness(_ bmp: SRGBBitmap) -> (mean: Double, behindClock: Double) {
        let sat = SummedArea(bmp)
        let frame = CheckPlan.primary
        let fw = Double(frame.width), fh = Double(frame.height)
        let crop = ReferenceResemblance.coverCrop(width: bmp.width, height: bmp.height, aspect: fw / fh, zoom: 1, dx: 0, dy: 0)
        let clock = ReferenceResemblance.clockRect(.top, width: fw, height: fh)
        let s = crop.width / fw
        let rect = CGRect(x: crop.minX + clock.minX * s, y: crop.minY + clock.minY * s, width: clock.width * s, height: clock.height * s)
        let c = sat.mean(in: rect)
        return (bmp.meanLuma, SRGBBitmap.luma(c.r, c.g, c.b))
    }

    /// Deterministic median cut: up to six colours, each with its share of the pixels; colours
    /// under 2 % are dropped. Boxes are split along their widest channel at the median value, so
    /// identical colours always stay in one box.
    static func palette(_ bmp: SRGBBitmap) -> [ReferenceSummary.Swatch] {
        let n = bmp.width * bmp.height
        guard n > 0 else { return [] }
        var pixels = [(UInt8, UInt8, UInt8)]()
        pixels.reserveCapacity(n)
        for i in stride(from: 0, to: bmp.rgba.count, by: 4) { pixels.append((bmp.rgba[i], bmp.rgba[i + 1], bmp.rgba[i + 2])) }
        func channel(_ p: (UInt8, UInt8, UInt8), _ c: Int) -> UInt8 { c == 0 ? p.0 : c == 1 ? p.1 : p.2 }
        func widest(_ box: [Int]) -> (channel: Int, range: Int) {
            var best = (0, -1)
            for c in 0..<3 {
                var lo = 255, hi = 0
                for i in box { let v = Int(channel(pixels[i], c)); lo = min(lo, v); hi = max(hi, v) }
                if hi - lo > best.1 { best = (c, hi - lo) }
            }
            return best
        }
        var boxes: [[Int]] = [Array(0..<n)]
        while boxes.count < paletteSize {
            var pick: (index: Int, channel: Int, score: Int)?
            for (i, box) in boxes.enumerated() {
                let w = widest(box)
                guard w.range > 0 else { continue }
                let score = box.count * w.range
                if pick == nil || score > pick!.score { pick = (i, w.channel, score) }
            }
            guard let pick else { break }
            let box = boxes[pick.index], c = pick.channel
            let sorted = box.sorted { (channel(pixels[$0], c), $0) < (channel(pixels[$1], c), $1) }
            let median = channel(pixels[sorted[sorted.count / 2]], c)
            var left = sorted.filter { channel(pixels[$0], c) < median }, right = sorted.filter { channel(pixels[$0], c) >= median }
            if left.isEmpty {
                left = sorted.filter { channel(pixels[$0], c) <= median }
                right = sorted.filter { channel(pixels[$0], c) > median }
            }
            boxes[pick.index] = left
            boxes.append(right)
        }
        var merged: [String: Int] = [:]
        for box in boxes where !box.isEmpty {
            var r = 0, g = 0, b = 0
            for i in box { r += Int(pixels[i].0); g += Int(pixels[i].1); b += Int(pixels[i].2) }
            let k = Double(box.count)
            merged[hex(Double(r) / k, Double(g) / k, Double(b) / k), default: 0] += box.count
        }
        return merged.map { ReferenceSummary.Swatch(hex: $0.key, share: round(Double($0.value) / Double(n), 3)) }
            .filter { $0.share >= minSwatchShare }
            .sorted { ($0.share, $1.hex) > ($1.share, $0.hex) }
            .prefix(paletteSize).map { $0 }
    }

    /// 12 columns × round(12 / aspect) rows (3…16) for landscape pictures; portrait ones transposed.
    static func gridSize(width: Int, height: Int) -> (cols: Int, rows: Int) {
        let aspect = Double(width) / Double(max(height, 1))
        func clamp(_ v: Double) -> Int { min(max(Int(v.rounded()), 3), 16) }
        return aspect >= 1 ? (gridColumns, clamp(Double(gridColumns) / aspect)) : (clamp(Double(gridColumns) * aspect), gridColumns)
    }

    static func grid(_ bmp: SRGBBitmap) -> ReferenceSummary.Grid {
        let (cols, rows) = gridSize(width: bmp.width, height: bmp.height)
        let sat = SummedArea(bmp)
        let cw = Double(bmp.width) / Double(cols), ch = Double(bmp.height) / Double(rows)
        let colors = (0..<rows).map { y in
            (0..<cols).map { x -> String in
                let c = sat.mean(in: CGRect(x: Double(x) * cw, y: Double(y) * ch, width: cw, height: ch))
                return hex(c.r, c.g, c.b)
            }
        }
        return .init(cols: cols, rows: rows, colors: colors)
    }
}
