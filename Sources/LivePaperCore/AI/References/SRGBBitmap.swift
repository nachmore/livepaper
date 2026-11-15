// SRGBBitmap — a small sRGB, 8-bit RGBA pixel buffer (premultiplied, i.e. composited over black),
// plus a summed-area table for exact area averages. Shared by the reference importer (summary,
// transparency) and the resemblance check. CoreGraphics only.
import CoreGraphics
import Foundation

struct SRGBBitmap: Sendable, Equatable {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    static let premultipliedInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    static let opaqueInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    let width: Int
    let height: Int
    /// RGBA, top row first.
    var rgba: [UInt8]

    init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width; self.height = height; self.rgba = rgba
    }

    /// `image` drawn into sRGB at its own size, or scaled so the long edge is at most `maxPixel`
    /// (never upscaled), with high-quality interpolation. Draws convert any colour space (P3,
    /// CMYK, grey, 16-bit, HDR) to 8-bit sRGB and carry no metadata.
    init?(image: CGImage, maxPixel: Int? = nil) {
        let (w, h) = Self.fitted(width: image.width, height: image.height, maxPixel: maxPixel)
        self.init(image: image, width: w, height: h)
    }

    /// `image` drawn into exactly `width`×`height` pixels.
    init?(image: CGImage, width w: Int, height h: Int) {
        guard w > 0, h > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: Self.colorSpace, bitmapInfo: Self.premultipliedInfo) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        width = w; height = h; rgba = buffer
    }

    /// Long edge scaled to at most `maxPixel` (aspect kept, at least 1 px per side).
    static func fitted(width: Int, height: Int, maxPixel: Int?) -> (Int, Int) {
        guard let maxPixel, max(width, height) > maxPixel else { return (width, height) }
        let s = Double(maxPixel) / Double(max(width, height))
        return (max(1, Int((Double(width) * s).rounded())), max(1, Int((Double(height) * s).rounded())))
    }

    /// Any pixel not fully opaque.
    var hasTransparency: Bool {
        var i = 3
        while i < rgba.count { if rgba[i] != 255 { return true }; i += 4 }
        return false
    }

    /// The pixels as a CGImage: with alpha (`opaque` false) or without (alpha ignored).
    func cgImage(opaque: Bool) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: Self.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: opaque ? Self.opaqueInfo : Self.premultipliedInfo),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Rec. 709 luma of sRGB-encoded values (0–255), as `livepaper check` measures brightness.
    static func luma(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    var meanLuma: Double {
        guard width * height > 0 else { return 0 }
        var sum = 0.0
        var i = 0
        while i < rgba.count {
            sum += Self.luma(Double(rgba[i]), Double(rgba[i + 1]), Double(rgba[i + 2]))
            i += 4
        }
        return sum / Double(width * height)
    }
}

/// Integral images of R, G and B: the exact mean colour of any (fractional) rectangle of a
/// piecewise-constant image in O(1). Bilinear interpolation of the integer-grid table is exact
/// here, because within one pixel the integral is bilinear in x and y.
struct SummedArea: Sendable {
    let width: Int
    let height: Int
    private var r: [Double], g: [Double], b: [Double]

    init(_ bmp: SRGBBitmap) {
        let w = bmp.width, h = bmp.height
        width = w; height = h
        let stride = w + 1
        var r = [Double](repeating: 0, count: stride * (h + 1)), g = r, b = r
        bmp.rgba.withUnsafeBufferPointer { px in
            for y in 0..<h {
                var rr = 0.0, gg = 0.0, bb = 0.0
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    rr += Double(px[i]); gg += Double(px[i + 1]); bb += Double(px[i + 2])
                    let o = (y + 1) * stride + x + 1, above = y * stride + x + 1
                    r[o] = r[above] + rr; g[o] = g[above] + gg; b[o] = b[above] + bb
                }
            }
        }
        self.r = r; self.g = g; self.b = b
    }

    private func integral(_ t: [Double], _ x: Double, _ y: Double) -> Double {
        let x = min(max(x, 0), Double(width)), y = min(max(y, 0), Double(height))
        var i = Int(x), j = Int(y)
        if i >= width { i = max(0, width - 1) }
        if j >= height { j = max(0, height - 1) }
        let fx = x - Double(i), fy = y - Double(j), s = width + 1
        let s00 = t[j * s + i], s10 = t[j * s + i + 1], s01 = t[(j + 1) * s + i], s11 = t[(j + 1) * s + i + 1]
        return s00 + fx * (s10 - s00) + fy * (s01 - s00) + fx * fy * (s11 - s10 - s01 + s00)
    }

    private func sum(_ t: [Double], _ rect: CGRect) -> Double {
        integral(t, rect.maxX, rect.maxY) - integral(t, rect.minX, rect.maxY) - integral(t, rect.maxX, rect.minY) + integral(t, rect.minX, rect.minY)
    }

    /// Mean R, G, B of every cell of a `cols`×`rows` grid laid over `rect` (row-major, top row
    /// first): one integral lookup per grid corner, so it is cheap enough for many framings.
    func cellMeans(rect: CGRect, cols: Int, rows: Int) -> (r: [Double], g: [Double], b: [Double]) {
        let cw = rect.width / Double(cols), ch = rect.height / Double(rows)
        let area = cw * ch
        func grid(_ t: [Double]) -> [Double] {
            var corners = [Double](repeating: 0, count: (cols + 1) * (rows + 1))
            for j in 0...rows {
                let y = rect.minY + Double(j) * ch
                for i in 0...cols { corners[j * (cols + 1) + i] = integral(t, rect.minX + Double(i) * cw, y) }
            }
            var out = [Double](repeating: 0, count: cols * rows)
            corners.withUnsafeBufferPointer { c in
                out.withUnsafeMutableBufferPointer { o in
                    let s = cols + 1
                    for j in 0..<rows {
                        for i in 0..<cols {
                            o[j * cols + i] = (c[(j + 1) * s + i + 1] - c[(j + 1) * s + i] - c[j * s + i + 1] + c[j * s + i]) / area
                        }
                    }
                }
            }
            return out
        }
        return (grid(r), grid(g), grid(b))
    }

    /// Mean R, G, B over `rect` (pixels, top-left origin), clipped to the image.
    func mean(in rect: CGRect) -> (r: Double, g: Double, b: Double) {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        let area = Double(clipped.width * clipped.height)
        guard !clipped.isNull, area > 1e-9 else { return (0, 0, 0) }
        return (sum(r, clipped) / area, sum(g, clipped) / area, sum(b, clipped) / area)
    }
}
