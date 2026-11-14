// SceneRenderer — executes render requests (ARCHITECTURE §8) one at a time on the main thread.
//
// Ported from the prototype's off-screen render server. Everything is drawn in ONE borderless window
// parked at (-30000, -30000) that is ordered in once for the renderer's lifetime: WebKit only renders
// for views in an ordered-in window, and re-creating windows (or processes) per request is what makes
// tooling steal focus. The window never takes mouse events and never becomes key or main.
import AppKit
import AVFoundation
import Foundation
import LivePaperCore
import WebKit

@MainActor
final class SceneRenderer {
    static let offscreenOrigin = NSPoint(x: -30000, y: -30000)

    /// Library thumbnails (ARCHITECTURE §4.2): 16:10 JPEG, rendered at a desktop-like viewport and
    /// downsampled so the scene's layout matches what users see on a real display.
    static let thumbnailPixels = (width: 640, height: 400)
    static let thumbnailViewport = CGSize(width: 1280, height: 800)

    private let window: NSWindow
    private let meter = ProcessEnergyMeter()

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.setFrameOrigin(Self.offscreenOrigin)
        window.orderFrontRegardless() // once, for the lifetime of the renderer; never key, never visible
    }

    func close() {
        window.contentView = nil
        window.orderOut(nil)
    }

    func perform(_ request: RenderRequest) async -> RenderResponse {
        let deadline = Date().addingTimeInterval(request.timeout ?? Self.defaultTimeout(request))
        do {
            switch request.op {
            case .still: return try await still(request, deadline: deadline)
            case .bench: return try await bench(request, deadline: deadline)
            case .live: return try await live(request, deadline: deadline)
            case .thumbnail: return try await thumbnail(request, deadline: deadline)
            case .ping, .shutdown: return RenderResponse(ok: true, ready: true)
            }
        } catch let failure as PageFailure {
            return RenderResponse(ok: false, ready: failure.ready, errors: failure.errors, note: failure.message)
        } catch {
            return RenderResponse(ok: false, note: "\(error)")
        }
    }

    static func defaultTimeout(_ r: RenderRequest) -> TimeInterval {
        switch r.op {
        case .live: return (r.seconds ?? 12) + (r.warmup ?? 3) + 30
        case .bench: return 90
        default: return 60
        }
    }

    /// A failure after the page was created: carries the JS errors seen so far.
    private struct PageFailure: Error {
        var message: String
        var ready: Bool
        var errors: [String]
    }

    // MARK: - Ops

    private func still(_ r: RenderRequest, deadline: Date) async throws -> RenderResponse {
        let (size, dpr) = try Self.geometry(r)
        let html = try Self.readHTML(r)
        let clock = r.clock ?? true
        // debug: JS errors are also printed on the frame, so whoever looks at the PNG sees them.
        let config: [String: Any] = ["still": true, "t": r.t ?? 8, "clock": clock, "debug": true,
                                     "dprMax": max(2, dpr), "seed": 1]
        return try await withPage(html: html, size: size, dpr: dpr, config: config, deadline: deadline) { page, info in
            let rect = Self.clockRect(info)
            try await page.nextFrames(deadline: deadline)
            // Luminance is measured on the scene alone: the clock overlay is hidden for that frame,
            // because the question is whether the *background* lets the white clock stay readable.
            var measured: Bitmap
            var final: Bitmap
            if clock {
                _ = try await page.evaluate("LivePaper.debug.overlay(false)", deadline: deadline)
                try await page.nextFrames(deadline: deadline)
                measured = try await page.snapshot(deadline: deadline)
                _ = try await page.evaluate("LivePaper.debug.overlay(true)", deadline: deadline)
                try await page.nextFrames(deadline: deadline)
                final = try await page.snapshot(deadline: deadline)
            } else {
                measured = try await page.snapshot(deadline: deadline)
                final = measured
            }
            var resp = RenderResponse(ok: true, ready: true, errors: page.errors)
            resp.meanLuma = measured.meanLuma().map(Self.round1)
            if let rect {
                let px = CGRect(x: rect.minX * dpr, y: rect.minY * dpr, width: rect.width * dpr, height: rect.height * dpr)
                resp.clockLuma = measured.meanLuma(in: px).map(Self.round1)
            }
            if let out = r.out {
                try final.write(to: URL(fileURLWithPath: out), as: .png)
                resp.out = out
            }
            return resp
        }
    }

    private func bench(_ r: RenderRequest, deadline: Date) async throws -> RenderResponse {
        let (size, dpr) = try Self.geometry(r)
        let html = try Self.readHTML(r)
        let frames = min(max(r.frames ?? 120, 1), 5000)
        let config: [String: Any] = ["bench": frames, "t": r.t ?? 0, "clock": false, "dprMax": max(2, dpr), "seed": 1]
        return try await withPage(html: html, size: size, dpr: dpr, config: config, deadline: deadline) { page, info in
            guard let ms = (info["bench"] as? NSNumber)?.doubleValue else {
                throw PageFailure(message: "the page did not report a bench result", ready: true, errors: page.errors)
            }
            var resp = RenderResponse(ok: true, ready: true, errors: page.errors)
            resp.benchMs = (ms * 1000).rounded() / 1000
            resp.note = "\(frames) frames at \(Int(size.width))x\(Int(size.height))@\(Self.format(dpr))"
            return resp
        }
    }

    private func live(_ r: RenderRequest, deadline: Date) async throws -> RenderResponse {
        let (size, dpr) = try Self.geometry(r)
        let html = try Self.readHTML(r)
        let fps = min(max(r.fps ?? 60, 10), 120), scale = min(max(r.scale ?? 1, 0.25), 1)
        let warmup = min(max(r.warmup ?? 3, 0), 60), seconds = min(max(r.seconds ?? 12, 1), 600)
        let config: [String: Any] = ["fps": fps, "scale": scale, "clock": r.clock ?? true, "dprMax": max(2, dpr), "seed": 1]
        return try await withPage(html: html, size: size, dpr: dpr, config: config, deadline: deadline) { page, _ in
            try await Task.sleep(nanoseconds: UInt64(warmup * 1e9))
            let pids = self.meter.ownedPIDs()
            let f0 = try await self.frameCount(page, deadline)
            let c0 = self.meter.sample(pids), t0 = Date()
            try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            // Helpers may have been (re)spawned during the window: count them from now on too.
            let pids2 = Array(Set(pids + self.meter.ownedPIDs()))
            let f1 = try await self.frameCount(page, deadline)
            let c1 = self.meter.sample(pids2)
            let dt = Date().timeIntervalSince(t0)
            var resp = RenderResponse(ok: true, ready: true, errors: page.errors)
            resp.seconds = Self.round1(dt)
            resp.fps = Self.round1((f1 - f0) / dt)
            resp.cpuPct = Self.round1((c1.cpuNs - c0.cpuNs) / (dt * 1e9) * 100)
            resp.cpuMW = ((c1.energyNj - c0.energyNj) / dt / 1e6).rounded()
            resp.note = "\(pids2.count) processes; fps cap \(Self.format(fps)), scale \(Self.format(scale))"
            return resp
        }
    }

    private func thumbnail(_ r: RenderRequest, deadline: Date) async throws -> RenderResponse {
        guard let scenePath = r.scene, let out = r.out else { throw RenderFailure("thumbnail needs \"scene\" and \"out\"") }
        let package = URL(fileURLWithPath: scenePath)
        let manifest: SceneManifest
        do { manifest = try SceneManifest.load(package: package) } catch {
            throw RenderFailure("cannot read \(package.appendingPathComponent(SceneManifest.fileName).path): \(error.localizedDescription)")
        }
        let pw = Int(r.width ?? Double(Self.thumbnailPixels.width)), ph = Int(r.height ?? Double(Self.thumbnailPixels.height))
        guard (16...4096).contains(pw), (16...4096).contains(ph) else { throw RenderFailure("thumbnail size must be 16–4096 px") }
        let outURL = URL(fileURLWithPath: out)
        switch manifest.kind {
        case .video:
            guard let video = manifest.video else { throw RenderFailure("scene.json has no \"video\" section") }
            let frame = try await Self.videoFrame(package.appendingPathComponent(video.file), at: r.t ?? 1)
            try Self.aspectFill(frame, width: pw, height: ph).write(to: outURL, as: .jpeg(quality: 0.85))
            return RenderResponse(ok: true, ready: true, out: out)
        case .web:
            let html: String
            do { html = try SceneCompiler().build(package: package).html } catch {
                throw RenderFailure("the scene does not compile: \(error.localizedDescription)")
            }
            let size = Self.thumbnailViewport
            let config: [String: Any] = ["still": true, "t": r.t ?? 8, "clock": r.clock ?? false, "dprMax": 2, "seed": 1]
            return try await withPage(html: html, size: size, dpr: 1, config: config, deadline: deadline) { page, _ in
                try await page.nextFrames(deadline: deadline)
                let frame = try await page.snapshot(deadline: deadline)
                guard let cg = frame.cgImage() else { throw RenderFailure("could not encode the frame") }
                try Self.aspectFill(cg, width: pw, height: ph).write(to: outURL, as: .jpeg(quality: 0.85))
                return RenderResponse(ok: true, ready: true, errors: page.errors, out: out)
            }
        }
    }

    // MARK: - Helpers

    /// Loads a page, waits for the runtime's 'ready', runs `body`, and always tears the page down.
    private func withPage(html: String, size: CGSize, dpr: Double, config: [String: Any], deadline: Date,
                          _ body: (RenderPage, [String: Any]) async throws -> RenderResponse) async throws -> RenderResponse {
        let page = try RenderPage(html: html, size: size, dpr: dpr, config: config, window: window)
        defer {
            page.close()
            window.contentView = nil
        }
        let info: [String: Any]
        do { info = try await page.waitUntilReady(deadline: deadline) } catch {
            throw PageFailure(message: "\(error)", ready: false, errors: page.errors)
        }
        if (info["failed"] as? Bool) == true {
            throw PageFailure(message: SceneChecker.startFailureNote + " (see errors)", ready: false, errors: page.errors)
        }
        try await verifyViewport(page, deadline: deadline)
        do { return try await body(page, info) } catch let f as PageFailure { throw f } catch {
            throw PageFailure(message: "\(error)", ready: true, errors: page.errors)
        }
    }

    /// Benchmarks and luminance numbers are only meaningful at the requested geometry; fail loudly if
    /// WebKit laid the page out at some other size or density.
    private func verifyViewport(_ page: RenderPage, deadline: Date) async throws {
        let v = try await page.evaluate("[innerWidth, innerHeight, devicePixelRatio]", deadline: deadline) as? [NSNumber]
        guard let v, v.count == 3 else { return }
        let w = v[0].doubleValue, h = v[1].doubleValue, d = v[2].doubleValue
        if abs(w - Double(page.size.width)) > 1 || abs(h - Double(page.size.height)) > 1 || abs(d - page.dpr) > 0.01 {
            throw PageFailure(message: "viewport is \(Self.format(w))x\(Self.format(h))@\(Self.format(d)), expected " +
                              "\(Int(page.size.width))x\(Int(page.size.height))@\(Self.format(page.dpr))", ready: true, errors: page.errors)
        }
    }

    private func frameCount(_ page: RenderPage, _ deadline: Date) async throws -> Double {
        let v = try await page.evaluate("LivePaper.debug.stats().frame", deadline: deadline)
        guard let n = (v as? NSNumber)?.doubleValue else { throw RenderFailure("the page did not report a frame count") }
        return n
    }

    private static func geometry(_ r: RenderRequest) throws -> (CGSize, Double) {
        let w = r.width ?? 1512, h = r.height ?? 982, dpr = r.dpr ?? 1
        guard (16...8192).contains(w), (16...8192).contains(h) else { throw RenderFailure("width/height must be 16–8192 CSS px") }
        guard (0.5...4).contains(dpr), w * dpr <= 16384, h * dpr <= 16384 else {
            throw RenderFailure("dpr must be 0.5–4 and the frame at most 16384 px per side")
        }
        return (CGSize(width: w.rounded(), height: h.rounded()), dpr)
    }

    private static func readHTML(_ r: RenderRequest) throws -> String {
        guard let path = r.html else { throw RenderFailure("\(r.op.rawValue) needs \"html\" (a compiled scene)") }
        do { return try String(contentsOfFile: path, encoding: .utf8) } catch {
            throw RenderFailure("cannot read \(path): \(error.localizedDescription)")
        }
    }

    /// The runtime's clock region (CSS px, top-left origin) from the 'ready' message.
    private static func clockRect(_ info: [String: Any]) -> CGRect? {
        guard let r = info["clockRect"] as? [String: Any],
              let x = (r["x"] as? NSNumber)?.doubleValue, let y = (r["y"] as? NSNumber)?.doubleValue,
              let w = (r["w"] as? NSNumber)?.doubleValue, let h = (r["h"] as? NSNumber)?.doubleValue else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func videoFrame(_ url: URL, at seconds: Double) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        do {
            let duration = try await asset.load(.duration).seconds
            let t = duration.isFinite && duration > 0 ? min(seconds, duration / 2) : 0
            return try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        } catch {
            throw RenderFailure("cannot read a frame from \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Scales `image` to cover `width`×`height` pixels, cropping the overflow (centred).
    private static func aspectFill(_ image: CGImage, width: Int, height: Int) throws -> Bitmap {
        let iw = Double(image.width), ih = Double(image.height)
        let s = max(Double(width) / iw, Double(height) / ih)
        let cw = (Double(width) / s).rounded(), ch = (Double(height) / s).rounded()
        let crop = CGRect(x: ((iw - cw) / 2).rounded(), y: ((ih - ch) / 2).rounded(), width: cw, height: ch)
        guard let cropped = image.cropping(to: crop), let bitmap = Bitmap(image: cropped, width: width, height: height) else {
            throw RenderFailure("could not scale the frame")
        }
        return bitmap
    }

    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
    static func format(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(x) }
}
