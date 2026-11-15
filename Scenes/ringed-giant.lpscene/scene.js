/*
 * Ringed Giant
 *
 * A quiet gas giant lit from the upper left. The cloud bands are an unlit albedo
 * map remapped at fixed time samples (orthographic sphere, per-latitude zonal
 * winds), smoothly blended under static full-resolution lighting layers (terminator,
 * limb, ring shadow, limb glow) so the bands turn beneath a fixed light. The whole
 * planet + ring system nods slowly; ring clumps orbit at Keplerian speeds; three
 * inclined moons pass in front of and behind the rings and the globe.
 */
const U = LivePaper.util;
const TAU = U.TAU;
const BAND_W = 1024;
const BAND_H = 512;
const RING_TILT = -0.13;
const RING_OUTER = 2.12;     // outer ring radius, in planet radii
const RING_INNER = 0.47;     // inner edge as a fraction of the outer radius
const RING_FLAT = 0.31;      // sin(viewing elevation above the ring plane)
const SIN_E = RING_FLAT;
const COS_E = Math.sqrt(1 - SIN_E * SIN_E);
const COS_T = Math.cos(RING_TILT);
const SIN_T = Math.sin(RING_TILT);
const ROT = BAND_W / 300;    // texels per second: one turn in ~5 minutes
const ALBEDO_HZ = 8;        // complete maps per second; interpolation runs every frame
const STORM_LON0 = -0.62;    // storm longitude (rad) at t = 0; moves left to right

// Light from the upper left, a little in front (screen frame: x right, y down, z to viewer).
const LIGHT = (function () {
  const v = [-0.72, -0.50, 0.48];
  const n = Math.hypot(v[0], v[1], v[2]);
  return [v[0] / n, v[1] / n, v[2] / n];
})();
// The same light in the ring frame (screen rotated by -RING_TILT).
const LIGHT_R = [
  LIGHT[0] * COS_T + LIGHT[1] * SIN_T,
  -LIGHT[0] * SIN_T + LIGHT[1] * COS_T,
  LIGHT[2]
];

const BAND_COLORS = [
  [168, 113, 128],
  [220, 199, 164],
  [187, 148, 91],
  [113, 137, 155],
  [194, 158, 132],
  [139, 105, 126],
  [206, 187, 157],
  [104, 126, 148]
];

const farStars = U.makeStars({ count: 520, seed: 184, tint: true, twinkle: 0.18, glow: 0.97 });
const midStars = U.makeStars({ count: 300, seed: 311, tint: true, twinkle: 0.22, glow: 0.96 });
const nearStars = U.makeStars({ count: 170, seed: 77, tint: true, twinkle: 0.3, glow: 0.9 });

// Ring clumps (soft, in the ring plane) and glints (tiny sparkles).
const CLUMPS = (function () {
  const R = U.mulberry32(5150);
  const zones = [[0.12, 0.23], [0.31, 0.54], [0.31, 0.54], [0.63, 0.80]];
  const out = [];
  for (let i = 0; i < 40; i++) {
    const z = zones[i % zones.length];
    const q = z[0] + R() * (z[1] - z[0]);
    const rho = (RING_INNER + (1 - RING_INNER) * q) * RING_OUTER;
    out.push({ rho, th: R() * TAU, s: 0.09 + R() * 0.13, a: 0.05 + R() * 0.07,
      w: 0.021 * Math.pow(rho, -1.5) * 1.84 });
  }
  return out;
})();
const GLINTS = (function () {
  const R = U.mulberry32(733);
  const out = [];
  for (let i = 0; i < 22; i++) {
    const q = [0.15, 0.35, 0.42, 0.5, 0.7][i % 5] + (R() - 0.5) * 0.06;
    const rho = (RING_INNER + (1 - RING_INNER) * q) * RING_OUTER;
    out.push({ rho, th: R() * TAU, per: 7 + R() * 9, ph: R() * TAU,
      w: 0.021 * Math.pow(rho, -1.5) * 1.84 });
  }
  return out;
})();

// Moons: orbit radius (planet radii), inclination, node, angular speed, size, colour.
const MOONS = [
  { rho: 2.32, inc: 0.28, node: 0.0, w: 0.0135, ph: 1.1, size: 0.042, col: [153, 179, 188], glow: '#9bbbc4' },
  { rho: 3.05, inc: -0.09, node: 0.9, w: 0.0089, ph: 3.6, size: 0.058, col: [210, 191, 155], glow: '#d7c6a5' },
  { rho: 3.7, inc: 0.06, node: 2.4, w: 0.0061, ph: 5.2, size: 0.072, col: [176, 160, 172], glow: '#c9b8c4' }
];

let sky = null;
let overlay = null;
let nebula = null;
let dust = null;
let dust2 = null;
let lowCost = false;         // battery / low power / reduced render scale
let brightStars = null;
let bandTex = null;          // Uint32Array, BAND_W x BAND_H, RGBA packed
let albedo = null;           // shared sphere map + three reusable surface samples
let lightL = null;           // static lighting (multiply)
let glowL = null;            // static limb atmosphere + halo (additive)
let shadowL = null;          // near-ring shadow on the globe, ring frame (multiply)
let ringImage = null;
let moonSprites = null;
let zones = null;            // per-row zonal wind blending
const moonTmp = [{}, {}, {}];

