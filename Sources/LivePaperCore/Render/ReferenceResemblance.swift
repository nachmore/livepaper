// ReferenceResemblance — does an "animate this exact image" scene still show the user's picture?
// (ARCHITECTURE §9, the resemblance step of `livepaper check`.)
//
// Each sampled still is compared with the cover-fit crop of the picture on a coarse grid (48
// columns), allowing for a slow camera: the crop may be zoomed in by up to 16 % and shifted by up to
// 6 % of its size, and the best of those 125 candidates counts. Per candidate:
//
//   low     Pearson correlation of the blurred luma (5×5 cells): the composition, light and shade
//   band    Pearson correlation of luma minus blur: the detail (edges, texture)
//   colour  cosine of the blurred chroma (R−G, (R+G)/2−B): hues, ignoring brightness
//   score   (0.25·low + 0.5·band + 0.25·colour) / the weights of the parts that are defined
//           (negatives count as 0), 0…1
//
// Correlations ignore even darkening and contrast changes (the brightness budgets often force
// those), the clock's cells are masked, and so are the cells where a transparent picture (a
// cut-out) is see-through: whatever the scene puts behind it isn't compared. A still that is flat
// next to the picture's own contrast scores 0. Measured bands (§9): the picture with a slow camera,
// darkening, fog or particles ≥ 0.75; the same layout with another picture 0.35–0.7; an unrelated
// scene ≤ 0.3. Only the deterministic rules (the scene never loads the picture) and a median below
// `failBelow` fail; everything else only warns.
import Accelerate
import CoreGraphics
import Foundation
import ImageIO

/// The picture to compare with: sRGB pixels at ≤ 384 px on the long edge.
public struct ReferenceFingerprint: Sendable, Equatable {
    public static let longEdge = 384
    public let width: Int
    public let height: Int
    /// RGBA (premultiplied, i.e. over black), top row first.
    public let rgba: [UInt8]

    /// Some pixel isn't fully opaque (the comparison then leaves out the see-through cells).
    public var hasAlpha: Bool {
        var i = 3
        while i < rgba.count { if rgba[i] != 255 { return true }; i += 4 }
        return false
    }

    public init(image: CGImage) {
        let bmp = SRGBBitmap(image: image, maxPixel: Self.longEdge) ?? SRGBBitmap(width: 1, height: 1, rgba: [0, 0, 0, 255])
        width = bmp.width; height = bmp.height; rgba = bmp.rgba
    }

    public init(data: Data) throws {
        guard let image = ReferenceImporter.thumbnail(of: data, maxPixel: Self.longEdge) else {
            throw ReferenceError.unreadable(name: "reference")
        }
        self.init(image: image)
    }

    public init(contentsOf url: URL) throws { try self.init(data: Data(contentsOf: url)) }

    var bitmap: SRGBBitmap { SRGBBitmap(width: width, height: height, rgba: rgba) }
}

/// What the check needs to judge an animate scene: where its copy of the picture is, the hash of
/// the copy LivePaper wrote, and the picture itself.
public struct ReferenceTarget: Sendable, Equatable {
    /// Relative to the scene package: "assets/reference.jpg".
    public var assetPath: String
    public var assetSHA256: String
    public var fingerprint: ReferenceFingerprint
    public init(assetPath: String, assetSHA256: String, fingerprint: ReferenceFingerprint) {
        self.assetPath = assetPath; self.assetSHA256 = assetSHA256; self.fingerprint = fingerprint
    }
}

