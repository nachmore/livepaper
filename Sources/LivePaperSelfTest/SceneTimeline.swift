// SceneTimeline — runs a 2D scene's resize()/draw() in JavaScriptCore against a recording stand-in
// for the canvas, so self tests can follow how the picture moves over time without a render server
// (nothing is rasterised and no process is started). Each frame is the list of the stage's draw calls:
// the bounding box (CSS px, after the current transform) and alpha of every image, rectangle and
// path. `TimeContinuity` compares frames 1/30 s apart:
//   - jumps: a visible sprite moves more than 0.8 % of the screen's longer side, or its alpha changes
//     by more than 0.2, in one frame (e.g. a position that snaps back when a period wraps);
//   - drift: each sprite's speed at 1 h, 10 h and 100 h must stay within the range seen in the first
//     half hour (e.g. a wrap length that changes with t bends the motion more the longer it runs).
// The real LivePaper.util is used (Runtime/runtime.js is loaded and its scene() call intercepted).
import Foundation
import JavaScriptCore

struct SceneDraw: Decodable {
    /// Images match by source canvas (a tiled layer is one image drawn twice); paths and
    /// rectangles by the scene.js line that paints them.
    let key: String
    let x0: Double, y0: Double, x1: Double, y1: Double
    let alpha: Double
    /// scene.js line of the draw call (for messages).
    let site: String

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        key = try c.decode(String.self)
        x0 = try c.decode(Double.self); y0 = try c.decode(Double.self)
        x1 = try c.decode(Double.self); y1 = try c.decode(Double.self)
        alpha = try c.decode(Double.self)
        site = try c.decode(String.self)
    }

    var cx: Double { (x0 + x1) / 2 }
    var cy: Double { (y0 + y1) / 2 }
    /// Largest move of any edge between two draws.
    func distance(to o: SceneDraw) -> Double {
        max(abs(x0 - o.x0), abs(y0 - o.y0), abs(x1 - o.x1), abs(y1 - o.y1))
    }
}

final class SceneTimeline {
    let width: Double, height: Double
    private let context: JSContext
    private var error: String?

    init(runtime: URL, scene: URL, width: Double, height: Double) throws {
        self.width = width; self.height = height
        guard let ctx = JSContext() else { throw TestFailure(description: "JavaScriptCore is unavailable") }
        context = ctx
        ctx.exceptionHandler = { [weak self] _, value in
            let stack = value?.objectForKeyedSubscript("stack")?.toString() ?? ""
            self?.error = "\(value?.toString() ?? "exception")\n\(stack)"
        }
        try evaluate(Self.prelude, url: "harness.js")
        try evaluate(String(contentsOf: runtime, encoding: .utf8), url: "livepaper-runtime.js")
        try evaluate(Self.capture, url: "harness-capture.js")
        try evaluate(String(contentsOf: scene, encoding: .utf8), url: "scene.js")
    }

    /// The stage's draw calls for one frame at time t (lp.t, as the runtime would pass it).
    func frame(_ t: Double, reducedMotion: Bool = false) throws -> [SceneDraw] {
        let fn = context.objectForKeyedSubscript("__frame")
        let json = fn?.call(withArguments: [t, width, height, reducedMotion])?.toString() ?? ""
        if let error { self.error = nil; throw TestFailure(description: "scene.js at t=\(t): \(error)") }
        return try JSONDecoder().decode([SceneDraw].self, from: Data(json.utf8))
    }

    private func evaluate(_ source: String, url: String) throws {
        context.evaluateScript(source, withSourceURL: URL(string: url))
        if let error { self.error = nil; throw TestFailure(description: "\(url): \(error)") }
    }

    // A headless stand-in for the page: just enough DOM for runtime.js to load without booting, and
    // canvases whose 2D contexts accept every call (scenes build their textures with them) while the
    // stage's records where each draw lands.
    private static let prelude = #"""
    var window = this;
    var __canvasId = 0, __recs = [];
    function __noop() {}
    function __Gradient() {}
    __Gradient.prototype.addColorStop = __noop;

