// Self tests for spanning displays in the runtime and the render server: the span request and its
// config keys, the check's span rules, and (opt-in, LIVEPAPER_SELFTEST_E2E=1) the crop test: every
// slice of a spanning scene, rendered the way each display renders its viewport, must match the
// corresponding crop of one render of the whole virtual canvas.
//
//   swift build && LIVEPAPER_SELFTEST_E2E=1 swift run LivePaperSelfTest runtime.e2e.span
import CoreGraphics
import Foundation
import ImageIO
import LivePaperCore

extension SelfTests {
    static var runtimeSpan: [TestCase] {
        [
            TestCase(name: "runtime.render.spanRequest", run: SpanRuntimeTests.spanRequest),
            TestCase(name: "runtime.check.spanRules", run: SpanRuntimeTests.checkSpanRules),
            TestCase(name: "runtime.e2e.spanCrops", run: SpanRuntimeTests.endToEndCrops),
            TestCase(name: "runtime.e2e.spanNegative", run: SpanRuntimeTests.endToEndNegative),
            TestCase(name: "runtime.e2e.spanCost", run: SpanRuntimeTests.endToEndCost),
        ]
    }
}

enum SpanRuntimeTests {
    static var e2e: Bool { ProcessInfo.processInfo.environment["LIVEPAPER_SELFTEST_E2E"] == "1" }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - Protocol