LivePaper.scene({
  context: '2d',

  resize(lp) {
    if (!bandTex) { bandTex = buildBandTexture(); zones = buildZones(); }
    buildSkyLayers(lp);
    const r = planetRadius(lp);
    const dpr = Math.min(lp.dpr, 2);
    const saving = lp.env.power === 'battery' || lp.env.lowPower || lp.scale < 0.9;
    lowCost = saving;
    // Albedo remap resolution: near full device resolution on power (crisp band edges
    // and storms), a cheap reduced map on battery / low power / reduced render scale.
    const ares = saving
      ?Math.round(U.clamp(2 * r * dpr * 0.4, 200, 520) / 2) * 2
      : Math.round(U.clamp(2 * r * dpr * 0.8, 256, 860) / 2) * 2;
    if (!albedo || albedo.res !== ares) albedo = buildAlbedoMap(ares);
    primeAlbedo(lp.t * (lp.env.reducedMotion ? 0.3 : 1));
    const sres = Math.round(U.clamp(2 * r * dpr, 256, 1024) / 2) * 2;
    if (!lightL || lightL.res !== sres) {
      lightL = buildLightLayer(sres);
      glowL = buildGlowLayer(sres);
    }
    if (!shadowL) shadowL = buildRingShadowLayer();
    ringImage = buildRingImage(r, Math.min(lp.dpr, 1.5));
    moonSprites = MOONS.map((m) => buildMoonSprite(64, m.col));
  },

  draw(lp) {
    const ctx = lp.ctx;
    const motion = lp.env.reducedMotion ? 0.3 : 1;
    const t = lp.t * motion;
    const sw = lp.w / 1512;

    // ---- Space -------------------------------------------------------------
    const camX = Math.sin(t * TAU / 127) * lp.w * 0.006;
    const camY = Math.sin(t * TAU / 151 + 2.0) * lp.h * 0.006;
    ctx.drawImage(sky.canvas, 0, 0, lp.w, lp.h);

    // Nebula: one oversized filament layer, drifting and breathing slowly.
    ctx.globalCompositeOperation = 'lighter';
    ctx.globalAlpha = 0.8 + 0.2 * Math.sin(t * TAU / 53) * Math.sin(t * TAU / 131 + 0.7);
    ctx.drawImage(nebula.canvas,
      -nebula.padX + camX * 0.3 + Math.sin(t * TAU / 83) * lp.w * 0.012,
      -nebula.padY + camY * 0.3 + Math.sin(t * TAU / 61 + 1) * lp.h * 0.010,
      nebula.w, nebula.h);
    ctx.globalAlpha = 1;
    ctx.globalCompositeOperation = 'source-over';

    // Three star layers in parallax, then two veils of fine dust drifting nearer still.
    farStars.draw(ctx, lp, {
      dx: -t * 1.3 * sw + camX * 0.5, dy: t * 0.2 * sw + camY * 0.5,
      fraction: lp.quality * (lowCost ? 0.7 : 1), brightness: 0.72, size: 0.85
    });
    midStars.draw(ctx, lp, {
      dx: -t * 3.4 * sw + camX * 0.8, dy: t * 0.45 * sw + camY * 0.8,
      fraction: lp.quality, brightness: 0.76, size: 0.95
    });
    nearStars.draw(ctx, lp, {
      dx: -t * 7.2 * sw + camX, dy: t * 0.9 * sw + camY,
      fraction: lp.quality, brightness: 0.8, size: 1.1
    });
    if (!lowCost && lp.quality > 0.6) {
      drawDust(ctx, lp, dust, -t * 10.5 * sw + camX * 1.3, t * 2.1 * sw + camY * 1.3, 0.9);
    }
    drawDust(ctx, lp, dust2, -t * 5.6 * sw + camX * 0.9, -t * 1.2 * sw + camY, 0.75);
    drawBrightStars(ctx, lp, t, camX * 0.7, camY * 0.7, sw);
    drawMeteor(ctx, lp, t);
    ctx.drawImage(overlay.canvas, 0, 0, lp.w, lp.h);

    // ---- Planet system ----------------------------------------------------
    const p = planetLayout(lp, t);
    const roll = 0.040 * Math.sin(t * TAU / 163) + 0.010 * Math.sin(t * TAU / 71 + 1.3);
    const breath = 1 + 0.050 * Math.sin(t * TAU / 137 + 0.5) + 0.014 * Math.sin(t * TAU / 59 + 2.1);
    const ang = RING_TILT + roll;
    const sE = SIN_E * breath;
    const cE = Math.sqrt(1 - sE * sE);
    p.ang = ang; p.roll = roll; p.breath = breath; p.sE = sE; p.cE = cE;

    renderAlbedo(t);

    for (let i = 0; i < MOONS.length; i++) {
      const m = moonState(moonTmp[i], p, i, t);
      // Fade a moon that strays near the clock.
      const cr = lp.clockRect;
      m.alpha = 1;
      if (cr) {
        const pad = lp.min * 0.08;
        const dx = Math.max(cr.x - m.x, 0, m.x - (cr.x + cr.w));
        const dy = Math.max(cr.y - m.y, 0, m.y - (cr.y + cr.h));
        m.alpha = 0.25 + 0.75 * U.smoothstep(0, pad, Math.hypot(dx, dy));
      }
    }

    for (let i = 0; i < MOONS.length; i++) {
      const m = moonTmp[i];
      if (m.behindPlanet && m.behindRing) drawMoon(ctx, m, i);
    }
    drawRing(ctx, p);
    drawRingLife(ctx, p, t, false, lp.quality);
    for (let i = 0; i < MOONS.length; i++) {
      const m = moonTmp[i];
      if (m.behindPlanet && !m.behindRing) drawMoon(ctx, m, i);
    }

    // Globe: albedo (rotates with the system) under fixed lighting.
    ctx.save();
    ctx.beginPath();
    ctx.arc(p.x, p.y, p.r + 0.5, 0, TAU);
    ctx.clip();
    ctx.translate(p.x, p.y);
    ctx.save();
    ctx.rotate(roll);
    let sc = p.r / albedo.r0;
    let s = albedo.res * sc;
    ctx.drawImage(albedo.lo.canvas, -s * 0.5, -s * 0.5, s, s);
    if (albedo.mix > 0) {
      ctx.globalAlpha = albedo.mix;
      ctx.drawImage(albedo.hi.canvas, -s * 0.5, -s * 0.5, s, s);
      ctx.globalAlpha = 1;
    }
    ctx.restore();
    ctx.globalCompositeOperation = 'multiply';
    sc = p.r / lightL.r0;
    s = lightL.res * sc;
    ctx.drawImage(lightL.canvas, -s * 0.5, -s * 0.5, s, s);
    ctx.rotate(ang);
    ctx.scale(1, breath);
    ctx.drawImage(shadowL.canvas, -shadowL.ex * p.r, -shadowL.ey * p.r,
      2 * shadowL.ex * p.r, 2 * shadowL.ey * p.r);
    ctx.restore();
    ctx.globalCompositeOperation = 'lighter';
    s = glowL.size * (p.r / lightL.r0);
    ctx.drawImage(glowL.canvas, p.x - s * 0.5, p.y - s * 0.5, s, s);
    ctx.globalCompositeOperation = 'source-over';

    drawNearRingAcrossPlanet(ctx, p);
    drawRingLife(ctx, p, t, true, lp.quality);

    for (let i = 0; i < MOONS.length; i++) {
      const m = moonTmp[i];
      if (!m.behindPlanet) {
        drawMoon(ctx, m, i);
        if (m.behindRing) drawRingOver(ctx, p, m);
      }
    }
  }
});

function planetRadius(lp) {
  if (lp.aspect > 2.15) return lp.h * 0.31;
  if (lp.aspect < 1.28) return lp.min * 0.225;
  return lp.min * 0.235;
}

function planetLayout(lp, t) {
  const r = planetRadius(lp);
  let x;
  let y;
  if (lp.aspect > 2.15) {
    x = lp.w * 0.235;
    y = lp.h * 0.675;
  } else if (lp.aspect < 1.28) {
    x = lp.w * 0.50;
    y = lp.h * 0.675;
  } else {
    x = lp.w * 0.36;
    y = lp.h * 0.69;
  }
  // The group drifts a little against the stars (looping, ~1.5 % of the screen).
  return {
    x: x + Math.sin(t * TAU / 113) * lp.min * 0.022 + Math.sin(t * TAU / 47 + 0.4) * lp.min * 0.004,
    y: y + Math.sin(t * TAU / 89 + 0.6) * lp.min * 0.013,
    r
  };
}

