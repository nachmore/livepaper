// SpanCheck — does a scene really span displays? Its slices, rendered the way each display of a
// spanning saver renders its viewport, must match the corresponding crops of one render of the whole
// virtual canvas (SCENE_API.md §16, `livepaper check`, the runtime.e2e.spanCrops self test).
// CoreGraphics only.
import CoreGraphics
import Foundation
import ImageIO

/// One arrangement of displays to check against: the virtual canvas, each display's viewport in it
/// (CSS px) with the density it renders at, and the display that carries the clock.
public struct SpanArrangement: Sendable, Equatable {
    public struct View: Sendable, Equatable {
        public var id: String
        public var rect: LPRect
        public var dpr: Double
        public init(id: String, rect: LPRect, dpr: Double) { self.id = id; self.rect = rect; self.dpr = dpr }
    }
    public var name: String
    public var canvasW: Double
    public var canvasH: Double
    public var views: [View]
    /// The main display: its viewport is the clock box.
    public var clockView: String
    /// Density of the full-canvas reference render: slices at the same density are compared strictly.
    public var fullDpr: Double

    public init(name: String, canvasW: Double, canvasH: Double, views: [View], clockView: String, fullDpr: Double = 1) {
        self.name = name; self.canvasW = canvasW; self.canvasH = canvasH; self.views = views; self.clockView = clockView
        self.fullDpr = fullDpr
    }

    /// The span keys a page of `view` renders with.
    public func span(for view: View) -> RenderSpan {
        let clock = views.first { $0.id == clockView }?.rect
        return RenderSpan(canvasW: canvasW, canvasH: canvasH, x: view.rect.x, y: view.rect.y,
                          clockX: clock?.x, clockY: clock?.y, clockW: clock?.width, clockH: clock?.height)
    }

    /// The whole canvas as one page (the reference every slice is compared with): the same span code
    /// path (governor off, layer cap), viewport = canvas, clock box = the main display's viewport.
    public var full: (view: View, span: RenderSpan) {
        let v = View(id: "full", rect: LPRect(x: 0, y: 0, width: canvasW, height: canvasH), dpr: fullDpr)
        return (v, span(for: v))
    }

    /// The same arrangement with every display, and the reference, at `dpr`.
    public func at(dpr: Double) -> SpanArrangement {
        var copy = self
        copy.views = views.map { View(id: $0.id, rect: $0.rect, dpr: dpr) }
        copy.fullDpr = dpr
        return copy
    }
}

/// How a slice differs from its crop of the full canvas.
public struct SpanCropDiff: Sendable, Equatable {
    /// Mean absolute difference of the RGB channels (0–255).
    public var meanAbs: Double
    /// Share of the compared pixels with a channel more than `SpanCheck.outlierLevel` apart (0–1).
    public var outliers: Double
    /// Compared at the same density (strict), or downsampled to 1/8 (mixed densities).
    public var strict: Bool
    public var passed: Bool
}

public enum SpanCheck {
    /// Equal densities: mean ≤ 1.5/255 and at most 0.5 % of pixels more than 8/255 apart.
    public static let strictMeanAbs = 1.5
    public static let strictOutlierShare = 0.005
    public static let outlierLevel = 8.0
    /// Mixed densities (device-space textures may differ): both downsampled to 1/8, mean ≤ 4/255.
    public static let mixedMeanAbs = 4.0
    public static let mixedDownsample = 8.0

    /// A: two 1512×982 displays side by side (2×, compared strictly with a 2× render of the canvas).
    /// B: a 1512×982 laptop (the main display, 2×) bottom-aligned left of a 2560×1440 display (1×): a
    /// 4072×1440 canvas with an empty corner. C: a 1920×1080 display (1×) above a centred 1512×982
    /// laptop (2×). B and C's references are 1×, so their laptop slices are compared at mixed densities.
    public static let standard: [SpanArrangement] = [
        SpanArrangement(name: "A", canvasW: 3024, canvasH: 982, views: [
            .init(id: "left", rect: LPRect(x: 0, y: 0, width: 1512, height: 982), dpr: 2),
            .init(id: "right", rect: LPRect(x: 1512, y: 0, width: 1512, height: 982), dpr: 2),
        ], clockView: "left", fullDpr: 2),
        SpanArrangement(name: "B", canvasW: 4072, canvasH: 1440, views: [
            .init(id: "laptop", rect: LPRect(x: 0, y: 458, width: 1512, height: 982), dpr: 2),
            .init(id: "external", rect: LPRect(x: 1512, y: 0, width: 2560, height: 1440), dpr: 1),
        ], clockView: "laptop"),
        SpanArrangement(name: "C", canvasW: 1920, canvasH: 2062, views: [
            .init(id: "top", rect: LPRect(x: 0, y: 0, width: 1920, height: 1080), dpr: 1),
            .init(id: "laptop", rect: LPRect(x: 204, y: 1080, width: 1512, height: 982), dpr: 2),
        ], clockView: "laptop"),
    ]