/// How much one still looks like the picture (the best candidate framing).
public struct ResemblanceScore: Codable, Sendable, Equatable {
    public var score: Double
    public var low: Double?
    public var band: Double?
    public var colour: Double?
    /// The framing that matched best: zoom of the cover-fit crop and its offset (share of the crop).
    public var zoom: Double
    public var offset: [Double]
    /// Standard deviation of the still's luma over the grid.
    public var stillContrast: Double
    /// The still was too flat to compare (scored 0): darkened, fogged or covered until the
    /// picture's detail is gone.
    public var flat: Bool
    public init(score: Double, low: Double? = nil, band: Double? = nil, colour: Double? = nil, zoom: Double, offset: [Double], stillContrast: Double,
                flat: Bool = false) {
        self.score = score; self.low = low; self.band = band; self.colour = colour; self.zoom = zoom; self.offset = offset
        self.stillContrast = stillContrast; self.flat = flat
    }
}

public struct ReferenceMeasurement: Sendable {
    public var assetPath: String
    /// The asset is a regular file with the bytes LivePaper wrote.
    public var assetIntact: Bool
    /// A string in scene.js names the asset's file.
    public var referencedInScene: Bool
    /// The picture has enough detail to compare with.
    public var referenceMeasurable: Bool
    /// Share of the picture that is opaque enough to compare (1 without transparency).
    public var opaqueShare: Double
    public var frames: [(frame: CheckFrame, score: ResemblanceScore)]
    public init(assetPath: String, assetIntact: Bool, referencedInScene: Bool, referenceMeasurable: Bool, opaqueShare: Double = 1,
                frames: [(frame: CheckFrame, score: ResemblanceScore)]) {
        self.assetPath = assetPath; self.assetIntact = assetIntact; self.referencedInScene = referencedInScene
        self.referenceMeasurable = referenceMeasurable; self.opaqueShare = opaqueShare; self.frames = frames
    }
}

/// Thresholds of the resemblance step (part of `CheckBudgets`).
public struct ReferenceBudgets: Sendable, Equatable {
    /// The median similarity below which the stills don't show the picture (fails).
    public var failBelow = 0.35
    /// Below this a primary still drifts too far from the picture (warns).
    public var warnBelow = 0.70
    /// 32:9 / 5:4 warn when their median is this far under the primary size's.
    public var aspectGap = 0.25
    /// A still is flat (scores 0) when its luma standard deviation is under
    /// max(`flatStillFloor`, min(`minStillContrast`, `flatStillShare` × the cover-fit picture's own)):
    /// relative, so a soft, bright picture darkened by TASK.md's darkenTo (≥ 0.42) still counts.
    public var minStillContrast = 3.0
    public var flatStillShare = 0.2
    public var flatStillFloor = 1.0
    /// A picture flatter than this can't be compared (warns "check by eye").
    public var minReferenceContrast = 4.0
    /// Cells of a transparent picture whose mean opacity is under this aren't compared (the
    /// scene's backdrop shows there).
    public var minCellOpacity = 0.9
    /// A transparent picture with less of its grid opaque than this can't be compared (warns).
    public var minOpaqueShare = 0.2
    /// The median colour match of the primary stills under which the picture's colours count as
    /// gone or changed (warns; greyscale scores 0 and a wash that shifts the hue −0.4–0.1, while even
    /// darkening and fog stay near 1).
    public var minColour = 0.3
    public init() {}
}

/// `report.json` › `reference`.
public struct ReferenceCheckSummary: Codable, Sendable, Equatable {
    public var asset: String
    public var assetIntact: Bool
    public var referencedInScene: Bool
    /// Frame label ("1512x982@2 t=12") → similarity 0…1.
    public var similarity: [String: Double]
    public var median: Double?
    public init(asset: String, assetIntact: Bool, referencedInScene: Bool, similarity: [String: Double], median: Double?) {
        self.asset = asset; self.assetIntact = assetIntact; self.referencedInScene = referencedInScene
        self.similarity = similarity; self.median = median
    }
}

public enum ReferenceResemblance {
    public static let columns = 48
    static let zooms: [Double] = [1, 1.04, 1.08, 1.12, 1.16]
    static let shifts: [Double] = [-0.06, -0.03, 0, 0.03, 0.06]
    /// Stills are decoded at this size (long edge) for scoring.
    static let stillPixels = 192
    static let blurRadius = 2   // 5×5 cells
    static let minBandStd = 1.5
    static let minReferenceChroma = 4.0
    static let minStillChroma = 1.0
    /// Detail counts most: blurred luma alone correlates for unrelated pictures that share a
    /// vertical light distribution (a night aurora vs a sunset lake: 0.69).
    static let weights = (low: 0.25, band: 0.5, colour: 0.25)

