/*
 * Voltron Lock Screens — shared scene runtime.
 *
 * Every scene file calls Voltron.register({...}) exactly once. The runtime owns:
 *   - the full-viewport stage canvas (2d or webgl/webgl2) + DPR / resize handling
 *   - the frame loop (fps cap, pause when hidden, dt clamping)
 *   - "still" mode for deterministic screenshots (steps update() at 1/30 s up to cfg.t)
 *   - "bench" mode (renders N frames synchronously and reports ms/frame)
 *   - the lock-screen clock overlay (separate 2d canvas on top of the stage)
 *   - error reporting (to the native host via webkit.messageHandlers.voltron and the DOM)
 *
 * Config comes from window.VOLTRON_CONFIG (injected by the screen saver) and can be
 * overridden by the URL hash, e.g.  scene.html#still=1&t=12&clock=0&debug=1
 */
(function () {
  'use strict';

  // ------------------------------------------------------------------ config
  var TYPES = {
    clock: 'bool', still: 'bool', debug: 'bool', hour12: 'bool', manual: 'bool',
    t: 'num', fps: 'num', scale: 'num', dprMax: 'num', bench: 'num', seed: 'num'
  };
  var cfg = { clock: true, still: false, debug: false, hour12: null, manual: false, t: 0, fps: 60, scale: 1, dprMax: 2, bench: 0, seed: 1 };
  var injected = window.VOLTRON_CONFIG || {};
  Object.keys(injected).forEach(function (k) { if (k in TYPES) cfg[k] = injected[k]; });
  new URLSearchParams(location.hash.replace(/^#/, '')).forEach(function (v, k) {
    if (!(k in TYPES)) return;
    cfg[k] = TYPES[k] === 'bool' ? (v === '' || v === '1' || v === 'true') : Number(v);
  });
  cfg.fps = Math.max(10, Math.min(120, cfg.fps || 60));
  cfg.scale = Math.max(0.25, Math.min(1, cfg.scale || 1));

  // ------------------------------------------------------------------ errors
  var errorBox = null, errorCount = 0;
  function post(msg) {
    try {
      var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.voltron;
      if (h) h.postMessage(msg);
    } catch (e) { /* ignore */ }
  }
  function reportError(message) {
    errorCount++;
    if (errorCount > 20) return;
    post({ type: 'error', message: String(message) });
    try { console.error('[voltron] ' + message); } catch (e) { /* ignore */ }
    if (!errorBox && document.body) {
      errorBox = document.createElement('pre');
      errorBox.id = 'voltron-errors';
      errorBox.style.cssText = 'position:fixed;left:8px;bottom:8px;margin:0;z-index:9;font:12px ui-monospace,monospace;color:#ff5a5a;white-space:pre-wrap;' +
        (cfg.debug ? '' : 'display:none;');
      document.body.appendChild(errorBox);
    }
    if (errorBox) errorBox.textContent += String(message) + '\n';
  }
  window.addEventListener('error', function (e) {
    reportError((e.message || 'error') + (e.lineno ? ' @' + e.lineno + ':' + e.colno : ''));
  });
  window.addEventListener('unhandledrejection', function (e) { reportError('unhandledrejection: ' + e.reason); });

  // ------------------------------------------------------------------ palette
  var LIONS = {
    black:  { name: 'Black Lion',  base: '#14161f', main: '#2b2e45', glow: '#8f6bff', light: '#cbbcff' },
    red:    { name: 'Red Lion',    base: '#4a0a0e', main: '#e3262f', glow: '#ff5a3c', light: '#ffb199' },
    green:  { name: 'Green Lion',  base: '#08331c', main: '#1fbf5f', glow: '#3dff8a', light: '#b6ffd2' },
    blue:   { name: 'Blue Lion',   base: '#081d45', main: '#1f6fff', glow: '#3fb8ff', light: '#b8e4ff' },
    yellow: { name: 'Yellow Lion', base: '#433204', main: '#f5c21b', glow: '#ffd84a', light: '#fff0b0' }
  };
  var ORDER = ['black', 'red', 'green', 'blue', 'yellow'];
  var UI = { white: '#f4f7ff', gold: '#ffcf5a', steel: '#9aa7c7', space: '#03040a', fire: '#ff7a1a', plasma: '#7ae0ff', violet: '#8f6bff' };

  // ------------------------------------------------------------------ math helpers
  function clamp(x, a, b) { return x < a ? a : x > b ? b : x; }
  function lerp(a, b, t) { return a + (b - a) * t; }
  function fract(x) { return x - Math.floor(x); }
  function smoothstep(a, b, x) { var t = clamp((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); }
  var ease = {
    inOutCubic: function (t) { return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2; },
    outCubic: function (t) { return 1 - Math.pow(1 - t, 3); },
    inCubic: function (t) { return t * t * t; },
    outExpo: function (t) { return t >= 1 ? 1 : 1 - Math.pow(2, -10 * t); },
    inOutSine: function (t) { return -(Math.cos(Math.PI * t) - 1) / 2; },
    outBack: function (t) { var c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2); }
  };
  function mulberry32(a) {
    a = a >>> 0;
    return function () {
      a = (a + 0x6D2B79F5) >>> 0;
      var t = a;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  function hexToRgb(hex) {
    var h = hex.replace('#', '');
    if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
    var n = parseInt(h, 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function rgba(hex, a) { var c = hexToRgb(hex); return 'rgba(' + c[0] + ',' + c[1] + ',' + c[2] + ',' + (a == null ? 1 : a) + ')'; }
  function mix(hexA, hexB, t) {
    var a = hexToRgb(hexA), b = hexToRgb(hexB);
    return 'rgb(' + Math.round(lerp(a[0], b[0], t)) + ',' + Math.round(lerp(a[1], b[1], t)) + ',' + Math.round(lerp(a[2], b[2], t)) + ')';
  }
  // Smooth 1D / 2D value noise in [0,1]. Deterministic.
  function hash2(x, y) { var h = Math.sin(x * 127.1 + y * 311.7) * 43758.5453123; return h - Math.floor(h); }
  function noise2(x, y) {
    var xi = Math.floor(x), yi = Math.floor(y), xf = x - xi, yf = y - yi;
    var u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf);
    var a = hash2(xi, yi), b = hash2(xi + 1, yi), c = hash2(xi, yi + 1), d = hash2(xi + 1, yi + 1);
    return lerp(lerp(a, b, u), lerp(c, d, u), v);
  }
  function noise1(x) { return noise2(x, 0.5); }
  function fbm2(x, y, oct) {
    var s = 0, amp = 0.5, f = 1, n = oct || 4, norm = 0;
    for (var i = 0; i < n; i++) { s += amp * noise2(x * f, y * f); norm += amp; amp *= 0.5; f *= 2.03; }
    return s / norm;
  }

  // ------------------------------------------------------------------ drawing helpers
  // Cached radial glow sprites: drawImage is far cheaper than shadowBlur.
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
  // Additive glow blob centred at (x, y) with radius r.
  function glow(ctx, x, y, r, color, alpha, falloff) {
    if (r <= 0 || alpha <= 0) return;
    var spr = glowSprite(color, 128, falloff);
    var prevA = ctx.globalAlpha, prevC = ctx.globalCompositeOperation;
    ctx.globalCompositeOperation = 'lighter';
    ctx.globalAlpha = clamp(alpha == null ? 1 : alpha, 0, 1);
    ctx.drawImage(spr, x - r, y - r, r * 2, r * 2);
    ctx.globalAlpha = prevA;
    ctx.globalCompositeOperation = prevC;
  }
  // Reusable parallax starfield. Positions are normalized so it survives resizes.
  function makeStars(opts) {
    opts = opts || {};
    var rnd = mulberry32(opts.seed || 7);
    var n = opts.count || 400, stars = [];
    for (var i = 0; i < n; i++) {
      stars.push({ x: rnd(), y: rnd(), z: Math.pow(rnd(), 2.2), tw: rnd() * Math.PI * 2, hue: rnd() });
    }
    return {
      stars: stars,
      draw: function (ctx, api, o) {
        o = o || {};
        var t = api.t, w = api.w, h = api.h, dx = o.dx || 0, dy = o.dy || 0, bright = o.brightness == null ? 1 : o.brightness;
        var scale = Math.max(w, h) / 1600;
        for (var i = 0; i < stars.length; i++) {
          var s = stars[i];
          var depth = 0.2 + s.z * 0.8;
          var x = (fract(s.x + dx * depth / w) * w);
          var y = (fract(s.y + dy * depth / h) * h);
          var tw = 0.65 + 0.35 * Math.sin(t * (0.6 + s.z * 2.2) + s.tw);
          var r = (0.4 + s.z * 1.5) * scale;
          var a = (0.25 + 0.75 * s.z) * tw * bright;
          ctx.fillStyle = s.hue > 0.85 ? 'rgba(190,210,255,' + a + ')' : s.hue < 0.08 ? 'rgba(255,220,190,' + a + ')' : 'rgba(255,255,255,' + a + ')';
          ctx.fillRect(x - r / 2, y - r / 2, r, r);
          if (s.z > 0.93) glow(ctx, x, y, r * 6, '#bcd4ff', a * 0.35);
        }
      }
    };
  }

  // ------------------------------------------------------------------ clock
  var DATE_FMT = new Intl.DateTimeFormat(undefined, { weekday: 'long', month: 'long', day: 'numeric' });
  function timeFmt() {
    var o = { hour: 'numeric', minute: '2-digit' };
    if (cfg.hour12 !== null) o.hour12 = !!cfg.hour12;
    return new Intl.DateTimeFormat(undefined, o);
  }
  var TIME_FMT = timeFmt();
  function clockParts(d) {
    d = d || new Date();
    var time = TIME_FMT.formatToParts(d)
      .filter(function (p) { return p.type !== 'dayPeriod'; })
      .map(function (p) { return p.value; }).join('').trim();
    return { time: time, date: DATE_FMT.format(d), hours: d.getHours(), minutes: d.getMinutes(), seconds: d.getSeconds(), date_obj: d };
  }

  // ------------------------------------------------------------------ stage
  var stage = document.createElement('canvas');
  var overlay = document.createElement('canvas');
  stage.id = 'stage';
  overlay.id = 'overlay';
  var style = document.createElement('style');
  style.textContent = 'html,body{margin:0;width:100%;height:100%;background:#000;overflow:hidden;cursor:none}' +
    'canvas{position:fixed;left:0;top:0;width:100%;height:100%;display:block}#overlay{pointer-events:none}';
  document.head.appendChild(style);

  var scene = null, api = null, raf = 0, last = 0, clockTimer = 0, running = false, booted = false;

  function measure() {
    var w = Math.max(1, window.innerWidth), h = Math.max(1, window.innerHeight);
    var sysDpr = Math.min(cfg.dprMax, window.devicePixelRatio || 1);
    var dpr = sysDpr * cfg.scale;
    api.w = w; api.h = h; api.dpr = dpr;
    api.pw = Math.max(1, Math.round(w * dpr)); api.ph = Math.max(1, Math.round(h * dpr));
    api.cx = w / 2; api.cy = h / 2;
    api.min = Math.min(w, h); api.max = Math.max(w, h); api.aspect = w / h;
    stage.width = api.pw; stage.height = api.ph;
    overlay.width = Math.round(w * sysDpr); overlay.height = Math.round(h * sysDpr);
    api.overlayDpr = sysDpr;
    api.clockRect = clockRect();
  }

  function clockMode() {
    if (!cfg.clock) return 'none';
    return scene && scene.clock ? scene.clock : 'top';
  }
  function clockSizes() {
    var timeSize = clamp(Math.min(api.w * 0.11, api.h * 0.15), 40, 210);
    return { time: timeSize, date: Math.max(13, timeSize * 0.2) };
  }
  // Region the clock occupies (CSS px) so scenes can keep it calm. null when hidden.
  function clockRect() {
    var mode = clockMode();
    if (mode === 'none') return null;
    var s = clockSizes();
    var bw = s.time * 3.4, bh = s.date * 1.6 + s.time * 1.1;
    var pad = Math.max(24, api.min * 0.06);
    if (mode === 'bottom-left') return { x: pad, y: api.h - pad - bh, w: bw, h: bh, mode: mode };
    if (mode === 'bottom-right') return { x: api.w - pad - bw, y: api.h - pad - bh, w: bw, h: bh, mode: mode };
    return { x: api.w / 2 - bw / 2, y: api.h * 0.07, w: bw, h: bh, mode: 'top' };
  }

  function drawClock() {
    var o = overlay.getContext('2d');
    o.setTransform(1, 0, 0, 1, 0, 0);
    o.clearRect(0, 0, overlay.width, overlay.height);
    var r = api.clockRect;
    if (!r) return;
    o.setTransform(api.overlayDpr, 0, 0, api.overlayDpr, 0, 0);
    var p = clockParts();
    var s = clockSizes();
    var align = r.mode === 'bottom-left' ? 'left' : r.mode === 'bottom-right' ? 'right' : 'center';
    var x = align === 'left' ? r.x : align === 'right' ? r.x + r.w : r.x + r.w / 2;
    var fam = '-apple-system, "SF Pro Display", system-ui, "Helvetica Neue", Helvetica, Arial, sans-serif';
    var glowCol = (scene && scene.clockGlow) || 'rgba(120,170,255,0.55)';
    var col = (scene && scene.clockColor) || 'rgba(246,248,255,0.94)';
    o.textAlign = align;
    o.textBaseline = 'alphabetic';
    o.shadowColor = glowCol;
    o.fillStyle = col;
    // date
    o.shadowBlur = s.date * 0.6;
    o.font = '600 ' + s.date.toFixed(1) + 'px ' + fam;
    var dateY = r.y + s.date * 1.1;
    o.fillText(p.date, x, dateY);
    // time
    o.shadowBlur = s.time * 0.18;
    o.font = '600 ' + s.time.toFixed(1) + 'px ' + fam;
    o.fillText(p.time, x, dateY + s.time * 0.98);
    o.shadowBlur = 0;
  }
  function scheduleClock() {
    clearTimeout(clockTimer);
    if (cfg.still) return;
    var ms = 1000 - (Date.now() % 1000) + 5;
    clockTimer = setTimeout(function () { drawClock(); scheduleClock(); }, ms);
  }

  // ------------------------------------------------------------------ frame loop
  function step(dt) {
    api.dt = dt;
    api.t += dt;
    api.frame++;
    if (scene.update) {
      try { scene.update(api, dt); } catch (e) { reportError('update: ' + (e && e.stack || e)); }
    }
  }
  function render() {
    if (api.is2d) {
      api.ctx.setTransform(api.dpr, 0, 0, api.dpr, 0, 0);
      api.ctx.globalAlpha = 1;
      api.ctx.globalCompositeOperation = 'source-over';
    }
    try { scene.draw(api); } catch (e) { reportError('draw: ' + (e && e.stack || e)); }
  }
  function tick(now) {
    raf = requestAnimationFrame(tick);
    if (!last) { last = now; return; }
    var elapsed = now - last;
    if (elapsed < (1000 / cfg.fps) * 0.75) return; // fps cap (also halves 120 Hz)
    last = now;
    step(Math.min(0.1, elapsed / 1000));
    render();
  }
  function start() {
    if (running || cfg.still || cfg.bench) return;
    running = true; last = 0;
    raf = requestAnimationFrame(tick);
    drawClock(); scheduleClock();
  }
  function stop() {
    running = false;
    cancelAnimationFrame(raf);
    clearTimeout(clockTimer);
  }
  function flush() {
    try {
      if (api.is2d) api.ctx.getImageData(0, 0, 1, 1);
      else if (api.gl) { var px = new Uint8Array(4); api.gl.readPixels(0, 0, 1, 1, api.gl.RGBA, api.gl.UNSIGNED_BYTE, px); }
    } catch (e) { /* ignore */ }
  }
  function markReady(extra) {
    document.documentElement.setAttribute('data-voltron', 'ready');
    var msg = { type: 'ready', scene: scene.id, errors: errorCount };
    if (extra) Object.keys(extra).forEach(function (k) { msg[k] = extra[k]; });
    post(msg);
  }

  function onResize() {
    if (!api) return;
    measure();
    if (scene.resize) { try { scene.resize(api); } catch (e) { reportError('resize: ' + (e && e.stack || e)); } }
    drawClock();
    if (!running) render();
  }

  function boot() {
    if (booted) return;
    booted = true;
    document.body.appendChild(stage);
    document.body.appendChild(overlay);
    api = {
      canvas: stage, ctx: null, gl: null, is2d: true,
      w: 0, h: 0, dpr: 1, pw: 0, ph: 0, cx: 0, cy: 0, min: 0, max: 0, aspect: 1,
      t: 0, dt: 0, frame: 0, cfg: cfg, clockRect: null,
      P: LIONS, ORDER: ORDER, UI: UI,
      rand: mulberry32(cfg.seed || 1)
    };
    var kind = scene.context || '2d';
    var opts = scene.contextOptions || (kind === '2d' ? { alpha: false } : { alpha: false, antialias: true, premultipliedAlpha: false });
    var ctx = stage.getContext(kind, opts);
    if (!ctx && kind === 'webgl2') { kind = 'webgl'; ctx = stage.getContext('webgl', opts); }
    if (!ctx) { reportError('could not create ' + kind + ' context'); return; }
    api.is2d = kind === '2d';
    if (api.is2d) api.ctx = ctx; else { api.gl = ctx; api.ctx = null; }
    api.contextKind = kind;
    measure();
    try { if (scene.setup) scene.setup(api); } catch (e) { reportError('setup: ' + (e && e.stack || e)); }
    try { if (scene.resize) scene.resize(api); } catch (e) { reportError('resize: ' + (e && e.stack || e)); }
    window.addEventListener('resize', onResize);

    if (cfg.bench > 0) {
      var n = Math.round(cfg.bench);
      var benchStart = Math.max(0, cfg.t || 0);   // bench a chosen phase: #bench=120&t=26
      while (api.t + 1 / 30 <= benchStart + 1e-9) step(1 / 30);
      for (var i = 0; i < 10; i++) { step(1 / 60); render(); } // warm-up
      flush();
      var t0 = performance.now();
      for (var j = 0; j < n; j++) { step(1 / 60); render(); }
      flush();
      var ms = (performance.now() - t0) / n;
      document.documentElement.setAttribute('data-bench', ms.toFixed(3));
      drawClock();
      markReady({ bench: ms, frames: n });
      return;
    }
    if (cfg.still) {
      var target = Math.max(0, cfg.t || 0), sdt = 1 / 30;
      while (api.t + sdt <= target + 1e-9) step(sdt);
      if (target - api.t > 1e-6) step(target - api.t);
      render();
      drawClock();
      markReady({ t: api.t });
      return;
    }
    if (cfg.manual) { // frame-by-frame capture: the host calls Voltron.advance(dt)
      var mt = Math.max(0, cfg.t || 0);
      while (api.t + 1 / 30 <= mt + 1e-9) step(1 / 30);
      render(); drawClock(); markReady({ t: api.t });
      return;
    }
    api.t = Math.max(0, cfg.t || 0);
    document.addEventListener('visibilitychange', function () { if (document.hidden) stop(); else start(); });
    render();
    start();
    markReady();
  }

  // ------------------------------------------------------------------ public API
  window.Voltron = {
    register: function (def) {
      if (scene) { reportError('Voltron.register called twice'); return; }
      if (!def || typeof def.draw !== 'function') { reportError('scene must define draw(api)'); return; }
      scene = def;
      if (document.body) boot(); else document.addEventListener('DOMContentLoaded', boot);
    },
    pause: stop,
    resume: start,
    setClock: function (on) {
      cfg.clock = !!on;
      if (!api) return;
      api.clockRect = clockRect();
      if (scene.resize) { try { scene.resize(api); } catch (e) { reportError('resize: ' + (e && e.stack || e)); } }
      drawClock();
      if (!running) render();
    },
    stats: function () { return api ? { frame: api.frame, t: api.t, w: api.w, h: api.h, dpr: api.dpr, running: running } : null; },
    clockParts: clockParts,
    advance: function (dt) { if (!api || !cfg.manual) return; step(dt); render(); },
    cfg: cfg,
    LIONS: LIONS, ORDER: ORDER, UI: UI,
    util: {
      clamp: clamp, lerp: lerp, fract: fract, smoothstep: smoothstep, ease: ease,
      mulberry32: mulberry32, hexToRgb: hexToRgb, rgba: rgba, mix: mix,
      noise1: noise1, noise2: noise2, fbm2: fbm2,
      glowSprite: glowSprite, glow: glow, makeStars: makeStars
    }
  };
})();
