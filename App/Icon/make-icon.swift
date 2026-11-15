// make-icon.swift — draws LivePaper's app icon procedurally (CoreGraphics + ImageIO only: no
// AppKit, no window server, no third-party artwork) and writes a complete .iconset.
//
//   swift App/Icon/make-icon.swift <out>/AppIcon.iconset && iconutil -c icns <out>/AppIcon.iconset
//
// (App/Icon/make-icon.sh does both.) The artwork: an aurora over a mountain lake at night inside
// the standard macOS icon shape, with a faint lock-screen clock bar — "your lock screen, alive".
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <AppIcon.iconset>\n".utf8))
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map { rgb($0.0, $0.1) } as CFArray, locations: stops.map(\.2))!
}

/// Deterministic pseudo-random numbers so every run produces identical PNGs.
struct LCG {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat(state >> 11) / CGFloat(1 << 53)
    }
}

/// The macOS icon outline: a continuous-corner rounded square (approximated with cubic corners).
func iconShape(in r: CGRect) -> CGPath {
    let radius = r.width * 0.2237
    let k: CGFloat = 0.552 * 1.18 // a little rounder than a circular arc, like Apple's squircle
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + radius, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
    p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + radius),
               control1: CGPoint(x: r.maxX - radius + radius * k, y: r.minY),
               control2: CGPoint(x: r.maxX, y: r.minY + radius - radius * k))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
    p.addCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY),
               control1: CGPoint(x: r.maxX, y: r.maxY - radius + radius * k),
               control2: CGPoint(x: r.maxX - radius + radius * k, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
    p.addCurve(to: CGPoint(x: r.minX, y: r.maxY - radius),
               control1: CGPoint(x: r.minX + radius - radius * k, y: r.maxY),
               control2: CGPoint(x: r.minX, y: r.maxY - radius + radius * k))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
    p.addCurve(to: CGPoint(x: r.minX + radius, y: r.minY),
               control1: CGPoint(x: r.minX, y: r.minY + radius - radius * k),
               control2: CGPoint(x: r.minX + radius - radius * k, y: r.minY))
    p.closeSubpath()
    return p
}

/// Draws the icon on a 1024-unit canvas (top-left origin), scaled to `pixels`.
func drawIcon(pixels: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high

    // Apple's grid: an 824-unit body centred on the 1024 canvas, with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = iconShape(in: body)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x071025))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Night sky.
    ctx.drawLinearGradient(gradient([(0x040A1E, 1, 0), (0x0B2340, 1, 0.55), (0x123E52, 1, 1)]),
                           start: CGPoint(x: 512, y: body.minY), end: CGPoint(x: 512, y: body.maxY), options: [])

    // Stars (fewer at small sizes so they don't turn into noise).
    var rng = LCG(state: 2026)
    let starCount = pixels >= 128 ? 70 : 18
    for _ in 0..<starCount {
        let x = body.minX + rng.next() * body.width
        let y = body.minY + rng.next() * body.height * 0.5
        let r = 1.5 + rng.next() * 3
        ctx.setFillColor(rgb(0xFFFFFF, 0.35 + rng.next() * 0.5))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    // Aurora: stacked translucent ribbons whose top edge follows a sum of sines.
    ctx.setBlendMode(.screen)
    let ribbons: [(color: UInt32, top: CGFloat, amp: CGFloat, freq: CGFloat, phase: CGFloat)] = [
        (0x3DF5A6, 330, 46, 1.25, 0.3), (0x9B7BFF, 400, 38, 1.6, 2.0), (0x40D6E8, 470, 30, 1.1, 4.1),
    ]
    for ribbon in ribbons {
        for layer in 0..<22 {
            let offset = CGFloat(layer) * 7
            let path = CGMutablePath()
            var first = true
            var x = body.minX - 10
            while x <= body.maxX + 10 {
                let u = (x - body.minX) / body.width
                let y = ribbon.top + offset + ribbon.amp * sin(u * ribbon.freq * .pi * 2 + ribbon.phase)
                    + ribbon.amp * 0.3 * sin(u * 9 + ribbon.phase * 1.7)
                if first { path.move(to: CGPoint(x: x, y: y)); first = false } else { path.addLine(to: CGPoint(x: x, y: y)) }
                x += 8
            }
            path.addLine(to: CGPoint(x: body.maxX + 10, y: ribbon.top + offset + 120))
            path.addLine(to: CGPoint(x: body.minX - 10, y: ribbon.top + offset + 120))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(rgb(ribbon.color, 0.055 * (1 - CGFloat(layer) / 22)))
            ctx.fillPath()
        }
    }
    ctx.setBlendMode(.normal)

    // Mountains.
    let ridge = CGMutablePath()
    ridge.move(to: CGPoint(x: body.minX, y: 700))
    let peaks: [(CGFloat, CGFloat)] = [(180, 640), (290, 560), (380, 630), (470, 585), (560, 655), (680, 545), (790, 625), (924, 600)]
    for (x, y) in peaks { ridge.addLine(to: CGPoint(x: x, y: y)) }
    ridge.addLine(to: CGPoint(x: body.maxX, y: 720))
    ridge.addLine(to: CGPoint(x: body.minX, y: 720))
    ridge.closeSubpath()
    ctx.addPath(ridge)
    ctx.setFillColor(rgb(0x040812))
    ctx.fillPath()

    // Lake with the aurora's reflection.
    let lake = CGRect(x: body.minX, y: 712, width: body.width, height: body.maxY - 712)
    ctx.drawLinearGradient(gradient([(0x0B2A3A, 1, 0), (0x030812, 1, 1)]),
                           start: CGPoint(x: 512, y: lake.minY), end: CGPoint(x: 512, y: lake.maxY), options: [])
    ctx.setBlendMode(.screen)
    var shimmer = LCG(state: 7)
    for i in 0..<16 {
        let y = lake.minY + 10 + CGFloat(i) * 11
        let width = 160 + shimmer.next() * 300
        let x = 512 - width / 2 + (shimmer.next() - 0.5) * 160
        ctx.setFillColor(rgb(i % 3 == 0 ? 0x9B7BFF : 0x3DF5A6, 0.20 * (1 - CGFloat(i) / 16)))
        ctx.fill(CGRect(x: x, y: y, width: width, height: 4))
    }
    ctx.setBlendMode(.normal)

    // A faint lock-screen clock bar near the top.
    let bar = CGRect(x: 412, y: 196, width: 200, height: 30)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 15, cornerHeight: 15, transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF, 0.78))
    ctx.fillPath()

    // Top sheen and a hairline edge for definition on dark Docks.
    ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.12, 0), (0xFFFFFF, 0, 0.45)]),
                           start: CGPoint(x: 512, y: body.minY), end: CGPoint(x: 512, y: body.midY), options: [])
    ctx.restoreGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
    ctx.setLineWidth(3)
    ctx.strokePath()
    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = points * scale
            guard let image = drawIcon(pixels: pixels) else { throw CocoaError(.fileWriteUnknown) }
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try writePNG(image, to: outputDirectory.appendingPathComponent(name))
        }
    }
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