// ---------------------------------------------------------------------------
// Sky
// ---------------------------------------------------------------------------

function buildSkyLayers(lp) {
  sky = U.layer(lp.w, lp.h, Math.min(lp.dpr, 1));
  const g = sky.ctx;
  const bg = g.createLinearGradient(0, 0, 0, lp.h);
  bg.addColorStop(0, '#010309');
  bg.addColorStop(0.42, '#030813');
  bg.addColorStop(0.78, '#071321');
  bg.addColorStop(1, '#091725');
  g.fillStyle = bg;
  g.fillRect(0, 0, lp.w, lp.h);

  const wide = lp.aspect > 2.15;

  nebula = buildNebula(lp);
  dust = buildDustTile(lp, 9001, 0.55);
  dust2 = buildDustTile(lp, 4417, 0.4);

  brightStars = wide
    ? [[0.63, 0.43, 2.2], [0.73, 0.72, 1.5], [0.81, 0.34, 1.8],
       [0.88, 0.59, 2.6], [0.94, 0.78, 1.4], [0.70, 0.86, 1.2], [0.06, 0.18, 1.3]]
    : [[0.77, 0.43, 1.6], [0.88, 0.68, 2.0], [0.93, 0.35, 1.3], [0.08, 0.16, 1.2], [0.20, 0.36, 1.0]];

  // Overlay: darkens the clock region and vignettes the frame (above the stars).
  overlay = U.layer(lp.w, lp.h, Math.min(lp.dpr, 1));
  const o = overlay.ctx;
  // Clock shade: an elliptical radial gradient that reaches zero well inside the layer
  // and is filled over all of it, so it has no edges at any aspect ratio.
  const shadeR = Math.min(lp.w * 0.31, lp.h * 0.72);
  o.save();
  o.translate(lp.cx, 0);
  o.scale(1.2, 0.8);
  const clockShade = o.createRadialGradient(0, 0, 0, 0, 0, shadeR);
  clockShade.addColorStop(0, 'rgba(0, 2, 7, 0.66)');
  clockShade.addColorStop(0.35, 'rgba(0, 2, 7, 0.5)');
  clockShade.addColorStop(0.65, 'rgba(0, 2, 7, 0.22)');
  clockShade.addColorStop(0.86, 'rgba(0, 2, 7, 0.06)');
  clockShade.addColorStop(1, 'rgba(0, 2, 7, 0)');
  o.fillStyle = clockShade;
  o.fillRect(-lp.w, 0, lp.w * 2, lp.h * 2);
  o.restore();
  const vignette = o.createRadialGradient(lp.cx, lp.h * 0.58, lp.min * 0.12, lp.cx, lp.h * 0.58, lp.max * 0.73);
  vignette.addColorStop(0, 'rgba(0, 1, 5, 0)');
  vignette.addColorStop(1, 'rgba(0, 1, 4, 0.38)');
  o.fillStyle = vignette;
  o.fillRect(0, 0, lp.w, lp.h);
}

// Deep-space nebula: thin, domain-warped filaments (contour lines of warped fbm) in
// dusky violet and teal, gathered on the far side of the sky from the planet and
// hollowed out behind the clock. Oversized for the drift; its edges stay off screen.
function buildNebula(lp) {
  const padX = lp.w * 0.04;
  const padY = lp.h * 0.04;
  const nw = lp.w + 2 * padX;
  const nh = lp.h + 2 * padY;
  const ns = Math.max(2, Math.sqrt(nw * nh / 240000));
  const cw = Math.ceil(nw / ns);
  const ch = Math.ceil(nh / ns);
  const nc = document.createElement('canvas');
  nc.width = cw;
  nc.height = ch;
  const ng = nc.getContext('2d');
  const img = ng.createImageData(cw, ch);
  const d = img.data;
  const f = 2.2 / lp.min;
  const pl = planetLayout(lp, 0);
  const clockW = lp.w * 0.18 + lp.min * 0.16;
  const clockH = lp.h * 0.40;
  for (let j = 0; j < ch; j++) {
    const y = j * ns - padY;
    for (let i = 0; i < cw; i++) {
      const x = i * ns - padX;
      const o = (j * cw + i) * 4;
      d[o + 3] = 255;
      // Where: far from the planet, biased to the right, nearly nothing behind the clock.
      const dx = (x - pl.x) / lp.min;
      const dy = (y - pl.y) / lp.min;
      let m = U.smoothstep(0.36, 0.85, Math.hypot(dx, dy * 1.15));
      m *= 0.35 + 0.65 * U.smoothstep(lp.w * 0.3, lp.w * 0.9, x);
      const cx = (x - lp.cx) / clockW;
      const cy = y / clockH;
      m *= 1 - 0.94 * Math.exp(-(cx * cx + cy * cy) * 1.4);
      const big = U.fbm2(x * f * 0.45 + 5.3, y * f * 0.45 - 2.1, 3);
      m *= 0.25 + 0.75 * U.smoothstep(0.34, 0.62, big);
      if (m < 0.004) continue;
      // What: streams along a gentle diagonal (stretched, lightly warped noise), each
      // a thin bright core inside a soft glow, plus a finer set of strands.
      const sx = (x * 0.92 + y * 0.39) * f;
      const sy = (y * 0.92 - x * 0.39) * f;
      const qx = U.fbm2(sx * 0.7 + 1.7, sy * 0.7 + 9.2, 3);
      const qy = U.fbm2(sx * 0.7 + 8.3, sy * 0.7 + 2.8, 3);
      const wx = sx * 0.45 + 0.9 * qx;
      const wy = sy * 1.9 + 0.9 * qy;
      const n = U.fbm2(wx, wy, 4);
      const e = Math.abs(n - 0.5);
      let core = Math.max(0, 1 - e * 13);
      core *= core;
      const glow = Math.exp(-e * e * 260);
      const n2 = U.fbm2(wx * 2.1 + 13.0, wy * 1.6 - 7.0, 3);
      let fine = Math.max(0, 1 - Math.abs(n2 - 0.5) * 20);
      fine *= fine * 0.45 * U.smoothstep(0.42, 0.6, big);
      const v = m * (core * 0.7 + glow * 0.42 + fine) * 0.42;
      const c = U.smoothstep(0.4, 0.6, U.fbm2(x * f * 0.3 + 30.0, y * f * 0.3 + 11.0, 2));
      d[o] = v * U.lerp(92, 30, c);
      d[o + 1] = v * U.lerp(52, 92, c);
      d[o + 2] = v * U.lerp(118, 104, c);
    }
  }
  ng.putImageData(img, 0, 0);
  return { canvas: nc, w: nw, h: nh, padX, padY };
}