    static func spanRequest() throws {
        let span = RenderSpan(canvasW: 4072, canvasH: 1440, x: 1512, y: 0, clockX: 0, clockY: 458, clockW: 1512, clockH: 982)
        let request = RenderRequest(op: .still, html: "/tmp/x.html", width: 2560, height: 1440, dpr: 1, t: 12, clock: false, span: span)
        let back = try JSONDecoder().decode(RenderRequest.self, from: JSONEncoder().encode(request))
        try expectEqual(back.span, span)
        try expectEqual(span.configKeys, ["spanW": 4072, "spanH": 1440, "spanX": 1512, "spanY": 0,
                                          "spanClockX": 0, "spanClockY": 458, "spanClockW": 1512, "spanClockH": 982])
        try expectEqual(RenderSpan(canvasW: 10, canvasH: 20, x: 1, y: 2).configKeys, ["spanW": 10, "spanH": 20, "spanX": 1, "spanY": 2])
        let merged = RenderSpan.config(["still": true, "t": 12.0, "spanX": 99.0], span: span)
        try expectEqual(merged["spanX"] as? Double, 1512)
        try expectEqual(merged["still"] as? Bool, true)
        try expectEqual(merged["spanClockH"] as? Double, 982)
        try expectEqual(RenderSpan.config(["t": 1.0], span: nil).count, 1)
        try expect(span.problem == nil)
        try expect(RenderSpan(canvasW: .infinity, canvasH: 10, x: 0, y: 0).problem != nil)
        try expect(RenderSpan(canvasW: 100_000, canvasH: 100, x: 0, y: 0).problem != nil)
        try expect(RenderSpan(canvasW: 100, canvasH: 100, x: 0, y: 0, clockX: .nan).problem != nil)
        // A request without a span is unchanged on the wire (old servers decode it as before).
        let plain = String(decoding: try JSONEncoder().encode(RenderRequest(op: .still, html: "/x")), as: UTF8.self)
        try expect(!plain.contains("span"), plain)
        // The response echoes what the page reported; old servers send neither key.
        let r = try JSONDecoder().decode(RenderResponse.self, from: Data(#"{"ok": true, "ready": true, "errors": [], "span": true, "hasUpdate": false}"#.utf8))
        try expectEqual(r.span, true); try expectEqual(r.hasUpdate, false)
        let old = try JSONDecoder().decode(RenderResponse.self, from: Data(#"{"ok": true, "ready": true, "errors": []}"#.utf8))
        try expect(old.span == nil && old.hasUpdate == nil)
        // The standard arrangements.
        try expectEqual(SpanCheck.standard.map(\.name), ["A", "B", "C"])
        let b = try unwrap(SpanCheck.arrangement("B"))
        try expectEqual(b.full.span, RenderSpan(canvasW: 4072, canvasH: 1440, x: 0, y: 0, clockX: 0, clockY: 458, clockW: 1512, clockH: 982))
        try expectEqual(b.span(for: b.views[1]).x, 1512)
        // The arrangements are real layouts: viewports from LPDisplayLayout.
        for a in SpanCheck.standard {
            let layout = LPDisplayLayout(a.views.enumerated().map { i, v in
                LPDisplay(id: "00000000-0000-4000-8000-00000000000\(i)", frame: v.rect.offsetBy(dx: -300, dy: 100), scale: v.dpr)
            })
            try expectEqual(layout.canvas.width, a.canvasW); try expectEqual(layout.canvas.height, a.canvasH)
            for (i, v) in a.views.enumerated() { try expectEqual(layout.viewport(of: "00000000-0000-4000-8000-00000000000\(i)"), v.rect) }
        }
        try compareSynthetic()
    }

    /// SpanCheck.compare on synthetic images: an exact crop passes, a shifted one fails; mixed densities.
    static func compareSynthetic() throws {
        func image(_ w: Int, _ h: Int, scale: Double, offset: (Double, Double) = (0, 0)) -> CGImage {
            var px = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                let cx = (Double(x) / scale) + offset.0, cy = (Double(y) / scale) + offset.1
                let i = (y * w + x) * 4
                px[i] = UInt8((cx.truncatingRemainder(dividingBy: 97) / 97 * 255).rounded())
                px[i + 1] = UInt8(((cx + cy).truncatingRemainder(dividingBy: 61) / 61 * 255).rounded())
                px[i + 2] = Int(cx / 40) % 2 == Int(cy / 40) % 2 ? 200 : 30
            } }
            let provider = CGDataProvider(data: Data(px) as CFData)!
            return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        let full = image(400, 200, scale: 1)
        let view = LPRect(x: 120, y: 40, width: 200, height: 120)
        let exact = SpanCheck.compare(full: full, fullDpr: 1, view: view, slice: image(200, 120, scale: 1, offset: (120, 40)), sliceDpr: 1)
        try expect(exact.passed && exact.strict && exact.meanAbs == 0, "\(exact)")
        let shifted = SpanCheck.compare(full: full, fullDpr: 1, view: view, slice: image(200, 120, scale: 1, offset: (140, 40)), sliceDpr: 1)
        try expect(!shifted.passed, "\(shifted)")
        let mixed = SpanCheck.compare(full: full, fullDpr: 1, view: view, slice: image(400, 240, scale: 2, offset: (120, 40)), sliceDpr: 2)
        try expect(mixed.passed && !mixed.strict, "\(mixed)")
        let mixedShifted = SpanCheck.compare(full: full, fullDpr: 1, view: view, slice: image(400, 240, scale: 2, offset: (180, 70)), sliceDpr: 2)
        try expect(!mixedShifted.passed, "\(mixedShifted)")
    }

    static func unwrap<T>(_ value: T?, _ what: String = "value") throws -> T {
        guard let value else { throw TestFailure(description: "\(what) is nil") }
        return value
    }

    // MARK: - Check rules

    /// A render server stand-in for span stills: draws a pattern that is a function of canvas
    /// coordinates (`offsetIgnored`: of the page's own coordinates, like a scene laid out from
    /// innerWidth) and writes it as a PNG.
    final class SpanFakeRender: RenderClienting, @unchecked Sendable {
        let base = RuntimeTests.FakeRender()
        var offsetIgnored = false
        var hasUpdate = false
        var reportsSpan = true
        private let lock = NSLock()
        private(set) var spanRequests: [RenderRequest] = []

        func send(_ request: RenderRequest, timeout: TimeInterval) async throws -> RenderResponse {
            var r = try await base.send(request, timeout: timeout)
            if request.op == .still || request.op == .bench { r.hasUpdate = hasUpdate }
            guard request.op == .still, let span = request.span, let out = request.out else { return r }
            lock.withLock { spanRequests.append(request) }
            let dpr = request.dpr ?? 1, w = Int(((request.width ?? 1) * dpr).rounded()), h = Int(((request.height ?? 1) * dpr).rounded())
            let ox = offsetIgnored ? 0 : span.x, oy = offsetIgnored ? 0 : span.y
            var px = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                let cx = Double(x) / dpr + ox, cy = Double(y) / dpr + oy, i = (y * w + x) * 4
                px[i] = UInt8(Int(cx / 3) % 256); px[i + 1] = UInt8(Int(cy / 2) % 256); px[i + 2] = Int(cx / 64) % 2 == Int(cy / 64) % 2 ? 220 : 20
            } }
            let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, nil)
            _ = CGImageDestinationFinalize(dest)
            r.span = reportsSpan ? true : nil
            return r
        }
    }