    // MARK: - Geometry

    /// The runtime clock's rect for `p` in a `width`×`height` CSS viewport (runtime.js `rectFor`);
    /// `none` gives the top rect, where Apple's own lock-screen clock appears.
    static func clockRect(_ p: LPClockPosition, width w: Double, height h: Double) -> CGRect {
        let time = min(max(min(w * 0.11, h * 0.15), 40), 210)
        let date = max(13, time * 0.2)
        let bw = time * 3.4, bh = date * 1.6 + time * 1.1
        let pad = max(24, min(w, h) * 0.06)
        switch p {
        case .bottomLeft: return CGRect(x: pad, y: h - pad - bh, width: bw, height: bh)
        case .bottomRight: return CGRect(x: w - pad - bw, y: h - pad - bh, width: bw, height: bh)
        case .top, .none: return CGRect(x: w / 2 - bw / 2, y: h * 0.07, width: bw, height: bh)
        }
    }

    /// The part of a `width`×`height` picture a cover-fit at `aspect` shows, zoomed in by `zoom`
    /// (crop / zoom) and shifted by (`dx`, `dy`) × the crop's size, kept inside the picture.
    static func coverCrop(width: Int, height: Int, aspect: Double, zoom: Double, dx: Double, dy: Double) -> CGRect {
        let w = Double(width), h = Double(height)
        var cw = w, ch = h
        if w / h > aspect { cw = h * aspect } else { ch = w / aspect }
        cw /= zoom; ch /= zoom
        let x = min(max((w - cw) / 2 + dx * cw, 0), w - cw)
        let y = min(max((h - ch) / 2 + dy * ch, 0), h - ch)
        return CGRect(x: x, y: y, width: cw, height: ch)
    }

    static func rows(aspect: Double) -> Int { max(8, Int((Double(columns) / aspect).rounded())) }

    // MARK: - Features

    /// One grid's measures over its unmasked cells (the clock's cells filled with the grid's own
    /// mean before blurring): z-scored blurred luma and detail, and the unit chroma vector, so that
    /// comparing two grids is three dot products.
    struct Features {
        var lowZ: [Double], bandZ: [Double], chroma: [Double]
        var lumaStd: Double, bandStd: Double, chromaRMS: Double
    }

    /// The clock's cells (its rect plus one cell around it) in a `cols`×`rows` grid over the viewport.
    static func mask(cols: Int, rows: Int, cssWidth: Double, cssHeight: Double, clock: LPClockPosition) -> [Bool] {
        let cw = cssWidth / Double(cols), ch = cssHeight / Double(rows)
        let r = clockRect(clock, width: cssWidth, height: cssHeight).insetBy(dx: -cw, dy: -ch)
        var m = [Bool](repeating: false, count: cols * rows)
        for y in 0..<rows { for x in 0..<cols where r.contains(CGPoint(x: (Double(x) + 0.5) * cw, y: (Double(y) + 0.5) * ch)) { m[y * cols + x] = true } }
        return m
    }

