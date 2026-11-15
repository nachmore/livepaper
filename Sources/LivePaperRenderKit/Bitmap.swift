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

    /// The motion heat map of `livepaper check` over this frame (MotionAnalysis.heatmap): tiles tinted
    /// by how often they changed within 5 s, thin tile borders, and tiles that flicker outlined in red.
    func motionHeatmap(alive: [Double], flicker: [Bool], cols: Int, rows: Int) -> Bitmap {
        Bitmap(width: width, height: height,
               pixels: MotionAnalysis.heatmap(pixels, width: width, height: height, alive: alive, flicker: flicker, cols: cols, rows: rows))
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