// Fine dust: a tile of tiny faint specks, seamless (specks near an edge are drawn on
// both sides), tiled over the screen while it drifts.
function buildDustTile(lp, seed, density) {
  const T = Math.round(Math.max(160, lp.min * 0.5));
  const dpr = Math.min(lp.dpr, 2);
  const L = U.layer(T, T, dpr);
  const g = L.ctx;
  const R = U.mulberry32(seed);
  const count = Math.round(T * T / 260 * density);
  const paths = [new Path2D(), new Path2D(), new Path2D()];
  for (let i = 0; i < count; i++) {
    const x = R() * T;
    const y = R() * T;
    const r = Math.max(0.45 + R() * 0.55, 0.85 / dpr);
    const p = paths[Math.floor(R() * 3)];
    for (let ox = -1; ox <= 1; ox++) {
      for (let oy = -1; oy <= 1; oy++) {
        const px = x + ox * T;
        const py = y + oy * T;
        if (px < -2 || px > T + 2 || py < -2 || py > T + 2) continue;
        p.moveTo(px + r, py);
        p.arc(px, py, r, 0, TAU);
      }
    }
  }
  const cols = ['rgba(150, 170, 205, 0.16)', 'rgba(175, 160, 205, 0.24)', 'rgba(160, 200, 205, 0.34)'];
  for (let k = 0; k < 3; k++) {
    g.fillStyle = cols[k];
    g.fill(paths[k]);
  }
  return { canvas: L.canvas, T };
}

function drawDust(ctx, lp, tile, ox, oy, alpha) {
  const T = tile.T;
  const x0 = ((ox % T) + T) % T - T;
  const y0 = ((oy % T) + T) % T - T;
  ctx.globalAlpha = alpha;
  for (let y = y0; y < lp.h; y += T) {
    for (let x = x0; x < lp.w; x += T) ctx.drawImage(tile.canvas, x, y, T, T);
  }
  ctx.globalAlpha = 1;
}

function drawBrightStars(ctx, lp, t, ox, oy, sw) {
  for (let i = 0; i < brightStars.length; i++) {
    const b = brightStars[i];
    const x = lp.w * b[0] + ox + Math.sin(t * 0.011 + i) * 3 * sw;
    const y = lp.h * b[1] + oy;
    const tw = 0.78 + 0.22 * Math.sin(t * (0.9 + i * 0.13) + i * 2.1) * Math.sin(t * 0.37 + i);
    U.glow(ctx, x, y, lp.min * 0.018 * b[2], i % 2 ? '#b8d7d8' : '#d9c4df', 0.22 * tw, 0.88);
    U.glow(ctx, x, y, Math.max(1.6, lp.min * 0.0042), i % 2 ? '#e4f4f2' : '#f3e8f5', 0.9 * tw, 0.6);
  }
}

// A faint, thin meteor every ~47 s, eased in and out, kept away from the clock.
function drawMeteor(ctx, lp, t) {
  const P = 47;
  const k = Math.floor(t / P);
  const local = t - k * P;
  const start = 6 + U.hash2(k, 1) * 32;
  const dur = 1.4;
  if (local < start || local > start + dur) return;
  const u = (local - start) / dur;
  const left = U.hash2(k, 2) < 0.5;
  const x0 = lp.w * (left ? 0.05 + U.hash2(k, 3) * 0.2 : 0.75 + U.hash2(k, 3) * 0.2);
  const y0 = lp.h * (0.06 + U.hash2(k, 4) * 0.38);
  const a = 0.35 + U.hash2(k, 5) * 0.5;
  const dx = (left ? -1 : 1) * Math.cos(a);
  const dy = Math.sin(a);
  const L = lp.min * 0.16;
  const e = U.ease.inOutSine(u);
  const hx = x0 + dx * L * e;
  const hy = y0 + dy * L * e;
  const tl = lp.min * 0.07 * Math.sin(Math.PI * Math.min(1, u * 1.3));
  const tx = hx - dx * tl;
  const ty = hy - dy * tl;
  const alpha = 0.34 * Math.sin(Math.PI * u);
  const gr = ctx.createLinearGradient(tx, ty, hx, hy);
  gr.addColorStop(0, 'rgba(200, 215, 235, 0)');
  gr.addColorStop(1, `rgba(220, 232, 245, ${alpha})`);
  ctx.strokeStyle = gr;
  ctx.lineWidth = 1.1;
  ctx.lineCap = 'round';
  ctx.beginPath();
  ctx.moveTo(tx, ty);
  ctx.lineTo(hx, hy);
  ctx.stroke();
}

// ---------------------------------------------------------------------------
// Planet
// ---------------------------------------------------------------------------

// Band coordinate of texel (u, v), u in [0,1) around the planet, v in [0,1) pole to pole.
function bandWarp(u, v) {
  const a = u * TAU;
  const broad = Math.sin(a * 2 + v * 2.7) * 0.30;
  const wave = Math.sin(a * 5 - v * 4.1 + 0.8) * 0.12;
  const curlNoise = U.fbm2(Math.cos(a) * 3.1 + 8.2, Math.sin(a) * 3.1 + v * 3.8, 3);
  return v * 14.6 + broad + wave + (curlNoise - 0.5) * 0.34;
}

// Latitude (as v) near vTarget where the storm sits in the middle of a band.
function bandCentre(u, vTarget) {
  let best = vTarget;
  let bestErr = 1;
  for (let k = -40; k <= 40; k++) {
    const v = vTarget + k * 0.001;
    const err = Math.abs(U.fract(bandWarp(u, v)) - 0.5);
    if (err < bestErr) {
      bestErr = err;
      best = v;
    }
  }
  return best;
}

const STORMS = [
  // u (texel), v target, half-width, half-height (texels), body, centre colours, swirl
  { u: 256, v: 0.5 - 0.30 / Math.PI, w: 36, h: 11.5,
    body: [150, 82, 94], core: [222, 176, 156], amount: 0.9 },
  { u: 768, v: 0.5 - 0.58 / Math.PI, w: 11, h: 4.2,
    body: [214, 204, 188], core: [236, 228, 212], amount: 0.62 }
];