    static func features(_ sat: SummedArea, rect: CGRect, cols: Int, rows: Int, masked: [Bool]) -> Features {
        let n = cols * rows
        var (r, g, b) = sat.cellMeans(rect: rect, cols: cols, rows: rows)
        var sr = 0.0, sg = 0.0, sb = 0.0, k = 0.0
        for i in 0..<n where !masked[i] { sr += r[i]; sg += g[i]; sb += b[i]; k += 1 }
        if k > 0 { for i in 0..<n where masked[i] { r[i] = sr / k; g[i] = sg / k; b[i] = sb / k } }
        let br = blur(r, cols, rows), bg = blur(g, cols, rows), bb = blur(b, cols, rows)
        var luma: [Double] = [], low: [Double] = [], band: [Double] = [], chroma: [Double] = []
        luma.reserveCapacity(n); low.reserveCapacity(n); band.reserveCapacity(n); chroma.reserveCapacity(2 * n)
        for i in 0..<n where !masked[i] {
            let l = SRGBBitmap.luma(r[i], g[i], b[i]), lb = SRGBBitmap.luma(br[i], bg[i], bb[i])
            luma.append(l); low.append(lb); band.append(l - lb)
            chroma.append(br[i] - bg[i]); chroma.append((br[i] + bg[i]) / 2 - bb[i])
        }
        let chromaNorm = dot(chroma, chroma).squareRoot()
        let (lowZ, _) = zScored(low), (bandZ, bandStd) = zScored(band), (_, lumaStd) = zScored(luma)
        if chromaNorm > 1e-9 {
            var scale = 1 / chromaNorm
            chroma.withUnsafeMutableBufferPointer { c in vDSP_vsmulD(c.baseAddress!, 1, &scale, c.baseAddress!, 1, vDSP_Length(c.count)) }
        }
        return Features(lowZ: lowZ, bandZ: bandZ, chroma: chroma, lumaStd: lumaStd, bandStd: bandStd,
                        chromaRMS: luma.isEmpty ? 0 : chromaNorm / Double(luma.count).squareRoot())
    }

    static func dot(_ a: [Double], _ b: [Double]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var out = 0.0
        vDSP_dotprD(a, 1, b, 1, &out, vDSP_Length(a.count))
        return out
    }

    /// (v − mean) / std, and std (population); all zeros when v is flat.
    static func zScored(_ v: [Double]) -> ([Double], Double) {
        guard v.count > 1 else { return ([Double](repeating: 0, count: v.count), 0) }
        var mean = 0.0, sd = 0.0
        vDSP_normalizeD(v, 1, nil, 1, &mean, &sd, vDSP_Length(v.count))
        // vDSP reports the sample standard deviation; the population one is what "contrast" means here.
        let std = sd * (Double(v.count - 1) / Double(v.count)).squareRoot()
        guard std > 1e-9 else { return ([Double](repeating: 0, count: v.count), 0) }
        var out = [Double](repeating: 0, count: v.count)
        var m = -mean, scale = 1 / std
        out.withUnsafeMutableBufferPointer { o in
            vDSP_vsaddD(v, 1, &m, o.baseAddress!, 1, vDSP_Length(v.count))
            vDSP_vsmulD(o.baseAddress!, 1, &scale, o.baseAddress!, 1, vDSP_Length(v.count))
        }
        return (out, std)
    }