    public static func arrangement(_ name: String) -> SpanArrangement? { standard.first { $0.name == name } }

    /// Compares `slice` (the page of viewport `view`, rendered at `sliceDpr`) with the crop of `full`
    /// (the whole canvas at `fullDpr`, origin = canvas origin).
    public static func compare(full: CGImage, fullDpr: Double, view: LPRect, slice: CGImage, sliceDpr: Double) -> SpanCropDiff {
        guard let f = RGBA(full), let s = RGBA(slice) else { return SpanCropDiff(meanAbs: 255, outliers: 1, strict: true, passed: false) }
        if abs(fullDpr - sliceDpr) < 0.001 {
            let x0 = Int((view.x * fullDpr).rounded()), y0 = Int((view.y * fullDpr).rounded())
            let w = min(s.width, f.width - x0), h = min(s.height, f.height - y0)
            guard x0 >= 0, y0 >= 0, w > 0, h > 0 else { return SpanCropDiff(meanAbs: 255, outliers: 1, strict: true, passed: false) }
            var sum = 0.0, over = 0
            for y in 0..<h {
                var fi = ((y0 + y) * f.width + x0) * 4, si = y * s.width * 4
                for _ in 0..<w {
                    let dr = abs(Int(f.px[fi]) - Int(s.px[si])), dg = abs(Int(f.px[fi + 1]) - Int(s.px[si + 1]))
                    let db = abs(Int(f.px[fi + 2]) - Int(s.px[si + 2]))
                    sum += Double(dr + dg + db) / 3
                    if Double(max(dr, dg, db)) > outlierLevel { over += 1 }
                    fi += 4; si += 4
                }
            }
            let n = Double(w * h), mean = sum / n, share = Double(over) / n
            return SpanCropDiff(meanAbs: mean, outliers: share, strict: true, passed: mean <= strictMeanAbs && share <= strictOutlierShare)
        }
        // Mixed densities: average both over cells of `mixedDownsample` points.
        let cols = max(1, Int(view.width / mixedDownsample)), rows = max(1, Int(view.height / mixedDownsample))
        let a = f.cells(origin: (view.x * fullDpr, view.y * fullDpr), cell: mixedDownsample * fullDpr, cols: cols, rows: rows)
        let b = s.cells(origin: (0, 0), cell: mixedDownsample * sliceDpr, cols: cols, rows: rows)
        var sum = 0.0, over = 0
        for i in 0..<(cols * rows) {
            let d = (abs(a[i * 3] - b[i * 3]) + abs(a[i * 3 + 1] - b[i * 3 + 1]) + abs(a[i * 3 + 2] - b[i * 3 + 2])) / 3
            sum += d
            if d > outlierLevel { over += 1 }
        }
        let mean = sum / Double(cols * rows)
        return SpanCropDiff(meanAbs: mean, outliers: Double(over) / Double(cols * rows), strict: false, passed: mean <= mixedMeanAbs)
    }

    /// One slice of a run: its render and how it compares with the full canvas.
    public struct Slice: Sendable {
        public var view: SpanArrangement.View
        public var path: String
        public var response: RenderResponse
        public var diff: SpanCropDiff?
    }

    /// Renders an arrangement once as a whole and once per display, and compares the crops.
    public struct Run: Sendable {
        public var arrangement: SpanArrangement
        public var t: Double
        public var fullPath: String
        public var full: RenderResponse
        public var slices: [Slice]

        /// Every render succeeded and reported span (an older render server ignores the span keys).
        public var rendered: Bool { full.ok && slices.allSatisfy(\.response.ok) }
        public var serverSupportsSpan: Bool { full.span == true && slices.allSatisfy { $0.response.span == true } }
        public var hasUpdate: Bool { full.hasUpdate == true || slices.contains { $0.response.hasUpdate == true } }
        public var mismatched: [Slice] { slices.filter { $0.diff?.passed != true } }
        public var passed: Bool { rendered && serverSupportsSpan && mismatched.isEmpty }
        public var errors: [String] {
            var out: [String] = []
            for e in full.errors + slices.flatMap(\.response.errors) where !out.contains(e) { out.append(e) }
            return out
        }

