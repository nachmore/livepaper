// render-saver-thumbnail — draws the saver's System Settings thumbnail procedurally.
//
//   swiftc -O -o /tmp/render-saver-thumbnail scripts/dev/render-saver-thumbnail.swift
//   /tmp/render-saver-thumbnail Saver/Resources
//
// Writes thumbnail.png (300×188) and thumbnail@2x.png (600×376). CoreGraphics/CoreText/ImageIO
// only — no AppKit, so it never registers with the window server. The output is checked in;
// re-run this only when changing the design.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

func semiboldSystemFont(_ size: CGFloat) -> CTFont {
    let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let traits = [kCTFontWeightTrait: 0.3] as CFDictionary
    let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), [kCTFontTraitsAttribute: traits] as CFDictionary)
    return CTFontCreateWithFontDescriptor(descriptor, size, nil)
}

/// Draws centred text with its baseline at `baselineFromTop`.
func drawCentered(_ text: String, font: CTFont, color: CGColor, in ctx: CGContext, width: CGFloat, height: CGFloat, baselineFromTop: CGFloat) {
    let attributed = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.textPosition = CGPoint(x: (width - lineWidth) / 2, y: height - baselineFromTop)
    CTLineDraw(line, ctx)
}

func render(width: Int, height: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let w = CGFloat(width), h = CGFloat(height), s = w / 300

    // Night sky: deep indigo at the top fading to near-black.
    let sky = CGGradient(colorsSpace: nil, colors: [color(0.10, 0.11, 0.26), color(0.04, 0.05, 0.12), color(0.01, 0.01, 0.03)] as CFArray,
                         locations: [0, 0.55, 1])
    if let sky { ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: []) }

    // Stars (deterministic LCG).
    var seed: UInt32 = 7
    func rand() -> CGFloat { seed = seed &* 1_664_525 &+ 1_013_904_223; return CGFloat(seed >> 8) / CGFloat(1 << 24) }
    for _ in 0..<70 {
        let x = rand() * w, y = h * 0.35 + rand() * h * 0.65, r = (0.3 + rand() * 0.7) * s * 0.6
        ctx.setFillColor(color(1, 1, 1, 0.25 + rand() * 0.5))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    // Two aurora ribbons: wide translucent strokes layered into a soft glow.
    ctx.setBlendMode(.plusLighter)
    ctx.setLineCap(.round)
    let ribbons: [(CGColor, CGFloat, CGFloat)] = [(color(0.25, 0.85, 0.75), 0.42, 0.10), (color(0.45, 0.40, 1.0), 0.30, 0.07)]
    for (tint, baseY, amp) in ribbons {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -0.1 * w, y: h * baseY))
        path.addCurve(to: CGPoint(x: 1.1 * w, y: h * (baseY + 0.05)),
                      control1: CGPoint(x: 0.3 * w, y: h * (baseY + amp * 3)), control2: CGPoint(x: 0.65 * w, y: h * (baseY - amp * 2)))
        // Many thin layers of decreasing width add up to a smooth falloff (CG has no blur).
        let layers = 24
        for i in 0..<layers {
            let f = CGFloat(i) / CGFloat(layers)
            ctx.setStrokeColor(tint.copy(alpha: 0.012 + 0.02 * f) ?? tint)
            ctx.setLineWidth((64 * (1 - f) + 1.5) * s)
            ctx.addPath(path)
            ctx.strokePath()
        }
    }
    ctx.setBlendMode(.normal)

    // Lock-screen clock, same proportions as the saver's native clock.
    let timeSize = h * 0.15 * 1.9, dateSize = max(13 * s * 0.5, timeSize * 0.2)
    let dateBaseline = h * 0.07 + dateSize * 1.1
    ctx.setShadow(offset: CGSize(width: 0, height: -s), blur: 4 * s, color: color(0, 0, 0, 0.35))
    drawCentered("Thursday, November 13", font: semiboldSystemFont(dateSize), color: color(0.965, 0.973, 1, 0.94), in: ctx,
                 width: w, height: h, baselineFromTop: dateBaseline)
    drawCentered("9:41", font: semiboldSystemFont(timeSize), color: color(0.965, 0.973, 1, 0.94), in: ctx,
                 width: w, height: h, baselineFromTop: dateBaseline + timeSize * 0.98)
    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "thumbnail", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "thumbnail", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
    }
}

do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    for (name, w, h) in [("thumbnail.png", 300, 188), ("thumbnail@2x.png", 600, 376)] {
        guard let image = render(width: w, height: h) else { throw NSError(domain: "thumbnail", code: 3) }
        try writePNG(image, to: outDir.appendingPathComponent(name))
        print("wrote \(outDir.appendingPathComponent(name).path)")
    }
} catch {
    FileHandle.standardError.write(Data("render-saver-thumbnail: \(error.localizedDescription)\n".utf8))
    exit(1)
}
