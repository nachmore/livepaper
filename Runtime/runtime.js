/*
 * LivePaper runtime v1 — hosts exactly one scene in a WKWebView (screen saver, app previews,
 * render server). Scene authors: see SCENE_API.md and livepaper.d.ts next to this file.
 *
 * A scene file calls LivePaper.scene({...}) exactly once. The runtime owns everything else:
 *   - the full-viewport stage canvas ('2d' | 'webgl' | 'webgl2'), DPR and resize handling
 *   - the frame loop: fps cap (also halves 120 Hz displays), dt clamping, pause when hidden
 *   - deterministic capture modes: still (#still=1&t=12), bench (#bench=120&t=26), manual
 *   - the Apple-style lock-screen clock overlay and the clock hand-off with the system lock UI
 *   - the performance governor (fps + render scale from the host's profile, adaptive step-down)
 *   - error/ready/stats reporting to the native host (webkit.messageHandlers.livepaper)
 *
 * Configuration, lowest to highest precedence:
 *   built-in defaults < window.LIVEPAPER_CONFIG (injected by the host at document start)
 *   < URL hash (#still=1&t=12, for development) < LivePaper.host.config({...}) at run time.
 * The compiler (LivePaperCore SceneCompiler) also injects window.LIVEPAPER_SCENE (manifest
 * metadata) and window.LIVEPAPER_ASSETS (assets/ as data: URLs) before this file.
 */