        /// "B t=12: laptop (2x) differs from its crop by 6.1/255 on average"
        public func describe(_ slice: Slice) -> String {
            let label = "\(arrangement.name) t=\(CheckFrame.num(t)): \(slice.view.id) (\(CheckFrame.num(slice.view.rect.width))x" +
                "\(CheckFrame.num(slice.view.rect.height))@\(CheckFrame.num(slice.view.dpr)) at \(CheckFrame.num(slice.view.rect.x)),\(CheckFrame.num(slice.view.rect.y)))"
            guard slice.response.ok else { return "\(label): \(slice.response.note ?? "render failed")" }
            guard let d = slice.diff else { return "\(label): could not read its PNG" }
            return String(format: "%@ differs from its crop of the full canvas: mean %.1f/255, %.1f %% of pixels over %.0f/255",
                          label, d.meanAbs, d.outliers * 100, outlierLevel)
        }
    }

    /// Renders `html` (a compiled scene) at `t` as the whole canvas of `arrangement` and as each of its
    /// displays' slices, writing `<prefix>-full.png` and `<prefix>-<view>.png` into `directory`.
    public static func run(render: RenderClienting, html: URL, arrangement: SpanArrangement, t: Double, clock: Bool,
                           directory: URL, prefix: String) async throws -> Run {
        func still(_ view: SpanArrangement.View, _ span: RenderSpan, _ name: String) async throws -> (String, RenderResponse) {
            let out = directory.appendingPathComponent("\(prefix)-\(name).png").path
            let request = RenderRequest(op: .still, html: html.path, width: view.rect.width, height: view.rect.height, dpr: view.dpr,
                                        t: t, out: out, clock: clock, span: span)
            return (out, try await render.send(request, timeout: RenderClient.defaultTimeout(for: request)))
        }
        let reference = arrangement.full
        let (fullPath, full) = try await still(reference.view, reference.span, "full")
        let fullImage = full.ok ? image(at: URL(fileURLWithPath: fullPath)) : nil
        var slices: [Slice] = []
        for view in arrangement.views {
            let (path, response) = try await still(view, arrangement.span(for: view), view.id)
            var diff: SpanCropDiff?
            if response.ok, let fullImage, let slice = image(at: URL(fileURLWithPath: path)) {
                diff = compare(full: fullImage, fullDpr: reference.view.dpr, view: view.rect, slice: slice, sliceDpr: view.dpr)
            }
            slices.append(Slice(view: view, path: path, response: response, diff: diff))
        }
        return Run(arrangement: arrangement, t: t, fullPath: fullPath, full: full, slices: slices)
    }

    /// A PNG (or any image file ImageIO reads).
    public static func image(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// 8-bit sRGB RGBA pixels of an image at its own size (over black).
    struct RGBA {
        let width: Int, height: Int
        let px: [UInt8]

        init?(_ image: CGImage) {
            guard let bitmap = SRGBBitmap(image: image) else { return nil }
            width = bitmap.width; height = bitmap.height; px = bitmap.rgba
        }

        /// Mean RGB of `cols`×`rows` square cells of `cell` pixels starting at `origin` (pixels),
        /// clipped to the image.
        func cells(origin: (Double, Double), cell: Double, cols: Int, rows: Int) -> [Double] {
            var out = [Double](repeating: 0, count: cols * rows * 3)
            for r in 0..<rows {
                for c in 0..<cols {
                    let x0 = max(0, Int((origin.0 + Double(c) * cell).rounded())), x1 = min(width, Int((origin.0 + Double(c + 1) * cell).rounded()))
                    let y0 = max(0, Int((origin.1 + Double(r) * cell).rounded())), y1 = min(height, Int((origin.1 + Double(r + 1) * cell).rounded()))
                    guard x1 > x0, y1 > y0 else { continue }
                    var sr = 0.0, sg = 0.0, sb = 0.0
                    for y in y0..<y1 {
                        var i = (y * width + x0) * 4
                        for _ in x0..<x1 { sr += Double(px[i]); sg += Double(px[i + 1]); sb += Double(px[i + 2]); i += 4 }
                    }
                    let n = Double((x1 - x0) * (y1 - y0)), k = (r * cols + c) * 3
                    out[k] = sr / n; out[k + 1] = sg / n; out[k + 2] = sb / n
                }
            }
            return out
        }
    }
}