    function Path2D(src) { this.pts = src && src.pts ? src.pts.slice() : []; }
    Path2D.prototype.moveTo = function (x, y) { this.pts.push(x, y); };
    Path2D.prototype.lineTo = Path2D.prototype.moveTo;
    Path2D.prototype.quadraticCurveTo = function (a, b, x, y) { this.pts.push(a, b, x, y); };
    Path2D.prototype.bezierCurveTo = function (a, b, c, d, x, y) { this.pts.push(a, b, c, d, x, y); };
    Path2D.prototype.arcTo = function (a, b, x, y) { this.pts.push(a, b, x, y); };
    Path2D.prototype.arc = function (x, y, r) { this.pts.push(x - r, y - r, x + r, y + r); };
    Path2D.prototype.ellipse = function (x, y, rx, ry) { var m = Math.max(rx, ry); this.pts.push(x - m, y - m, x + m, y + m); };
    Path2D.prototype.rect = function (x, y, w, h) { this.pts.push(x, y, x + w, y + h); };
    Path2D.prototype.roundRect = Path2D.prototype.rect;
    Path2D.prototype.closePath = __noop;
    Path2D.prototype.addPath = function (p) { if (p && p.pts) this.pts = this.pts.concat(p.pts); };

    function __callSite() {
      var m = /scene\.js:(\d+)/.exec(new Error().stack || '');
      return m ? m[1] : '?';
    }
    function __styleAlpha(s) {
      if (typeof s !== 'string') return 1;
      var m = /^rgba\(([^)]*)\)/.exec(s.replace(/\s+/g, ''));
      if (m) { var p = m[1].split(','); return p.length > 3 ? Number(p[3]) : 1; }
      return s === 'transparent' ? 0 : 1;
    }

    function __Ctx(canvas, record) {
      this.canvas = canvas; this.__rec = record;
      this.globalAlpha = 1; this.globalCompositeOperation = 'source-over';
      this.fillStyle = '#000'; this.strokeStyle = '#000'; this.lineWidth = 1;
      this.lineCap = 'butt'; this.lineJoin = 'miter'; this.miterLimit = 10;
      this.font = '10px sans-serif'; this.textAlign = 'start'; this.textBaseline = 'alphabetic';
      this.imageSmoothingEnabled = true; this.imageSmoothingQuality = 'low';
      this.shadowBlur = 0; this.shadowColor = 'transparent'; this.shadowOffsetX = 0; this.shadowOffsetY = 0;
      this.filter = 'none'; this.lineDashOffset = 0;
      this.__m = [1, 0, 0, 1, 0, 0]; this.__stack = []; this.__path = new Path2D();
    }
    (function (P) {
      var STATE = ['globalAlpha', 'globalCompositeOperation', 'fillStyle', 'strokeStyle', 'lineWidth', 'lineCap',
        'lineJoin', 'font', 'textAlign', 'textBaseline', 'shadowBlur', 'shadowColor', 'filter', 'imageSmoothingEnabled'];
      P.save = function () {
        var s = { m: this.__m.slice() };
        for (var i = 0; i < STATE.length; i++) s[STATE[i]] = this[STATE[i]];
        this.__stack.push(s);
      };
      P.restore = function () {
        var s = this.__stack.pop();
        if (!s) return;
        this.__m = s.m;
        for (var i = 0; i < STATE.length; i++) this[STATE[i]] = s[STATE[i]];
      };
      P.setTransform = function (a, b, c, d, e, f) {
        if (a && typeof a === 'object') { this.__m = [a.a, a.b, a.c, a.d, a.e, a.f]; return; }
        this.__m = arguments.length ? [a, b, c, d, e, f] : [1, 0, 0, 1, 0, 0];
      };
      P.resetTransform = function () { this.__m = [1, 0, 0, 1, 0, 0]; };
      P.getTransform = function () { var m = this.__m; return { a: m[0], b: m[1], c: m[2], d: m[3], e: m[4], f: m[5] }; };
      P.transform = function (a, b, c, d, e, f) {
        var m = this.__m;
        this.__m = [m[0] * a + m[2] * b, m[1] * a + m[3] * b, m[0] * c + m[2] * d, m[1] * c + m[3] * d,
          m[0] * e + m[2] * f + m[4], m[1] * e + m[3] * f + m[5]];
      };
      P.translate = function (x, y) { this.transform(1, 0, 0, 1, x, y); };
      P.scale = function (x, y) { this.transform(x, 0, 0, y, 0, 0); };
      P.rotate = function (a) { var c = Math.cos(a), s = Math.sin(a); this.transform(c, s, -s, c, 0, 0); };
      P.__box = function (pts, kind, src, alpha) {
        if (!this.__rec || !pts.length) return;
        var m = this.__m, x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
        for (var i = 0; i + 1 < pts.length; i += 2) {
          var x = m[0] * pts[i] + m[2] * pts[i + 1] + m[4], y = m[1] * pts[i] + m[3] * pts[i + 1] + m[5];
          if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y;
        }
        var site = __callSite();
        __recs.push([kind === 'img' ? 'img' + src : kind + '@' + site, x0, y0, x1, y1, this.globalAlpha * alpha, site]);
      };
      P.drawImage = function (img) {
        var a = arguments, dx, dy, dw, dh;
        if (a.length >= 9) { dx = a[5]; dy = a[6]; dw = a[7]; dh = a[8]; }
        else if (a.length >= 5) { dx = a[1]; dy = a[2]; dw = a[3]; dh = a[4]; }
        else { dx = a[1]; dy = a[2]; dw = img.width; dh = img.height; }
        this.__box([dx, dy, dx + dw, dy, dx, dy + dh, dx + dw, dy + dh], 'img', img && img.__id, 1);
      };
      P.fillRect = function (x, y, w, h) { this.__box([x, y, x + w, y, x, y + h, x + w, y + h], 'rect', '', __styleAlpha(this.fillStyle)); };
      P.strokeRect = P.fillRect;
      P.clearRect = __noop;
      P.beginPath = function () { this.__path = new Path2D(); };
      ['moveTo', 'lineTo', 'quadraticCurveTo', 'bezierCurveTo', 'arcTo', 'arc', 'ellipse', 'rect', 'roundRect'].forEach(function (k) {
        P[k] = function () {
          // the context's own path is built in device space: transform its points as they come
          var p = new Path2D(), m = this.__m;
          Path2D.prototype[k].apply(p, arguments);
          for (var i = 0; i + 1 < p.pts.length; i += 2) {
            var x = p.pts[i], y = p.pts[i + 1];
            this.__path.pts.push(m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]);
          }
        };
      });
      P.closePath = __noop;
      P.__paint = function (path, kind, style) {
        if (path && path.pts) { this.__box(path.pts, kind, '', __styleAlpha(style)); return; }
        var m = this.__m;
        this.__m = [1, 0, 0, 1, 0, 0];
        this.__box(this.__path.pts, kind, '', __styleAlpha(style));
        this.__m = m;
      };
      P.fill = function (path) { this.__paint(path, 'fill', this.fillStyle); };
      P.stroke = function (path) { this.__paint(path, 'stroke', this.strokeStyle); };
      P.clip = __noop;
      P.fillText = __noop; P.strokeText = __noop;
      P.measureText = function (s) { return { width: String(s).length * 6 }; };
      P.setLineDash = __noop; P.getLineDash = function () { return []; };
      P.isPointInPath = function () { return false; };
      P.createLinearGradient = function () { return new __Gradient(); };
      P.createRadialGradient = P.createLinearGradient;
      P.createConicGradient = P.createLinearGradient;
      P.createPattern = function () { return { setTransform: __noop }; };
      P.createImageData = function (w, h) {
        if (w && typeof w === 'object') { h = w.height; w = w.width; }
        w = Math.max(1, Math.round(w)); h = Math.max(1, Math.round(h));
        return { width: w, height: h, data: new Uint8ClampedArray(w * h * 4) };
      };
      P.getImageData = function (x, y, w, h) { return P.createImageData(w, h); };
      P.putImageData = __noop;
    })(__Ctx.prototype);

    function __Canvas() { this.width = 300; this.height = 150; this.style = {}; this.__id = ++__canvasId; this.__ctx = null; }
    __Canvas.prototype.getContext = function (kind) {
      if (kind !== '2d') return null;
      if (!this.__ctx) this.__ctx = new __Ctx(this, false);
      return this.__ctx;
    };
    __Canvas.prototype.addEventListener = __noop;
    __Canvas.prototype.toDataURL = function () { return ''; };

    var document = {
      createElement: function (tag) {
        if (tag === 'canvas') return new __Canvas();
        return { style: {}, appendChild: __noop, setAttribute: __noop, textContent: '' };
      },
      head: { appendChild: __noop },
      documentElement: { appendChild: __noop, setAttribute: __noop },
      body: null, hidden: false, fonts: null,          // no body: the runtime never boots
      addEventListener: __noop
    };
    window.addEventListener = __noop;
    window.matchMedia = function () { return { matches: false, addEventListener: __noop }; };
    window.innerWidth = 1512; window.innerHeight = 982; window.devicePixelRatio = 1;
    var location = { hash: '' };
    var performance = { now: function () { return 0; } };
    var requestAnimationFrame = function () { return 0; }, cancelAnimationFrame = __noop;
    var setTimeout = function () { return 0; }, clearTimeout = __noop;
    var Image = function () {};
    var console = { log: __noop, error: __noop, warn: __noop, info: __noop };
    """#

    // After runtime.js: keep the real LivePaper.util, take the scene definition instead of booting it,
    // and draw it on demand like the runtime's still mode does (dpr 1, top clock).
    private static let capture = #"""
    var __rt = window.LivePaper, __def = null;
    window.LivePaper = {
      version: __rt.version, api: __rt.api, util: __rt.util, clockParts: __rt.clockParts, host: __rt.host, debug: __rt.debug,
      asset: function () { return null; }, image: function () { return null; }, text: function () { return null; },
      scene: function (d) { if (!__def) __def = d; }
    };
    Math.random = __rt.util.mulberry32(0x5bd1e994);
    var __stage = new __Canvas(), __ctx = new __Ctx(__stage, true), __lp = null, __size = '';

    function __frame(t, w, h, reducedMotion) {
      if (!__def) throw new Error('scene.js did not call LivePaper.scene({...})');
      if (__def.update) throw new Error('scene simulates in update(): frames at large t need a replay, not supported here');
      if (!__lp) {
        __lp = {
          canvas: __stage, ctx: __ctx, gl: null, context: '2d',
          w: 0, h: 0, dpr: 1, pw: 0, ph: 0, cx: 0, cy: 0, min: 0, max: 0, aspect: 1, scale: 1,
          t: 0, dt: 1 / 30, frame: 0, mode: 'still', rand: __rt.util.mulberry32(1), quality: 1,
          clockRect: null, clockVisible: true, clockAlpha: 1,
          env: { power: 'ac', lowPower: false, reducedMotion: false, preview: false }, cfg: {}, util: __rt.util
        };
        if (__def.setup) __def.setup(__lp);
      }
      __lp.env.reducedMotion = !!reducedMotion;
      if (w + 'x' + h !== __size) {
        __size = w + 'x' + h;
        __lp.w = w; __lp.h = h; __lp.pw = w; __lp.ph = h; __lp.cx = w / 2; __lp.cy = h / 2;
        __lp.min = Math.min(w, h); __lp.max = Math.max(w, h); __lp.aspect = w / h;
        __stage.width = w; __stage.height = h;
        // the runtime's clock rectangle at top centre (rectFor('top') in runtime.js)
        var time = Math.max(40, Math.min(210, Math.min(w * 0.11, h * 0.15)));
        var date = Math.max(13, time * 0.2), bw = time * 3.4, bh = date * 1.6 + time * 1.1;
        __lp.clockRect = { x: w / 2 - bw / 2, y: h * 0.07, w: bw, h: bh };
        if (__def.resize) __def.resize(__lp);
      }
      __lp.t = t; __lp.frame++;
      __recs = [];
      __ctx.__m = [1, 0, 0, 1, 0, 0]; __ctx.__stack = [];
      __ctx.globalAlpha = 1; __ctx.globalCompositeOperation = 'source-over';
      __def.draw(__lp);
      return JSON.stringify(__recs);
    }
    """#
}

enum TimeContinuity {
    static let frameDt = 1.0 / 30

    struct Jump: CustomStringConvertible {
        let t: Double, draw: SceneDraw, distance: Double, alphaChange: Double
        var description: String {
            let d = distance.isFinite ? String(format: "moves %.0f px", distance) : "appears or vanishes"
            return String(format: "t=%.3f: scene.js:%@ %@ (alpha %.2f, changes by %.2f) in one frame", t, draw.site, d, draw.alpha, alphaChange)
        }
    }

    /// Visible: not (nearly) transparent and at least a few px on screen.
    static func visible(_ d: SceneDraw, w: Double, h: Double) -> Bool {
        d.alpha >= 0.04 && min(d.x1, w) - max(d.x0, 0) >= 3 && min(d.y1, h) - max(d.y0, 0) >= 3
    }

    /// For every visible draw of `b`, the nearest draw with the same key in `a`.
    static func nearest(_ a: [SceneDraw], _ b: [SceneDraw], w: Double, h: Double) -> [(SceneDraw, SceneDraw?)] {
        let byKey = Dictionary(grouping: a, by: \.key)
        return b.filter { visible($0, w: w, h: h) }.map { d in
            (d, byKey[d.key]?.min { $0.distance(to: d) < $1.distance(to: d) })
        }
    }

    /// Visible draws that jump between two successive frames (in either direction, so things that
    /// pop out are caught as well as things that pop in).
    static func jumps(at t: Double, _ a: [SceneDraw], _ b: [SceneDraw], w: Double, h: Double) -> [Jump] {
        let limit = 0.008 * max(w, h)
        var out: [Jump] = []
        for (x, y) in [(a, b), (b, a)] {
            for (d, match) in nearest(x, y, w: w, h: h) {
                let dist = match.map { $0.distance(to: d) } ?? .infinity
                let da = abs((match?.alpha ?? 0) - d.alpha)
                if dist > limit || da > 0.2 { out.append(Jump(t: t, draw: d, distance: dist, alphaChange: da)) }
            }
        }
        return out
    }

    /// Per key, the range of the per-frame motion (px per 1/30 s) of its visible draws.
    struct Speeds { var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity, site = "" }

    static func addSpeeds(_ a: [SceneDraw], _ b: [SceneDraw], w: Double, h: Double, into speeds: inout [String: Speeds]) {
        for (d, match) in nearest(a, b, w: w, h: h) {
            guard let m = match, visible(m, w: w, h: h), m.distance(to: d) <= 0.008 * max(w, h) else { continue }
            let vx = d.cx - m.cx, vy = d.cy - m.cy
            var s = speeds[d.key] ?? Speeds(site: d.site)
            s.minX = min(s.minX, vx); s.maxX = max(s.maxX, vx); s.minY = min(s.minY, vy); s.maxY = max(s.maxY, vy)
            speeds[d.key] = s
        }
    }

    /// Late speeds outside the early range (with a margin of a quarter of the range plus 1 px/s).
    static func drift(early: [String: Speeds], late: [String: Speeds], at t: Double) -> [String] {
        late.compactMap { key, l in
            guard let e = early[key] else { return nil }
            let mx = 0.25 * (e.maxX - e.minX) + 1.0 / 30, my = 0.25 * (e.maxY - e.minY) + 1.0 / 30
            guard l.minX < e.minX - mx || l.maxX > e.maxX + mx || l.minY < e.minY - my || l.maxY > e.maxY + my else { return nil }
            let fps = 1 / frameDt
            return String(format: "t=%.1f: scene.js:%@ moves at %.1f…%.1f, %.1f…%.1f px/s (x, y); in the first half hour %.1f…%.1f, %.1f…%.1f",
                          t, l.site, l.minX * fps, l.maxX * fps, l.minY * fps, l.maxY * fps, e.minX * fps, e.maxX * fps, e.minY * fps, e.maxY * fps)
        }
    }
}