function buildBandTexture() {
  const data = new Uint8ClampedArray(BAND_W * BAND_H * 4);
  for (const s of STORMS) s.vc = bandCentre(s.u / BAND_W, s.v) * BAND_H;

  for (let y = 0; y < BAND_H; y++) {
    const v = (y + 0.5) / BAND_H;
    const polar = 0.84 + 0.16 * Math.sin(v * Math.PI);
    for (let x = 0; x < BAND_W; x++) {
      const u = (x + 0.5) / BAND_W;
      const a = u * TAU;
      const warped = bandWarp(u, v);
      const band = Math.floor(warped);
      const f = U.smoothstep(0.12, 0.88, U.fract(warped));
      const ca = BAND_COLORS[(band + 32) % BAND_COLORS.length];
      const cb = BAND_COLORS[(band + 33) % BAND_COLORS.length];
      const soft = f * f * (3 - 2 * f);
      const fine = Math.sin(a * 13 + v * 41) * 2.1 +
        (U.noise2(Math.cos(a) * 13 + 20, Math.sin(a) * 13 + v * 24) - 0.5) * 3.5;
      let r = ca[0] * (1 - soft) + cb[0] * soft + fine;
      let g = ca[1] * (1 - soft) + cb[1] * soft + fine;
      let b = ca[2] * (1 - soft) + cb[2] * soft + fine;

      for (const s of STORMS) {
        let du = x + 0.5 - s.u;
        du -= Math.round(du / BAND_W) * BAND_W;
        const ex = du / s.w;
        const ey = (y + 0.5 - s.vc) / s.h;
        const e = Math.sqrt(ex * ex + ey * ey);
        if (e > 1.25) continue;
        const body = (1 - U.smoothstep(0.35, 1.2, e)) * s.amount;
        const core = (1 - U.smoothstep(0.0, 0.85, e)) * 0.34;
        const swirl = Math.sin(2 * Math.atan2(ey, ex) - e * 6.2) * 0.07 * U.smoothstep(0.1, 0.5, e);
        const sr = U.lerp(s.body[0], s.core[0], core) * (1 + swirl);
        const sg = U.lerp(s.body[1], s.core[1], core) * (1 + swirl);
        const sb = U.lerp(s.body[2], s.core[2], core) * (1 + swirl);
        r = U.lerp(r, sr, body);
        g = U.lerp(g, sg, body);
        b = U.lerp(b, sb, body);
      }
      const cap = 1 - U.smoothstep(0.05, 0.17, Math.min(v, 1 - v));
      r = U.lerp(r, 122, cap);
      g = U.lerp(g, 114, cap);
      b = U.lerp(b, 130, cap);
      const i = (y * BAND_W + x) * 4;
      data[i] = r * polar;
      data[i + 1] = g * polar;
      data[i + 2] = b * polar;
      data[i + 3] = 255;
    }
  }
  return new Uint32Array(data.buffer);
}

// Zonal winds: latitude zones that slide against each other (bounded, periodic),
// with soft transitions where the band edges shear and ripple. Storms sit in zone cores.
function buildZones() {
  const st = STORMS.slice().sort((a, b) => a.vc - b.vc);
  const lo = st[0];
  const hi = st[1];
  const edges = [];
  const mid = ((lo.vc + lo.h * 1.25) + (hi.vc - hi.h * 1.25)) * 0.5;
  let e = lo.vc - lo.h * 1.25 - 13;
  const above = [];
  while (e > 24) { above.unshift(e); e -= 58; }
  edges.push(...above, mid);
  e = hi.vc + hi.h * 1.25 + 13;
  while (e < BAND_H - 24) { edges.push(e); e += 58; }
  const nz = edges.length + 1;
  const R = U.mulberry32(4242);
  const amp = [];
  const per = [];
  const ph = [];
  for (let i = 0; i < nz; i++) {
    amp.push((14 + R() * 20) * (i % 2 ? 1 : -1));
    per.push(140 + R() * 190);
    ph.push(R() * TAU);
  }
  const za = new Uint8Array(BAND_H);
  const zb = new Uint8Array(BAND_H);
  const mix = new Float32Array(BAND_H);
  const edge = new Float32Array(BAND_H);
  const HW = 11;
  for (let y = 0; y < BAND_H; y++) {
    let z = 0;
    while (z < edges.length && y >= edges[z]) z++;
    za[y] = z; zb[y] = z; mix[y] = 0;
    // Nearest edge for blending.
    let best = -1, bd = 1e9;
    for (let k = 0; k < edges.length; k++) {
      const dd = Math.abs(y - edges[k]);
      if (dd < bd) { bd = dd; best = k; }
    }
    if (best >= 0 && bd < HW) {
      const m = U.smoothstep(-HW, HW, y - edges[best]);
      za[y] = best; zb[y] = best + 1; mix[y] = m;
      edge[y] = 1 - bd / HW;
    }
  }
  return { nz, amp, per, ph, za, zb, mix, edge, val: new Float32Array(nz) };
}

// Static map of the visible hemisphere at low resolution: texel row and longitude.
function buildAlbedoMap(res) {
  const half = res * 0.5;
  const r0 = half - 2.5;
  const n = res * res;
  const idx = new Int32Array(n);
  const ry = new Uint16Array(n);
  const texRow = new Uint32Array(n);
  const lonT = new Float32Array(n);
  const canvas = document.createElement('canvas');
  canvas.width = res;
  canvas.height = res;
  const ctx = canvas.getContext('2d');
  const image = ctx.createImageData(res, res);
  const out32 = new Uint32Array(image.data.buffer);
  let k = 0;
  let bx0 = res, bx1 = 0, by0 = res, by1 = 0;
  for (let y = 0; y < res; y++) {
    for (let x = 0; x < res; x++) {
      const px = x + 0.5 - half;
      const py = y + 0.5 - half;
      const dist = Math.sqrt(px * px + py * py);
      if (dist > half) continue;
      let X = px / r0;
      let Y = py / r0;
      let d2 = X * X + Y * Y;
      if (d2 > 0.9995) {
        const s = Math.sqrt(0.9995 / d2);
        X *= s;
        Y *= s;
        d2 = 0.9995;
      }
      const Z = Math.sqrt(1 - d2);
      // Deep night side (with margin for the roll): lighting multiplies it to black,
      // so it never needs remapping.
      if (X * LIGHT[0] + Y * LIGHT[1] + Z * LIGHT[2] < -0.14) {
        out32[y * res + x] = 0xff6a6470;
        continue;
      }
      const a = X * COS_T + Y * SIN_T;
      const b = -X * SIN_T + Y * COS_T;
      const lat = Math.asin(U.clamp(-b * COS_E + Z * SIN_E, -1, 1));
      const lon = Math.atan2(a, b * SIN_E + Z * COS_E);
      if (x < bx0) bx0 = x;
      if (x > bx1) bx1 = x;
      if (y < by0) by0 = y;
      if (y > by1) by1 = y;
      idx[k] = y * res + x;
      ry[k] = U.clamp(Math.floor((0.5 - lat / Math.PI) * BAND_H), 0, BAND_H - 1);
      texRow[k] = ry[k] * BAND_W;
      lonT[k] = (lon / TAU) * BAND_W;
      k++;
    }
  }
  const stormLonT = (STORM_LON0 / TAU) * BAND_W;
  const samples = [];
  for (let i = 0; i < 3; i++) {
    const c = i === 0 ? canvas : document.createElement('canvas');
    c.width = res; c.height = res;
    const g = i === 0 ? ctx : c.getContext('2d');
    const im = i === 0 ? image : g.createImageData(res, res);
    const out = new Uint32Array(im.data.buffer);
    if (i !== 0) out.set(out32);
    g.putImageData(im, 0, 0);
    samples.push({ canvas: c, ctx: g, image: im, out32: out,
      rowOff: new Float32Array(BAND_H), tick: NaN, cursor: 0 });
  }
  return {
    res, r0, count: k, idx, ry, texRow, lonT,
    lo: samples[0], hi: samples[1], next: samples[2], mix: 0,
    dirty: [bx0, by0, bx1 - bx0 + 1, by1 - by0 + 1],
    offset: 2048 + (((STORMS[0].u - stormLonT) % BAND_W) + BAND_W) % BAND_W
  };
}

