// ReferenceFixtures — generated pictures for the reference-image tests (no personal files, ever):
// seeded synthetic "photos" (lake, city, portrait, flowers), the stills a scene might render from
// them (cover-fit with a camera offset, darkened, fogged, mirrored, stretched, …), JPEGs carrying
// EXIF/GPS/TIFF/IPTC metadata, a PNG whose header claims 30000 × 30000 px, valid blank PNGs of any
// size (a few KB, for the pixel caps), cut-outs on transparency, soft bright pictures, and a sparse
// 101 MB file.
// CoreGraphics + ImageIO only.
import CoreGraphics
import Foundation
import ImageIO
import LivePaperCore
import UniformTypeIdentifiers

enum ReferenceFixtures {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: - Drawing helpers

    struct RNG {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 &+ 1 }
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 11) & ((1 << 53) - 1)) / Double(1 << 53)
        }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
    }

    /// Smooth 1-D value noise in [0, 1].
    static func noise(_ x: Double, seed: UInt64) -> Double {
        func h(_ i: Int) -> Double { var r = RNG(seed &+ UInt64(bitPattern: Int64(i)) &* 2654435761); return r.next() }
        let i = Int(floor(x)), f = x - floor(x), u = f * f * (3 - 2 * f)
        return h(i) * (1 - u) + h(i + 1) * u
    }

    static func context(_ w: Int, _ h: Int, alpha: Bool = false) -> CGContext {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: info)!
        // Top-left origin, like the canvas.
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        return ctx
    }

    static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        CGColor(colorSpace: sRGB, components: [r, g, b, a])!
    }

    static func verticalGradient(_ ctx: CGContext, _ rect: CGRect, _ stops: [(Double, CGColor)]) {
        let g = CGGradient(colorsSpace: sRGB, colors: stops.map(\.1) as CFArray, locations: stops.map { CGFloat($0.0) })!
        ctx.saveGState(); ctx.clip(to: rect)
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        ctx.restoreGState()
    }

    static func softBlob(_ ctx: CGContext, x: Double, y: Double, r: Double, color: (Double, Double, Double), alpha: Double) {
        let g = CGGradient(colorsSpace: sRGB, colors: [rgb(color.0, color.1, color.2, alpha), rgb(color.0, color.1, color.2, 0)] as CFArray,
                           locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
    }

    // MARK: - Synthetic photos

    enum Layout: String, CaseIterable { case lake, city, portrait, flowers }

    /// A busy, photo-like picture of `layout`; `seed` varies the details (ridges, trees, windows).
    static func photo(_ layout: Layout, seed: UInt64 = 1, width: Int = 1200, height: Int = 800) -> CGImage {
        let ctx = context(width, height)
        let w = Double(width), h = Double(height)
        var rng = RNG(seed)
        switch layout {
        case .lake:
            let horizon = h * (0.52 + 0.06 * (rng.next() - 0.5))
            verticalGradient(ctx, CGRect(x: 0, y: 0, width: w, height: horizon),
                             [(0, rgb(0.10, 0.16, 0.36)), (0.6, rgb(0.55, 0.42, 0.52)), (1, rgb(0.95, 0.62, 0.36))])
            let sunX = w * rng.range(0.25, 0.75)
            softBlob(ctx, x: sunX, y: horizon * 0.78, r: h * 0.18, color: (1, 0.85, 0.6), alpha: 0.8)
            ctx.setFillColor(rgb(1, 0.93, 0.78)); ctx.fillEllipse(in: CGRect(x: sunX - h * 0.04, y: horizon * 0.78 - h * 0.04, width: h * 0.08, height: h * 0.08))
            // Three ridges of noise mountains.
            for (k, (base, amp, shade)) in [(0.80, 0.22, 0.32), (0.90, 0.16, 0.22), (0.98, 0.10, 0.14)].enumerated() {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: horizon))
                var x = 0.0
                while x <= w {
                    let n = noise(x / w * (5 + Double(k) * 3), seed: seed &+ UInt64(k) * 17) * 0.7 + noise(x / w * 23, seed: seed &+ 99) * 0.3
                    path.addLine(to: CGPoint(x: x, y: horizon * base - horizon * amp * n))
                    x += 4
                }
                path.addLine(to: CGPoint(x: w, y: horizon)); path.closeSubpath()
                ctx.setFillColor(rgb(shade * 0.8, shade * 0.85, shade * 1.25)); ctx.addPath(path); ctx.fillPath()
            }
            // Lake: a darker mirrored gradient with horizontal reflection stripes.
            verticalGradient(ctx, CGRect(x: 0, y: horizon, width: w, height: h - horizon),
                             [(0, rgb(0.62, 0.45, 0.40)), (0.3, rgb(0.25, 0.26, 0.40)), (1, rgb(0.05, 0.07, 0.14))])
            var y = horizon
            while y < h {
                let t = (y - horizon) / (h - horizon)
                let x0 = sunX - w * (0.05 + 0.15 * t) * rng.range(0.6, 1.4)
                ctx.setFillColor(rgb(1, 0.8, 0.55, 0.55 * (1 - t)))
                ctx.fill(CGRect(x: x0, y: y, width: w * (0.1 + 0.3 * t) * rng.range(0.5, 1.2), height: max(1, h * 0.004)))
                ctx.setFillColor(rgb(0.7, 0.75, 0.95, 0.12))
                ctx.fill(CGRect(x: rng.range(0, w), y: y, width: rng.range(w * 0.05, w * 0.3), height: max(1, h * 0.003)))
                y += h * rng.range(0.008, 0.02)
            }
            // Trees on the shore.
            for _ in 0..<Int(rng.range(14, 26)) {
                let tx = rng.range(0, w), th = h * rng.range(0.06, 0.16), tw = th * 0.35
                let base = horizon + h * 0.01
                let path = CGMutablePath()
                path.move(to: CGPoint(x: tx, y: base - th)); path.addLine(to: CGPoint(x: tx - tw, y: base)); path.addLine(to: CGPoint(x: tx + tw, y: base))
                path.closeSubpath()
                ctx.setFillColor(rgb(0.04, 0.08, 0.06)); ctx.addPath(path); ctx.fillPath()
            }
        case .city:
            verticalGradient(ctx, CGRect(x: 0, y: 0, width: w, height: h), [(0, rgb(0.03, 0.04, 0.10)), (1, rgb(0.20, 0.12, 0.25))])
            var x = 0.0
            while x < w {
                let bw = w * rng.range(0.04, 0.1), bh = h * rng.range(0.25, 0.75)
                let shade = rng.range(0.06, 0.16)
                ctx.setFillColor(rgb(shade, shade, shade * 1.3)); ctx.fill(CGRect(x: x, y: h - bh, width: bw, height: bh))
                var wy = h - bh + h * 0.02
                while wy < h - h * 0.03 {
                    var wx = x + bw * 0.12
                    while wx < x + bw - bw * 0.15 {
                        if rng.next() < 0.55 {
                            ctx.setFillColor(rgb(1, rng.range(0.7, 0.9), rng.range(0.3, 0.6), rng.range(0.6, 1)))
                            ctx.fill(CGRect(x: wx, y: wy, width: bw * 0.14, height: h * 0.018))
                        }
                        wx += bw * 0.22
                    }
                    wy += h * 0.035
                }
                x += bw + w * rng.range(0, 0.01)
            }
        case .portrait:
            verticalGradient(ctx, CGRect(x: 0, y: 0, width: w, height: h), [(0, rgb(0.35, 0.40, 0.45)), (1, rgb(0.12, 0.14, 0.18))])
            let cx = w * rng.range(0.4, 0.6), cy = h * 0.45, r = min(w, h) * 0.28
            ctx.setFillColor(rgb(0.15, 0.12, 0.1)); ctx.fillEllipse(in: CGRect(x: cx - r * 1.1, y: cy - r * 1.25, width: r * 2.2, height: r * 2.2))
            ctx.setFillColor(rgb(0.86, 0.68, 0.56)); ctx.fillEllipse(in: CGRect(x: cx - r * 0.8, y: cy - r, width: r * 1.6, height: r * 2.1))
            for ex in [-0.32, 0.32] {
                ctx.setFillColor(rgb(1, 1, 1)); ctx.fillEllipse(in: CGRect(x: cx + ex * r - r * 0.16, y: cy - r * 0.2, width: r * 0.32, height: r * 0.18))
                ctx.setFillColor(rgb(0.2, 0.3, 0.45)); ctx.fillEllipse(in: CGRect(x: cx + ex * r - r * 0.07, y: cy - r * 0.18, width: r * 0.14, height: r * 0.14))
            }
            ctx.setFillColor(rgb(0.65, 0.3, 0.3)); ctx.fill(CGRect(x: cx - r * 0.3, y: cy + r * 0.55, width: r * 0.6, height: r * 0.08))
            ctx.setFillColor(rgb(0.25, 0.35, 0.55)); ctx.fill(CGRect(x: cx - r * 1.4, y: cy + r * 1.1, width: r * 2.8, height: h))
        case .flowers:
            verticalGradient(ctx, CGRect(x: 0, y: 0, width: w, height: h), [(0, rgb(0.18, 0.34, 0.16)), (1, rgb(0.06, 0.16, 0.06))])
            for _ in 0..<160 {
                let fx = rng.range(0, w), fy = rng.range(0, h), fr = min(w, h) * rng.range(0.015, 0.05)
                let hue = rng.next()
                let color = hue < 0.33 ? rgb(0.95, 0.3, 0.4) : hue < 0.66 ? rgb(1, 0.85, 0.2) : rgb(0.7, 0.45, 0.95)
                ctx.setFillColor(color)
                for k in 0..<5 {
                    let a = Double(k) / 5 * 2 * .pi
                    ctx.fillEllipse(in: CGRect(x: fx + cos(a) * fr - fr * 0.6, y: fy + sin(a) * fr - fr * 0.6, width: fr * 1.2, height: fr * 1.2))
                }
                ctx.setFillColor(rgb(1, 0.95, 0.6)); ctx.fillEllipse(in: CGRect(x: fx - fr * 0.4, y: fy - fr * 0.4, width: fr * 0.8, height: fr * 0.8))
            }
        }
        // Film grain, as in a photo.
        for _ in 0..<(width * height / 40) {
            let v = rng.next()
            ctx.setFillColor(rgb(v, v, v, 0.06)); ctx.fill(CGRect(x: rng.range(0, w), y: rng.range(0, h), width: 1, height: 1))
        }
        return ctx.makeImage()!
    }

    /// A procedural night aurora: what an unrelated scene might look like.
    static func aurora(width: Int, height: Int, seed: UInt64 = 3) -> CGImage {
        let ctx = context(width, height)
        let w = Double(width), h = Double(height)
        verticalGradient(ctx, CGRect(x: 0, y: 0, width: w, height: h), [(0, rgb(0.01, 0.02, 0.06)), (1, rgb(0.03, 0.08, 0.10))])
        var rng = RNG(seed)
        for i in 0..<6 {
            let y0 = h * (0.15 + 0.1 * Double(i))
            for k in 0..<40 {
                let x = w * Double(k) / 40, y = y0 + h * 0.08 * sin(Double(k) * 0.4 + Double(i))
                softBlob(ctx, x: x, y: y, r: h * 0.12, color: (0.2, 0.9 - 0.08 * Double(i), 0.5 + 0.05 * Double(i)), alpha: 0.12)
            }
        }
        for _ in 0..<200 {
            ctx.setFillColor(rgb(1, 1, 1, rng.range(0.3, 0.9))); ctx.fill(CGRect(x: rng.range(0, w), y: rng.range(0, h * 0.6), width: 1.5, height: 1.5))
        }
        return ctx.makeImage()!
    }

    // MARK: - Stills a scene might render

    enum Variant: CustomStringConvertible {
        case cover(zoom: Double, dx: Double, dy: Double)
        case darken(Double)
        case topGradient
        case fog
        case particles
        case greyscale
        case mirrored
        case stretched
        case letterboxed
        case unrelated
        case otherPicture(UInt64)
        /// A transparent picture cover-fit over a backdrop (what a scene animating a cut-out draws).
        case over(Backdrop)
        /// Evenly darkened to `k` and fogged: `fog` adds the fog layer too.
        case darkenedFog(Double, fog: Bool)
        /// A colour wash over the picture (a "dusk grade"): `rgb` at `alpha`.
        case tinted((Double, Double, Double), alpha: Double)

        var description: String {
            switch self {
            case .cover(let z, let dx, let dy): return "cover z\(z) \(dx),\(dy)"
            case .darken(let k): return "darken \(k)"
            case .topGradient: return "top gradient"
            case .fog: return "fog"
            case .particles: return "particles"
            case .greyscale: return "greyscale"
            case .mirrored: return "mirrored"
            case .stretched: return "stretched"
            case .letterboxed: return "letterboxed"
            case .unrelated: return "unrelated aurora"
            case .otherPicture(let s): return "same layout, seed \(s)"
            case .over(let b): return "over \(b)"
            case .darkenedFog(let k, let fog): return "darken \(k)\(fog ? " + fog" : "")"
            case .tinted(let c, let a): return String(format: "tint %.2f,%.2f,%.2f @ %.2f", c.0, c.1, c.2, a)
            }
        }
    }

    enum Backdrop: CustomStringConvertible {
        case black
        case grey(Double)
        case colour(Double, Double, Double)
        /// Top to bottom.
        case gradient((Double, Double, Double), (Double, Double, Double))
        var description: String {
            switch self {
            case .black: return "black"
            case .grey(let v): return "grey \(Int(v * 255))"
            case .colour(let r, let g, let b): return String(format: "rgb %.2f,%.2f,%.2f", r, g, b)
            case .gradient(let a, let b): return String(format: "gradient %.2f→%.2f", (a.0 + a.1 + a.2) / 3, (b.0 + b.1 + b.2) / 3)
            }
        }
        func fill(_ ctx: CGContext, _ w: Double, _ h: Double) {
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            switch self {
            case .black: ctx.setFillColor(rgb(0, 0, 0)); ctx.fill(rect)
            case .grey(let v): ctx.setFillColor(rgb(v, v, v)); ctx.fill(rect)
            case .colour(let r, let g, let b): ctx.setFillColor(rgb(r, g, b)); ctx.fill(rect)
            case .gradient(let a, let b): verticalGradient(ctx, rect, [(0, rgb(a.0, a.1, a.2)), (1, rgb(b.0, b.1, b.2))])
            }
        }
    }

    /// `photo` (scaled by `brightness`) cut out as an irregular blob covering about half of the
    /// picture, on full transparency: a sticker or illustration.
    static func cutout(_ photo: CGImage, brightness: Double = 1) -> CGImage {
        let w = photo.width, h = photo.height
        let ctx = context(w, h, alpha: true)
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        let path = CGMutablePath()
        let cx = Double(w) / 2, cy = Double(h) / 2, r = Double(min(w, h)) * 0.42
        for i in 0...72 {
            let a = Double(i) / 72 * 2 * .pi, k = 1 + 0.18 * sin(a * 3) + 0.08 * cos(a * 5)
            let p = CGPoint(x: cx + cos(a) * r * k * 1.25, y: cy + sin(a) * r * k)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        drawImage(ctx, photo, CGRect(x: 0, y: 0, width: w, height: h))
        if brightness < 1 { ctx.setFillColor(rgb(0, 0, 0, 1 - brightness)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        ctx.restoreGState()
        return ctx.makeImage()!
    }

    /// A soft, high-key picture (snow field, fog, pale watercolour): mean luma about 215, little
    /// contrast — a gentle gradient, a few faint shapes and grain.
    static func softBright(width: Int = 1200, height: Int = 800, seed: UInt64 = 4) -> CGImage {
        let ctx = context(width, height)
        let w = Double(width), h = Double(height)
        var rng = RNG(seed)
        verticalGradient(ctx, CGRect(x: 0, y: 0, width: w, height: h), [(0, rgb(0.80, 0.83, 0.87)), (1, rgb(0.86, 0.86, 0.88))])
        for _ in 0..<9 {
            softBlob(ctx, x: rng.range(0, w), y: rng.range(h * 0.3, h), r: h * rng.range(0.1, 0.25), color: (0.72, 0.75, 0.79), alpha: 0.6)
        }
        for _ in 0..<7 {
            ctx.setFillColor(rgb(0.70, 0.72, 0.75, 0.6))
            let x = rng.range(0, w), y = h * rng.range(0.55, 0.8)
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: w * rng.range(0.05, 0.15), height: h * rng.range(0.02, 0.05)))
        }
        for _ in 0..<(width * height / 40) {
            let v = rng.next()
            ctx.setFillColor(rgb(v, v, v, 0.04)); ctx.fill(CGRect(x: rng.range(0, w), y: rng.range(0, h), width: 1, height: 1))
        }
        return ctx.makeImage()!
    }

    /// Draws `photo` cover-fit into a `w`×`h` context: zoomed in by `zoom` around the centre,
    /// shifted by (dx, dy) × the frame size.
    static func drawCover(_ ctx: CGContext, _ photo: CGImage, _ w: Double, _ h: Double, zoom: Double = 1, dx: Double = 0, dy: Double = 0) {
        let s = max(w / Double(photo.width), h / Double(photo.height)) * zoom
        let dw = Double(photo.width) * s, dh = Double(photo.height) * s
        drawImage(ctx, photo, CGRect(x: (w - dw) / 2 + dx * w, y: (h - dh) / 2 + dy * h, width: dw, height: dh))
    }

    /// `CGContext.draw` in the flipped (top-left origin) context without flipping the picture.
    static func drawImage(_ ctx: CGContext, _ image: CGImage, _ rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// The still a scene showing `photo` this way would render at `w`×`h` pixels (with the white
    /// runtime clock at the top when `clock`), laid out for a `cssWidth`×`cssHeight` viewport.
    static func still(_ photo: CGImage, _ variant: Variant, width: Int, height: Int, clock: Bool = true, layout: Layout = .lake) -> CGImage {
        let ctx = context(width, height)
        let w = Double(width), h = Double(height)
        var rng = RNG(77)
        switch variant {
        case .cover(let z, let dx, let dy): drawCover(ctx, photo, w, h, zoom: z, dx: dx, dy: dy)
        case .darken(let k):
            drawCover(ctx, photo, w, h, zoom: 1.03)
            ctx.setFillColor(rgb(0, 0, 0, 1 - k)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        case .topGradient:
            drawCover(ctx, photo, w, h, zoom: 1.02, dx: 0.01)
            verticalGradient(ctx, CGRect(x: 0, y: 0, width: w, height: h * 0.45), [(0, rgb(0, 0, 0, 0.7)), (1, rgb(0, 0, 0, 0))])
        case .fog:
            drawCover(ctx, photo, w, h, zoom: 1.04, dx: -0.01)
            for _ in 0..<14 { softBlob(ctx, x: rng.range(0, w), y: rng.range(h * 0.3, h), r: h * rng.range(0.15, 0.3), color: (0.8, 0.85, 0.9), alpha: 0.22) }
        case .particles:
            drawCover(ctx, photo, w, h, zoom: 1.05, dy: 0.01)
            for _ in 0..<Int(w * h / 600) { softBlob(ctx, x: rng.range(0, w), y: rng.range(0, h), r: max(1.5, h * 0.006), color: (1, 0.95, 0.8), alpha: 0.8) }
        case .greyscale:
            drawCover(ctx, photo, w, h)
            ctx.setBlendMode(.saturation); ctx.setFillColor(rgb(0.5, 0.5, 0.5)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setBlendMode(.normal)
        case .mirrored:
            ctx.saveGState(); ctx.translateBy(x: w, y: 0); ctx.scaleBy(x: -1, y: 1); drawCover(ctx, photo, w, h); ctx.restoreGState()
        case .stretched: drawImage(ctx, photo, CGRect(x: 0, y: 0, width: w, height: h))
        case .letterboxed:
            ctx.setFillColor(rgb(0, 0, 0)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let s = min(w / Double(photo.width), h / Double(photo.height))
            let dw = Double(photo.width) * s, dh = Double(photo.height) * s
            drawImage(ctx, photo, CGRect(x: (w - dw) / 2, y: (h - dh) / 2, width: dw, height: dh))
        case .unrelated: drawImage(ctx, aurora(width: width, height: height), CGRect(x: 0, y: 0, width: w, height: h))
        case .otherPicture(let seed): drawCover(ctx, ReferenceFixtures.photo(layout, seed: seed), w, h)
        case .over(let backdrop):
            backdrop.fill(ctx, w, h)
            drawCover(ctx, photo, w, h)
        case .tinted(let c, let a):
            drawCover(ctx, photo, w, h)
            ctx.setFillColor(rgb(c.0, c.1, c.2, a)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        case .darkenedFog(let k, let fog):
            drawCover(ctx, photo, w, h, zoom: 1.03)
            ctx.setFillColor(rgb(0, 0, 0, 1 - k)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            if fog {
                for _ in 0..<10 {
                    softBlob(ctx, x: rng.range(0, w), y: rng.range(h * 0.4, h), r: h * rng.range(0.12, 0.25), color: (0.8, 0.85, 0.9), alpha: 0.12 * k)
                }
            }
        }
        if clock { drawFakeClock(ctx, w, h) }
        return ctx.makeImage()!
    }

    /// A white block of "text" where the runtime draws its clock (top centre), sized for a viewport
    /// of `w`×`h` pixels laid out at the same aspect.
    static func drawFakeClock(_ ctx: CGContext, _ w: Double, _ h: Double) {
        let time = min(max(min(w * 0.11, h * 0.15), 40 * h / 982), 210)
        let bw = time * 3.4 * 0.8, bh = time * 0.9
        let x = w / 2 - bw / 2, y = h * 0.07 + time * 0.35
        ctx.setFillColor(rgb(1, 1, 1, 0.92))
        for i in 0..<5 { ctx.fill(CGRect(x: x + Double(i) * bw / 5 + bw * 0.02, y: y, width: bw / 5 * 0.8, height: bh)) }
    }

    // MARK: - Files

    static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(dest), "encoding \(type.identifier) failed")
        return data as Data
    }

    /// A JPEG with camera, GPS, IPTC and XMP-ish metadata and EXIF orientation 6 (rotate 90° CW to
    /// display): the importer must apply the orientation and drop every bit of it.
    static func jpegWithMetadata(_ image: CGImage) -> Data {
        encode(image, type: .jpeg, properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "LivePaperCam", kCGImagePropertyTIFFModel: "Model Secret",
                                             kCGImagePropertyTIFFArtist: "A. Person"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private comment", kCGImagePropertyExifLensModel: "Lens 42",
                                             kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.8584, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 2.2945, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["secret-keyword"], kCGImagePropertyIPTCByline: ["A. Person"]],
        ])
    }

    /// Every metadata dictionary in an encoded image's properties (for the "no metadata" checks).
    static func metadataKeys(_ data: Data) -> Set<String> {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return [] }
        var keys = Set(props.keys.filter { $0.hasPrefix("{") })
        for (dict, values) in props where dict.hasPrefix("{") {
            for key in (values as? [String: Any])?.keys ?? [:].keys { keys.insert("\(dict).\(key)") }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            for k in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFArtist] where tiff[k as String] != nil {
                keys.insert("TIFF.\(k)")
            }
        }
        if let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil), let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] {
            for tag in tags {
                let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? "?", name = (CGImageMetadataTagCopyName(tag) as String?) ?? "?"
                keys.insert("xmp:\(prefix):\(name)")
            }
        }
        return keys
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    /// A PNG signature + a valid IHDR chunk claiming `width`×`height` RGBA, then IEND — no pixel data.
    static func pngHeaderOnly(width: UInt32, height: UInt32) -> Data {
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let t = Array(type.utf8)
            return be(UInt32(body.count)) + t + body + be(crc32(t + body))
        }
        let ihdr = be(width) + be(height) + [8, 6, 0, 0, 0]
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", ihdr) + chunk("IEND", []))
    }

    /// A valid, all-black 1-bit greyscale PNG of `width`×`height` pixels that is only a few KB on
    /// disk (its zero rows deflate to almost nothing): for the importer's pixel caps.
    static func blankPNG(width: UInt32, height: UInt32) -> Data {
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let t = Array(type.utf8)
            return be(UInt32(body.count)) + t + body + be(crc32(t + body))
        }
        let rawCount = Int(height) * (1 + (Int(width) + 7) / 8)   // a filter byte and the bits of each row, all 0
        let deflated = try! (Data(count: rawCount) as NSData).compressed(using: .zlib) as Data   // raw DEFLATE
        // zlib wrapper: header, the deflate stream, Adler-32 (of zeros: a = 1, b = n mod 65521).
        let adler = (UInt32(rawCount % 65521) << 16) | 1
        let idat = [0x78, 0x9C] + [UInt8](deflated) + be(adler)
        let ihdr = be(width) + be(height) + [1, 0, 0, 0, 0]
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", ihdr) + chunk("IDAT", idat) + chunk("IEND", []))
    }

    /// A photo whose only transparency is a small corner (rounded or feathered corners, a stray
    /// pixel): `corner`×`corner` px, alpha 0.
    static func nearlyOpaquePNG(_ photo: CGImage, corner: Int = 8) -> Data {
        let ctx = context(photo.width, photo.height, alpha: true)
        drawImage(ctx, photo, CGRect(x: 0, y: 0, width: photo.width, height: photo.height))
        ctx.clear(CGRect(x: 0, y: 0, width: corner, height: corner))
        return encode(ctx.makeImage()!, type: .png)
    }

    /// A file of `bytes` bytes that takes no disk space (ftruncate).
    static func sparseFile(at url: URL, bytes: UInt64) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data([0x89, 0x50, 0x4E, 0x47]))
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: bytes)
        try h.close()
    }

    /// A 16-bit-per-channel TIFF (Display P3 when available).
    static func tiff16(width: Int, height: Int) -> Data {
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? sRGB
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.9, 0.2, 0.1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.1, 0.3, 0.9, 1])!)
        ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        return encode(ctx.makeImage()!, type: .tiff)
    }

    /// A two-frame GIF (red, then blue).
    static func gif2(width: Int, height: Int) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.gif.identifier as CFString, 2, nil)!
        for color in [rgb(0.9, 0.1, 0.1), rgb(0.1, 0.1, 0.9)] {
            let ctx = context(width, height)
            ctx.setFillColor(color); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(dest))
        return data as Data
    }

    /// A greyscale (single channel) PNG.
    static func greyPNG(width: Int, height: Int) -> Data {
        let grey = CGColorSpaceCreateDeviceGray()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: grey,
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        for i in 0..<8 {
            ctx.setFillColor(gray: Double(i) / 7, alpha: 1)
            ctx.fill(CGRect(x: width * i / 8, y: 0, width: width / 8 + 1, height: height))
        }
        return encode(ctx.makeImage()!, type: .png)
    }

    /// A PNG whose left half is transparent.
    /// Per-pixel random colour — what compresses worst — inside a centred ellipse, transparent
    /// around it (`cutout` false: everywhere, opaque). For the animate asset's size ladder.
    static func noise(width: Int, height: Int, seed: UInt64 = 3, cutout: Bool = true) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var state = seed &* 0x9E3779B97F4A7C15 &+ 1
        let cx = Double(width) / 2, cy = Double(height) / 2
        bytes.withUnsafeMutableBufferPointer { px in
            for y in 0..<height {
                let dy = (Double(y) + 0.5 - cy) / cy
                for x in 0..<width {
                    let dx = (Double(x) + 0.5 - cx) / cx
                    guard !cutout || dx * dx + dy * dy <= 1 else { continue }   // premultiplied: all zero outside
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    let i = (y * width + x) * 4, v = state >> 24
                    px[i] = UInt8(truncatingIfNeeded: v); px[i + 1] = UInt8(truncatingIfNeeded: v >> 8)
                    px[i + 2] = UInt8(truncatingIfNeeded: v >> 16); px[i + 3] = 255
                }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func transparentPNG(width: Int, height: Int) -> Data {
        let ctx = context(width, height, alpha: true)
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(rgb(0.2, 0.7, 0.3)); ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return encode(ctx.makeImage()!, type: .png)
    }

    /// A two-colour picture: the left `share` of the width one colour, the rest another.
    static func twoColour(width: Int, height: Int, share: Double, _ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> CGImage {
        let ctx = context(width, height)
        let split = Int((Double(width) * share).rounded())
        ctx.setFillColor(rgb(a.0, a.1, a.2)); ctx.fill(CGRect(x: 0, y: 0, width: split, height: height))
        ctx.setFillColor(rgb(b.0, b.1, b.2)); ctx.fill(CGRect(x: split, y: 0, width: width - split, height: height))
        return ctx.makeImage()!
    }

    /// Size and pixel at (x, y) of encoded image data (top-left origin), decoded as sRGB.
    static func pixel(_ data: Data, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return (Int(px[0]), Int(px[1]), Int(px[2]), Int(px[3]))
    }

    static func size(_ data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return (img.width, img.height)
    }
}
