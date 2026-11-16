// Runtime logic of spanning displays, the shared time base and paused starts, run in
// JavaScriptCore against a minimal stand-in for the page (nothing is rendered, no process started):
// Runtime/runtime.js boots a recording scene and the test inspects lp, the stage's transforms, the
// WebGL viewport calls, the frame loop and the ready message. The pixels are runtime.e2e.spanCrops'
// job (through the render server).
import Foundation
import JavaScriptCore
import LivePaperCore

extension SelfTests {
    static var runtimeSpanJS: [TestCase] {
        [TestCase(name: "runtime.span.jsLogic", run: RuntimeSpanJS.logic)]
    }
}

/// One page: runtime.js booted with `config` at innerWidth × innerHeight @ dpr, and `scene` registered.
final class RuntimeJSPage {
    let context: JSContext
    private var error: String?

    init(config: [String: Any], width: Double, height: Double, dpr: Double, scene: String) throws {
        guard let ctx = JSContext() else { throw TestFailure(description: "JavaScriptCore is unavailable") }
        context = ctx
        ctx.exceptionHandler = { [weak self] _, value in
            self?.error = "\(value?.toString() ?? "exception") \(value?.objectForKeyedSubscript("stack")?.toString() ?? "")"
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        try run("var innerWidth = \(width), innerHeight = \(height), devicePixelRatio = \(dpr);" + Self.prelude +
                "window.LIVEPAPER_CONFIG = \(json);", "harness.js")
        let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Runtime/runtime.js")
        try run(String(contentsOf: runtime, encoding: .utf8), "livepaper-runtime.js")
        try run(scene, "scene.js")
    }

    @discardableResult
    func run(_ js: String, _ url: String = "test.js") throws -> JSValue? {
        let v = context.evaluateScript(js, withSourceURL: URL(string: url))
        if let error { self.error = nil; throw TestFailure(description: "\(url): \(error)") }
        return v
    }

    /// Values of expressions (an exception shows up as NaN / false / "" here and fails the next `run`).
    func double(_ js: String) -> Double { (try? run(js))??.toDouble() ?? .nan }
    func bool(_ js: String) -> Bool { (try? run(js))??.toBool() ?? false }
    func string(_ js: String) -> String { (try? run("JSON.stringify(\(js))"))??.toString() ?? "" }

    /// A stand-in for the page: canvases whose 2D contexts record the transform, a WebGL context that
    /// records viewport/scissor calls, requestAnimationFrame / setTimeout queues the test drives, a
    /// controllable clock (performance.now) and the message handler.
    static let prelude = #"""
    var window = this, self = this;
    var __posted = [], __rafs = [], __now = 1000, __listeners = {};
    var performance = { timeOrigin: 1800000000000, now: function () { return __now; } };
    var location = { hash: '' };
    var console = { error: function () {}, log: function () {} };
    function URLSearchParams() { this.forEach = function () {}; }
    window.matchMedia = function () { return { matches: false, addEventListener: function () {} }; };
    window.addEventListener = function (type, fn) { (__listeners[type] = __listeners[type] || []).push(fn); };
    window.webkit = { messageHandlers: { livepaper: { postMessage: function (m) { __posted.push(JSON.parse(JSON.stringify(m))); } } } };
    function requestAnimationFrame(fn) { __rafs.push(fn); return __rafs.length; }
    function cancelAnimationFrame(id) { if (id > 0) __rafs[id - 1] = null; }
    function setTimeout() { return 1; }
    function clearTimeout() {}
    // Runs the pending animation frames at time `now` (ms since timeOrigin).
    function __tick(now) {
      __now = now;
      var pending = __rafs; __rafs = [];
      pending.forEach(function (fn) { if (fn) fn(now); });
      return __rafs.filter(function (f) { return !!f; }).length;
    }
    function DOMMatrix(m) {
      m = m || [1, 0, 0, 1, 0, 0];
      this.a = m[0]; this.b = m[1]; this.c = m[2]; this.d = m[3]; this.e = m[4]; this.f = m[5];
    }
    DOMMatrix.fromMatrix = function (o) { return new DOMMatrix([o.a, o.b, o.c, o.d, o.e, o.f]); };
    function __ctx2d(canvas) {
      var c = { canvas: canvas, __m: [1, 0, 0, 1, 0, 0], globalAlpha: 1, globalCompositeOperation: 'source-over' };
      c.setTransform = function (a, b, cc, d, e, f) {
        if (arguments.length <= 1) { var m = a; c.__m = [m.a, m.b, m.c, m.d, m.e, m.f]; } else c.__m = [a, b, cc, d, e, f];
      };
      c.getTransform = function () { return new DOMMatrix(c.__m); };
      c.resetTransform = function () { c.__m = [1, 0, 0, 1, 0, 0]; };
      ['fillRect', 'clearRect', 'fillText', 'strokeRect', 'beginPath', 'arc', 'fill', 'stroke', 'drawImage', 'save', 'restore',
       'translate', 'scale', 'rotate', 'moveTo', 'lineTo', 'closePath', 'putImageData'].forEach(function (k) { c[k] = function () {}; });
      c.createLinearGradient = c.createRadialGradient = function () { return { addColorStop: function () {} }; };
      c.getImageData = function () { return { data: [0, 0, 0, 0] }; };
      c.measureText = function () { return { width: 10 }; };
      return c;
    }
    function __gl(canvas) {
      var g = { canvas: canvas, FRAMEBUFFER: 0x8D40, MAX_VIEWPORT_DIMS: 0x0D3A, RGBA: 1, UNSIGNED_BYTE: 2, calls: [] };
      g.getParameter = function (p) { return p === g.MAX_VIEWPORT_DIMS ? [16384, 16384] : 0; };
      g.viewport = function (x, y, w, h) { g.calls.push(['viewport', x, y, w, h]); };
      g.scissor = function (x, y, w, h) { g.calls.push(['scissor', x, y, w, h]); };
      g.bindFramebuffer = function (t, fb) { g.calls.push(['bind', fb ? 1 : 0]); };
      g.readPixels = function () {};
      return g;
    }
    function __element(tag) {
      var el = { tagName: tag, style: {}, children: [], width: 300, height: 150, offsetWidth: 0, __ctx: null,
                 appendChild: function (c) { el.children.push(c); return c; }, setAttribute: function () {} };
      if (tag === 'canvas') el.getContext = function (kind) {
        if (!el.__ctx) el.__ctx = kind === '2d' ? __ctx2d(el) : __gl(el);
        return el.__ctx;
      };
      return el;
    }
    var document = { createElement: __element, hidden: false, fonts: null, addEventListener: function () {} };
    document.head = __element('head'); document.body = __element('body'); document.documentElement = __element('html');
    """#
}

enum RuntimeSpanJS {
    /// A 2D scene that records what it sees.
    static let scene2D = """
    var seen = { draws: 0, frames: [] };
    LivePaper.scene({
      draw(lp) {
        seen.draws++;
        seen.lp = { w: lp.w, h: lp.h, pw: lp.pw, ph: lp.ph, dpr: lp.dpr, t: lp.t, viewport: lp.viewport, span: lp.span,
                    fragOffset: lp.fragOffset, clockRect: lp.clockRect, clockBox: lp.clockBox, quality: lp.quality, scale: lp.scale };
        seen.m = lp.ctx.__m.slice();
        seen.get = (function () { var m = lp.ctx.getTransform(); return [m.e, m.f]; })();
        lp.ctx.setTransform(1, 0, 0, 1, 10, 20); seen.abs = lp.ctx.__m.slice();
        lp.ctx.setTransform(lp.ctx.getTransform()); seen.roundTrip = lp.ctx.__m.slice();
        lp.ctx.resetTransform(); seen.reset = lp.ctx.__m.slice();
        var L = LivePaper.util.layer(lp.w, lp.h, lp.dpr); seen.layerDpr = L.dpr;
        seen.frames.push(lp.t);
      }
    });
    """

    static let sceneGL = """
    var seen = {};
    LivePaper.scene({
      context: 'webgl',
      draw(lp) {
        var gl = lp.gl;
        gl.calls.length = 0;
        gl.viewport(0, 0, lp.pw, lp.ph);
        gl.scissor(5, 6, 7, 8);
        gl.bindFramebuffer(gl.FRAMEBUFFER, {});
        gl.viewport(0, 0, 64, 32);
        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
        gl.viewport(1, 2, 3, 4);
        seen.calls = gl.calls.slice();
        seen.lp = { pw: lp.pw, ph: lp.ph, fragOffset: lp.fragOffset, dpr: lp.dpr };
      }
    });
    """

    static func logic() throws {
        // Arrangement B's external display: viewport 2560×1440 at (1512, 0) of a 4072×1440 canvas;
        // the laptop (1512×982 at (0, 458)) is the main display and holds the clock.
        let span: [String: Any] = ["spanW": 4072, "spanH": 1440, "spanX": 1512, "spanY": 0,
                                   "spanClockX": 0, "spanClockY": 458, "spanClockW": 1512, "spanClockH": 982]
        let page = try RuntimeJSPage(config: span.merging(["seed": 3]) { a, _ in a }, width: 2560, height: 1440, dpr: 1, scene: scene2D)
        try expectEqual(page.double("seen.draws"), 1)
        try expectEqual(page.string("[seen.lp.w, seen.lp.h, seen.lp.pw, seen.lp.ph]"), "[4072,1440,4072,1440]")
        try expectEqual(page.string("[document.body.children[0].width, document.body.children[0].height]"), "[2560,1440]")
        try expectEqual(page.string("seen.lp.viewport"), #"{"x":1512,"y":0,"w":2560,"h":1440}"#)
        try expectEqual(page.string("seen.lp.fragOffset"), "[1512,0]")
        try expect(page.bool("seen.lp.span"))
        // The runtime's own transform and the scene's absolute ones are offset by the viewport;
        // getTransform hides the offset, so round trips are exact.
        try expectEqual(page.string("seen.m"), "[1,0,0,1,-1512,0]")
        try expectEqual(page.string("seen.get"), "[0,0]")
        try expectEqual(page.string("seen.abs"), "[1,0,0,1,-1502,20]")
        try expectEqual(page.string("seen.roundTrip"), "[1,0,0,1,-1502,20]")
        try expectEqual(page.string("seen.reset"), "[1,0,0,1,-1512,0]")
        // The clock is laid out in the main display's viewport (canvas coordinates).
        let rect = SaverClockLayout.make(width: 1512, height: 982, position: .top)!.rect
        try expectEqual(page.double("seen.lp.clockRect.x"), rect.x)
        try expectEqual(page.double("seen.lp.clockRect.y"), rect.y + 458)
        try expectEqual(page.string("seen.lp.clockBox"), #"{"x":0,"y":458,"w":1512,"h":982}"#)
        try expectEqual(page.string("[seen.lp.quality, seen.lp.scale]"), "[1,1]")
        // Ready reports the viewport, span and update().
        try expectEqual(page.string("__posted.filter(function (m) { return m.type === 'ready'; }).map(function (m) { return [m.span, m.hasUpdate, m.viewport.x]; })"),
                        "[[true,false,1512]]")

        // Mixed density: a 2× laptop slice (bottom-aligned at y = 458).
        let laptop = try RuntimeJSPage(config: span.merging(["spanX": 0, "spanY": 458]) { _, b in b }, width: 1512, height: 982, dpr: 2, scene: scene2D)
        try expectEqual(laptop.string("[seen.lp.pw, seen.lp.ph, seen.lp.dpr]"), "[8144,2880,2]")
        try expectEqual(laptop.string("[document.body.children[0].width, document.body.children[0].height]"), "[3024,1964]")
        try expectEqual(laptop.string("seen.m"), "[2,0,0,2,0,-916]")
        try expectEqual(laptop.string("seen.lp.fragOffset"), "[0,0]")   // GL bottom-left: the laptop is at the bottom
        // Canvas-size layers are capped at 16 MP while spanning (4072×1440 at 2× would be 23 MP).
        try expect(laptop.double("seen.layerDpr") < 1.7 && laptop.double("seen.layerDpr") > 1.6, "layer cap \(laptop.double("seen.layerDpr"))")
        // Without span nothing changes.
        let plain = try RuntimeJSPage(config: [:], width: 1512, height: 982, dpr: 2, scene: scene2D)
        try expectEqual(plain.string("[seen.lp.w, seen.lp.pw, seen.lp.span, seen.m, seen.abs, seen.layerDpr]"),
                        "[1512,3024,false,[2,0,0,2,0,0],[1,0,0,1,10,20],2]")
        try expectEqual(plain.string("seen.lp.viewport"), #"{"x":0,"y":0,"w":1512,"h":982}"#)

        // WebGL: the default framebuffer's viewport and scissor are offset (GL's bottom-left origin),
        // offscreen framebuffers aren't. Top slice of arrangement C: 1920×1080 at (0, 0) of 1920×2062.
        let gl = try RuntimeJSPage(config: ["spanW": 1920, "spanH": 2062, "spanX": 0, "spanY": 0], width: 1920, height: 1080, dpr: 1, scene: sceneGL)
        try expectEqual(gl.string("seen.lp.fragOffset"), "[0,982]")
        try expectEqual(gl.string("seen.calls"),
                        #"[["viewport",0,-982,1920,2062],["scissor",5,-976,7,8],["bind",1],["viewport",0,0,64,32],["bind",0],["viewport",1,-980,3,4]]"#)

        // The wall-clock time base: every display computes t from the same origin.
        let origin = 1_800_000_000_000.0 + 1000 - 5000   // 5 s before the page's clock reads 1000 ms
        let timed = try RuntimeJSPage(config: span.merging(["timeOrigin": origin]) { a, _ in a }, width: 2560, height: 1440, dpr: 1, scene: scene2D)
        try expect(abs(timed.double("seen.lp.t") - 5) < 1e-9, "t at boot \(timed.double("seen.lp.t"))")
        _ = try timed.run("__tick(1100)")          // the first frame only arms the loop
        _ = try timed.run("__tick(1117)")
        try expect(abs(timed.double("seen.lp.t") - 5.117) < 1e-9, "t \(timed.double("seen.lp.t"))")
        _ = try timed.run("__tick(61117)")         // after a stall t follows the clock, not dt
        try expect(abs(timed.double("seen.lp.t") - 65.117) < 1e-9, "t after a minute \(timed.double("seen.lp.t"))")
        // Without a time origin, t advances by the (clamped) frame time, as before.
        let local = try RuntimeJSPage(config: [:], width: 800, height: 600, dpr: 1, scene: scene2D)
        _ = try local.run("__tick(1100)"); _ = try local.run("__tick(1117)"); _ = try local.run("__tick(61117)")
        try expect(abs(local.double("seen.lp.t") - 0.117) < 1e-9, "local t \(local.double("seen.lp.t"))")

        // Starting paused: one frame, no frame loop until resume().
        let paused = try RuntimeJSPage(config: ["paused": true], width: 800, height: 600, dpr: 1, scene: scene2D)
        try expectEqual(paused.double("seen.draws"), 1)
        try expectEqual(paused.double("__rafs.length"), 0)
        _ = try paused.run("LivePaper.host.resume()")
        try expectEqual(paused.double("__rafs.length"), 1)

        // The governor is off while spanning: frames far over budget never lower quality or scale.
        let busy = try RuntimeJSPage(config: span.merging(["budgetMs": 0.001]) { a, _ in a }, width: 2560, height: 1440, dpr: 1,
                                     scene: scene2D.replacingOccurrences(of: "seen.draws++;", with: "seen.draws++; __now += 50;"))
        var t = 1100.0
        for _ in 0..<200 { t += 60; _ = try busy.run("__tick(\(t))") }
        try expectEqual(busy.string("[seen.lp.quality, seen.lp.scale]"), "[1,1]")
        let busyPlain = try RuntimeJSPage(config: ["budgetMs": 0.001], width: 2560, height: 1440, dpr: 1,
                                          scene: scene2D.replacingOccurrences(of: "seen.draws++;", with: "seen.draws++; __now += 50;"))
        t = 1100
        for _ in 0..<200 { t += 60; _ = try busyPlain.run("__tick(\(t))") }
        try expect(busyPlain.double("seen.lp.quality") < 1, "the governor still works without span")

        // host.config can switch span on (and re-lays the page out).
        let late = try RuntimeJSPage(config: [:], width: 1000, height: 500, dpr: 1, scene: scene2D)
        _ = try late.run("LivePaper.host.config({spanW: 3000, spanH: 500, spanX: 2000, spanY: 0})")
        _ = try late.run("__tick(1100)"); _ = try late.run("__tick(1200)")
        try expectEqual(late.string("[seen.lp.w, seen.lp.viewport.x, seen.m]"), "[3000,2000,[1,0,0,1,-2000,0]]")
    }
}
