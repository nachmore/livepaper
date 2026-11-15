/*
 * Ringed Giant
 *
 * A quiet gas giant lit from the upper left. The planet is an orthographic sphere
 * remapped from a latitude/longitude band texture with lighting, the near ring's
 * shadow and the limb glow baked in per pixel. The remap only reruns when the band
 * drift advances by 1/8 texel (every ~0.4 s); every frame is a few drawImage calls.
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
const DRIFT = 0.31;          // band drift, texels per second (1024 texels = one turn)
const DRIFT_STEP = 8;        // remap whenever the drift crosses 1/8 texel
const STORM_LON0 = -0.62;   // storm longitude (rad) at t = 0; moves left to right

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

const stars = U.makeStars({
  count: 430,
  seed: 184,
  tint: '#bdcad8',
  twinkle: 0.12,
  glow: 0.94
});

let sky = null;
let bandTex = null;          // Uint32Array, BAND_W x BAND_H, RGBA packed
let planet = null;           // { canvas, ctx, image, out32, map arrays, res, r0 }
let halo = null;
let ringImage = null;
let moonSprites = null;
let lastShift = NaN;

LivePaper.scene({
  context: '2d',

  resize(lp) {
    sky = buildSky(lp);
    if (!bandTex) bandTex = buildBandTexture();
    const r = planetRadius(lp);
    const res = Math.round(U.clamp(2 * r * Math.min(lp.dpr, 2) * 0.85, 256, 720) / 2) * 2;
    if (!planet || planet.res !== res) {
      planet = buildPlanetMap(res);
      halo = buildHalo(res);
    }
    lastShift = NaN;
    ringImage = buildRingImage(r, Math.min(lp.dpr, 1.5));
    moonSprites = [
      buildMoonSprite(72, [210, 191, 155]),
      buildMoonSprite(64, [153, 179, 188])
    ];
  },

  draw(lp) {
    const ctx = lp.ctx;
    const motion = lp.env.reducedMotion ? 0.25 : 1;
    const t = lp.t * motion;
    const phase = ((t % 720) / 720) * TAU;
    const p = planetLayout(lp, phase);
    const shift = Math.floor(((t * DRIFT) % BAND_W) * DRIFT_STEP) / DRIFT_STEP;
    if (shift !== lastShift) {
      renderPlanet(shift);
      lastShift = shift;
    }

    ctx.drawImage(sky.canvas, 0, 0, lp.w, lp.h);
    stars.draw(ctx, lp, {
      dx: -t * 0.27,
      dy: t * 0.035,
      fraction: lp.quality,
      brightness: 0.62,
      size: 0.88
    });

    drawMoonPass(ctx, p, 0, t, false);
    drawMoonPass(ctx, p, 1, t, false);

    // Whole ring -> opaque globe (hides the far half) -> near half again, clipped to
    // the disc. Outside the disc the ring is painted once, so the ansae have no seam.
    drawRing(ctx, p);

    const scale = p.r / planet.r0;
    const hs = halo.width * scale;
    ctx.drawImage(halo, p.x - hs * 0.5, p.y - hs * 0.5, hs, hs);
    const ps = planet.res * scale;
    ctx.drawImage(planet.canvas, p.x - ps * 0.5, p.y - ps * 0.5, ps, ps);

    drawNearRingAcrossPlanet(ctx, p);

    drawMoonPass(ctx, p, 0, t, true);
    drawMoonPass(ctx, p, 1, t, true);
  }
});

function planetRadius(lp) {
  if (lp.aspect > 2.15) return lp.h * 0.31;
  if (lp.aspect < 1.28) return lp.min * 0.225;
  return lp.min * 0.235;
}

function planetLayout(lp, phase) {
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
  return {
    x: x + Math.sin(phase) * lp.min * 0.010,
    y: y + Math.sin(phase * 0.79 + 0.6) * lp.min * 0.005,
    r
  };
}

function buildSky(lp) {
  const L = U.layer(lp.w, lp.h, lp.dpr);
  const g = L.ctx;
  const bg = g.createLinearGradient(0, 0, 0, lp.h);
  bg.addColorStop(0, '#010309');
  bg.addColorStop(0.42, '#030813');
  bg.addColorStop(0.78, '#071321');
  bg.addColorStop(1, '#091725');
  g.fillStyle = bg;
  g.fillRect(0, 0, lp.w, lp.h);

  const wide = lp.aspect > 2.15;
  const rnd = U.mulberry32(932);
  const cloudCount = wide ? 18 : 11;
  for (let i = 0; i < cloudCount; i++) {
    const x = lp.w * (wide ? 0.57 : 0.66) + rnd() * lp.w * (wide ? 0.43 : 0.34);
    const y = lp.h * (0.27 + rnd() * 0.58);
    const radius = lp.h * (0.16 + rnd() * (wide ? 0.34 : 0.24));
    const violet = i % 3 !== 1;
    const alpha = (wide ? 0.075 : 0.048) + rnd() * (wide ? 0.075 : 0.045);
    const neb = g.createRadialGradient(x, y, 0, x, y, radius);
    neb.addColorStop(0, violet
      ? `rgba(93, 56, 107, ${alpha})`
      : `rgba(39, 103, 108, ${alpha * 0.88})`);
    neb.addColorStop(0.46, violet
      ? `rgba(64, 46, 91, ${alpha * 0.52})`
      : `rgba(31, 73, 84, ${alpha * 0.48})`);
    neb.addColorStop(1, 'rgba(4, 8, 17, 0)');
    g.fillStyle = neb;
    g.fillRect(x - radius, y - radius, radius * 2, radius * 2);
  }

  const lane = g.createLinearGradient(lp.w * 0.56, lp.h, lp.w, lp.h * 0.30);
  lane.addColorStop(0, 'rgba(1, 3, 8, 0)');
  lane.addColorStop(0.46, 'rgba(1, 3, 8, 0.16)');
  lane.addColorStop(0.62, 'rgba(1, 3, 8, 0.04)');
  lane.addColorStop(1, 'rgba(1, 3, 8, 0)');
  g.fillStyle = lane;
  g.fillRect(lp.w * 0.50, lp.h * 0.18, lp.w * 0.50, lp.h * 0.82);

  const bright = wide
    ? [[0.63, 0.43, 2.2], [0.73, 0.72, 1.5], [0.81, 0.34, 1.8],
       [0.88, 0.59, 2.6], [0.94, 0.78, 1.4], [0.70, 0.86, 1.2]]
    : [[0.77, 0.43, 1.6], [0.88, 0.68, 2.0], [0.93, 0.35, 1.3]];
  g.globalCompositeOperation = 'lighter';
  for (let i = 0; i < bright.length; i++) {
    const b = bright[i];
    U.glow(g, lp.w * b[0], lp.h * b[1], lp.min * 0.018 * b[2],
      i % 2 ? '#b8d7d8' : '#d9c4df', 0.22, 0.88);
    g.fillStyle = i % 2 ? 'rgba(210,235,233,0.80)' : 'rgba(238,220,241,0.78)';
    g.beginPath();
    g.arc(lp.w * b[0], lp.h * b[1], Math.max(0.8, lp.min * 0.0017), 0, TAU);
    g.fill();
  }
  g.globalCompositeOperation = 'source-over';

  const clockShade = g.createRadialGradient(
    lp.cx, 0, 0,
    lp.cx, 0, Math.min(lp.w * 0.31, lp.h * 0.72)
  );
  clockShade.addColorStop(0, 'rgba(0, 2, 7, 0.64)');
  clockShade.addColorStop(0.62, 'rgba(0, 2, 7, 0.24)');
  clockShade.addColorStop(1, 'rgba(0, 2, 7, 0)');
  g.fillStyle = clockShade;
  g.fillRect(lp.cx - lp.w * 0.25, 0, lp.w * 0.50, lp.h * 0.44);

  const vignette = g.createRadialGradient(
    lp.cx, lp.h * 0.58, lp.min * 0.12,
    lp.cx, lp.h * 0.58, lp.max * 0.73
  );
  vignette.addColorStop(0, 'rgba(0, 1, 5, 0)');
  vignette.addColorStop(1, 'rgba(0, 1, 4, 0.38)');
  g.fillStyle = vignette;
  g.fillRect(0, 0, lp.w, lp.h);
  return L;
}

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
        // A gentle two-armed spiral of slightly lighter and darker cloud.
        const swirl = Math.sin(2 * Math.atan2(ey, ex) - e * 6.2) * 0.07 * U.smoothstep(0.1, 0.5, e);
        const sr = U.lerp(s.body[0], s.core[0], core) * (1 + swirl);
        const sg = U.lerp(s.body[1], s.core[1], core) * (1 + swirl);
        const sb = U.lerp(s.body[2], s.core[2], core) * (1 + swirl);
        r = U.lerp(r, sr, body);
        g = U.lerp(g, sg, body);
        b = U.lerp(b, sb, body);
      }
      // Calm, muted polar caps (hides the texture's convergence at the poles).
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

// Static per-pixel map of the visible hemisphere: texel row, longitude, lighting
// (terminator, limb darkening, near-ring shadow) and lit-limb atmosphere.
function buildPlanetMap(res) {
  const half = res * 0.5;
  const r0 = half - 1.5;
  const n = res * res;
  const idx = new Int32Array(n);
  const row = new Int32Array(n);
  const lonT = new Float32Array(n);
  const shade = new Float32Array(n);
  const air = new Float32Array(n);
  const cover = new Uint8Array(n);
  const L = LIGHT;
  let k = 0;

  for (let y = 0; y < res; y++) {
    for (let x = 0; x < res; x++) {
      const px = x + 0.5 - half;
      const py = y + 0.5 - half;
      const dist = Math.sqrt(px * px + py * py);
      if (dist > r0 + 0.5) continue;
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
      // Ring/equator frame.
      const a = X * COS_T + Y * SIN_T;
      const b = -X * SIN_T + Y * COS_T;
      const lat = Math.asin(U.clamp(-b * COS_E + Z * SIN_E, -1, 1));
      const lon = Math.atan2(a, b * SIN_E + Z * COS_E);

      const lam = X * L[0] + Y * L[1] + Z * L[2];
      const day = U.smoothstep(-0.035, 0.05, lam);
      const limb = 0.58 + 0.42 * Math.pow(Z, 0.5);

      // The near ring's shadow: a soft copy of the ring's opacity, displaced upward.
      let acc = 0;
      for (let j = 0; j < 6; j++) {
        const bb = b + 0.035 + j * 0.016;
        if (bb <= 0) continue;
        const sx = a / RING_OUTER;
        const sy = bb / (RING_OUTER * RING_FLAT);
        const q = (Math.sqrt(sx * sx + sy * sy) - RING_INNER) / (1 - RING_INNER);
        if (q >= 0 && q <= 1) acc += ringAlpha(q);
      }
      const ringShade = 1 - Math.min(0.78, (acc / 6) * 1.15);

      const lit = day * (0.12 + 0.88 * Math.max(lam, 0)) * limb * ringShade;
      const edge = Math.pow(1 - Z, 5);
      const limbLit = U.smoothstep(-0.05, 0.5, (X * L[0] + Y * L[1]) / Math.hypot(L[0], L[1]));

      idx[k] = (y * res + x) * 4;
      row[k] = U.clamp(Math.floor((0.5 - lat / Math.PI) * BAND_H), 0, BAND_H - 1) * BAND_W;
      lonT[k] = (lon / TAU) * BAND_W;
      shade[k] = 0.028 + lit;
      air[k] = edge * limbLit * 0.62 * ringShade;
      cover[k] = Math.round(U.clamp(r0 + 0.5 - dist, 0, 1) * 255);
      k++;
    }
  }
  const canvas = document.createElement('canvas');
  canvas.width = res;
  canvas.height = res;
  const ctx = canvas.getContext('2d');
  const stormLonT = (STORM_LON0 / TAU) * BAND_W;
  return {
    res, r0, canvas, ctx, count: k,
    image: ctx.createImageData(res, res),
    idx, row, lonT, shade, air, cover,
    offset: 2048 + (((STORMS[0].u - stormLonT) % BAND_W) + BAND_W) % BAND_W
  };
}

function renderPlanet(shift) {
  const P = planet;
  const out = P.image.data;
  const tex = bandTex;
  const { idx, row, lonT, shade, air, cover } = P;
  const off = P.offset - shift;
  const mask = BAND_W - 1;
  for (let k = 0; k < P.count; k++) {
    const u = lonT[k] + off;
    const i = u | 0;
    const f = u - i;
    const g = 1 - f;
    const rb = row[k];
    const c0 = tex[rb + (i & mask)];
    const c1 = tex[rb + ((i + 1) & mask)];
    const s = shade[k];
    const ai = air[k];
    const o = idx[k];
    out[o] = ((c0 & 255) * g + (c1 & 255) * f) * s + ai * 196;
    out[o + 1] = (((c0 >> 8) & 255) * g + ((c1 >> 8) & 255) * f) * s + ai * 220;
    out[o + 2] = (((c0 >> 16) & 255) * g + ((c1 >> 16) & 255) * f) * s + ai * 232;
    out[o + 3] = cover[k];
  }
  P.ctx.putImageData(P.image, 0, 0);
}

// Thin pale glow just outside the lit limb.
function buildHalo(res) {
  const r0 = res * 0.5 - 1.5;
  const size = Math.ceil(res * 1.1 / 2) * 2;
  const half = size * 0.5;
  const c = document.createElement('canvas');
  c.width = size;
  c.height = size;
  const g = c.getContext('2d');
  const image = g.createImageData(size, size);
  const data = image.data;
  const ln = Math.hypot(LIGHT[0], LIGHT[1]);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const px = x + 0.5 - half;
      const py = y + 0.5 - half;
      const d = Math.sqrt(px * px + py * py) / r0;
      if (d < 0.99) continue;
      const dir = (px * LIGHT[0] + py * LIGHT[1]) / (d * r0 * ln);
      const lit = U.smoothstep(-0.15, 0.7, dir);
      const fall = Math.exp(-Math.max(0, d - 1) / 0.016);
      const i = (y * size + x) * 4;
      data[i] = 190;
      data[i + 1] = 216;
      data[i + 2] = 230;
      data[i + 3] = Math.round(U.clamp(fall * lit * 0.42, 0, 1) * 255);
    }
  }
  g.putImageData(image, 0, 0);
  return c;
}

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

// Ring opacity at fractional radius q in [0,1]: dense bands nearly opaque, gaps clear.
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
      // Planet shadow: does the ray from this ring point toward the light hit the globe?
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

function drawRing(ctx, p) {
  ctx.save();
  ctx.translate(p.x, p.y);
  ctx.rotate(RING_TILT);
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(
    ringImage.canvas,
    -ringImage.width * 0.5,
    -ringImage.height * 0.5,
    ringImage.width,
    ringImage.height
  );
  ctx.restore();
}

function drawNearRingAcrossPlanet(ctx, p) {
  ctx.save();
  ctx.beginPath();
  ctx.arc(p.x, p.y, p.r + 0.6, 0, TAU);
  ctx.clip();
  ctx.translate(p.x, p.y);
  ctx.rotate(RING_TILT);
  ctx.beginPath();
  ctx.rect(-ringImage.width * 0.5, -0.5, ringImage.width, ringImage.height * 0.5 + 1);
  ctx.clip();
  ctx.drawImage(
    ringImage.canvas,
    -ringImage.width * 0.5,
    -ringImage.height * 0.5,
    ringImage.width,
    ringImage.height
  );
  ctx.restore();
}

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
      const light = (0.06 + day * (0.35 + U.clamp(lambert, 0, 1) * 0.59)) * limb;
      const i = (y * size + x) * 4;
      data[i] = Math.round(base[0] * light);
      data[i + 1] = Math.round(base[1] * light);
      data[i + 2] = Math.round(base[2] * light);
      data[i + 3] = Math.round(U.smoothstep(0.0, 0.045, 1 - d) * 255);
    }
  }
  g.putImageData(image, 0, 0);
  return c;
}

function moonState(p, index, t) {
  const phase = t * (index === 0 ? 0.0105 : -0.0062) + (index === 0 ? 0.7 : 3.55);
  const orbitX = p.r * (index === 0 ? 2.58 : 1.82);
  const orbitY = p.r * (index === 0 ? 0.74 : 0.54);
  return {
    x: p.x + Math.cos(phase) * orbitX,
    y: p.y + Math.sin(phase) * orbitY,
    front: Math.sin(phase) >= 0,
    size: p.r * (index === 0 ? 0.054 : 0.040)
  };
}

function drawMoonPass(ctx, p, index, t, frontPass) {
  const m = moonState(p, index, t);
  if (m.front !== frontPass) return;
  U.glow(ctx, m.x, m.y, m.size * 2.2,
    index === 0 ? '#d7c6a5' : '#9bbbc4', 0.12, 0.84);
  ctx.drawImage(moonSprites[index], m.x - m.size, m.y - m.size, m.size * 2, m.size * 2);
}
