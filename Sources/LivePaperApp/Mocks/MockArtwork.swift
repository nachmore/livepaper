// MockArtwork — procedural, original artwork for the mock services: thumbnails, AI "stills" and a
// small animated HTML page for live previews. CoreGraphics + ImageIO only (no AppKit, no window
// server), so it also runs inside LivePaperSelfTest.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MockArtwork {
    /// Visual families used by the sample scenes. A scene picks one through its first matching tag.
    enum Style: String, CaseIterable, Sendable {
        case aurora, dunes, lanterns, rain, ocean, orbit, fog, ink, glass

        /// Background top, background bottom, accent A, accent B.
        var palette: [UInt32] {
            switch self {
            case .aurora: return [0x050B1F, 0x0E2A3B, 0x3DF5A6, 0x9B7BFF]
            case .dunes: return [0x2A1B3D, 0xF5A26B, 0xFFD39A, 0x7A3E5C]
            case .lanterns: return [0x0F0A26, 0x3B1D4A, 0xFFB35C, 0xFF6B4A]
            case .rain: return [0x0B1220, 0x1F2C3F, 0xFFC56E, 0x6EC8FF]
            case .ocean: return [0x1C2A55, 0xFF9E8A, 0xFFE1B0, 0x173452]
            case .orbit: return [0x04050D, 0x101433, 0xFFD27A, 0x7FD6FF]
            case .fog: return [0xD3DEE6, 0x6A7A86, 0x2F3B45, 0xF4F7FA]
            case .ink: return [0x030716, 0x0A1636, 0x37A8FF, 0xE85DFF]
            case .glass: return [0x03303A, 0x0C6A72, 0x8FF7E8, 0xFFFFFF]
            }
        }

        /// The style for a scene: first tag naming a style, else a stable hash of the id.
        static func forScene(id: String, tags: [String]) -> Style {
            if let s = tags.lazy.compactMap(Style.init(rawValue:)).first { return s }
            return allCases[Int(MockArtwork.stableHash(id) % UInt64(allCases.count))]
        }
    }

    /// FNV-1a — `Hasher` is randomly seeded per process, which would make artwork change per run.
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100_0000_01b3 }
        return h
    }

    // MARK: rendering

    /// Renders one frame of a style at time `t` (seconds).
    static func render(style: Style, seed: UInt64, width: Int, height: Int, t: Double = 8) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Draw in a top-left origin space; it reads more naturally for scenery.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        var p = Painter(ctx: ctx, w: CGFloat(width), h: CGFloat(height), rng: SplitMix(seed: seed), t: t, pal: style.palette)
        p.background()
        switch style {
        case .aurora: p.aurora()
        case .dunes: p.dunes()
        case .lanterns: p.lanterns()
        case .rain: p.rain()
        case .ocean: p.ocean()
        case .orbit: p.orbit()
        case .fog: p.fog()
        case .ink: p.ink()
        case .glass: p.glass()
        }
        p.vignette()
        return ctx.makeImage()
    }

    @discardableResult
    static func writeImage(style: Style, seed: UInt64, width: Int, height: Int, t: Double = 8, to url: URL) -> Bool {
        guard let image = render(style: style, seed: seed, width: width, height: height, t: t) else { return false }
        let type = url.pathExtension.lowercased() == "png" ? UTType.png : UTType.jpeg
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// A tiny self-contained animated page in the style's palette (stands in for a compiled scene).
    static func html(name: String, style: Style) -> String {
        let hex = style.palette.map { String(format: "#%06X", $0) }
        let title = name.replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
        <style>html,body{margin:0;height:100%;background:\(hex[0]);overflow:hidden}canvas{display:block;width:100%;height:100%}</style>
        </head><body><canvas id="c"></canvas><script>
        (function(){var c=document.getElementById('c'),x=c.getContext('2d'),w=0,h=0,d=Math.min(2,window.devicePixelRatio||1);
        var cols=['\(hex[2])','\(hex[3])'],blobs=[];for(var i=0;i<7;i++)blobs.push({a:Math.random()*6.28,s:.05+Math.random()*.12,r:.18+Math.random()*.25,o:Math.random()*6.28,c:cols[i%2]});
        function size(){w=c.width=Math.round(innerWidth*d*.75);h=c.height=Math.round(innerHeight*d*.75);}
        addEventListener('resize',size);size();var last=0;
        function frame(ts){requestAnimationFrame(frame);if(ts-last<33)return;last=ts;var t=ts/1000;
        var g=x.createLinearGradient(0,0,0,h);g.addColorStop(0,'\(hex[0])');g.addColorStop(1,'\(hex[1])');x.globalCompositeOperation='source-over';x.fillStyle=g;x.fillRect(0,0,w,h);
        x.globalCompositeOperation='lighter';blobs.forEach(function(b){var px=w*(.5+.38*Math.cos(b.a+t*b.s)),py=h*(.45+.3*Math.sin(b.o+t*b.s*1.3)),r=Math.max(w,h)*b.r;
        var rg=x.createRadialGradient(px,py,0,px,py,r);rg.addColorStop(0,b.c+'55');rg.addColorStop(1,b.c+'00');x.fillStyle=rg;x.fillRect(0,0,w,h);});}
        requestAnimationFrame(frame);
        try{webkit.messageHandlers.livepaper.postMessage({type:'ready'})}catch(e){}})();
        </script></body></html>
        """
    }

    // MARK: painter

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        mutating func range(_ a: Double, _ b: Double) -> CGFloat { CGFloat(a + (b - a) * next()) }
    }

    private struct Painter {
        let ctx: CGContext
        let w: CGFloat, h: CGFloat
        var rng: SplitMix
        let t: Double
        let pal: [UInt32]

        func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: a)
        }

        func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient? {
            CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)
        }

        func background() {
            guard let g = gradient([color(pal[0]), color(pal[1])]) else { return }
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        }

        func glow(_ c: CGPoint, _ r: CGFloat, _ hex: UInt32, _ a: CGFloat) {
            guard let g = gradient([color(hex, a), color(hex, 0)]) else { return }
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
        }

        mutating func stars(_ n: Int, maxY: CGFloat, _ hex: UInt32 = 0xFFFFFF) {
            for _ in 0..<n {
                let p = CGPoint(x: rng.range(0, Double(w)), y: rng.range(0, Double(maxY)))
                let r = rng.range(0.4, 1.6) * h / 600
                ctx.setFillColor(color(hex, rng.range(0.3, 0.9)))
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            }
        }

        /// A horizontal band whose top edge follows a sum of sines.
        func wave(top: CGFloat, amp: CGFloat, freq: CGFloat, phase: CGFloat, bottom: CGFloat) -> CGPath {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: bottom))
            var x: CGFloat = 0
            while x <= w + 8 {
                let u = x / w
                let y = top + amp * sin(u * freq * .pi * 2 + phase) + amp * 0.35 * sin(u * freq * 5.3 + phase * 1.7)
                path.addLine(to: CGPoint(x: x, y: y))
                x += 8
            }
            path.addLine(to: CGPoint(x: w, y: bottom))
            path.closeSubpath()
            return path
        }

        mutating func aurora() {
            stars(Int(w * h / 2500), maxY: h * 0.6)
            ctx.setBlendMode(.screen)
            for i in 0..<3 {
                let base = h * (0.18 + CGFloat(i) * 0.1)
                let phase = CGFloat(t * 0.15) + CGFloat(i) * 1.7
                let hex = i == 1 ? pal[3] : pal[2]
                for k in 0..<14 {
                    let off = CGFloat(k) * h * 0.012
                    ctx.addPath(wave(top: base + off, amp: h * 0.06, freq: 1.2 + CGFloat(i) * 0.3, phase: phase, bottom: base + off + h * 0.02))
                    ctx.setFillColor(color(hex, 0.10 * (1 - CGFloat(k) / 14)))
                    ctx.fillPath()
                }
            }
            ctx.setBlendMode(.normal)
            // Lake with a soft reflection.
            ctx.setFillColor(color(0x02060F, 0.85))
            ctx.fill(CGRect(x: 0, y: h * 0.68, width: w, height: h * 0.32))
            ctx.setBlendMode(.screen)
            for i in 0..<18 {
                let y = h * 0.7 + CGFloat(i) * h * 0.016
                ctx.setFillColor(color(pal[2], 0.05 * (1 - CGFloat(i) / 18)))
                ctx.fill(CGRect(x: w * rng.range(0.05, 0.3), y: y, width: w * rng.range(0.3, 0.7), height: h * 0.004))
            }
            ctx.setBlendMode(.normal)
            ctx.addPath(wave(top: h * 0.66, amp: h * 0.02, freq: 2.2, phase: 0.6, bottom: h * 0.7))
            ctx.setFillColor(color(0x01030A))
            ctx.fillPath()
        }

        mutating func dunes() {
            let sun = CGPoint(x: w * (0.62 + 0.01 * CGFloat(sin(t * 0.1))), y: h * 0.46)
            glow(sun, h * 0.55, pal[2], 0.55)
            ctx.setFillColor(color(0xFFF1D6))
            ctx.fillEllipse(in: CGRect(x: sun.x - h * 0.07, y: sun.y - h * 0.07, width: h * 0.14, height: h * 0.14))
            let shades: [UInt32] = [0xC0705A, 0x9A4E52, 0x6E3448, 0x3E1D33]
            for (i, s) in shades.enumerated() {
                let top = h * (0.55 + CGFloat(i) * 0.1)
                ctx.addPath(wave(top: top, amp: h * 0.05, freq: 0.8 + CGFloat(i) * 0.25, phase: CGFloat(i) * 2.1 + CGFloat(t * 0.02), bottom: h))
                ctx.setFillColor(color(s))
                ctx.fillPath()
            }
        }

        mutating func lanterns() {
            stars(Int(w * h / 5000), maxY: h * 0.7, 0xFFE7C2)
            ctx.setBlendMode(.screen)
            for _ in 0..<38 {
                let depth = rng.range(0.25, 1)
                let x = rng.range(0, Double(w))
                let span = h * 1.2
                let raw = (rng.range(0, Double(span)) - CGFloat(t * 6) * depth).truncatingRemainder(dividingBy: span)
                let y = raw < 0 ? raw + span : raw
                let r = h * 0.018 * depth
                glow(CGPoint(x: x, y: y), r * 5, pal[2], 0.35 * depth)
                ctx.setFillColor(color(depth > 0.7 ? pal[2] : pal[3], 0.9))
                ctx.fill(CGRect(x: x - r * 0.7, y: y - r, width: r * 1.4, height: r * 2))
            }
            ctx.setBlendMode(.normal)
            ctx.addPath(wave(top: h * 0.86, amp: h * 0.02, freq: 1.5, phase: 1, bottom: h))
            ctx.setFillColor(color(0x07040F))
            ctx.fillPath()
        }

        mutating func rain() {
            ctx.setBlendMode(.screen)
            for _ in 0..<60 {
                let c = CGPoint(x: rng.range(0, Double(w)), y: rng.range(Double(h * 0.25), Double(h)))
                let r = h * rng.range(0.02, 0.08)
                glow(c, r, rng.next() > 0.4 ? pal[2] : pal[3], rng.range(0.15, 0.45))
            }
            ctx.setBlendMode(.normal)
            ctx.setLineCap(.round)
            for _ in 0..<140 {
                let x = rng.range(0, Double(w)), y = rng.range(0, Double(h))
                let len = h * rng.range(0.01, 0.04)
                ctx.setStrokeColor(color(0xD8E6FF, rng.range(0.08, 0.3)))
                ctx.setLineWidth(max(1, h / 700))
                ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + len * 0.15, y: y + len))
                ctx.strokePath()
            }
        }

        mutating func ocean() {
            let sun = CGPoint(x: w * 0.5, y: h * 0.56)
            glow(sun, h * 0.6, pal[2], 0.6)
            ctx.setFillColor(color(pal[3]))
            ctx.fill(CGRect(x: 0, y: h * 0.58, width: w, height: h * 0.42))
            ctx.setBlendMode(.screen)
            for i in 0..<40 {
                let y = h * 0.59 + CGFloat(i) * h * 0.01
                let spread = w * (0.04 + CGFloat(i) * 0.006)
                ctx.setFillColor(color(pal[2], 0.35 * (1 - CGFloat(i) / 40)))
                ctx.fill(CGRect(x: sun.x - spread * rng.range(0.5, 1.2), y: y, width: spread * rng.range(1, 2.2), height: h * 0.003))
            }
            ctx.setBlendMode(.normal)
            ctx.addPath(wave(top: h * 0.8, amp: h * 0.03, freq: 0.6, phase: 2.4, bottom: h))
            ctx.setFillColor(color(0x0B1A2C))
            ctx.fillPath()
        }

        mutating func orbit() {
            stars(Int(w * h / 1800), maxY: h)
            let c = CGPoint(x: w * 0.5, y: h * 0.52)
            glow(c, h * 0.45, pal[2], 0.45)
            ctx.setFillColor(color(0xFFF3D1))
            ctx.fillEllipse(in: CGRect(x: c.x - h * 0.05, y: c.y - h * 0.05, width: h * 0.1, height: h * 0.1))
            for i in 1...4 {
                let rx = h * 0.16 * CGFloat(i) * 1.5, ry = rx * 0.38
                ctx.setStrokeColor(color(0xFFFFFF, 0.12))
                ctx.setLineWidth(max(1, h / 600))
                ctx.strokeEllipse(in: CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2))
                let a = CGFloat(t) * 0.2 / CGFloat(i) + CGFloat(i) * 1.3
                let p = CGPoint(x: c.x + rx * cos(a), y: c.y + ry * sin(a))
                let r = h * (0.012 + 0.006 * CGFloat(i % 3))
                glow(p, r * 4, pal[3], 0.5)
                ctx.setFillColor(color(i % 2 == 0 ? pal[3] : 0xFFC9A3))
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            }
        }

        mutating func fog() {
            for layer in 0..<4 {
                let shade = [0x9AA8B3, 0x7B8A96, 0x56636E, 0x333D46][layer] as UInt32
                let baseY = h * (0.48 + CGFloat(layer) * 0.1)
                ctx.setFillColor(color(shade))
                var x: CGFloat = -20
                while x < w + 20 {
                    let tw = h * rng.range(0.03, 0.06) * (1 + CGFloat(layer) * 0.3)
                    let th = tw * rng.range(2.2, 3.4)
                    ctx.move(to: CGPoint(x: x, y: baseY)); ctx.addLine(to: CGPoint(x: x + tw / 2, y: baseY - th)); ctx.addLine(to: CGPoint(x: x + tw, y: baseY))
                    ctx.fillPath()
                    x += tw * rng.range(0.5, 0.9)
                }
                ctx.fill(CGRect(x: 0, y: baseY, width: w, height: h - baseY))
                if let g = gradient([color(pal[3], 0), color(pal[3], 0.45), color(pal[3], 0)]) {
                    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: baseY - h * 0.12), end: CGPoint(x: 0, y: baseY + h * 0.06), options: [])
                }
            }
        }

        mutating func ink() {
            ctx.setBlendMode(.screen)
            for i in 0..<9 {
                let c = CGPoint(x: w * rng.range(0.15, 0.85), y: h * rng.range(0.2, 0.8))
                let r = h * rng.range(0.15, 0.4) * CGFloat(1 + 0.05 * sin(t * 0.3 + Double(i)))
                glow(c, r, i % 3 == 0 ? pal[3] : pal[2], rng.range(0.25, 0.55))
            }
            ctx.setBlendMode(.normal)
        }

        mutating func glass() {
            ctx.setBlendMode(.screen)
            for i in 0..<22 {
                let rect = CGRect(x: w * rng.range(-0.1, 0.9), y: h * rng.range(-0.1, 0.9), width: w * rng.range(0.1, 0.35), height: h * rng.range(0.1, 0.4))
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: min(rect.width, rect.height) * 0.45, cornerHeight: min(rect.width, rect.height) * 0.45, transform: nil))
                ctx.setFillColor(color(i % 4 == 0 ? pal[3] : pal[2], rng.range(0.04, 0.14)))
                ctx.fillPath()
            }
            ctx.setBlendMode(.normal)
        }

        func vignette() {
            guard let g = gradient([color(0x000000, 0), color(0x000000, 0.35)]) else { return }
            let c = CGPoint(x: w / 2, y: h / 2)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: min(w, h) * 0.35, endCenter: c, endRadius: max(w, h) * 0.75, options: [.drawsAfterEndLocation])
        }
    }
}