function beginAlbedoSample(S, tick) {
  const A = albedo;
  const t = tick / ALBEDO_HZ;
  S.tick = tick;
  S.cursor = 0;
  const Z = zones;
  for (let i = 0; i < Z.nz; i++) Z.val[i] = Z.amp[i] * Math.sin(t * TAU / Z.per[i] + Z.ph[i]);
  const base = A.offset - ((t * ROT) % BAND_W);
  const rip = t * 0.45;
  for (let y = 0; y < BAND_H; y++) {
    const m = Z.mix[y];
    let o = Z.val[Z.za[y]] * (1 - m) + Z.val[Z.zb[y]] * m;
    const e = Z.edge[y];
    if (e > 0) o += e * 3.2 * Math.sin(y * 0.41 + rip) * Math.sin(y * 0.13 - rip * 0.6 + 1.0);
    S.rowOff[y] = base + o;
  }
}

function remapAlbedoSample(S, end) {
  if (end <= S.cursor) return;
  const A = albedo;
  const out = S.out32;
  const tex = bandTex;
  const { idx, ry, texRow, lonT } = A;
  const rowOff = S.rowOff;
  const mask = BAND_W - 1;
  for (let k = S.cursor; k < end; k++) {
    const u = lonT[k] + rowOff[ry[k]];
    const i = u | 0;
    const f = u - i;
    const g = 1 - f;
    const rb = texRow[k];
    const c0 = tex[rb + (i & mask)];
    const c1 = tex[rb + ((i + 1) & mask)];
    const r = ((c0 & 255) * g + (c1 & 255) * f) | 0;
    const gg = (((c0 >> 8) & 255) * g + ((c1 >> 8) & 255) * f) | 0;
    const b = (((c0 >> 16) & 255) * g + ((c1 >> 16) & 255) * f) | 0;
    out[idx[k]] = 0xff000000 | (b << 16) | (gg << 8) | r;
  }
  S.cursor = end;
  // Upload only a complete map. A partially remapped canvas is never displayed.
  if (end === A.count) {
    const d = A.dirty;
    S.ctx.putImageData(S.image, 0, 0, d[0], d[1], d[2], d[3]);
  }
}

function primeAlbedo(t) {
  const A = albedo;
  const tick = Math.floor(t * ALBEDO_HZ);
  beginAlbedoSample(A.lo, tick);
  remapAlbedoSample(A.lo, A.count);
  beginAlbedoSample(A.hi, tick + 1);
  remapAlbedoSample(A.hi, A.count);
  beginAlbedoSample(A.next, tick + 2);
}

function renderAlbedo(t) {
  const A = albedo;
  const phase = t * ALBEDO_HZ;
  const tick = Math.floor(phase);
  if (tick === A.hi.tick) {
    // The next complete sample becomes the upper endpoint; recycle the old lower one.
    remapAlbedoSample(A.next, A.count);
    const spare = A.lo;
    A.lo = A.hi; A.hi = A.next; A.next = spare;
    beginAlbedoSample(A.next, tick + 2);
  } else if (tick !== A.lo.tick) {
    // Arbitrary seeks and first frames use exactly the same time bracket as live playback.
    primeAlbedo(t);
  }
  A.mix = phase - tick;
  // Build the following endpoint ahead of time in small chunks. Finish before the
  // current interval ends, with spare frames for 30/60 Hz cadence variation.
  const progress = Math.min(1, (A.mix + 0.13) * 1.12);
  remapAlbedoSample(A.next, Math.ceil(A.count * progress));
}

// Fixed lighting over the disc: terminator and limb darkening, as a multiply layer.
function buildLightLayer(res) {
  const half = res * 0.5;
  const r0 = half - 1.5;
  const c = document.createElement('canvas');
  c.width = res;
  c.height = res;
  const g = c.getContext('2d');
  const image = g.createImageData(res, res);
  const data = image.data;
  const L = LIGHT;
  for (let y = 0; y < res; y++) {
    for (let x = 0; x < res; x++) {
      const px = x + 0.5 - half;
      const py = y + 0.5 - half;
      const dist = Math.sqrt(px * px + py * py);
      if (dist > half) continue;
      let X = px / r0;
      let Y = py / r0;
      let d2 = X * X + Y * Y;
      if (d2 > 0.9995) {
        const s = Math.sqrt(0.9995 / d2);
        X *= s; Y *= s; d2 = 0.9995;
      }
      const Z = Math.sqrt(1 - d2);
      const lam = X * L[0] + Y * L[1] + Z * L[2];
      const day = U.smoothstep(-0.035, 0.05, lam);
      const limb = 0.58 + 0.42 * Math.pow(Z, 0.5);
      const lit = Math.min(1, 0.028 + day * (0.12 + 0.88 * Math.max(lam, 0)) * limb);
      const v = Math.round(lit * 255);
      const i = (y * res + x) * 4;
      data[i] = v; data[i + 1] = v; data[i + 2] = v;
      data[i + 3] = 255;   // the disc clip provides the antialiased edge
    }
  }
  g.putImageData(image, 0, 0);
  return { canvas: c, res, r0 };
}

// Lit-limb atmosphere inside the disc plus the thin halo outside (additive).
function buildGlowLayer(res) {
  const r0 = res * 0.5 - 1.5;
  const size = Math.ceil(res * 1.1 / 2) * 2;
  const half = size * 0.5;
  const c = document.createElement('canvas');
  c.width = size;
  c.height = size;
  const g = c.getContext('2d');
  const image = g.createImageData(size, size);
  const data = image.data;
  const L = LIGHT;
  const ln = Math.hypot(L[0], L[1]);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const px = x + 0.5 - half;
      const py = y + 0.5 - half;
      const dist = Math.sqrt(px * px + py * py);
      const d = dist / r0;
      const i = (y * size + x) * 4;
      if (d < 1) {
        if (d < 0.6) continue;
        const Z = Math.sqrt(Math.max(0, 1 - d * d));
        const edge = Math.pow(1 - Z, 5);
        const limbLit = U.smoothstep(-0.05, 0.5, (px * L[0] + py * L[1]) / (dist * ln));
        const a = edge * limbLit * 0.62;
        data[i] = 196; data[i + 1] = 220; data[i + 2] = 232;
        data[i + 3] = Math.round(U.clamp(a, 0, 1) * 255);
      } else {
        const dir = (px * L[0] + py * L[1]) / (dist * ln);
        const lit = U.smoothstep(-0.15, 0.7, dir);
        const fall = Math.exp(-Math.max(0, d - 1) / 0.016);
        data[i] = 190; data[i + 1] = 216; data[i + 2] = 230;
        data[i + 3] = Math.round(U.clamp(fall * lit * 0.42, 0, 1) * 255);
      }
    }
  }
  g.putImageData(image, 0, 0);
  return { canvas: c, size };
}