    /// Separable box blur, (2·blurRadius + 1)² cells, averaging only the cells inside the grid
    /// (vDSP: shifted adds, then one multiply by the reciprocal cell counts).
    static func blur(_ v: [Double], _ cols: Int, _ rows: Int) -> [Double] {
        let r = blurRadius, n = v.count
        guard n == cols * rows, n > 0 else { return v }
        var h = [Double](repeating: 0, count: n), out = h
        v.withUnsafeBufferPointer { src in
            h.withUnsafeMutableBufferPointer { dst in
                for y in 0..<rows {
                    let row = y * cols
                    for d in -r...r {
                        let from = max(0, d), to = max(0, -d), len = cols - abs(d)
                        guard len > 0 else { continue }
                        vDSP_vaddD(src.baseAddress! + row + from, 1, dst.baseAddress! + row + to, 1, dst.baseAddress! + row + to, 1, vDSP_Length(len))
                    }
                }
            }
        }
        h.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for d in -r...r {
                    let from = max(0, d) * cols, to = max(0, -d) * cols, len = (rows - abs(d)) * cols
                    guard len > 0 else { continue }
                    vDSP_vaddD(src.baseAddress! + from, 1, dst.baseAddress! + to, 1, dst.baseAddress! + to, 1, vDSP_Length(len))
                }
            }
        }
        let weights = blurWeights(cols, rows)
        out.withUnsafeMutableBufferPointer { o in
            vDSP_vmulD(o.baseAddress!, 1, weights, 1, o.baseAddress!, 1, vDSP_Length(n))
        }
        return out
    }

    /// 1 / (cells averaged) per cell of a `cols`×`rows` grid.
    static func blurWeights(_ cols: Int, _ rows: Int) -> [Double] {
        let r = blurRadius
        func count(_ i: Int, _ size: Int) -> Double { Double(min(size - 1, i + r) - max(0, i - r) + 1) }
        var w = [Double](repeating: 0, count: cols * rows)
        for y in 0..<rows { let cy = count(y, rows); for x in 0..<cols { w[y * cols + x] = 1 / (cy * count(x, cols)) } }
        return w
    }

    static func compare(still s: Features, reference r: Features) -> (score: Double, low: Double, band: Double?, colour: Double?) {
        let n = Double(max(1, s.lowZ.count))
        let low = dot(s.lowZ, r.lowZ) / n
        let band: Double? = r.bandStd < minBandStd ? nil : dot(s.bandZ, r.bandZ) / n
        var colour: Double?
        if r.chromaRMS >= minReferenceChroma { colour = s.chromaRMS < minStillChroma ? 0 : dot(s.chroma, r.chroma) }
        // Weighted mean of the parts that are defined (negative correlations count as 0).
        var sum = weights.low * max(0, low), weight = weights.low
        if let band { sum += weights.band * max(0, band); weight += weights.band }
        if let colour { sum += weights.colour * max(0, colour); weight += weights.colour }
        return (min(max(sum / weight, 0), 1), low, band, colour)
    }

    // MARK: - Scoring

    /// Scores stills against one picture, caching the picture's candidate framings per viewport
    /// (they don't depend on the still): use one for all the stills of a check.
    public final class Scorer {
        public let reference: ReferenceFingerprint
        public let clock: LPClockPosition
        public let budgets: ReferenceBudgets
        private let sat: SummedArea

        /// One framing of the picture: its features, and — when the picture is see-through somewhere
        /// in it — the cells left out (clock + transparent), which the still is then measured with too.
        private struct Candidate {
            var zoom: Double, offset: [Double], features: Features, mask: [Bool]?
        }
        private struct Viewport {
            var cols: Int, rows: Int, clockMask: [Bool], candidates: [Candidate]
            /// The cover-fit framing itself (zoom 1, centred).
            var centre: Candidate
        }
        private var viewports: [String: Viewport] = [:]

        public init(reference: ReferenceFingerprint, clock: LPClockPosition, budgets: ReferenceBudgets = .init()) {
            self.reference = reference; self.clock = clock; self.budgets = budgets
            sat = SummedArea(reference.bitmap, withAlpha: reference.hasAlpha)
        }

        public func score(still: CGImage, cssWidth: Double, cssHeight: Double) -> ResemblanceScore {
            let vp = viewport(cssWidth: cssWidth, cssHeight: cssHeight)
            guard let bmp = SRGBBitmap(image: still, maxPixel: ReferenceResemblance.stillPixels) else {
                return ResemblanceScore(score: 0, zoom: 1, offset: [0, 0], stillContrast: 0)
            }
            let stillSAT = SummedArea(bmp), full = CGRect(x: 0, y: 0, width: bmp.width, height: bmp.height)
            let base = ReferenceResemblance.features(stillSAT, rect: full, cols: vp.cols, rows: vp.rows, masked: vp.clockMask)
            func stillFeatures(_ c: Candidate) -> Features {
                c.mask.map { ReferenceResemblance.features(stillSAT, rect: full, cols: vp.cols, rows: vp.rows, masked: $0) } ?? base
            }
            let centre = stillFeatures(vp.centre)
            let contrast = ReferenceResemblance.rounded(centre.lumaStd)
            guard centre.lumaStd >= flatBelow(vp) else {
                return ResemblanceScore(score: 0, zoom: 1, offset: [0, 0], stillContrast: contrast, flat: true)
            }
            var best: ResemblanceScore?
            for c in vp.candidates {
                let m = ReferenceResemblance.compare(still: stillFeatures(c), reference: c.features)
                if best == nil || m.score > best!.score + 1e-12 {
                    best = ResemblanceScore(score: m.score, low: m.low, band: m.band, colour: m.colour, zoom: c.zoom, offset: c.offset,
                                            stillContrast: contrast)
                }
            }
            return best ?? ResemblanceScore(score: 0, zoom: 1, offset: [0, 0], stillContrast: contrast)
        }

        /// The luma contrast under which a still at this viewport is flat: relative to the
        /// cover-fit picture's own, capped by `minStillContrast`.
        private func flatBelow(_ vp: Viewport) -> Double {
            max(budgets.flatStillFloor, min(budgets.minStillContrast, budgets.flatStillShare * vp.centre.features.lumaStd))
        }

        private func viewport(cssWidth: Double, cssHeight: Double) -> Viewport {
            let key = "\(cssWidth)x\(cssHeight)"
            if let known = viewports[key] { return known }
            let aspect = cssWidth / cssHeight
            let cols = ReferenceResemblance.columns, rows = ReferenceResemblance.rows(aspect: aspect)
            let clockMask = ReferenceResemblance.mask(cols: cols, rows: rows, cssWidth: cssWidth, cssHeight: cssHeight, clock: clock)
            var list: [Candidate] = []
            for z in ReferenceResemblance.zooms {
                for dy in ReferenceResemblance.shifts {
                    for dx in ReferenceResemblance.shifts {
                        let crop = ReferenceResemblance.coverCrop(width: reference.width, height: reference.height, aspect: aspect, zoom: z, dx: dx, dy: dy)
                        let masked = maskWithTransparency(clockMask, crop: crop, cols: cols, rows: rows)
                        list.append(Candidate(zoom: z, offset: [dx, dy],
                                              features: ReferenceResemblance.features(sat, rect: crop, cols: cols, rows: rows, masked: masked ?? clockMask),
                                              mask: masked))
                    }
                }
            }
            let centre = list.first { $0.zoom == 1 && $0.offset == [0, 0] } ?? list[0]
            let vp = Viewport(cols: cols, rows: rows, clockMask: clockMask, candidates: list, centre: centre)
            viewports[key] = vp
            return vp
        }

        /// `base` plus the cells of `crop` the picture doesn't cover opaquely enough, or nil when
        /// that adds nothing (an opaque picture, or an opaque part of it).
        private func maskWithTransparency(_ base: [Bool], crop: CGRect, cols: Int, rows: Int) -> [Bool]? {
            guard let alpha = sat.cellAlpha(rect: crop, cols: cols, rows: rows) else { return nil }
            let limit = budgets.minCellOpacity * 255
            var m = base, changed = false
            for i in m.indices where !m[i] && alpha[i] < limit { m[i] = true; changed = true }
            return changed ? m : nil
        }

        /// Luma contrast of the whole picture on the comparison grid (its opaque parts).
        public var referenceContrast: Double {
            let (cols, rows, rect, masked) = wholeGrid()
            return ReferenceResemblance.features(sat, rect: rect, cols: cols, rows: rows, masked: masked).lumaStd
        }

        /// Share of the whole picture's grid that is opaque enough to compare (1 without transparency).
        public var opaqueShare: Double {
            let (_, _, _, masked) = wholeGrid()
            return masked.isEmpty ? 1 : Double(masked.filter { !$0 }.count) / Double(masked.count)
        }

        private func wholeGrid() -> (cols: Int, rows: Int, rect: CGRect, masked: [Bool]) {
            let aspect = Double(reference.width) / Double(max(reference.height, 1))
            let cols = ReferenceResemblance.columns, rows = ReferenceResemblance.rows(aspect: aspect)
            let rect = CGRect(x: 0, y: 0, width: reference.width, height: reference.height)
            let none = [Bool](repeating: false, count: cols * rows)
            return (cols, rows, rect, maskWithTransparency(none, crop: rect, cols: cols, rows: rows) ?? none)
        }
    }

    /// How much `still` (a frame laid out at `cssWidth`×`cssHeight`) looks like the cover-fit picture.
    public static func score(still: CGImage, cssWidth: Double, cssHeight: Double, reference: ReferenceFingerprint,
                             clock: LPClockPosition, budgets: ReferenceBudgets = .init()) -> ResemblanceScore {
        Scorer(reference: reference, clock: clock, budgets: budgets).score(still: still, cssWidth: cssWidth, cssHeight: cssHeight)
    }

    /// Scores every still (PNG paths, absolute or relative to `package`) and checks the package's
    /// copy of the picture.
    public static func measure(package: URL, target: ReferenceTarget, stills: [(frame: CheckFrame, path: String)],
                               clock: LPClockPosition, budgets: ReferenceBudgets = .init()) -> ReferenceMeasurement {
        let assetURL = package.appendingPathComponent(target.assetPath)
        let intact = FileOps.isRegularFile(assetURL) && (try? Data(contentsOf: assetURL)).map(ReferenceImporter.sha256) == target.assetSHA256
        let name = (target.assetPath as NSString).lastPathComponent
        let js = (try? String(contentsOf: package.appendingPathComponent(SceneCompiler.sceneFile), encoding: .utf8)) ?? ""
        let referenced = JSTokenizer.tokens(js).contains { $0.kind == .string && $0.text.contains(name) }
        let scorer = Scorer(reference: target.fingerprint, clock: clock, budgets: budgets)
        var frames: [(frame: CheckFrame, score: ResemblanceScore)] = []
        for (frame, path) in stills {
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : package.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url), let image = ReferenceImporter.thumbnail(of: data, maxPixel: stillPixels) else { continue }
            frames.append((frame, scorer.score(still: image, cssWidth: Double(frame.width), cssHeight: Double(frame.height))))
        }
        return ReferenceMeasurement(assetPath: target.assetPath, assetIntact: intact, referencedInScene: referenced,
                                    referenceMeasurable: scorer.referenceContrast >= budgets.minReferenceContrast,
                                    opaqueShare: rounded(scorer.opaqueShare), frames: frames)
    }

    // MARK: - Verdict

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func two(_ x: Double) -> String { String(format: "%.2f", x) }
    static func rounded(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    /// "16:10", "32:9", "5:4" — how the check's sizes are named in messages.
    static func aspectLabel(_ f: CheckFrame) -> String {
        if f.width == 2560 && f.height == 720 { return "32:9" }
        if f.width == 1280 && f.height == 1024 { return "5:4" }
        if f.width == CheckPlan.primary.width && f.height == CheckPlan.primary.height { return "16:10" }
        return ReferenceAnalysis.aspectName(width: f.width, height: f.height)
    }

    static func isPrimary(_ f: CheckFrame) -> Bool { f.width == CheckPlan.primary.width && f.height == CheckPlan.primary.height }

    /// Problems (blocking), warnings and the report's summary.
    public static func verdict(_ m: ReferenceMeasurement, budgets b: ReferenceBudgets) -> (problems: [String], warnings: [String], summary: ReferenceCheckSummary) {
        var problems: [String] = [], warnings: [String] = []
        let scores = m.frames.map(\.score.score)
        let med = median(scores)
        let summary = ReferenceCheckSummary(asset: m.assetPath, assetIntact: m.assetIntact, referencedInScene: m.referencedInScene,
                                            similarity: Dictionary(m.frames.map { ($0.frame.label, rounded($0.score.score)) }, uniquingKeysWith: { a, _ in a }),
                                            median: med.map(rounded))
        let name = (m.assetPath as NSString).lastPathComponent
        if !m.referencedInScene {
            problems.append("This scene must animate the user's picture, but scene.js never loads it: draw LivePaper.image('\(name)') " +
                            "cover-fit every frame (scale = max(lp.w / img.width, lp.h / img.height), centred) and animate on top of it.")
        }
        if !m.assetIntact {
            warnings.append("scene/\(m.assetPath) is not the file LivePaper provided (changed, replaced or removed). Leave it exactly as it is: " +
                            "LivePaper puts the original back when you finish, and the scene is checked with that file.")
        }
        guard m.opaqueShare >= b.minOpaqueShare else {
            warnings.append("Too little of the picture to animate is opaque to compare with the stills (\(Int((m.opaqueShare * 100).rounded())) % " +
                            "of it); check by eye that every still shows it.")
            return (problems, warnings, summary)
        }
        guard m.referenceMeasurable else {
            warnings.append("The picture to animate has too little detail to compare with the stills; check by eye that every still shows it.")
            return (problems, warnings, summary)
        }
        guard let med, m.referencedInScene else { return (problems, warnings, summary) }
        if med < b.failBelow {
            let flat = m.frames.filter(\.score.flat)
            if flat.count * 2 > m.frames.count {
                let most = flat.map(\.score.stillContrast).max() ?? 0
                problems.append("The stills are too flat to show the user's picture: at \(SceneChecker.frameList(flat.map(\.frame))) its detail " +
                                "is gone (luma contrast \(two(most)) or less) \u{2014} darkened, fogged or covered too much. Darken evenly no further " +
                                "than TASK.md's darkenTo, keep fog and overlays light and local, and put the dark gradient only behind the clock.")
                return (problems, warnings, summary)
            }
            let worst = m.frames.sorted { $0.score.score < $1.score.score }.map(\.frame)
            problems.append("The stills don't show the user's picture: similarity to the cover-fit reference is \(two(med)) (needs ≥ " +
                            "\(two(b.failBelow)); 1 = identical) across \(SceneChecker.frameList(worst)). Draw assets/\(name) as the " +
                            "base layer of every frame and keep overlays light enough that the picture stays visible.")
            return (problems, warnings, summary)
        }
        let primary = m.frames.filter { isPrimary($0.frame) }
        let drifting = primary.filter { $0.score.score < b.warnBelow }.sorted { $0.score.score < $1.score.score }
        if let worst = drifting.first {
            warnings.append("At \(SceneChecker.frameList(drifting.map(\.frame))) the frame looks less like the picture (\(two(worst.score.score)), " +
                            "aim ≥ \(two(b.warnBelow))): keep the camera within a few % of the cover-fit framing and the overlays light.")
        }
        if let primaryMedian = median(primary.map(\.score.score)) {
            for label in ["32:9", "5:4"] {
                guard let there = median(m.frames.filter { aspectLabel($0.frame) == label }.map(\.score.score)),
                      there < b.warnBelow, primaryMedian - there >= b.aspectGap else { continue }
                warnings.append("At \(label) the picture doesn't line up with a cover-fit crop (\(two(there)) vs \(two(primaryMedian)) at " +
                                "16:10): scale with max(lp.w / img.width, lp.h / img.height) and centre it; never stretch or letterbox.")
            }
        }
        // Colour is only defined when the picture has some (a grey picture can't lose it).
        let colours = primary.filter { !$0.score.flat }.compactMap(\.score.colour)
        if !colours.isEmpty, let colour = median(colours), colour < b.minColour {
            warnings.append("The picture's colours are gone or changed (colour match \(two(colour)) at 16:10, aim ≥ \(two(b.minColour))): keep its " +
                            "own colours \u{2014} darken evenly with black at a low alpha; don't desaturate, tint or recolour it.")
        }
        return (problems, warnings, summary)
    }
}