    static func checkSpanRules() throws {
        let spanManifest = #"{"id":"spanning","name":"Spanning","kind":"web","span":true}"#
        func check(_ js: String = RuntimeTests.minimalScene, manifest: String = spanManifest, quick: Bool = false,
                   configure: (SpanFakeRender) -> Void = { _ in }) throws -> (CheckReport, SpanFakeRender) {
            let pkg = try RuntimeTests.package("spanning", js: js, manifest: manifest)
            defer { try? FileManager.default.removeItem(at: pkg.deletingLastPathComponent()) }
            let fake = SpanFakeRender()
            configure(fake)
            let checker = SceneChecker(compiler: SceneCompiler(), render: fake)
            let report = try RuntimeTests.blocking { try await checker.check(package: pkg, options: CheckOptions(quick: quick, power: false)) }
            return (report, fake)
        }
        // A pure scene spans: B at t = 12, the whole canvas and both displays at 1×.
        let (good, fake) = try check()
        try expect(good.passed, "\(good.problems)")
        try expectEqual(fake.spanRequests.count, 3)
        try expectEqual(fake.spanRequests.map(\.width), [4072, 1512, 2560])
        try expect(fake.spanRequests.allSatisfy { $0.dpr == 1 && $0.t == 12 && $0.clock == false }, "B at 1×, t = 12, clock off")
        try expectEqual(good.span?.map(\.display), ["laptop", "external"])
        try expect(good.span?.allSatisfy { $0.passed == true && $0.path.hasSuffix(".png") } == true, "\(good.span ?? [])")
        // The verdict publishing reads (PublishedSpan).
        try expectEqual(good.spanPassed, true); try expectEqual(good.spanVerdict, true)
        // A scene laid out from its own page size doesn't.
        let (broken, _) = try check { $0.offsetIgnored = true }
        try expect(!broken.passed && broken.problems.contains { $0.contains("doesn't span displays") && $0.contains("innerWidth") }, "\(broken.problems)")
        try expect(broken.problems.contains { $0.contains("external") }, "names the slice: \(broken.problems)")
        try expectEqual(broken.spanPassed, false)
        // update() and Math.random() can't span.
        let (stateful, _) = try check { $0.hasUpdate = true }
        try expect(stateful.problems.contains { $0.contains("defines update(lp, dt)") }, "\(stateful.problems)")
        try expectEqual(stateful.spanPassed, false)
        let random = "LivePaper.scene({ draw(lp) { lp.ctx.fillStyle = Math.random() > 0.5 ? '#000' : '#111'; lp.ctx.fillRect(0, 0, lp.w, lp.h); } });\n"
        let (randomReport, _) = try check(random, quick: true)
        try expect(randomReport.problems.contains { $0.contains("Math.random()") }, "\(randomReport.problems)")
        try expectEqual(randomReport.spanPassed, false)
        // gl_FragCoord without lp.fragOffset is a warning.
        let frag = "LivePaper.scene({ context: 'webgl', setup(lp) { this.src = 'void main(){ gl_FragColor = vec4(gl_FragCoord.xy, 0.0, 1.0); }'; }, draw(lp) {} });\n"
        let (fragReport, _) = try check(frag, quick: true)
        try expect(fragReport.warnings.contains { $0.contains("gl_FragCoord") && $0.contains("lp.fragOffset") }, "\(fragReport.warnings)")
        // A quick check skips the crop comparison (but not the static rules).
        let (quick, quickFake) = try check(quick: true)
        try expect(quick.passed && quickFake.spanRequests.isEmpty && quick.span == nil, "\(quick.problems)")
        try expectEqual(quick.spanPassed, true)   // the rules it checked passed
        // An old render server (no span echo) is a warning, not a failure.
        let (old, _) = try check { $0.reportsSpan = false }
        try expect(old.passed && old.warnings.contains { $0.contains("Spanning displays was not checked") }, "\(old.warnings)")
        // Scenes that don't declare span get none of this.
        let (plain, plainFake) = try check(random, manifest: #"{"id":"spanning","name":"Plain","kind":"web"}"#) { $0.hasUpdate = true }
        try expect(plain.passed && plainFake.spanRequests.isEmpty && plain.span == nil, "\(plain.problems)")
        try expect(plain.spanPassed == nil && plain.spanVerdict == nil)
    }

    // MARK: - Synthetic scenes

    /// Pure functions of (t, canvas size) exercising what slicing must get right.
    static let spanScenes: [(name: String, js: String)] = [
        ("absolute-2d", """
        LivePaper.scene({
          draw(lp) {
            const c = lp.ctx;
            const g = c.createLinearGradient(0, 0, lp.w, lp.h);
            g.addColorStop(0, '#102040'); g.addColorStop(1, '#402010');
            c.fillStyle = g; c.fillRect(0, 0, lp.w, lp.h);
            for (let i = 0; i < 60; i++) {
              const x = (i * 97.3 + lp.t * 20) % lp.w, y = (i * 53.1 + lp.t * 7) % lp.h;
              c.fillStyle = 'hsl(' + (i * 9) + ',70%,50%)';
              c.beginPath(); c.arc(x, y, 20 + (i % 7) * 6, 0, Math.PI * 2); c.fill();
            }
            // Absolute transforms in device pixels (rotations), as the built-ins do.
            for (let i = 0; i < 16; i++) {
              const a = lp.t * 0.3 + i, x = lp.w * (i + 0.5) / 16, y = lp.h * (0.3 + 0.4 * (i % 2));
              c.setTransform(lp.dpr * Math.cos(a), lp.dpr * Math.sin(a), -lp.dpr * Math.sin(a), lp.dpr * Math.cos(a), lp.dpr * x, lp.dpr * y);
              c.fillStyle = '#e0c060'; c.fillRect(-30, -30, 60, 60);
            }
            // A device-space pattern: identity transform, canvas device pixels (lp.pw/lp.ph).
            c.setTransform(1, 0, 0, 1, 0, 0);
            c.fillStyle = 'rgba(255,255,255,0.15)';
            for (let x = 0; x < lp.pw; x += 37) c.fillRect(x, 0, 3, lp.ph);
            // getTransform/setTransform(matrix) round trip, translate on top.
            c.setTransform(lp.dpr, 0, 0, lp.dpr, 0, 0);
            const m = c.getTransform();
            c.setTransform(m); c.translate(lp.w * 0.5, 60);
            c.fillStyle = '#30d0a0'; c.fillRect(-200, 0, 400, 24);
            c.resetTransform();
            c.fillStyle = 'rgba(0,0,0,0.4)'; c.fillRect(Math.round(lp.pw * 0.25), Math.round(lp.ph * 0.25), 128, 128);
            // Layout around the clock (the same lp.clockRect on every display).
            c.setTransform(lp.dpr, 0, 0, lp.dpr, 0, 0);
            const r = lp.clockRect || { x: lp.w / 2 - 100, y: 40, w: 200, h: 120 };
            c.strokeStyle = '#ff4060'; c.lineWidth = 6; c.strokeRect(r.x - 12, r.y - 12, r.w + 24, r.h + 24);
          }
        });
        """),
        ("layers-2d", """
        LivePaper.scene({
          resize(lp) {
            // A canvas-sized layer (capped while spanning) and a small tile drawn in device space.
            this.L = LivePaper.util.layer(lp.w, lp.h, lp.dpr);
            const g = this.L.ctx;
            for (let i = 0; i < 30; i++) {
              const gr = g.createRadialGradient(lp.w * ((i * 0.37) % 1), lp.h * ((i * 0.61) % 1), 0, lp.w * ((i * 0.37) % 1), lp.h * ((i * 0.61) % 1), 160);
              gr.addColorStop(0, 'rgba(120,180,255,0.5)'); gr.addColorStop(1, 'rgba(120,180,255,0)');
              g.fillStyle = gr; g.fillRect(0, 0, lp.w, lp.h);
            }
          },
          draw(lp) {
            const c = lp.ctx;
            c.fillStyle = '#05070c'; c.fillRect(0, 0, lp.w, lp.h);
            c.drawImage(this.L.canvas, 0, 0, lp.w, lp.h);
            const k = 0.5 + 0.5 * Math.sin(lp.t);
            c.globalAlpha = 0.6;
            for (let x = 0; x < lp.w; x += 80) { c.fillStyle = k > 0.5 ? '#d08040' : '#4080d0'; c.fillRect(x + 20 * k, lp.h * 0.8, 40, 40); }
            c.globalAlpha = 1;
          }
        });
        """),
        ("uv-webgl", """
        LivePaper.scene({
          context: 'webgl',
          setup(lp) {
            const gl = lp.gl;
            const vs = 'attribute vec2 p; varying highp vec2 uv; void main(){ uv = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0); }';
            const fs = 'precision highp float; varying highp vec2 uv; uniform float t;' +
              'void main(){ gl_FragColor = vec4(0.5 + 0.5 * sin(uv.x * 40.0 + t), 0.5 + 0.5 * sin(uv.y * 25.0 - t * 0.7), step(0.5, fract((uv.x + uv.y) * 6.0)), 1.0); }';
            const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s; };
            const prog = gl.createProgram();
            gl.attachShader(prog, sh(gl.VERTEX_SHADER, vs)); gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, fs)); gl.linkProgram(prog);
            this.prog = prog; this.t = gl.getUniformLocation(prog, 't');
            const buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf);
            gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
            const loc = gl.getAttribLocation(prog, 'p'); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
            // An offscreen pass at a quarter of the canvas (offscreen framebuffers aren't offset).
            this.tex = gl.createTexture(); this.fb = gl.createFramebuffer();
          },
          resize(lp) {
            const gl = lp.gl;
            this.fw = Math.max(16, Math.ceil(lp.pw / 4)); this.fh = Math.max(16, Math.ceil(lp.ph / 4));
            gl.bindTexture(gl.TEXTURE_2D, this.tex);
            gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, this.fw, this.fh, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
            gl.bindFramebuffer(gl.FRAMEBUFFER, this.fb);
            gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, this.tex, 0);
            gl.bindFramebuffer(gl.FRAMEBUFFER, null);
          },
          draw(lp) {
            const gl = lp.gl;
            gl.useProgram(this.prog);
            gl.uniform1f(this.t, lp.t);
            gl.bindFramebuffer(gl.FRAMEBUFFER, this.fb);
            gl.viewport(0, 0, this.fw, this.fh);
            gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
            gl.bindFramebuffer(gl.FRAMEBUFFER, null);
            gl.viewport(0, 0, lp.pw, lp.ph);
            gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
            // A scissored band in canvas device pixels.
            gl.enable(gl.SCISSOR_TEST);
            gl.scissor(Math.round(lp.pw * 0.1), Math.round(lp.ph * 0.45), Math.round(lp.pw * 0.8), Math.round(lp.ph * 0.1));
            gl.clearColor(0.1, 0.1, 0.12, 1); gl.clear(gl.COLOR_BUFFER_BIT);
            gl.disable(gl.SCISSOR_TEST);
          }
        });
        """),
        ("fragcoord-webgl", """
        LivePaper.scene({
          context: 'webgl',
          setup(lp) {
            const gl = lp.gl;
            const vs = 'attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }';
            const fs = 'precision highp float; uniform vec2 off; uniform vec2 res; uniform float t;' +
              'void main(){ vec2 q = (gl_FragCoord.xy + off) / res; gl_FragColor = vec4(fract(q.x * 9.0 + t * 0.1), fract(q.y * 5.0), step(0.5, fract((q.x - q.y) * 4.0)), 1.0); }';
            const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s; };
            const prog = gl.createProgram();
            gl.attachShader(prog, sh(gl.VERTEX_SHADER, vs)); gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, fs)); gl.linkProgram(prog);
            this.prog = prog; this.u = { off: gl.getUniformLocation(prog, 'off'), res: gl.getUniformLocation(prog, 'res'), t: gl.getUniformLocation(prog, 't') };
            const buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf);
            gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
            const loc = gl.getAttribLocation(prog, 'p'); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
          },
          draw(lp) {
            const gl = lp.gl;
            gl.useProgram(this.prog);
            gl.uniform2f(this.u.off, lp.fragOffset[0], lp.fragOffset[1]);
            gl.uniform2f(this.u.res, lp.pw, lp.ph);
            gl.uniform1f(this.u.t, lp.t);
            gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
          }
        });
        """),
    ]

    /// Scenes that defeat slicing: laid out from the page's own size, or the drawing buffer's.
    static let brokenScenes: [(name: String, js: String)] = [
        ("inner-width-2d", """
        LivePaper.scene({
          draw(lp) {
            const c = lp.ctx, W = innerWidth, H = innerHeight;
            c.fillStyle = '#101820'; c.fillRect(0, 0, lp.w, lp.h);
            for (let i = 0; i < 12; i++) { c.fillStyle = 'hsl(' + (i * 30) + ',70%,50%)'; c.fillRect(W * i / 12, H * 0.2, W / 24, H * 0.6); }
          }
        });
        """),
        ("drawing-buffer-webgl", """
        LivePaper.scene({
          context: 'webgl',
          setup(lp) {
            const gl = lp.gl;
            const vs = 'attribute vec2 p; varying highp vec2 uv; void main(){ uv = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0); }';
            const fs = 'precision highp float; varying highp vec2 uv; void main(){ gl_FragColor = vec4(fract(uv.x * 8.0), uv.y, step(0.5, fract(uv.x * 3.0)), 1.0); }';
            const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s; };
            const prog = gl.createProgram();
            gl.attachShader(prog, sh(gl.VERTEX_SHADER, vs)); gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, fs)); gl.linkProgram(prog);
            this.prog = prog;
            const buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf);
            gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
            const loc = gl.getAttribLocation(prog, 'p'); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
          },
          draw(lp) {
            const gl = lp.gl;
            gl.viewport(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight);
            gl.useProgram(this.prog);
            gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
          }
        });
        """),
    ]

    /// The built-in scenes that declare `"span": true` (LIVEPAPER_SPAN_ALL_BUILTINS=1: every web
    /// built-in, to measure candidates before opting them in).
    static func builtinSpanScenes() throws -> [URL] {
        let fm = FileManager.default
        let all = ProcessInfo.processInfo.environment["LIVEPAPER_SPAN_ALL_BUILTINS"] == "1"
        return try fm.contentsOfDirectory(at: repoRoot.appendingPathComponent("Scenes"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lpscene" }.sorted { $0.path < $1.path }
            .filter { url in
                guard let m = try? SceneManifest.load(package: url) else { return false }
                return all ? m.kind == .web : m.spans
            }
    }

    /// Compiles a package into `.check/scene.html`.
    static func compiled(_ pkg: URL) throws -> URL {
        let html = pkg.appendingPathComponent(".check/scene.html")
        try FileManager.default.createDirectory(at: html.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SceneCompiler().compile(package: pkg, to: html)
        return html
    }

    // MARK: - End to end

    /// One render server for all the span e2e tests of this run (a test process may launch the
    /// daemon only once): the one LIVEPAPER_HOME serves, or a fresh one shut down at exit.
    nonisolated(unsafe) private static var spanServer: RenderClient?
    nonisolated(unsafe) private static var spanServerHome: URL?

    static func withSpanServer(_ body: (RenderClient) throws -> Void) throws {
        if spanServer == nil {
            let env = ProcessInfo.processInfo.environment
            let ownHome = env["LIVEPAPER_HOME"]?.isEmpty ?? true
            let home = ownHome ? URL(fileURLWithPath: "/tmp/lp-st-\(getpid())-span") : LPPaths.supportRoot
            spanServer = RenderClient(socket: home.appendingPathComponent("render.sock"))
            if ownHome {
                spanServerHome = home
                atexit {
                    guard let client = SpanRuntimeTests.spanServer, let home = SpanRuntimeTests.spanServerHome else { return }
                    _ = try? client.sendBlocking(RenderRequest(op: .shutdown), timeout: 10)
                    try? FileManager.default.removeItem(at: home)
                }
            }
        }
        try body(spanServer!)
    }

    static func endToEndCrops() throws {
        guard e2e else {
            print("  (skipped: set LIVEPAPER_SELFTEST_E2E=1 to run it; it uses or starts one LivePaperRenderd)")
            return
        }
        let env = ProcessInfo.processInfo.environment
        let only = env["LIVEPAPER_SPAN_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        try withSpanServer { client in
            var failures: [String] = []
            var packages: [(String, URL)] = []
            var cleanup: [URL] = []
            defer { for u in cleanup { try? FileManager.default.removeItem(at: u) } }
            for (name, js) in spanScenes {
                let pkg = try RuntimeTests.package("span-\(name)", js: js)
                cleanup.append(pkg.deletingLastPathComponent())
                packages.append((name, pkg))
            }
            for source in try builtinSpanScenes() {
                let tmp = try tempDir("span-builtin")
                cleanup.append(tmp)
                let pkg = tmp.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: pkg)
                packages.append((source.deletingPathExtension().lastPathComponent, pkg))
            }
            if let only { packages = packages.filter { only.contains($0.0) } }
            let times: [Double] = (env["LIVEPAPER_SPAN_TIMES"]?.split(separator: ",").compactMap { Double($0) }) ?? [12, 90]
            for (name, pkg) in packages {
                let html = try compiled(pkg)
                let dir = pkg.appendingPathComponent(".check")
                for arrangement in SpanCheck.standard {
                    for t in times {
                        let started = Date()
                        let run = try RuntimeTests.blocking {
                            try await SpanCheck.run(render: client, html: html, arrangement: arrangement, t: t, clock: false, directory: dir,
                                                    prefix: "span-\(arrangement.name)-t\(CheckFrame.num(t))")
                        }
                        let diffs = run.slices.map { s in s.diff.map { String(format: "%@ %.2f/%.2f%%", s.view.id, $0.meanAbs, $0.outliers * 100) } ?? "\(s.view.id) -" }
                        print("  \(name) \(arrangement.name) t=\(CheckFrame.num(t)): \(diffs.joined(separator: ", "))" +
                              (run.passed ? "" : " ✗") + String(format: " (%.1f s)", Date().timeIntervalSince(started)))
                        if !run.errors.isEmpty { failures.append("\(name): JavaScript errors \(run.errors)") }
                        if !run.rendered { failures.append("\(name) \(arrangement.name): \(run.full.note ?? run.slices.compactMap(\.response.note).joined(separator: "; "))") }
                        else if !run.serverSupportsSpan { failures.append("\(name): the render server did not report span (an old server is running?)") }
                        for slice in run.mismatched { failures.append("\(name): " + run.describe(slice)) }
                        if run.hasUpdate { failures.append("\(name): defines update(), which can't span") }
                    }
                }
            }
            // With the clock on, the clock appears only in the main display's slice. (A scene whose
            // layout doesn't follow lp.clockRect, so the clock is the only difference.)
            if let (name, pkg) = packages.first(where: { $0.0 == "layers-2d" }) {
                let html = try compiled(pkg)
                let dir = pkg.appendingPathComponent(".check")
                let b = try unwrap(SpanCheck.arrangement("B"))
                let off = try RuntimeTests.blocking {
                    try await SpanCheck.run(render: client, html: html, arrangement: b, t: 12, clock: false, directory: dir, prefix: "clock-off")
                }
                let on = try RuntimeTests.blocking {
                    try await SpanCheck.run(render: client, html: html, arrangement: b, t: 12, clock: true, directory: dir, prefix: "clock-on")
                }
                if !on.mismatched.isEmpty { failures.append("\(name) clock on: \(on.mismatched.map(on.describe).joined(separator: "; "))") }
                for (a, c) in zip(off.slices, on.slices) {
                    guard let ia = SpanCheck.image(at: URL(fileURLWithPath: a.path)), let ic = SpanCheck.image(at: URL(fileURLWithPath: c.path)) else {
                        failures.append("clock: missing PNGs"); continue
                    }
                    let d = SpanCheck.compare(full: ia, fullDpr: a.view.dpr, view: LPRect(x: 0, y: 0, width: a.view.rect.width, height: a.view.rect.height),
                                              slice: ic, sliceDpr: c.view.dpr)
                    print(String(format: "  clock on vs off, %@: mean %.3f/255", a.view.id, d.meanAbs))
                    if a.view.id == b.clockView {
                        if d.outliers < 0.0005 { failures.append("clock: the main slice (\(a.view.id)) shows no clock") }
                    } else if d.meanAbs > 0.01 {
                        failures.append("clock: \(a.view.id) (not the main display) shows a clock (mean \(d.meanAbs))")
                    }
                }
            }
            if !failures.isEmpty { throw TestFailure(description: failures.joined(separator: "\n    ")) }
        }
    }

    /// The opt-in criteria for built-ins (docs/SCENES.md): the biggest slice of arrangement B — the
    /// 2560×1440 display, here at 2× (a 5K panel, twice the pixels of check's 5120×1440@1 budget) — is
    /// ready within 3 s, and while it issues the whole canvas's drawing it benches at most 6 ms per
    /// frame or, where the display alone already costs about that, no more than 15 % over the same
    /// display unspanned: spanning must not add real cost.
    static let spanReadySeconds = 3.0
    static let spanBenchMs = 6.0
    static let spanOverheadFactor = 1.15

    static func endToEndCost() throws {
        guard e2e else {
            print("  (skipped: set LIVEPAPER_SELFTEST_E2E=1 to run it; it uses or starts one LivePaperRenderd)")
            return
        }
        let only = ProcessInfo.processInfo.environment["LIVEPAPER_SPAN_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        try withSpanServer { client in
            var failures: [String] = []
            let b = try unwrap(SpanCheck.arrangement("B"))
            var view = b.views[1]
            view.dpr = 2
            let span = b.span(for: view)
            for source in try builtinSpanScenes() where only?.contains(source.deletingPathExtension().lastPathComponent) ?? true {
                let name = source.deletingPathExtension().lastPathComponent
                let tmp = try tempDir("span-cost")
                defer { try? FileManager.default.removeItem(at: tmp) }
                let pkg = tmp.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: pkg)
                let html = try compiled(pkg)
                // Warm the server (first page of a process pays for WebKit's start-up).
                _ = try client.sendBlocking(RenderRequest(op: .still, html: html.path, width: 320, height: 200, dpr: 1, t: 1, clock: false), timeout: 120)
                let started = Date()
                let still = try client.sendBlocking(RenderRequest(op: .still, html: html.path, width: view.rect.width, height: view.rect.height,
                                                                  dpr: view.dpr, t: 90, clock: true, span: span), timeout: 120)
                let seconds = Date().timeIntervalSince(started)
                let bench = try client.sendBlocking(RenderRequest(op: .bench, html: html.path, width: view.rect.width, height: view.rect.height,
                                                                  dpr: view.dpr, t: 90, frames: 120, span: span), timeout: 180)
                // The same display without span, for comparison (what it costs there today).
                let plain = try client.sendBlocking(RenderRequest(op: .bench, html: html.path, width: view.rect.width, height: view.rect.height,
                                                                  dpr: view.dpr, t: 90, frames: 120), timeout: 180)
                print(String(format: "  %@: slice 2560x1440@2 of 4072x1440 ready+rendered in %.2f s, bench %.2f ms/frame (%.2f ms unspanned)",
                             name, seconds, bench.benchMs ?? -1, plain.benchMs ?? -1))
                if !still.ok || !bench.ok { failures.append("\(name): \(still.note ?? bench.note ?? "failed")"); continue }
                if bench.span != true { failures.append("\(name): the render server did not report span") }
                if seconds > spanReadySeconds { failures.append(String(format: "%@: the slice took %.2f s (budget %.0f s)", name, seconds, spanReadySeconds)) }
                if let ms = bench.benchMs, ms > max(spanBenchMs, (plain.benchMs ?? 0) * spanOverheadFactor) {
                    failures.append(String(format: "%@: %.2f ms per frame spanned, %.2f ms unspanned (budget %.0f ms, or +%.0f %%)",
                                           name, ms, plain.benchMs ?? -1, spanBenchMs, (spanOverheadFactor - 1) * 100))
                }
            }
            if !failures.isEmpty { throw TestFailure(description: failures.joined(separator: "\n    ")) }
        }
    }

    static func endToEndNegative() throws {
        guard e2e else {
            print("  (skipped: set LIVEPAPER_SELFTEST_E2E=1 to run it; it uses or starts one LivePaperRenderd)")
            return
        }
        try withSpanServer { client in
            var failures: [String] = []
            let b = try unwrap(SpanCheck.arrangement("B")).at(dpr: 1)
            for (name, js) in brokenScenes {
                let pkg = try RuntimeTests.package("span-\(name)", js: js)
                defer { try? FileManager.default.removeItem(at: pkg.deletingLastPathComponent()) }
                let html = try compiled(pkg)
                let run = try RuntimeTests.blocking {
                    try await SpanCheck.run(render: client, html: html, arrangement: b, t: 12, clock: false,
                                            directory: pkg.appendingPathComponent(".check"), prefix: "span")
                }
                print("  \(name): " + run.slices.map { s in s.diff.map { String(format: "%@ %.1f", s.view.id, $0.meanAbs) } ?? s.view.id }.joined(separator: ", "))
                if !run.rendered { failures.append("\(name) did not render: \(run.full.note ?? "-")"); continue }
                if run.mismatched.isEmpty { failures.append("\(name): the crop test should catch it, but every slice matched") }
            }
            if !failures.isEmpty { throw TestFailure(description: failures.joined(separator: "\n    ")) }
        }
    }
}