// The near ring's shadow on the globe, in the ring frame (planet radii), multiply layer.
function buildRingShadowLayer() {
  const ex = 1.04;
  const ey = 1.25;
  const W = 220;
  const H = Math.round(W * ey / ex);
  const c = document.createElement('canvas');
  c.width = W;
  c.height = H;
  const g = c.getContext('2d');
  const image = g.createImageData(W, H);
  const data = image.data;
  for (let y = 0; y < H; y++) {
    const b = ((y + 0.5) / H * 2 - 1) * ey;
    for (let x = 0; x < W; x++) {
      const a = ((x + 0.5) / W * 2 - 1) * ex;
      let acc = 0;
      for (let j = 0; j < 6; j++) {
        const bb = b + 0.035 + j * 0.016;
        if (bb <= 0) continue;
        const sx = a / RING_OUTER;
        const sy = bb / (RING_OUTER * RING_FLAT);
        const q = (Math.sqrt(sx * sx + sy * sy) - RING_INNER) / (1 - RING_INNER);
        if (q >= 0 && q <= 1) acc += ringAlpha(q);
      }
      const v = Math.round((1 - Math.min(0.78, (acc / 6) * 1.15)) * 255);
      const i = (y * W + x) * 4;
      data[i] = v; data[i + 1] = v; data[i + 2] = v; data[i + 3] = 255;
    }
  }
  g.putImageData(image, 0, 0);
  return { canvas: c, ex, ey };
}

// ---------------------------------------------------------------------------
// Rings
// ---------------------------------------------------------------------------

const RING_COLORS = [
  [134, 130, 145], [201, 174, 145], [91, 103, 116], [220, 202, 170],
  [94, 103, 112], [177, 135, 139], [133, 156, 166]
];

function ringZone(q) {
  if (q < 0.10) return 0;
  if (q < 0.24) return 1;
  if (q < 0.29) return 2;
  if (q < 0.55) return 3;
  if (q < 0.61) return 4;
  if (q < 0.81) return 5;
  return 6;
}

function ringAlpha(q) {
  let alpha;
  switch (ringZone(q)) {
    case 0: alpha = 0.14 + q * 1.6; break;
    case 1: alpha = 0.60 + Math.sin((q - 0.10) / 0.14 * Math.PI) * 0.22; break;
    case 2: alpha = 0.05; break;
    case 3: alpha = 0.86 + Math.sin((q - 0.29) / 0.26 * Math.PI) * 0.10; break;
    case 4: alpha = 0.07; break;
    case 5: alpha = 0.64 + Math.sin((q - 0.61) / 0.20 * Math.PI) * 0.16; break;
    default: alpha = 0.34 * (1 - U.smoothstep(0.81, 1, q)) + 0.04;
  }
  const grooves = 0.94 + Math.sin(q * TAU * 31) * 0.04 +
    Math.sin(q * TAU * 73 + 0.8) * 0.02;
  return U.clamp(alpha * grooves, 0, 0.97);
}

function buildRingImage(r, dpr) {
  const outer = r * RING_OUTER;
  const flatten = RING_FLAT;
  const Lr = LIGHT_R;
  const width = Math.ceil(outer * 2 + 10);
  const height = Math.ceil(outer * flatten * 2 + 10);
  const c = document.createElement('canvas');
  c.width = Math.max(2, Math.ceil(width * dpr));
  c.height = Math.max(2, Math.ceil(height * dpr));
  const g = c.getContext('2d');
  const image = g.createImageData(c.width, c.height);
  const data = image.data;
  const cx = c.width * 0.5;
  const cy = c.height * 0.5;
  const outerX = outer * dpr;
  const outerY = outer * flatten * dpr;
  const inner = RING_INNER;

  for (let y = 0; y < c.height; y++) {
    const sy = (y + 0.5 - cy) / outerY;
    for (let x = 0; x < c.width; x++) {
      const sx = (x + 0.5 - cx) / outerX;
      const radial = Math.sqrt(sx * sx + sy * sy);
      const q = (radial - inner) / (1 - inner);
      if (q < 0 || q > 1) continue;
      const alpha = ringAlpha(q);
      const col = RING_COLORS[ringZone(q)];
      const leftLight = 0.74 + (1 - U.smoothstep(-0.82, 0.88, sx)) * 0.26;
      const px = sx * RING_OUTER;
      const w = sy * RING_OUTER;
      const b = px * Lr[0] + w * SIN_E * Lr[1] + w * COS_E * Lr[2];
      const cc = px * px + w * w - 1;
      const shadow = U.smoothstep(0.02, -0.10, b) * U.smoothstep(-0.07, 0.09, b * b - cc);
      const light = leftLight * (1 - shadow * 0.86);
      const i = (y * c.width + x) * 4;
      data[i] = Math.round(U.clamp(col[0] * light, 0, 255));
      data[i + 1] = Math.round(U.clamp(col[1] * light, 0, 255));
      data[i + 2] = Math.round(U.clamp(col[2] * light, 0, 255));
      data[i + 3] = Math.round(alpha * 255);
    }
  }
  g.putImageData(image, 0, 0);
  return { canvas: c, width, height };
}

function ringTransform(ctx, p) {
  ctx.translate(p.x, p.y);
  ctx.rotate(p.ang);
  ctx.scale(1, p.breath);
}

function drawRingImage(ctx) {
  ctx.drawImage(ringImage.canvas, -ringImage.width * 0.5, -ringImage.height * 0.5,
    ringImage.width, ringImage.height);
}

function drawRing(ctx, p) {
  ctx.save();
  ringTransform(ctx, p);
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  drawRingImage(ctx);
  ctx.restore();
}

function drawNearRingAcrossPlanet(ctx, p) {
  ctx.save();
  ctx.beginPath();
  ctx.arc(p.x, p.y, p.r + 0.6, 0, TAU);
  ctx.clip();
  ringTransform(ctx, p);
  ctx.beginPath();
  ctx.rect(-ringImage.width * 0.5, -0.5, ringImage.width, ringImage.height * 0.5 + 1);
  ctx.clip();
  drawRingImage(ctx);
  ctx.restore();
}

// Ring over a moon that sits below the ring plane on the near side.
function drawRingOver(ctx, p, m) {
  ctx.save();
  ctx.beginPath();
  ctx.arc(m.x, m.y, m.size * 0.9 + 0.5, 0, TAU);
  ctx.clip();
  ringTransform(ctx, p);
  drawRingImage(ctx);
  ctx.restore();
}

// Planet shadow on the ring plane at (rx, ry) in ring-plane planet radii.
function ringShadowAt(rx, ry) {
  const Lr = LIGHT_R;
  const b = rx * Lr[0] + ry * SIN_E * Lr[1] + ry * COS_E * Lr[2];
  const cc = rx * rx + ry * ry - 1;
  return U.smoothstep(0.02, -0.10, b) * U.smoothstep(-0.07, 0.09, b * b - cc);
}

