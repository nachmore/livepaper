// Bitmap — exact-size sRGB RGBA pixel buffers: luminance statistics and PNG/JPEG output.
import CoreGraphics
import Foundation
import ImageIO
import LivePaperCore

/// An opaque 8-bit sRGB RGBA image of an exact pixel size.
struct Bitmap {
    let width: Int
    let height: Int
    /// Premultiplied RGBA, row-major, `width * 4` bytes per row.
    private(set) var pixels: [UInt8]

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    /// Draws `image` scaled to exactly `width`×`height` pixels over black. Snapshots normally come
    /// back at that size already; scaling only happens if WebKit ignored the requested pixel density.
    init?(image: CGImage, width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: Bitmap.colorSpace, bitmapInfo: Bitmap.bitmapInfo) else { return false }
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        pixels = buffer
    }

    /// Wraps an existing buffer (`width * height * 4` bytes, premultiplied RGBA).
    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The motion heat map of `livepaper check`: this frame dimmed to grey, each tile of a
    /// `cols`×`rows` grid tinted by how often it changed within 5 s (`alive`, 0–1: blue at some
    /// sampled moments, amber at most of them, plain grey never), thin tile borders, and tiles that
    /// flicker outlined in red.
    func motionHeatmap(alive: [Double], flicker: [Bool], cols: Int, rows: Int) -> Bitmap {
        var out = pixels
        let colOf = (0..<width).map { $0 * cols / width }, rowOf = (0..<height).map { $0 * rows / height }
        for y in 0..<height {
            let r = rowOf[y]
            let rowEdge = y == 0 || rowOf[y - 1] != r, rowEdge2 = rowEdge || y == 1 || (y > 1 && rowOf[y - 2] != r)
            for x in 0..<width {
                let c = colOf[x], tile = r * cols + c, i = (y * width + x) * 4
                let colEdge = x == 0 || colOf[x - 1] != c, colEdge2 = colEdge || x == 1 || (x > 1 && colOf[x - 2] != c)
                let luma = 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
                // Lifted and stretched so even a dark scene stays recognisable under the tint.
                let grey = 40 + 0.8 * luma
                var rgb = (grey, grey, grey)
                let a = tile < alive.count ? alive[tile] : 0
                if a > 0 {
                    let (tint, k): ((Double, Double, Double), Double) = a >= 0.5 ? ((255, 165, 30), 0.22 + 0.2 * a) : ((70, 150, 255), 0.3)
                    rgb = (rgb.0 + (tint.0 - rgb.0) * k, rgb.1 + (tint.1 - rgb.1) * k, rgb.2 + (tint.2 - rgb.2) * k)
                }
                if tile < flicker.count, flicker[tile], rowEdge2 || colEdge2 {
                    rgb = (235, 40, 40)
                } else if rowEdge || colEdge {
                    rgb = (rgb.0 * 0.55, rgb.1 * 0.55, rgb.2 * 0.55)
                }
                out[i] = UInt8(max(0, min(255, rgb.0.rounded())))
                out[i + 1] = UInt8(max(0, min(255, rgb.1.rounded())))
                out[i + 2] = UInt8(max(0, min(255, rgb.2.rounded())))
                out[i + 3] = 255
            }
        }
        return Bitmap(width: width, height: height, pixels: out)
    }

    func cgImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: Bitmap.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: Bitmap.bitmapInfo), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Mean Rec. 709 luma (0–255, on the sRGB-encoded values) of `rect` (pixels, top-left origin),
    /// or of the whole image. Sampled on a grid of at most ~250k points: plenty for a mean.
    func meanLuma(in rect: CGRect? = nil) -> Double? {
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let r = (rect ?? full).integral.intersection(full)
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        let x0 = Int(r.minX), x1 = Int(r.maxX), y0 = Int(r.minY), y1 = Int(r.maxY)
        let step = max(1, Int((Double((x1 - x0) * (y1 - y0)) / 250_000).squareRoot().rounded(.up)))
        var sum = 0.0, n = 0
        pixels.withUnsafeBufferPointer { px in
            var y = y0
            while y < y1 {
                var i = (y * width + x0) * 4
                var x = x0
                while x < x1 {
                    sum += 0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])
                    n += 1
                    x += step; i += step * 4
                }
                y += step
            }
        }
        return n > 0 ? sum / Double(n) : nil
    }

    enum FileType {
        case png, jpeg(quality: Double)
        var uti: CFString {
            switch self {
            case .png: return "public.png" as CFString
            case .jpeg: return "public.jpeg" as CFString
            }
        }
    }

    /// The image encoded as PNG or JPEG.
    func encoded(as type: FileType) throws -> Data {
        guard let image = cgImage() else { throw RenderFailure("could not encode the frame") }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type.uti, 1, nil) else {
            throw RenderFailure("could not encode the frame")
        }
        var props: [CFString: Any] = [:]
        if case .jpeg(let q) = type { props[kCGImageDestinationLossyCompressionQuality] = q }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenderFailure("could not encode the frame") }
        return data as Data
    }

    /// Writes the image to the `out` of `request`, within what `policy` allows (RenderOutputPolicy:
    /// confined folders, symlinks resolved at write time, atomic replace).
    func write(for request: RenderRequest, as type: FileType, policy: RenderOutputPolicy) throws {
        let data = try encoded(as: type)
        do { try policy.write(data, for: request) } catch { throw RenderFailure(error.localizedDescription) }
    }
}