(function () {
  'use strict';
  if (window.LivePaper && window.LivePaper.version) return; // inlined twice: keep the first

  var VERSION = '1.0.0';
  var API_VERSION = 1;
  var SCENE_META = window.LIVEPAPER_SCENE || {};
  var ASSETS = window.LIVEPAPER_ASSETS || {};
  var CLOCK_POSITIONS = { top: 1, 'bottom-left': 1, 'bottom-right': 1, none: 1 };
  var FADE_MS = 300;

  // ---------------------------------------------------------------------------------- config
  var TYPES = {
    still: 'bool', t: 'num', bench: 'num', manual: 'bool',
    clock: 'bool', clockPosition: 'str', hour12: 'bool?', clockTime: 'str',
    fps: 'num', scale: 'num', dprMax: 'num', performance: 'str',
    power: 'str', lowPower: 'bool', reducedMotion: 'bool', preview: 'bool', lockUI: 'bool',
    seed: 'num', debug: 'bool', governor: 'bool', budgetMs: 'num', statsEvery: 'num'
  };
  var cfg = {
    still: false, t: 0, bench: 0, manual: false,
    clock: true, clockPosition: null, hour12: null, clockTime: null,
    fps: null, scale: null, dprMax: 2, performance: 'automatic',
    power: 'ac', lowPower: false, reducedMotion: false, preview: false, lockUI: false,
    seed: 1, debug: false, governor: true, budgetMs: 0, statsEvery: 0
  };
  function coerce(type, v) {
    if (type === 'num') { var n = Number(v); return isFinite(n) ? n : undefined; }
    if (type === 'str') return v == null ? null : String(v);
    if (type === 'bool?' && (v === null || v === 'null' || v === 'auto')) return null;
    if (typeof v === 'string') return v === '' || v === '1' || v === 'true';
    return !!v;
  }
  function applyConfig(obj) {
    if (!obj || typeof obj !== 'object') return;
    Object.keys(obj).forEach(function (k) {
      if (!(k in TYPES)) return;
      var v = coerce(TYPES[k], obj[k]);
      if (v !== undefined) cfg[k] = v;
    });
  }
  applyConfig(window.LIVEPAPER_CONFIG);
  (function () {
    var fromHash = {};
    try { new URLSearchParams(location.hash.replace(/^#/, '')).forEach(function (v, k) { fromHash[k] = v; }); } catch (e) { /* no hash */ }
    applyConfig(fromHash);
  })();

  var MODE = cfg.bench > 0 ? 'bench' : cfg.still ? 'still' : cfg.manual ? 'manual' : 'live';
  var CAPTURE = MODE !== 'live';

  // Environment the scene can adapt to (lp.env). The host keeps it current via LivePaper.host.power().
  var reducedMotionQuery = null;
  try { reducedMotionQuery = window.matchMedia('(prefers-reduced-motion: reduce)'); } catch (e) { /* old engine */ }
  var env = { power: 'ac', lowPower: false, reducedMotion: false, preview: false };
  function refreshEnv() {
    env.power = cfg.power === 'battery' ? 'battery' : 'ac';
    env.lowPower = !!cfg.lowPower;
    env.preview = !!cfg.preview;
    env.reducedMotion = !!cfg.reducedMotion || !!(reducedMotionQuery && reducedMotionQuery.matches);
  }
  refreshEnv();

  // Performance profiles, mirroring LPPerformanceProfile.resolved(onBatteryOrLowPower:) in Swift.
  var PROFILES = { best: [60, 1], balanced: [60, 0.75], battery: [30, 0.75] };
  function profileTargets() {
    var p = cfg.performance;
    var saver = env.power === 'battery' || env.lowPower;
    var r = p === 'automatic' || !PROFILES[p] ? (saver ? PROFILES.battery : PROFILES.best) : PROFILES[p];
    return {
      fps: clamp(cfg.fps != null ? cfg.fps : r[0], 10, 120),
      scale: clamp(cfg.scale != null ? cfg.scale : r[1], 0.25, 1)
    };
  }

  // ---------------------------------------------------------------------------------- errors
  var errorLog = [], errorCounts = {}, errorTotal = 0, errorBox = null;
  function post(msg) {
    try {
      var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.livepaper;
      if (h) h.postMessage(msg);
    } catch (e) { /* host gone */ }
  }
  // Maps an error to "scene.js:LINE:COL". Inline scripts carry //# sourceURL=scene.js; as a fallback
  // the compiler tells us the document line where scene.js starts (LIVEPAPER_SCENE.line).
  function locate(stack, filename, line, col) {
    var m = /scene\.js:(\d+):(\d+)/.exec(stack || '');
    if (m) return 'scene.js:' + m[1] + ':' + m[2];
    if (line && /scene\.js$/.test(filename || '')) return 'scene.js:' + line + ':' + (col || 0);
    if (/livepaper-runtime\.js$/.test(filename || '')) return 'runtime.js:' + line;
    if (line && SCENE_META.line && line >= SCENE_META.line) return 'scene.js:' + (line - SCENE_META.line + 1) + ':' + (col || 0);
    return line ? 'line ' + line : '';
  }
  function describe(err) {
    if (err && typeof err === 'object' && 'message' in err) {
      var name = err.name && err.name !== 'Error' ? err.name + ': ' : '';
      var where = locate(err.stack, err.sourceURL, err.line, err.column);
      return name + err.message + (where ? ' (' + where + ')' : '');
    }
    return String(err);
  }
  function reportError(where, err, location) {
    var text = (where ? where + ': ' : '') + (typeof err === 'string' ? err : describe(err)) + (location ? ' (' + location + ')' : '');
    errorTotal++;
    var seen = errorCounts[text] = (errorCounts[text] || 0) + 1;
    if (seen > 3 || errorLog.length >= 50) return; // the same error every frame is reported only a few times
    errorLog.push(text);
    post({ type: 'error', message: text });
    try { console.error('[livepaper] ' + text); } catch (e) { /* no console */ }
    if (!errorBox && document.body) {
      errorBox = document.createElement('pre');
      errorBox.id = 'livepaper-errors';
      errorBox.style.cssText = 'position:fixed;left:12px;bottom:12px;right:12px;margin:0;z-index:3;' +
        'font:12px/1.35 ui-monospace,Menlo,monospace;color:#ff6b6b;white-space:pre-wrap;pointer-events:none;' +
        (cfg.debug ? '' : 'display:none;');
      document.body.appendChild(errorBox);
    }
    if (errorBox) errorBox.textContent += text + '\n';
  }
  window.addEventListener('error', function (e) {
    var msg = e.message || 'error';
    reportError('', msg, locate(e.error && e.error.stack, e.filename, e.lineno, e.colno));
  });
  window.addEventListener('unhandledrejection', function (e) { reportError('unhandled promise rejection', e.reason); });
  function guarded(where, fn) {
    try { return fn(); } catch (e) { reportError(where, e); }
  }

  // ---------------------------------------------------------------------------------- math
  var TAU = Math.PI * 2;
  function clamp(x, a, b) { return x < a ? a : x > b ? b : x; }
  function lerp(a, b, t) { return a + (b - a) * t; }
  function invLerp(a, b, x) { return a === b ? 0 : (x - a) / (b - a); }
  function fract(x) { return x - Math.floor(x); }
  function smoothstep(a, b, x) { var t = clamp((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); }
  var ease = {
    linear: function (t) { return t; },
    inQuad: function (t) { return t * t; },
    outQuad: function (t) { return 1 - (1 - t) * (1 - t); },
    inOutQuad: function (t) { return t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2; },
    inCubic: function (t) { return t * t * t; },
    outCubic: function (t) { return 1 - Math.pow(1 - t, 3); },
    inOutCubic: function (t) { return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2; },
    inOutSine: function (t) { return -(Math.cos(Math.PI * t) - 1) / 2; },
    outExpo: function (t) { return t >= 1 ? 1 : 1 - Math.pow(2, -10 * t); },
    outBack: function (t) { var c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2); }
  };
  // Small, fast, seedable PRNG returning [0, 1).
  function mulberry32(seed) {
    var a = seed >>> 0;
    return function () {
      a = (a + 0x6D2B79F5) >>> 0;
      var t = a;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  // Integer lattice hash in [0, 1). Integer maths keeps it exact for any coordinate (no sin()).
  function hash2(x, y) {
    var h = Math.imul(x | 0, 0x27d4eb2d) ^ Math.imul(y | 0, 0x165667b1);
    h = Math.imul(h ^ (h >>> 15), 0x85ebca6b);
    h = Math.imul(h ^ (h >>> 13), 0xc2b2ae35);
    return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
  }
  // Smooth value noise in [0, 1]. Deterministic.
  function noise2(x, y) {
    var xi = Math.floor(x), yi = Math.floor(y), xf = x - xi, yf = y - yi;
    var u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf);
    var a = hash2(xi, yi), b = hash2(xi + 1, yi), c = hash2(xi, yi + 1), d = hash2(xi + 1, yi + 1);
    return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v;
  }
  function noise1(x) { return noise2(x, 0.5); }
  // Fractal (octave) noise in [0, 1].
  function fbm2(x, y, octaves) {
    var s = 0, amp = 0.5, f = 1, n = octaves || 4, norm = 0;
    for (var i = 0; i < n; i++) { s += amp * noise2(x * f + i * 17.3, y * f); norm += amp; amp *= 0.5; f *= 2.03; }
    return s / norm;
  }

  // ---------------------------------------------------------------------------------- colour
  function hexToRgb(hex) {
    var h = String(hex).replace('#', '');
    if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
    var n = parseInt(h, 16);
    return isFinite(n) ? [(n >> 16) & 255, (n >> 8) & 255, n & 255] : [255, 255, 255];
  }
  function rgba(hex, a) { var c = hexToRgb(hex); return 'rgba(' + c[0] + ',' + c[1] + ',' + c[2] + ',' + (a == null ? 1 : a) + ')'; }
  function mix(hexA, hexB, t) {
    var a = hexToRgb(hexA), b = hexToRgb(hexB);
    return 'rgb(' + Math.round(lerp(a[0], b[0], t)) + ',' + Math.round(lerp(a[1], b[1], t)) + ',' + Math.round(lerp(a[2], b[2], t)) + ')';
  }

  // ---------------------------------------------------------------------------------- drawing
  // Offscreen canvas for pre-rendered layers, sized in CSS px and pre-scaled by dpr.
  function layer(cssW, cssH, dpr) {
    var d = dpr || 1;
    var c = document.createElement('canvas');
    c.width = Math.max(1, Math.round(cssW * d));
    c.height = Math.max(1, Math.round(cssH * d));
    var g = c.getContext('2d');
    g.setTransform(d, 0, 0, d, 0, 0);
    return { canvas: c, ctx: g, w: cssW, h: cssH, dpr: d };
  }
  // Cached radial glow sprites: one drawImage is far cheaper than shadowBlur or ctx.filter.
  var spriteCache = {};
  function glowSprite(color, size, falloff) {
    size = Math.max(4, Math.round(size || 128));
    falloff = falloff == null ? 2 : falloff;
    var key = color + '|' + size + '|' + falloff;
    if (spriteCache[key]) return spriteCache[key];
    var c = document.createElement('canvas');
    c.width = c.height = size;
    var g = c.getContext('2d');
    var grad = g.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
    for (var i = 0; i <= 8; i++) {
      var s = i / 8;
      grad.addColorStop(s, rgba(color, Math.pow(1 - s, falloff)));
    }
    g.fillStyle = grad;
    g.fillRect(0, 0, size, size);
    spriteCache[key] = c;
    return c;
  }
  // Additive glow blob centred at (x, y) with radius r (CSS px).
  function glow(ctx, x, y, r, color, alpha, falloff) {
    if (!(r > 0) || !(alpha > 0)) return;
    var spr = glowSprite(color, 128, falloff);
    var prevA = ctx.globalAlpha, prevC = ctx.globalCompositeOperation;
    ctx.globalCompositeOperation = 'lighter';
    ctx.globalAlpha = clamp(alpha, 0, 1);
    ctx.drawImage(spr, x - r, y - r, r * 2, r * 2);
    ctx.globalAlpha = prevA;
    ctx.globalCompositeOperation = prevC;
  }
  // Parallax starfield. Positions are normalised (0..1) so it survives resizes. Stars are drawn
  // in a handful of batched paths (one fill per brightness bucket), not one draw call per star.
  function makeStars(opts) {
    opts = opts || {};
    var rnd = mulberry32(opts.seed == null ? 7 : opts.seed);
    var n = Math.max(0, Math.round(opts.count == null ? 400 : opts.count));
    var tint = opts.tint !== false, twinkle = opts.twinkle == null ? 1 : opts.twinkle;
    var glowAbove = opts.glow == null ? 0.93 : opts.glow;
    var stars = [];
    for (var i = 0; i < n; i++) {
      stars.push({ x: rnd(), y: rnd(), z: Math.pow(rnd(), 2.2), tw: rnd() * TAU, hue: rnd() });
    }
    var BUCKETS = 6;
    var colours = ['255,255,255', '200,215,255', '255,226,200'];
    return {
      stars: stars,
      draw: function (ctx, lp, o) {
        o = o || {};
        var rx = o.x || 0, ry = o.y || 0, rw = o.w || lp.w, rh = o.h || lp.h;
        var dx = o.dx || 0, dy = o.dy || 0, bright = o.brightness == null ? 1 : o.brightness;
        var count = Math.round(stars.length * clamp(o.fraction == null ? 1 : o.fraction, 0, 1));
        var unit = Math.max(lp.w, lp.h) / 1600 * (o.size || 1);
        var t = lp.t, b, c, k;
        var paths = [];
        for (b = 0; b < BUCKETS * 3; b++) paths.push(null);
        var glows = [];
        for (var i = 0; i < count; i++) {
          var s = stars[i];
          var depth = 0.2 + s.z * 0.8;
          var x = rx + fract(s.x + dx * depth / rw) * rw;
          var y = ry + fract(s.y + dy * depth / rh) * rh;
          var tw = 1 - twinkle * 0.35 * (0.5 + 0.5 * Math.sin(t * (0.6 + s.z * 2.2) + s.tw));
          var a = (0.25 + 0.75 * s.z) * tw * bright;
          if (a <= 0.02) continue;
          var r = (0.45 + s.z * 1.5) * unit;
          c = !tint ? 0 : s.hue > 0.85 ? 1 : s.hue < 0.08 ? 2 : 0;
          k = c * BUCKETS + Math.min(BUCKETS - 1, Math.floor(clamp(a, 0, 1) * BUCKETS));
          if (!paths[k]) { paths[k] = new Path2D(); }
          paths[k].rect(x - r / 2, y - r / 2, r, r);
          if (s.z > glowAbove) glows.push(x, y, r * 6, a * 0.35);
        }
        var prevA = ctx.globalAlpha;
        for (k = 0; k < paths.length; k++) {
          if (!paths[k]) continue;
          c = Math.floor(k / BUCKETS);
          ctx.globalAlpha = prevA * ((k % BUCKETS) + 0.5) / BUCKETS;
          ctx.fillStyle = 'rgb(' + colours[c] + ')';
          ctx.fill(paths[k]);
        }
        ctx.globalAlpha = prevA;
        for (var g = 0; g < glows.length; g += 4) glow(ctx, glows[g], glows[g + 1], glows[g + 2], '#bcd4ff', glows[g + 3]);
      }
    };
  }

  // ---------------------------------------------------------------------------------- assets
  // assets/ files are inlined by the compiler as data: URLs. Images and fonts are decoded before
  // setup() runs so scenes (and deterministic stills) never see a half-loaded asset.
  var images = {}, textCache = {};
  function mimeOf(url) { var m = /^data:([^;,]+)/.exec(url || ''); return m ? m[1] : ''; }
  function fontFamilyFor(name) { return name.replace(/^.*\//, '').replace(/\.[^.]+$/, ''); }
  var assetsReady = (function () {
    var pending = [];
    Object.keys(ASSETS).forEach(function (name) {
      var url = ASSETS[name], mime = mimeOf(url);
      if (/^image\//.test(mime)) {
        var img = new Image();
        img.src = url;
        images[name] = img;
        if (img.decode) pending.push(img.decode().catch(function () { reportError('asset', name + ' could not be decoded as an image'); }));
      } else if (/^font\//.test(mime) && window.FontFace && document.fonts) {
        var face = new FontFace(fontFamilyFor(name), 'url(' + url + ')');
        pending.push(face.load().then(function (f) { document.fonts.add(f); }, function () { reportError('asset', name + ' could not be loaded as a font'); }));
      }
    });
    return Promise.all(pending);
  })();
  function asset(name) { return Object.prototype.hasOwnProperty.call(ASSETS, name) ? ASSETS[name] : null; }
  function image(name) { return images[name] || null; }
  function text(name) {
    if (name in textCache) return textCache[name];
    var url = asset(name);
    if (!url) return null;
    var comma = url.indexOf(','), head = url.slice(0, comma), body = url.slice(comma + 1), out;
    if (/;base64$/.test(head)) {
      var bin = atob(body), bytes = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      out = new TextDecoder('utf-8').decode(bytes);
    } else {
      out = decodeURIComponent(body);
    }
    textCache[name] = out;
    return out;
  }

  // ---------------------------------------------------------------------------------- clock
  var DATE_FMT = new Intl.DateTimeFormat(undefined, { weekday: 'long', month: 'long', day: 'numeric' });
  var TIME_FMT = null;
  function timeFormatter() {
    if (!TIME_FMT) {
      var o = { hour: 'numeric', minute: '2-digit' };
      if (cfg.hour12 !== null) o.hour12 = !!cfg.hour12;
      TIME_FMT = new Intl.DateTimeFormat(undefined, o);
    }
    return TIME_FMT;
  }
  function clockNow() {
    if (cfg.clockTime != null && cfg.clockTime !== '') {
      var fixed = /^\d+$/.test(cfg.clockTime) ? new Date(Number(cfg.clockTime)) : new Date(cfg.clockTime);
      if (!isNaN(fixed.getTime())) return fixed;
    }
    return new Date();
  }
  // Formatted clock text like the macOS lock screen: "9:41" (no AM/PM) and "Thursday, 13 November".
  function clockParts(d) {
    d = d || clockNow();
    var time = timeFormatter().formatToParts(d)
      .filter(function (p) { return p.type !== 'dayPeriod'; })
      .map(function (p) { return p.value; }).join('').trim();
    return { time: time, date: DATE_FMT.format(d), hours: d.getHours(), minutes: d.getMinutes(), seconds: d.getSeconds(), now: d };
  }

  // ---------------------------------------------------------------------------------- stage
  var stage = document.createElement('canvas');
  var overlay = document.createElement('canvas');
  stage.id = 'livepaper-stage';
  overlay.id = 'livepaper-clock';
  var styleEl = document.createElement('style');
  styleEl.textContent = 'html,body{margin:0;width:100%;height:100%;background:#000;overflow:hidden;cursor:none}' +
    '#livepaper-stage,#livepaper-clock{position:fixed;left:0;top:0;width:100%;height:100%;display:block}' +
    '#livepaper-clock{pointer-events:none;z-index:2;transition:opacity ' + FADE_MS + 'ms ease}';
  (document.head || document.documentElement).appendChild(styleEl);

  var scene = null, lp = null, booted = false;
  var raf = 0, running = false, hostPaused = false, lastFrame = 0, lastRaf = 0, vsyncMs = 1000 / 60;
  // cfg.lockUI: the host loads us while the lock UI is already up (start with the clock hidden).
  var clockTimer = 0, clockText = '', lockUIShowing = !!cfg.lockUI, overlayForcedHidden = false;
  var fade = { from: 1, to: 1, start: 0 };
  var targets = profileTargets();
  var stats = { fps: 0, frameMs: 0, framesInWindow: 0, windowStart: 0, sinceStart: 0 };

  function clockPosition() {
    var p = (scene && scene.clock) || cfg.clockPosition || SCENE_META.clock || 'top';
    return CLOCK_POSITIONS[p] ? p : 'top';
  }
  // Whether a clock should currently be visible (runtime overlay, or the scene's own clock).
  function clockWanted() { return !!cfg.clock && !lockUIShowing; }
  function clockSizes(w, h) {
    var time = clamp(Math.min(w * 0.11, h * 0.15), 40, 210);
    return { time: time, date: Math.max(13, time * 0.2) };
  }
  // Region a clock occupies in CSS px for a given position (top centre = where macOS draws its own).
  function rectFor(position, w, h) {
    var s = clockSizes(w, h);
    var bw = s.time * 3.4, bh = s.date * 1.6 + s.time * 1.1;
    var pad = Math.max(24, Math.min(w, h) * 0.06);
    if (position === 'bottom-left') return { x: pad, y: h - pad - bh, w: bw, h: bh };
    if (position === 'bottom-right') return { x: w - pad - bw, y: h - pad - bh, w: bw, h: bh };
    return { x: w / 2 - bw / 2, y: h * 0.07, w: bw, h: bh };
  }
  function runtimeClockRect() {
    var p = clockPosition();
    return !cfg.clock || p === 'none' || !lp ? null : rectFor(p, lp.w, lp.h);
  }

  function measure() {
    var w = Math.max(1, window.innerWidth), h = Math.max(1, window.innerHeight);
    var sysDpr = Math.min(cfg.dprMax || 2, window.devicePixelRatio || 1);
    var dpr = sysDpr * governor.scale();
    lp.w = w; lp.h = h; lp.dpr = dpr; lp.scale = governor.scale();
    lp.pw = Math.max(1, Math.round(w * dpr)); lp.ph = Math.max(1, Math.round(h * dpr));
    lp.cx = w / 2; lp.cy = h / 2;
    lp.min = Math.min(w, h); lp.max = Math.max(w, h); lp.aspect = w / h;
    if (stage.width !== lp.pw) stage.width = lp.pw;
    if (stage.height !== lp.ph) stage.height = lp.ph;
    var ow = Math.round(w * sysDpr), oh = Math.round(h * sysDpr);
    if (overlay.width !== ow || overlay.height !== oh) { overlay.width = ow; overlay.height = oh; }
    lp.clockRect = runtimeClockRect();
    overlayDpr = sysDpr;
    clockText = '';
  }
  var overlayDpr = 1;

  function drawClock(force) {
    var r = lp && lp.clockRect;
    var p = r ? clockParts() : null;
    var key = p ? p.date + '|' + p.time + '|' + overlay.width + 'x' + overlay.height : '';
    if (!force && key === clockText) return;
    clockText = key;
    var o = overlay.getContext('2d');
    o.setTransform(1, 0, 0, 1, 0, 0);
    o.clearRect(0, 0, overlay.width, overlay.height);
    if (!r) return;
    o.setTransform(overlayDpr, 0, 0, overlayDpr, 0, 0);
    var s = clockSizes(lp.w, lp.h), pos = clockPosition();
    var align = pos === 'bottom-left' ? 'left' : pos === 'bottom-right' ? 'right' : 'center';
    var x = align === 'left' ? r.x : align === 'right' ? r.x + r.w : r.x + r.w / 2;
    var fam = '-apple-system, "SF Pro Display", system-ui, "Helvetica Neue", Helvetica, Arial, sans-serif';
    o.textAlign = align;
    o.textBaseline = 'alphabetic';
    // A soft dark shadow keeps the white text legible on any scene. Drawn at most once a minute,
    // so shadowBlur is fine here (it is not fine in a per-frame draw()).
    o.shadowColor = 'rgba(0,0,0,0.28)';
    o.fillStyle = (scene && scene.clockColor) || 'rgba(255,255,255,0.9)';
    o.shadowBlur = s.date * 0.5;
    o.font = '600 ' + s.date.toFixed(1) + 'px ' + fam;
    var dateY = r.y + s.date * 1.1;
    o.fillText(p.date, x, dateY);
    o.shadowBlur = s.time * 0.08;
    o.font = '700 ' + s.time.toFixed(1) + 'px ' + fam;
    o.fillText(p.time, x, dateY + s.time * 0.98);
    o.shadowBlur = 0;
  }
  function scheduleClock() {
    clearTimeout(clockTimer);
    if (CAPTURE || !running) return;
    clockTimer = setTimeout(function () { drawClock(false); scheduleClock(); }, 1000 - (Date.now() % 1000) + 5);
  }
  function applyClockVisibility(animate) {
    var want = clockWanted();
    var now = performance.now();
    var current = clockAlphaAt(now);
    fade = animate && running ? { from: current, to: want ? 1 : 0, start: now } : { from: want ? 1 : 0, to: want ? 1 : 0, start: 0 };
    overlay.style.transition = animate ? '' : 'none';
    overlay.style.opacity = want && !overlayForcedHidden ? '1' : '0';
    if (!animate) { void overlay.offsetWidth; overlay.style.transition = ''; }
    if (lp) { lp.clockVisible = want; lp.clockAlpha = clockAlphaAt(now); }
  }
  function clockAlphaAt(now) {
    if (fade.from === fade.to) return fade.to;
    var k = clamp((now - fade.start) / FADE_MS, 0, 1);
    return lerp(fade.from, fade.to, ease.inOutSine(k));
  }

  // ---------------------------------------------------------------------------------- governor
  // Keeps live scenes within their frame budget: when update()+draw() stays over budget for ~2 s the
  // render scale steps down (x0.85, floor 0.6) and lp.quality drops (scenes may thin particles);
  // with sustained headroom it steps back up. Never active in capture modes (they must be exact).
  var governor = (function () {
    var MAX_LEVEL = 4, WINDOW_MS = 500, DOWN_WINDOWS = 4;
    var level = 0, acc = 0, n = 0, winStart = 0, over = 0, under = 0, upWindows = 16, lastUp = -1e9, quietUntil = 0;
    function active() { return MODE === 'live' && cfg.governor; }
    function scaleFor(l) {
      var base = targets.scale;
      return Math.max(Math.min(0.6, base), base * Math.pow(0.85, l));
    }
    function budget() { return cfg.budgetMs > 0 ? cfg.budgetMs : 0.5 * 1000 / targets.fps; }
    function setLevel(l, reason) {
      var before = scaleFor(level);
      level = clamp(l, 0, MAX_LEVEL);
      if (lp) lp.quality = 1 - 0.125 * level;
      if (lp && scaleFor(level) !== before) resizeAll();
      quietUntil = performance.now() + 1500;
      post({ type: 'stats', reason: reason, level: level, scale: scaleFor(level), quality: 1 - 0.125 * level, frameMs: round2(stats.frameMs), fps: stats.fps });
    }
    return {
      scale: function () { return active() ? scaleFor(level) : targets.scale; },
      level: function () { return level; },
      budget: budget,
      // Ignore frames for a moment after (re)starts and resizes: JIT warm-up and layer rebuilds are not steady state.
      quiet: function (ms) { quietUntil = Math.max(quietUntil, performance.now() + ms); acc = 0; n = 0; winStart = 0; over = 0; under = 0; },
      reset: function () { level = 0; if (lp) lp.quality = 1; this.quiet(1500); },
      sample: function (ms, now) {
        if (!active() || now < quietUntil) return;
        if (!winStart) winStart = now;
        acc += ms; n++;
        if (now - winStart < WINDOW_MS) return;
        var avg = acc / n, b = budget();
        acc = 0; n = 0; winStart = now;
        if (avg > b) { over++; under = 0; } else if (avg < b * 0.55) { under++; over = 0; } else { over = 0; under = 0; }
        if (over >= DOWN_WINDOWS && level < MAX_LEVEL) {
          // Stepping down right after a step up means the step up was premature: wait longer next time.
          if (now - lastUp < 15000) upWindows = Math.min(240, upWindows * 2);
          over = 0;
          setLevel(level + 1, 'governor-down');
        } else if (under >= upWindows && level > 0) {
          under = 0; lastUp = now;
          setLevel(level - 1, 'governor-up');
        }
      }
    };
  })();
  function round2(x) { return Math.round(x * 100) / 100; }

  // ---------------------------------------------------------------------------------- frame loop
  function step(dt) {
    lp.dt = dt;
    lp.t += dt;
    lp.frame++;
    lp.clockAlpha = clockAlphaAt(performance.now());
    if (scene.update) guarded('update', function () { scene.update(lp, dt); });
  }
  function render() {
    if (lp.ctx) {
      lp.ctx.setTransform(lp.dpr, 0, 0, lp.dpr, 0, 0);
      lp.ctx.globalAlpha = 1;
      lp.ctx.globalCompositeOperation = 'source-over';
    } else if (lp.gl) {
      lp.gl.viewport(0, 0, lp.pw, lp.ph);
    }
    guarded('draw', function () { scene.draw(lp); });
  }
  function frame(dt) {
    var t0 = performance.now();
    step(dt);
    render();
    var t1 = performance.now(), ms = t1 - t0;
    stats.frameMs = stats.frameMs ? stats.frameMs + (ms - stats.frameMs) * 0.05 : ms;
    stats.framesInWindow++;
    if (!stats.windowStart) stats.windowStart = t1;
    if (t1 - stats.windowStart >= 1000) {
      stats.fps = Math.round(stats.framesInWindow * 1000 / (t1 - stats.windowStart) * 10) / 10;
      stats.framesInWindow = 0; stats.windowStart = t1;
      stats.sinceStart++;
      if (cfg.statsEvery > 0 && stats.sinceStart % Math.max(1, Math.round(cfg.statsEvery)) === 0) post(statsMessage('periodic'));
    }
    governor.sample(ms, t1);
  }
  function tick(now) {
    raf = requestAnimationFrame(tick);
    // Estimate the display refresh interval from rAF cadence (60 Hz, 120 Hz ProMotion, ...).
    if (lastRaf) { var d = now - lastRaf; if (d > 2 && d < 100) vsyncMs += (d - vsyncMs) * 0.1; }
    lastRaf = now;
    if (!lastFrame) { lastFrame = now; return; }
    var elapsed = now - lastFrame;
    // fps cap: render when a whole frame interval has (almost) passed. Half a vsync of tolerance makes
    // 120 Hz displays run a 60 fps cap at exactly every other refresh, and a 30 fps cap every 4th.
    if (elapsed < 1000 / targets.fps - vsyncMs * 0.5) return;
    lastFrame = now;
    frame(Math.min(0.1, elapsed / 1000));
  }
  function shouldRun() { return booted && MODE === 'live' && !hostPaused && !document.hidden; }
  function sync() {
    if (shouldRun() === running) return;
    if (shouldRun()) {
      running = true; lastFrame = 0; lastRaf = 0;
      governor.quiet(1500);
      raf = requestAnimationFrame(tick);
      drawClock(true); scheduleClock();
    } else {
      running = false;
      cancelAnimationFrame(raf);
      clearTimeout(clockTimer);
    }
  }
  function resizeAll() {
    measure();
    if (scene.resize) guarded('resize', function () { scene.resize(lp); });
    drawClock(true);
    governor.quiet(1000);
    if (!running && booted) render();
  }
  function flush() {
    try {
      if (lp.ctx) lp.ctx.getImageData(0, 0, 1, 1);
      else if (lp.gl) { var px = new Uint8Array(4); lp.gl.readPixels(0, 0, 1, 1, lp.gl.RGBA, lp.gl.UNSIGNED_BYTE, px); }
    } catch (e) { /* tainted or lost context */ }
  }
  function stepTo(target) {
    var sdt = 1 / 30;
    while (lp.t + sdt <= target + 1e-9) step(sdt);
    if (target - lp.t > 1e-6) step(target - lp.t);
  }
  function debugClockRect() {
    if (!lp) return null;
    var r = lp.clockRect, kind = 'runtime';
    // Scenes that draw their own clock (or have the clock off) still get the macOS lock UI clock at
    // top centre when the user wakes the screen, so that is the region that must stay calm.
    if (!r) { r = rectFor('top', lp.w, lp.h); kind = 'system'; }
    return { x: r.x, y: r.y, w: r.w, h: r.h, kind: kind, position: clockPosition() };
  }
  function statsMessage(reason) {
    return {
      type: 'stats', reason: reason, mode: MODE, frame: lp ? lp.frame : 0, t: lp ? round2(lp.t) : 0,
      fps: stats.fps, frameMs: round2(stats.frameMs), budgetMs: round2(governor.budget()),
      targetFps: targets.fps, scale: governor.scale(), quality: lp ? lp.quality : 1, level: governor.level(),
      running: running, w: lp ? lp.w : 0, h: lp ? lp.h : 0, dpr: lp ? lp.dpr : 0, errors: errorTotal
    };
  }
  function markReady(extra) {
    document.documentElement.setAttribute('data-livepaper', 'ready');
    var msg = { type: 'ready', mode: MODE, scene: SCENE_META.id || null, t: lp ? lp.t : 0, errors: errorTotal, clockRect: debugClockRect() };
    if (extra) Object.keys(extra).forEach(function (k) { msg[k] = extra[k]; });
    post(msg);
  }

  function boot() {
    if (booted || !scene) return;
    booted = true;
    document.body.appendChild(stage);
    document.body.appendChild(overlay);
    if (CAPTURE) {
      // Capture modes must be reproducible: seed Math.random too (lp.rand is always seeded).
      Math.random = mulberry32((cfg.seed ^ 0x5bd1e995) >>> 0);
    }
    lp = {
      canvas: stage, ctx: null, gl: null, context: '2d',
      w: 0, h: 0, dpr: 1, pw: 0, ph: 0, cx: 0, cy: 0, min: 0, max: 0, aspect: 1, scale: 1,
      t: 0, dt: 0, frame: 0, mode: MODE,
      rand: mulberry32(cfg.seed || 1), quality: 1,
      clockRect: null, clockVisible: clockWanted(), clockAlpha: clockWanted() ? 1 : 0,
      env: env, cfg: cfg, util: util
    };
    var kind = scene.context || '2d';
    var opts = scene.contextOptions || (kind === '2d' ? { alpha: false } :
      { alpha: false, antialias: true, premultipliedAlpha: false, powerPreference: 'low-power' });
    var ctx = stage.getContext(kind, opts);
    if (!ctx && kind === 'webgl2') { kind = 'webgl'; ctx = stage.getContext('webgl', opts); }
    if (!ctx) { reportError('setup', 'could not create a ' + kind + ' context'); markReady({ failed: true }); return; }
    lp.context = kind;
    if (kind === '2d') lp.ctx = ctx; else lp.gl = ctx;
    measure();
    applyClockVisibility(false);
    if (scene.setup) guarded('setup', function () { scene.setup(lp); });
    if (scene.resize) guarded('resize', function () { scene.resize(lp); });
    window.addEventListener('resize', function () { if (booted) resizeAll(); });

    var start = Math.max(0, cfg.t || 0);
    if (MODE === 'bench') {
      var n = Math.max(1, Math.round(cfg.bench));
      stepTo(start);                                   // bench a chosen phase: #bench=120&t=26
      for (var i = 0; i < 10; i++) { step(1 / 60); render(); } // warm-up (JIT, sprite caches)
      flush();
      var t0 = performance.now();
      for (var j = 0; j < n; j++) { step(1 / 60); render(); }
      flush();
      var ms = (performance.now() - t0) / n;
      document.documentElement.setAttribute('data-bench', ms.toFixed(3));
      drawClock(true);
      markReady({ bench: ms, frames: n });
      return;
    }
    if (MODE === 'still' || MODE === 'manual') {
      stepTo(start);
      render();
      drawClock(true);
      markReady();
      return;
    }
    lp.t = start;
    document.addEventListener('visibilitychange', sync);
    if (reducedMotionQuery && reducedMotionQuery.addEventListener) reducedMotionQuery.addEventListener('change', refreshEnv);
    render();
    sync();
    markReady();
  }

  function whenDomReady(fn) {
    if (document.body) fn(); else document.addEventListener('DOMContentLoaded', fn);
  }
  // A scene that never registers (syntax error, exception at top level) must not leave the host
  // waiting for 'ready' until it times out.
  window.addEventListener('load', function () {
    if (scene) return;
    reportError('scene', 'scene.js did not call LivePaper.scene({...}) (look for an earlier error)');
    markReady({ failed: true });
  });

  // ---------------------------------------------------------------------------------- public API
  var util = {
    TAU: TAU, clamp: clamp, lerp: lerp, invLerp: invLerp, fract: fract, smoothstep: smoothstep, ease: ease,
    mulberry32: mulberry32, hash2: hash2, noise1: noise1, noise2: noise2, fbm2: fbm2,
    hexToRgb: hexToRgb, rgba: rgba, mix: mix,
    layer: layer, glowSprite: glowSprite, glow: glow, makeStars: makeStars
  };
  Object.freeze(ease);
  Object.freeze(util);

  var host = {
    // Runtime configuration changes (same keys as LIVEPAPER_CONFIG). Capture-mode keys are ignored.
    config: function (obj) {
      var o = {};
      Object.keys(obj || {}).forEach(function (k) { if (k !== 'still' && k !== 'bench' && k !== 'manual' && k !== 't') o[k] = obj[k]; });
      applyConfig(o);
      if ('hour12' in o) TIME_FMT = null;
      if ('lockUI' in o) lockUIShowing = !!cfg.lockUI;
      refreshEnv();
      retarget();
      if (!lp) return;
      var before = JSON.stringify(lp.clockRect);
      lp.clockRect = runtimeClockRect();
      if (JSON.stringify(lp.clockRect) !== before) resizeAll(); // scenes lay out around the clock
      applyClockVisibility(true);
      drawClock(true);
    },
    pause: function () { hostPaused = true; sync(); },
    resume: function () { hostPaused = false; sync(); },
    // The system lock UI (with Apple's own clock) is being drawn over us: fade our clock out (and tell
    // scenes with their own clock via lp.clockVisible / lp.clockAlpha); false fades it back in.
    lockUI: function (showing) {
      lockUIShowing = !!showing;
      applyClockVisibility(true);
      if (lp && !running && booted) { lp.clockAlpha = clockWanted() ? 1 : 0; render(); }
    },
    power: function (obj) {
      obj = obj || {};
      var o = {};
      ['power', 'lowPower', 'reducedMotion', 'fps', 'scale', 'performance'].forEach(function (k) { if (k in obj) o[k] = obj[k]; });
      applyConfig(o);
      refreshEnv();
      retarget();
    },
    // Manual mode: advance the scene by dt seconds and render one frame (frame-by-frame capture).
    advance: function (dt) {
      if (!lp || MODE !== 'manual') return;
      step(Math.max(0, Number(dt) || 0));
      render();
    }
  };
  function retarget() {
    var next = profileTargets();
    var scaleChanged = next.scale !== targets.scale;
    targets = next;
    if (scaleChanged && lp) { governor.reset(); resizeAll(); }
  }
  Object.freeze(host);

  var debug = {
    clockRect: debugClockRect,
    stats: function () { return statsMessage('query'); },
    errors: function () { return errorLog.slice(); },
    // Render server: hide the clock overlay to measure the luminance behind it.
    overlay: function (visible) { overlayForcedHidden = !visible; overlay.style.transition = 'none'; overlay.style.opacity = visible && clockWanted() ? '1' : '0'; }
  };
  Object.freeze(debug);

  window.LivePaper = Object.freeze({
    version: VERSION,
    api: API_VERSION,
    scene: function (def) {
      if (scene) { reportError('scene', 'LivePaper.scene() was called more than once; only the first scene is used'); return; }
      if (!def || typeof def.draw !== 'function') { reportError('scene', 'LivePaper.scene() needs an object with a draw(lp) function'); return; }
      if (def.context && ['2d', 'webgl', 'webgl2'].indexOf(def.context) < 0) {
        reportError('scene', 'context must be "2d", "webgl" or "webgl2" (got "' + def.context + '")'); return;
      }
      if (def.clock && !CLOCK_POSITIONS[def.clock]) reportError('scene', 'clock must be top, bottom-left, bottom-right or none (got "' + def.clock + '")');
      scene = def;
      assetsReady.then(function () { whenDomReady(boot); }, function () { whenDomReady(boot); });
    },
    util: util,
    clockParts: clockParts,
    asset: asset,
    image: image,
    text: text,
    host: host,
    debug: debug
  });
})();
//# sourceURL=livepaper-runtime.js