// Clumps, a travelling brightness ripple and sparse glints on the far (near=false)
// or near (near=true) half of the rings.
function drawRingLife(ctx, p, t, near, quality) {
  const r = p.r;
  const rip = -t * 0.026;
  ctx.save();
  ctx.translate(p.x, p.y);
  ctx.rotate(p.ang);
  ctx.scale(1, p.sE);
  const n = Math.floor(CLUMPS.length * (0.6 + 0.4 * quality));
  for (let i = 0; i < n; i++) {
    const c = CLUMPS[i];
    const th = c.th - t * c.w;
    const sn = Math.sin(th);
    if ((sn >= 0) !== near) continue;
    const cs = Math.cos(th);
    const rx = c.rho * cs;
    const ry = c.rho * sn;
    const sh = ringShadowAt(rx, ry);
    const wave = 0.5 + 0.5 * Math.cos(th - rip * 1.0 + c.rho * 1.7);
    const a = c.a * (0.35 + 0.65 * wave * wave) * (1 - 0.9 * sh) * (0.8 + 0.2 * cs * -1);
    if (a < 0.006) continue;
    U.glow(ctx, rx * r, ry * r, c.s * r, '#f2e4cc', a, 0.9);
  }
  // Soft brightness ripple: three broad swells travelling round the bright B ring.
  for (let k = 0; k < 3; k++) {
    const th = rip + k * TAU / 3;
    const sn = Math.sin(th);
    if ((sn >= 0) !== near) continue;
    const cs = Math.cos(th);
    const sh = ringShadowAt(1.46 * cs, 1.46 * sn);
    U.glow(ctx, 1.46 * cs * r, 1.46 * sn * r, 0.34 * r, '#e8d8bd', 0.05 * (1 - 0.9 * sh), 0.95);
  }
  ctx.restore();

  // Glints in screen space (round, tiny), smooth slow sparkle.
  const ca = Math.cos(p.ang);
  const sa = Math.sin(p.ang);
  const ng = Math.floor(GLINTS.length * quality);
  for (let i = 0; i < ng; i++) {
    const gl = GLINTS[i];
    const th = gl.th - t * gl.w;
    const sn = Math.sin(th);
    if ((sn >= 0) !== near) continue;
    const s = Math.sin(t * TAU / gl.per + gl.ph);
    if (s <= 0.2) continue;
    const pk = Math.pow((s - 0.2) / 0.8, 3);
    const cs = Math.cos(th);
    const sh = ringShadowAt(gl.rho * cs, gl.rho * sn);
    const a = pk * 0.42 * (1 - sh);
    if (a < 0.01) continue;
    const lx = gl.rho * cs * r;
    const ly = gl.rho * sn * p.sE * r;
    const x = p.x + lx * ca - ly * sa;
    const y = p.y + lx * sa + ly * ca;
    U.glow(ctx, x, y, r * 0.022, '#fff4e2', a, 0.5);
  }
}

// ---------------------------------------------------------------------------
// Moons
// ---------------------------------------------------------------------------

function buildMoonSprite(size, base) {
  const c = document.createElement('canvas');
  c.width = size;
  c.height = size;
  const g = c.getContext('2d');
  const image = g.createImageData(size, size);
  const data = image.data;
  const half = size * 0.5;
  const lx = LIGHT[0];
  const ly = LIGHT[1];
  const lz = LIGHT[2];
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const nx = (x - half + 0.5) / (half * 0.88);
      const ny = (y - half + 0.5) / (half * 0.88);
      const d = nx * nx + ny * ny;
      if (d >= 1) continue;
      const nz = Math.sqrt(1 - d);
      const lambert = nx * lx + ny * ly + nz * lz;
      const day = U.smoothstep(-0.08, 0.12, lambert);
      const limb = 0.52 + 0.48 * nz;
      const mott = 0.9 + 0.2 * U.noise2(nx * 3 + base[0] * 0.1, ny * 3);
      const light = (0.06 + day * (0.35 + U.clamp(lambert, 0, 1) * 0.59)) * limb * mott;
      const i = (y * size + x) * 4;
      data[i] = Math.round(Math.min(255, base[0] * light));
      data[i + 1] = Math.round(Math.min(255, base[1] * light));
      data[i + 2] = Math.round(Math.min(255, base[2] * light));
      data[i + 3] = Math.round(U.smoothstep(0.0, 0.045, 1 - d) * 255);
    }
  }
  g.putImageData(image, 0, 0);
  return c;
}

function moonState(out, p, index, t) {
  const M = MOONS[index];
  const phi = M.ph - t * M.w;
  // Planet frame: x along the ring's long axis, y along the ring plane toward the
  // viewer, z along the pole.
  const ox = M.rho * Math.cos(phi);
  const oy = M.rho * Math.sin(phi) * Math.cos(M.inc);
  const oz = M.rho * Math.sin(phi) * Math.sin(M.inc);
  const cn = Math.cos(M.node);
  const sn = Math.sin(M.node);
  const x = ox * cn - oy * sn;
  const y = ox * sn + oy * cn;
  const z = oz;
  // Ring screen frame (a right, b down, Z toward viewer).
  const a = x;
  const b = y * p.sE - z * p.cE;
  const Z = y * p.cE + z * p.sE;
  const ca = Math.cos(p.ang);
  const sa = Math.sin(p.ang);
  out.x = p.x + p.r * (a * ca - b * sa);
  out.y = p.y + p.r * (a * sa + b * ca);
  out.behindPlanet = Z < 0;
  out.behindRing = z < 0;
  out.size = p.r * M.size * (1 + 0.04 * Z / M.rho);
  // Planet's shadow (cylinder along the light) in the ring frame.
  const L = LIGHT_R;
  const s = a * L[0] + b * L[1] + Z * L[2];
  let shade = 0;
  if (s < 0) {
    const perp = Math.sqrt(Math.max(0, a * a + b * b + Z * Z - s * s));
    shade = U.smoothstep(1.06, 0.92, perp);
  }
  out.shade = shade;
  return out;
}

function drawMoon(ctx, m, index) {
  const M = MOONS[index];
  const lit = 1 - m.shade;
  if (lit > 0.02) U.glow(ctx, m.x, m.y, m.size * 2.2, M.glow, 0.12 * lit * m.alpha, 0.84);
  if (m.shade > 0.01 || m.alpha < 1) {
    // Darken toward the sky (planet shadow, or near the clock) without going transparent.
    ctx.drawImage(moonSprites[index], m.x - m.size, m.y - m.size, m.size * 2, m.size * 2);
    ctx.fillStyle = `rgba(2, 4, 9, ${1 - (1 - 0.9 * m.shade) * m.alpha})`;
    ctx.beginPath();
    ctx.arc(m.x, m.y, m.size * 0.89, 0, TAU);
    ctx.fill();
  } else {
    ctx.drawImage(moonSprites[index], m.x - m.size, m.y - m.size, m.size * 2, m.size * 2);
  }
}
