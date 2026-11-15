/*
 * Ink and Ember — a quiet sumi-e mountain landscape at dusk.
 *
 * The painting is assembled from prerendered ink washes. Mountain edges are
 * made only from overlapping fills: no outlined silhouettes. A low seal-red
 * sun lives in the sky behind the ranges, while broad mist veils drift slowly
 * through the valleys and around a gnarled pine on the near crag.
 */
const U = LivePaper.util;
const TAU = U.TAU;
const SUN_CYCLE = 960;

const RIDGE_SPECS = [
  {
    base: 0.575, lift: 0.105, seed: 11.7, scale: 0.72,
    color: '#71807e', alpha: 0.48, marks: 4, character: 'far',
    peaks: [[0.07, 0.08, 0.14, 0.040], [0.38, 0.10, 0.17, 0.055], [0.79, 0.13, 0.08, 0.042]],
    secondary: [[0.49, 0.045, 0.070, 0.018], [0.89, 0.050, 0.034, 0.014]],
    saddles: [[0.24, 0.13, 0.018], [0.60, 0.16, 0.022], [0.84, 0.028, 0.010]]
  },
  {
    base: 0.635, lift: 0.125, seed: 23.9, scale: 0.88,
    color: '#5b6966', alpha: 0.60, marks: 5, character: 'far',
    peaks: [[0.16, 0.11, 0.07, 0.052], [0.51, 0.08, 0.16, 0.064], [0.91, 0.15, 0.06, 0.050]],
    secondary: [[0.08, 0.040, 0.032, 0.017], [0.60, 0.045, 0.060, 0.022], [0.83, 0.055, 0.034, 0.016]],
    saddles: [[0.33, 0.12, 0.026], [0.73, 0.11, 0.021], [0.56, 0.026, 0.011]]
  },
  {
    base: 0.700, lift: 0.145, seed: 38.2, scale: 1.04,
    color: '#46514d', alpha: 0.72, marks: 6, character: 'craggy',
    peaks: [[0.02, 0.05, 0.13, 0.058], [0.31, 0.09, 0.12, 0.071], [0.67, 0.15, 0.08, 0.060]],
    secondary: [[0.12, 0.035, 0.050, 0.030], [0.39, 0.030, 0.048, 0.032], [0.61, 0.050, 0.026, 0.027], [0.77, 0.028, 0.052, 0.034]],
    saddles: [[0.18, 0.10, 0.026], [0.49, 0.14, 0.032], [0.84, 0.12, 0.025], [0.355, 0.018, 0.018], [0.735, 0.020, 0.017]]
  },
  {
    base: 0.765, lift: 0.165, seed: 52.6, scale: 1.22,
    color: '#303936', alpha: 0.84, marks: 7, character: 'craggy',
    peaks: [[0.12, 0.09, 0.15, 0.074], [0.45, 0.14, 0.07, 0.055], [0.82, 0.08, 0.13, 0.082]],
    secondary: [[0.03, 0.028, 0.050, 0.034], [0.21, 0.050, 0.026, 0.028], [0.53, 0.030, 0.058, 0.036], [0.73, 0.040, 0.024, 0.030], [0.91, 0.030, 0.060, 0.032]],
    saddles: [[0.29, 0.12, 0.032], [0.62, 0.13, 0.028], [0.17, 0.020, 0.017], [0.50, 0.022, 0.020], [0.875, 0.021, 0.018]]
  },
  {
    base: 0.835, lift: 0.185, seed: 69.1, scale: 1.45,
    color: '#1d2421', alpha: 0.94, marks: 8, character: 'broad',
    peaks: [[0.05, 0.06, 0.11, 0.070], [0.36, 0.12, 0.08, 0.088], [0.70, 0.10, 0.16, 0.078]],
    secondary: [[0.14, 0.040, 0.070, 0.025], [0.43, 0.055, 0.036, 0.030], [0.62, 0.055, 0.034, 0.026], [0.81, 0.040, 0.075, 0.024]],
    saddles: [[0.20, 0.11, 0.035], [0.54, 0.12, 0.030], [0.91, 0.15, 0.028], [0.405, 0.025, 0.015]]
  }
];

const PRIMARY_TOWERS = [
  { dx: -0.105, height: 0.255, width: 0.060, lean: -0.020, seed: 91 },
  { dx: -0.048, height: 0.335, width: 0.078, lean: 0.024, seed: 103 },
  { dx: 0.010, height: 0.225, width: 0.054, lean: -0.014, seed: 117 },
  { dx: 0.058, height: 0.295, width: 0.066, lean: 0.034, seed: 131 }
];

const FAR_TOWERS = [
  { dx: -0.045, height: 0.180, width: 0.040, lean: 0.016, seed: 207 },
  { dx: 0.000, height: 0.245, width: 0.052, lean: -0.020, seed: 221 },
  { dx: 0.040, height: 0.205, width: 0.044, lean: 0.025, seed: 239 }
];

let paper = null;
let ridges = [];
let farKarst = null;
let karst = null;
let foreground = null;
let mists = [];
let sun = null;
let overlay = null;
let tiles = null;

LivePaper.scene({
  context: '2d',

  resize(lp) {
    getTiles();
    paper = buildPaper(lp);
    overlay = buildOverlay(lp);
    ridges = RIDGE_SPECS.map(function (spec, index) {
      return buildRidge(lp, spec, index);
    });
    farKarst = buildKarstGroup(lp, FAR_TOWERS, lp.aspect > 2.25 ? 0.245 : 0.275, 0.650, '#64716f', 0.61);
    karst = buildKarstGroup(lp, PRIMARY_TOWERS, lp.aspect > 2.25 ? 0.735 : 0.705, 0.735, '#303b38', 0.93);
    foreground = buildForeground(lp);
    mists = [
      buildMist(lp, 0.548, 0.078, 0.36, 0.42, 0.13),
      buildMist(lp, 0.620, 0.086, 0.44, -0.31, 0.31),
      buildMist(lp, 0.690, 0.094, 0.54, 0.24, 0.49),
      buildMist(lp, 0.755, 0.104, 0.60, -0.18, 0.68),
      buildMist(lp, 0.820, 0.112, 0.58, 0.12, 0.87)
    ];
    sun = buildSun(lp);
  },

  draw(lp) {
    const ctx = lp.ctx;
    const t = lp.env.reducedMotion ? lp.t * 0.25 : lp.t;
    const phase = (t % SUN_CYCLE) / SUN_CYCLE;
    const arc = Math.sin(Math.PI * phase);
    const sunX = lp.w * (0.34 + 0.36 * phase);
    const sunY = lp.h * (0.555 - 0.070 * arc);
    const sunSize = lp.min * 0.235;

    ctx.drawImage(paper.canvas, 0, 0, lp.w, lp.h);
    ctx.globalAlpha = 0.94;
    ctx.drawImage(sun.canvas, sunX - sunSize * 0.5, sunY - sunSize * 0.5, sunSize, sunSize);
    ctx.globalAlpha = 1;
    drawBirds(ctx, lp, t);

    drawBlock(ctx, ridges[0]);
    drawBlock(ctx, farKarst);
    drawMist(ctx, lp, mists[0], t);
    drawBlock(ctx, ridges[1]);
    drawMist(ctx, lp, mists[1], t);
    drawBlock(ctx, ridges[2]);
    drawBlock(ctx, karst);
    drawMist(ctx, lp, mists[2], t);
    drawBlock(ctx, ridges[3]);
    drawMist(ctx, lp, mists[3], t);
    drawBlock(ctx, ridges[4]);
    drawMist(ctx, lp, mists[4], t);
    ctx.drawImage(foreground.canvas, 0, 0, lp.w, lp.h);
    ctx.drawImage(overlay.canvas, 0, 0, lp.w, lp.h);
  }
});

function drawBlock(ctx, b) {
  ctx.drawImage(b.canvas, b.x, b.y, b.w, b.h);
}

/* ---------- ink & paper textures (built once) ---------- */

function getTiles() {
  if (tiles) return tiles;
  const big = periodicNoise(64, 4, 17, 3);
  const fine = periodicNoise(96, 12, 59, 2);
  tiles = {
    bigDark: alphaTile(big, 64, 0.52, 0.95),
    bigLight: alphaTile(big, 64, 0.46, 0.08),
    fineDark: alphaTile(fine, 96, 0.55, 0.98),
    fineLight: alphaTile(fine, 96, 0.44, 0.04),
    fibre: fibreTile(320, 7)
  };
  return tiles;
}

function periodicNoise(size, cells, seed, octaves) {
  const v = new Float32Array(size * size);
  let amp = 1;
  for (let o = 0; o < octaves; o++) {
    const c = cells << o;
    const s = seed * 97 + o * 1013 + 5;
    for (let y = 0; y < size; y++) {
      const fy = y / size * c;
      const iy = Math.floor(fy);
      let ty = fy - iy;
      ty = ty * ty * (3 - 2 * ty);
      const y0 = iy % c + s;
      const y1 = (iy + 1) % c + s;
      for (let x = 0; x < size; x++) {
        const fx = x / size * c;
        const ix = Math.floor(fx);
        let tx = fx - ix;
        tx = tx * tx * (3 - 2 * tx);
        const x0 = ix % c + s * 3;
        const x1 = (ix + 1) % c + s * 3;
        const a = U.hash2(x0, y0);
        const b = U.hash2(x1, y0);
        const cc = U.hash2(x0, y1);
        const d = U.hash2(x1, y1);
        const top = a + (b - a) * tx;
        const bot = cc + (d - cc) * tx;
        v[y * size + x] += amp * (top + (bot - top) * ty);
      }
    }
    amp *= 0.5;
  }
  let lo = Infinity;
  let hi = -Infinity;
  for (let i = 0; i < v.length; i++) {
    lo = Math.min(lo, v[i]);
    hi = Math.max(hi, v[i]);
  }
  for (let i = 0; i < v.length; i++) v[i] = (v[i] - lo) / Math.max(1e-6, hi - lo);
  return v;
}

function ramp(e0, e1, x) {
  const q = Math.min(1, Math.max(0, (x - e0) / (e1 - e0)));
  return q * q * (3 - 2 * q);
}

function alphaTile(values, size, e0, e1) {
  const c = document.createElement('canvas');
  c.width = c.height = size;
  const g = c.getContext('2d');
  const img = g.createImageData(size, size);
  for (let i = 0; i < size * size; i++) {
    img.data[i * 4] = 6;
    img.data[i * 4 + 1] = 10;
    img.data[i * 4 + 2] = 9;
    img.data[i * 4 + 3] = Math.round(255 * ramp(e0, e1, values[i]));
  }
  g.putImageData(img, 0, 0);
  return c;
}

function fibreTile(size, seed) {
  const c = document.createElement('canvas');
  c.width = c.height = size;
  const g = c.getContext('2d');
  const rnd = U.mulberry32(seed);
  const light = new Path2D();
  const dark = new Path2D();
  for (let i = 0; i < 260; i++) {
    const x = rnd() * size;
    const y = rnd() * size;
    const a = rnd() * TAU;
    const len = 6 + rnd() * 26;
    const bend = (rnd() - 0.5) * len * 0.5;
    const ex = Math.cos(a) * len;
    const ey = Math.sin(a) * len;
    const mx = ex * 0.5 - Math.sin(a) * bend;
    const my = ey * 0.5 + Math.cos(a) * bend;
    const p = rnd() < 0.55 ? light : dark;
    for (let ox = -size; ox <= size; ox += size) {
      for (let oy = -size; oy <= size; oy += size) {
        p.moveTo(x + ox, y + oy);
        p.quadraticCurveTo(x + ox + mx, y + oy + my, x + ox + ex, y + oy + ey);
      }
    }
  }
  g.lineCap = 'round';
  g.lineWidth = 0.8;
  g.strokeStyle = 'rgba(226,220,204,0.16)';
  g.stroke(light);
  g.strokeStyle = 'rgba(0,0,0,0.20)';
  g.stroke(dark);
  return c;
}

/* Seamless tiling: rescale the tile once to `cell` px and fill with a repeating pattern. */
function tileOver(g, tile, x, y, w, h, cell, ox, oy) {
  const size = Math.max(4, Math.round(cell));
  const c = document.createElement('canvas');
  c.width = c.height = size;
  const cg = c.getContext('2d');
  cg.imageSmoothingEnabled = true;
  cg.drawImage(tile, 0, 0, size, size);
  g.save();
  g.translate(ox, oy);
  g.fillStyle = g.createPattern(c, 'repeat');
  g.fillRect(x - ox, y - oy, w, h);
  g.restore();
}

/*
 * Ink texture inside a wash that has already been laid down in g: granulation at
 * two scales (pigment pooling dark, paper peaks light), applied source-atop so
 * it only lives where there is ink.
 */
function granulate(g, lp, x, y, w, h, seed, strength) {
  const r = U.mulberry32(seed);
  const big = lp.min * (0.42 + r() * 0.18);
  const fine = lp.min * (0.11 + r() * 0.04);
  g.save();
  g.globalCompositeOperation = 'source-atop';
  g.globalAlpha = 0.20 * strength;
  tileOver(g, tiles.bigDark, x, y, w, h, big, r() * big, r() * big);
  g.globalAlpha = 0.15 * strength;
  tileOver(g, tiles.fineDark, x, y, w, h, fine, r() * fine, r() * fine);
  g.globalCompositeOperation = 'destination-out';
  g.globalAlpha = 0.22 * strength;
  tileOver(g, tiles.bigLight, x, y, w, h, big * 0.8, r() * big, r() * big);
  g.globalAlpha = 0.16 * strength;
  tileOver(g, tiles.fineLight, x, y, w, h, fine, r() * fine, r() * fine);
  g.restore();
}

/*
 * A wash block: paintShade lays ink (gradients, texture, streaks) over the box,
 * then the feathered silhouette mask (several jittered low-alpha passes plus a
 * soft low-resolution bleed) cuts it out.
 */
function inkBlock(lp, bx, by, bw, bh, paintShade, passes, bleed) {
  bx = Math.floor(bx);
  by = Math.floor(by);
  bw = Math.ceil(bw);
  bh = Math.ceil(bh);
  const L = U.layer(bw, bh, lp.dpr);
  const g = L.ctx;
  g.save();
  g.translate(-bx, -by);
  paintShade(g);
  g.restore();

  const M = U.layer(bw, bh, lp.dpr);
  const m = M.ctx;
  m.translate(-bx, -by);
  m.fillStyle = '#fff';
  for (let i = 0; i < passes.length; i++) {
    m.globalAlpha = passes[i].alpha;
    m.fill(passes[i].path);
  }
  if (bleed) {
    const k = Math.max(3, lp.min * 0.0065);
    const S = U.layer(Math.ceil(bw / k) + 2, Math.ceil(bh / k) + 2, 1);
    S.ctx.scale(1 / k, 1 / k);
    S.ctx.translate(-bx, -by);
    S.ctx.fillStyle = '#fff';
    S.ctx.fill(bleed.path);
    m.setTransform(lp.dpr, 0, 0, lp.dpr, 0, 0);
    m.globalAlpha = bleed.alpha;
    m.drawImage(S.canvas, 0, 0, S.w * k, S.h * k);
  }

  g.globalCompositeOperation = 'destination-in';
  g.drawImage(M.canvas, 0, 0, bw, bh);
  g.globalCompositeOperation = 'source-over';
  return { canvas: L.canvas, ctx: g, x: bx, y: by, w: bw, h: bh };
}

function buildOverlay(lp) {
  const L = U.layer(lp.w, lp.h, lp.dpr);
  const g = L.ctx;
  g.globalAlpha = 0.16;
  tileOver(g, tiles.fibre, 0, 0, lp.w, lp.h, 320, 37, 91);
  g.globalAlpha = 0.10;
  tileOver(g, tiles.fibre, 0, 0, lp.w, lp.h, 520, 211, 13);
  g.globalAlpha = 1;
  const vignette = g.createRadialGradient(lp.w * 0.50, lp.h * 0.50, lp.min * 0.25, lp.w * 0.50, lp.h * 0.50, lp.max * 0.75);
  vignette.addColorStop(0, 'rgba(0,0,0,0)');
  vignette.addColorStop(0.60, 'rgba(0,0,0,0.06)');
  vignette.addColorStop(1, 'rgba(0,0,0,0.40)');
  g.fillStyle = vignette;
  g.fillRect(0, 0, lp.w, lp.h);
  return L;
}

function buildPaper(lp) {
  const L = U.layer(lp.w, lp.h, lp.dpr);
  const g = L.ctx;
  const sky = g.createLinearGradient(0, 0, 0, lp.h);
  sky.addColorStop(0, '#0d1316');
  sky.addColorStop(0.30, '#171e1f');
  sky.addColorStop(0.54, '#343632');
  sky.addColorStop(0.72, '#30312d');
  sky.addColorStop(1, '#171b19');
  g.fillStyle = sky;
  g.fillRect(0, 0, lp.w, lp.h);

  const warmth = g.createRadialGradient(lp.w * 0.52, lp.h * 0.58, 0, lp.w * 0.52, lp.h * 0.58, lp.max * 0.48);
  warmth.addColorStop(0, 'rgba(133,72,53,0.095)');
  warmth.addColorStop(0.50, 'rgba(105,66,54,0.040)');
  warmth.addColorStop(1, 'rgba(74,52,47,0)');
  g.fillStyle = warmth;
  g.fillRect(0, 0, lp.w, lp.h);

  const tileSize = 112;
  const tile = document.createElement('canvas');
  tile.width = tile.height = tileSize;
  const tg = tile.getContext('2d');
  const img = tg.createImageData(tileSize, tileSize);
  const rnd = U.mulberry32(713);
  for (let i = 0; i < tileSize * tileSize; i++) {
    const v = rnd() < 0.52 ? 180 : 70;
    img.data[i * 4] = v;
    img.data[i * 4 + 1] = Math.max(0, v - 4);
    img.data[i * 4 + 2] = Math.max(0, v - 10);
    img.data[i * 4 + 3] = 2 + Math.floor(rnd() * 7);
  }
  tg.putImageData(img, 0, 0);
  g.fillStyle = g.createPattern(tile, 'repeat');
  g.fillRect(0, 0, lp.w, lp.h);

  const clockCalm = g.createLinearGradient(0, 0, 0, lp.h * 0.36);
  clockCalm.addColorStop(0, 'rgba(1,4,5,0.30)');
  clockCalm.addColorStop(1, 'rgba(1,4,5,0)');
  g.fillStyle = clockCalm;
  g.fillRect(0, 0, lp.w, lp.h * 0.36);
  return L;
}


function sampleRidge(lp, spec) {
  const points = [];
  const step = Math.max(3, lp.min / 190);
  const count = Math.ceil(lp.w / step);
  for (let i = 0; i <= count; i++) {
    const x = Math.min(lp.w, i * step);
    const u = x / Math.max(1, lp.w);
    const world = x / Math.max(1, lp.min);
    const broad = U.fbm2(world * spec.scale + spec.seed, spec.seed * 0.137, 4);
    const medium = U.noise1(world * spec.scale * 3.8 + spec.seed * 2.31);
    const isCraggy = spec.character === 'craggy';
    const isBroad = spec.character === 'broad';
    const crinkle = (U.fbm2(world * (isCraggy ? 3.7 : 2.65) + spec.seed * 0.71, spec.seed * 0.51, 4) - 0.5) *
      (isCraggy ? 0.034 : isBroad ? 0.023 : 0.020);
    let relief = spec.lift * (0.20 + broad * 0.66);
    for (let k = 0; k < spec.peaks.length; k++) {
      const p = spec.peaks[k];
      relief += sharpPeak(u, p[0], p[1], p[2], isCraggy ? 0.72 : isBroad ? 1.05 : 1.32) * p[3] * 1.18;
    }
    for (let k = 0; k < spec.secondary.length; k++) {
      const p = spec.secondary[k];
      relief += sharpPeak(u, p[0], p[1], p[2], isCraggy ? 0.48 : isBroad ? 0.78 : 0.96) * p[3];
    }
    for (let k = 0; k < spec.saddles.length; k++) {
      const s = spec.saddles[k];
      const q = (u - s[0]) / s[1];
      relief -= Math.exp(-Math.pow(Math.abs(q), isCraggy && s[1] < 0.03 ? 0.86 : 2) * (isCraggy ? 3.0 : 2.4)) * s[2];
    }
    relief += crinkle;
    const fine = (U.noise1(world * (isCraggy ? 39 : isBroad ? 27 : 23) + spec.seed * 4.7) - 0.5) *
      (isCraggy ? 0.0065 : isBroad ? 0.0042 : 0.0028);
    const tooth = isCraggy ?
      (U.noise1(world * 71 + spec.seed * 9.1) - 0.5) * 0.0024 : 0;
    const grain = (medium - 0.5) * (isCraggy ? 0.016 : isBroad ? 0.011 : 0.008) +
      (U.noise1(world * 11.0 + spec.seed) - 0.5) * 0.004 + fine + tooth;
    points.push({ x: x, y: (spec.base - relief + grain) * lp.h });
  }
  return points;
}

function sharpPeak(u, center, left, right, power) {
  const d = u < center ? (center - u) / left : (u - center) / right;
  return Math.exp(-Math.pow(Math.abs(d), power || 1.18) * 2.35);
}


function ridgeAt(points, x) {
  const last = points.length - 1;
  for (let i = 1; i <= last; i++) {
    if (x <= points[i].x) {
      const a = points[i - 1];
      const b = points[i];
      const q = (x - a.x) / Math.max(1, b.x - a.x);
      return a.y + (b.y - a.y) * q;
    }
  }
  return points[last].y;
}

function addSmoothSide(path, points, move) {
  if (move) path.moveTo(points[0].x, points[0].y);
  for (let i = 1; i < points.length - 1; i++) {
    const mx = (points[i].x + points[i + 1].x) * 0.5;
    const my = (points[i].y + points[i + 1].y) * 0.5;
    path.quadraticCurveTo(points[i].x, points[i].y, mx, my);
  }
  const last = points[points.length - 1];
  path.lineTo(last.x, last.y);
}

function drawPine(g, lp, x, ground) {
  const m = lp.min * 0.86;
  const ink = '#080c0b';
  const base = { x: x, y: ground + m * 0.010 };
  const knot = { x: x + m * 0.010, y: ground - m * 0.135 };
  const shoulder = { x: x + m * 0.068, y: ground - m * 0.220 };
  const tip = { x: x + m * 0.142, y: ground - m * 0.320 };

  const trunk = new Path2D();
  trunk.moveTo(base.x - m * 0.010, base.y);
  trunk.bezierCurveTo(x - m * 0.018, ground - m * 0.070, knot.x - m * 0.014, knot.y + m * 0.025, knot.x - m * 0.009, knot.y);
  trunk.bezierCurveTo(knot.x - m * 0.006, knot.y - m * 0.042, shoulder.x - m * 0.018, shoulder.y + m * 0.020, shoulder.x - m * 0.008, shoulder.y);
  trunk.bezierCurveTo(shoulder.x + m * 0.012, shoulder.y - m * 0.045, tip.x - m * 0.012, tip.y + m * 0.024, tip.x - m * 0.004, tip.y);
  trunk.lineTo(tip.x + m * 0.004, tip.y + m * 0.004);
  trunk.bezierCurveTo(tip.x + m * 0.010, tip.y + m * 0.026, shoulder.x + m * 0.020, shoulder.y - m * 0.026, shoulder.x + m * 0.009, shoulder.y + m * 0.006);
  trunk.bezierCurveTo(shoulder.x - m * 0.002, shoulder.y + m * 0.032, knot.x + m * 0.016, knot.y - m * 0.038, knot.x + m * 0.012, knot.y + m * 0.005);
  trunk.bezierCurveTo(knot.x + m * 0.008, knot.y + m * 0.045, base.x + m * 0.012, base.y - m * 0.065, base.x + m * 0.012, base.y);
  trunk.closePath();
  g.fillStyle = ink;
  g.fill(trunk);

  const branches = [
    [knot.x, knot.y + m * 0.010, x - m * 0.030, ground - m * 0.175, x - m * 0.090, ground - m * 0.166, m * 0.0080, m * 0.0020],
    [shoulder.x, shoulder.y + m * 0.008, x + m * 0.150, ground - m * 0.245, x + m * 0.285, ground - m * 0.228, m * 0.0085, m * 0.0022],
    [shoulder.x + m * 0.020, shoulder.y - m * 0.025, x + m * 0.155, ground - m * 0.292, x + m * 0.235, ground - m * 0.288, m * 0.0065, m * 0.0018],
    [tip.x - m * 0.008, tip.y + m * 0.012, x + m * 0.180, ground - m * 0.342, x + m * 0.225, ground - m * 0.350, m * 0.0048, m * 0.0014]
  ];
  for (let i = 0; i < branches.length; i++) {
    const b = branches[i];
    g.fill(taperedBranch(b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]));
  }

  const clusters = [
    { x: x - m * 0.078, y: ground - m * 0.177, rx: m * 0.082, ry: m * 0.027 },
    { x: x + m * 0.150, y: ground - m * 0.243, rx: m * 0.105, ry: m * 0.032 },
    { x: x + m * 0.270, y: ground - m * 0.228, rx: m * 0.084, ry: m * 0.029 },
    { x: x + m * 0.205, y: ground - m * 0.294, rx: m * 0.073, ry: m * 0.027 },
    { x: x + m * 0.218, y: ground - m * 0.351, rx: m * 0.056, ry: m * 0.024 }
  ];
  const pads = new Path2D();
  const cores = new Path2D();
  const ragged = new Path2D();
  const rnd = U.mulberry32(991);
  for (let c = 0; c < clusters.length; c++) {
    const cluster = clusters[c];
    addCloudPad(pads, cluster.x, cluster.y, cluster.rx, cluster.ry, rnd, 1);
    addCloudPad(cores, cluster.x - cluster.rx * 0.12, cluster.y + cluster.ry * 0.03, cluster.rx * 0.52, cluster.ry * 0.54, rnd, 0.68);
    addCloudPad(cores, cluster.x + cluster.rx * 0.24, cluster.y - cluster.ry * 0.04, cluster.rx * 0.42, cluster.ry * 0.46, rnd, 0.62);
    for (let i = 0; i < 10; i++) {
      const side = rnd() < 0.5 ? -1 : 1;
      const px = cluster.x + side * cluster.rx * (0.62 + rnd() * 0.42);
      const py = cluster.y + (rnd() - 0.5) * cluster.ry * 1.55;
      addDab(ragged, px, py, m * (0.008 + rnd() * 0.015), m * (0.0018 + rnd() * 0.0023), (rnd() - 0.5) * 0.26);
    }
  }
  g.globalAlpha = 0.91;
  g.fillStyle = '#111815';
  g.fill(pads);
  g.globalAlpha = 0.90;
  g.fillStyle = ink;
  g.fill(cores);
  g.globalAlpha = 0.90;
  g.fill(ragged);
  g.globalAlpha = 1;
}

function taperedBranch(x0, y0, cx, cy, x1, y1, w0, w1) {
  const dx = x1 - x0;
  const dy = y1 - y0;
  const len = Math.max(1, Math.sqrt(dx * dx + dy * dy));
  const nx = -dy / len;
  const ny = dx / len;
  const p = new Path2D();
  p.moveTo(x0 + nx * w0, y0 + ny * w0);
  p.quadraticCurveTo(cx + nx * (w0 + w1) * 0.42, cy + ny * (w0 + w1) * 0.42, x1 + nx * w1, y1 + ny * w1);
  p.lineTo(x1 - nx * w1, y1 - ny * w1);
  p.quadraticCurveTo(cx - nx * (w0 + w1) * 0.42, cy - ny * (w0 + w1) * 0.42, x0 - nx * w0, y0 - ny * w0);
  p.closePath();
  return p;
}

function addBrushSlash(path, x0, y0, x1, y1, width) {
  const dx = x1 - x0;
  const dy = y1 - y0;
  const len = Math.max(1, Math.sqrt(dx * dx + dy * dy));
  const nx = -dy / len * width;
  const ny = dx / len * width;
  path.moveTo(x0 + nx, y0 + ny);
  path.lineTo(x1 + nx * 0.18, y1 + ny * 0.18);
  path.lineTo(x1 - nx * 0.12, y1 - ny * 0.12);
  path.lineTo(x0 - nx, y0 - ny);
  path.closePath();
}


function addDab(path, x, y, length, width, angle) {
  const dx = Math.cos(angle) * length * 0.5;
  const dy = Math.sin(angle) * length * 0.5;
  const nx = -Math.sin(angle) * width;
  const ny = Math.cos(angle) * width;
  path.moveTo(x - dx + nx * 0.55, y - dy + ny * 0.55);
  path.lineTo(x + dx + nx * 0.22, y + dy + ny * 0.22);
  path.lineTo(x + dx - nx * 0.28, y + dy - ny * 0.28);
  path.lineTo(x - dx - nx * 0.55, y - dy - ny * 0.55);
  path.closePath();
}

function addCloudPad(path, cx, cy, rx, ry, rnd, fullness) {
  const steps = 9;
  path.moveTo(cx - rx, cy + ry * 0.08);
  for (let i = 1; i <= steps; i++) {
    const q = i / steps;
    const x = cx - rx + q * rx * 2;
    const arch = Math.sin(q * Math.PI);
    const y = cy - ry * (0.20 + arch * (0.54 + rnd() * 0.25)) + (rnd() - 0.5) * ry * 0.24;
    path.lineTo(x, y);
  }
  for (let i = steps - 1; i >= 0; i--) {
    const q = i / steps;
    const x = cx - rx + q * rx * 2;
    const belly = Math.sin(q * Math.PI);
    const y = cy + ry * (0.12 + belly * (0.26 + rnd() * 0.18) * fullness) + (rnd() - 0.5) * ry * 0.18;
    path.lineTo(x, y);
  }
  path.closePath();
}

function buildMist(lp, yFactor, heightFactor, alpha, speed, phase) {
  const targetW = Math.max(lp.w * 0.68, lp.min * 1.45);
  const targetH = Math.max(40, lp.min * heightFactor);
  const L = U.layer(Math.ceil(targetW / 4.2), Math.ceil(targetH / 3.2), 1);
  const g = L.ctx;
  const w = L.w;
  const h = L.h;
  const veil = g.createLinearGradient(0, 0, 0, h);
  veil.addColorStop(0, 'rgba(218,222,211,0)');
  veil.addColorStop(0.22, 'rgba(220,224,213,0.10)');
  veil.addColorStop(0.50, 'rgba(229,226,211,0.27)');
  veil.addColorStop(0.76, 'rgba(207,216,210,0.11)');
  veil.addColorStop(1, 'rgba(202,211,205,0)');
  g.fillStyle = veil;
  g.fillRect(0, 0, w, h);

  const rnd = U.mulberry32(Math.floor(phase * 1000) + 51);
  for (let i = 0; i < 9; i++) {
    const cx = w * (-0.05 + i / 8 * 1.10) + (rnd() - 0.5) * w * 0.06;
    const cy = h * (0.43 + (rnd() - 0.5) * 0.18);
    const rx = w * (0.10 + rnd() * 0.08);
    const ry = h * (0.22 + rnd() * 0.16);
    g.fillStyle = 'rgba(232,230,216,' + (0.030 + rnd() * 0.030) + ')';
    g.beginPath();
    g.ellipse(cx, cy, rx, ry, 0, 0, TAU);
    g.fill();
  }

  const mask = g.createLinearGradient(0, 0, w, 0);
  mask.addColorStop(0, 'rgba(0,0,0,0)');
  mask.addColorStop(0.12, 'rgba(0,0,0,0.96)');
  mask.addColorStop(0.50, 'rgba(0,0,0,1)');
  mask.addColorStop(0.88, 'rgba(0,0,0,0.96)');
  mask.addColorStop(1, 'rgba(0,0,0,0)');
  g.globalCompositeOperation = 'destination-in';
  g.fillStyle = mask;
  g.fillRect(0, 0, w, h);
  g.globalCompositeOperation = 'source-over';

  return {
    canvas: L.canvas,
    w: targetW,
    h: targetH,
    y: lp.h * yFactor - targetH * 0.52,
    alpha: alpha,
    speed: speed,
    offset: targetW * (0.21 + phase),
    phase: phase * 5.7,
    breathe: 0.006 + phase * 0.002
  };
}

function drawMist(ctx, lp, mist, t) {
  const span = lp.w + mist.w;
  const x = wrap(t * mist.speed + mist.offset, span) - mist.w;
  ctx.globalAlpha = mist.alpha * (0.88 + 0.12 * Math.sin(t * mist.breathe + mist.phase));
  ctx.drawImage(mist.canvas, x, mist.y, mist.w, mist.h);
  ctx.drawImage(mist.canvas, x + span, mist.y, mist.w, mist.h);
  ctx.globalAlpha = 1;
}

function wrap(value, length) {
  return ((value % length) + length) % length;
}

function buildSun(lp) {
  const size = Math.max(72, Math.ceil(lp.min * 0.235));
  const L = U.layer(size, size, 1);
  const g = L.ctx;
  const c = size * 0.5;
  const r = size * 0.205;
  const glow = g.createRadialGradient(c, c, r * 0.20, c, c, size * 0.50);
  glow.addColorStop(0, 'rgba(188,75,50,0.16)');
  glow.addColorStop(0.46, 'rgba(165,65,47,0.065)');
  glow.addColorStop(1, 'rgba(131,53,43,0)');
  g.fillStyle = glow;
  g.fillRect(0, 0, size, size);

  const softEdge = makeSunPath(c, c, r * 1.05, 44.2, 0.070);
  g.globalAlpha = 0.34;
  g.fillStyle = '#9a3b32';
  g.fill(softEdge);
  g.globalAlpha = 1;

  const stamp = makeSunPath(c, c, r, 44.8, 0.120);
  const disc = g.createRadialGradient(c - r * 0.18, c - r * 0.18, r * 0.10, c, c, r * 1.06);
  disc.addColorStop(0, '#c05a43');
  disc.addColorStop(0.68, '#aa4738');
  disc.addColorStop(1, 'rgba(139,51,42,0.78)');
  g.fillStyle = disc;
  g.fill(stamp);

  const rnd = U.mulberry32(44);
  g.save();
  g.clip(stamp);
  for (let i = 0; i < 38; i++) {
    const a = rnd() * TAU;
    const d = Math.sqrt(rnd()) * r * 0.91;
    const rr = r * (0.016 + rnd() * 0.060);
    g.globalAlpha = 0.045 + rnd() * 0.105;
    g.fillStyle = rnd() < 0.42 ? '#e19472' : '#64282a';
    g.beginPath();
    g.ellipse(c + Math.cos(a) * d, c + Math.sin(a) * d, rr * (0.7 + rnd() * 0.8), rr, rnd() * TAU, 0, TAU);
    g.fill();
  }
  g.restore();
  g.globalAlpha = 1;
  return L;
}

function makeSunPath(cx, cy, radius, seed, roughness) {
  const p = new Path2D();
  const steps = 72;
  for (let i = 0; i <= steps; i++) {
    const a = i / steps * TAU;
    const n = U.fbm2(Math.cos(a) * 2.2 + seed, Math.sin(a) * 2.2 + seed * 0.71, 3);
    const tooth = U.noise1(i * 0.47 + seed * 3.4);
    const rr = radius * (1 + (n - 0.5) * roughness + (tooth - 0.5) * roughness * 0.34);
    const x = cx + Math.cos(a) * rr;
    const y = cy + Math.sin(a) * rr;
    if (i === 0) p.moveTo(x, y);
    else p.lineTo(x, y);
  }
  p.closePath();
  return p;
}

function drawBirds(ctx, lp, t) {
  const cycle = 172;
  const phase = (t % cycle) / cycle;
  const fade = U.smoothstep(0.02, 0.12, phase) * (1 - U.smoothstep(0.84, 0.98, phase));
  if (fade <= 0.001) return;
  const travel = U.smoothstep(0, 1, phase);
  const leadX = lp.w * (0.92 - travel * 0.80);
  const baseY = lp.h * 0.335;
  ctx.save();
  ctx.strokeStyle = 'rgba(9,13,12,' + (0.34 * fade) + ')';
  ctx.lineWidth = Math.max(0.65, lp.min * 0.00085);
  ctx.lineCap = 'round';
  for (let i = 0; i < 3; i++) {
    const x = leadX + lp.min * (i * 0.024);
    const y = baseY + lp.min * (i * 0.010 + Math.sin(phase * TAU + i * 1.7) * 0.004);
    const wing = lp.min * (0.0065 + i * 0.0006);
    ctx.beginPath();
    ctx.moveTo(x - wing, y);
    ctx.quadraticCurveTo(x - wing * 0.42, y - wing * 0.42, x, y);
    ctx.quadraticCurveTo(x + wing * 0.43, y - wing * 0.34, x + wing, y + wing * 0.04);
    ctx.stroke();
  }
  ctx.restore();
}
function buildRidge(lp, spec, index) {
  const points = sampleRidge(lp, spec);
  let topY = lp.h;
  for (let i = 0; i < points.length; i++) topY = Math.min(topY, points[i].y);
  const by = Math.max(0, topY - lp.min * 0.03);
  const footY = Math.min(lp.h, spec.base * lp.h + lp.min * (0.105 + index * 0.008));
  const a = spec.alpha;
  const lead = lp.min * 0.010;
  const depth = lp.h * (0.10 + index * 0.017);

  // Vertical ink profile that follows the ridge line: darkest just inside it.
  const strip = document.createElement('canvas');
  strip.width = 1;
  strip.height = 256;
  const sg = strip.getContext('2d');
  const sgrad = sg.createLinearGradient(0, 0, 0, 256);
  const leadQ = lead / depth;
  sgrad.addColorStop(0, U.rgba(spec.color, a * 0.25));
  sgrad.addColorStop(leadQ, U.rgba(spec.color, a * 0.92));
  sgrad.addColorStop(leadQ + 0.05, U.rgba(spec.color, a));
  sgrad.addColorStop(leadQ + 0.12, U.rgba(spec.color, a * 0.86));
  sgrad.addColorStop(0.34, U.rgba(spec.color, a * 0.55));
  sgrad.addColorStop(0.64, U.rgba(spec.color, a * 0.22));
  sgrad.addColorStop(1, U.rgba(spec.color, 0));
  sg.fillStyle = sgrad;
  sg.fillRect(0, 0, 1, 256);

  const ext = lp.min * 0.03;
  const paint = function (g) {
    const body = g.createLinearGradient(0, topY, 0, footY);
    body.addColorStop(0, U.rgba(spec.color, a * 0.36));
    body.addColorStop(0.5, U.rgba(spec.color, a * 0.24));
    body.addColorStop(1, U.rgba(spec.color, 0));
    g.fillStyle = body;
    g.fillRect(-ext, by, lp.w + ext * 2, lp.h - by);
    const step = 2;
    let k = 1;
    for (let x = -Math.ceil(ext / step) * step; x < lp.w + ext; x += step) {
      const px = Math.min(lp.w, Math.max(0, x + step * 0.5));
      while (k < points.length - 1 && points[k].x < px) k++;
      const p0 = points[k - 1];
      const p1 = points[k];
      const q = Math.min(1, Math.max(0, (px - p0.x) / Math.max(1, p1.x - p0.x)));
      const y = p0.y + (p1.y - p0.y) * q;
      g.drawImage(strip, x, y - lead, step, depth);
    }
    granulate(g, lp, -ext, by, lp.w + ext * 2, lp.h - by, 300 + index * 17, 0.8 + index * 0.08);

    const rnd = U.mulberry32(400 + index * 31);
    const dry = new Path2D();
    for (let i = 0; i < spec.marks; i++) {
      const px = lp.w * (0.06 + (i + 0.35 + rnd() * 0.35) / (spec.marks + 0.7) * 0.88);
      const probe = lp.min * 0.035;
      const leftY = ridgeAt(points, Math.max(0, px - probe));
      const rightY = ridgeAt(points, Math.min(lp.w, px + probe));
      const dir = rightY > leftY ? 1 : -1;
      const slope = Math.atan(Math.abs(rightY - leftY) / (probe * 2));
      const ang = Math.min(1.15, Math.max(0.45, slope * 1.1 + 0.15));
      const py = ridgeAt(points, px) + lp.min * (0.010 + rnd() * 0.020);
      const len = lp.min * (0.060 + rnd() * 0.070);
      dryBrush(dry, px, py, px + dir * Math.cos(ang) * len, py + Math.sin(ang) * len,
        lp.min * (0.005 + rnd() * 0.005), rnd);
    }
    g.globalAlpha = 0.09 + index * 0.025;
    g.fillStyle = index < 2 ? '#18211f' : '#0b100e';
    g.fill(dry);
    g.globalAlpha = 1;
  };

  const m = lp.min;
  const P = [
    [-0.0032, 0.0012, 1.0025, 0.18, 0.0042],
    [0.0028, 0.0026, 0.9985, 0.20, 0.0034],
    [0.0010, -0.0016, 1.0012, 0.16, 0.0048],
    [-0.0014, 0.0040, 1.0, 0.30, 0.0026],
    [0.0004, 0.0068, 1.0, 0.68, 0.0016]
  ];
  const passes = P.map(function (p, i) {
    return {
      path: jitterPolyPath(points, lp.min, index * 7 + i * 1.37, p[0] * m, p[1] * m, p[2], lp.w * 0.5, p[4] * m, ext, ext, lp.h + 4),
      alpha: p[3]
    };
  });
  const bleed = { path: jitterPolyPath(points, lp.min, index * 7 + 9.1, 0, -0.001 * m, 1, lp.w * 0.5, 0.003 * m, ext, ext, lp.h + 4), alpha: 0.18 };
  return inkBlock(lp, 0, by, lp.w, lp.h - by, paint, passes, bleed);
}

/* Polyline silhouette closed to `bottom`, with organic edge wobble. */
function jitterPolyPath(points, unit, seed, dx, dy, sx, cx, amp, extL, extR, bottom) {
  const p = new Path2D();
  const n = points.length;
  const f = 1 / Math.max(1, unit);
  const first = points[0];
  const last = points[n - 1];
  p.moveTo(first.x - extL, first.y + dy);
  for (let i = 0; i < n; i++) {
    const pt = points[i];
    const w = pt.x * f;
    const j = (U.noise1(w * 19 + seed * 13.7) - 0.5) * 2 * amp +
      (U.noise1(w * 77 + seed * 5.3) - 0.5) * amp * 0.8;
    p.lineTo(cx + (pt.x - cx) * sx + dx, pt.y + dy + j);
  }
  p.lineTo(last.x + extR, last.y + dy);
  p.lineTo(last.x + extR, bottom);
  p.lineTo(first.x - extL, bottom);
  p.closePath();
  return p;
}

/* Dry brush: a few broken parallel bristle marks that thin out as the ink runs dry. */
function dryBrush(path, x0, y0, x1, y1, width, rnd) {
  const dx = x1 - x0;
  const dy = y1 - y0;
  const len = Math.max(1, Math.sqrt(dx * dx + dy * dy));
  const nx = -dy / len;
  const ny = dx / len;
  const bristles = 5 + Math.floor(rnd() * 3);
  for (let b = 0; b < bristles; b++) {
    const off = ((b + 0.5) / bristles - 0.5) * width * 2 + (rnd() - 0.5) * width * 0.3;
    const bw = width * (0.09 + rnd() * 0.09);
    let s = rnd() * 0.15;
    while (s < 1) {
      const e = Math.min(1, s + 0.10 + rnd() * 0.30 * (1 - s * 0.5));
      if (rnd() < 0.85 - s * 0.4) {
        const bend = Math.sin((s + b) * 2.1) * width * 0.15;
        addBrushSlash(path,
          x0 + dx * s + nx * (off + bend), y0 + dy * s + ny * (off + bend),
          x0 + dx * e + nx * (off + bend), y0 + dy * e + ny * (off + bend),
          bw * (1 - s * 0.5));
      }
      s = e + 0.02 + rnd() * 0.08 * (0.4 + s);
    }
  }
}
function buildKarstGroup(lp, towers, anchor, floorFactor, color, alpha) {
  const blocks = [];
  let x0 = Infinity;
  let y0 = Infinity;
  let x1 = -Infinity;
  let y1 = -Infinity;
  for (let i = 0; i < towers.length; i++) {
    const b = buildTowerBlock(lp, towers[i], anchor, floorFactor, color, alpha, i);
    blocks.push(b);
    x0 = Math.min(x0, b.x);
    y0 = Math.min(y0, b.y);
    x1 = Math.max(x1, b.x + b.w);
    y1 = Math.max(y1, b.y + b.h);
  }
  const L = U.layer(Math.ceil(x1 - x0), Math.ceil(y1 - y0), lp.dpr);
  for (let i = 0; i < blocks.length; i++) {
    const b = blocks[i];
    L.ctx.drawImage(b.canvas, b.x - x0, b.y - y0, b.w, b.h);
  }
  return { canvas: L.canvas, x: x0, y: y0, w: L.w, h: L.h };
}

function buildTowerBlock(lp, spec, anchor, floorFactor, color, alpha, index) {
  const floor = lp.h * floorFactor + lp.min * ((index % 2) * 0.010);
  const x = lp.w * anchor + lp.min * spec.dx;
  const towerH = lp.h * spec.height;
  const width = lp.min * spec.width;
  const top = floor - towerH;
  const rnd = U.mulberry32(spec.seed);
  const levels = 13;
  const left = [];
  const right = [];
  const profile = [0.58, 0.72, 0.56, 0.78, 0.49, 0.66, 0.43, 0.58, 0.39, 0.50, 0.33, 0.27, 0.18];

  for (let i = 0; i < levels; i++) {
    const q = i / (levels - 1);
    const y = floor - towerH * q;
    const center = x + lp.min * spec.lean * q + Math.sin(q * 8.7 + spec.seed) * width * 0.065;
    const half = width * profile[i];
    const leftJitter = 0.86 + rnd() * 0.25;
    const rightJitter = 0.84 + rnd() * 0.29;
    left.push({ x: center - half * leftJitter, y: y });
    right.push({ x: center + half * rightJitter, y: y + (i > 9 ? (rnd() - 0.5) * width * 0.10 : 0) });
  }
  const apexX = x + lp.min * spec.lean + width * (-0.20 + rnd() * 0.42);

  let minX = apexX;
  let maxX = apexX;
  for (let i = 0; i < levels; i++) {
    minX = Math.min(minX, left[i].x);
    maxX = Math.max(maxX, right[i].x);
  }
  const bx = minX - width * 0.4;
  const by = top - width * 0.4;
  const bw = maxX - minX + width * 0.8;
  const bh = floor + lp.min * 0.03 - by;

  const paint = function (g) {
    const grad = g.createLinearGradient(0, top, 0, floor + lp.min * 0.02);
    grad.addColorStop(0, U.rgba(color, alpha));
    grad.addColorStop(0.20, U.rgba(color, alpha * 0.97));
    grad.addColorStop(0.50, U.rgba(color, alpha * 0.74));
    grad.addColorStop(0.78, U.rgba(color, alpha * 0.30));
    grad.addColorStop(1, U.rgba(color, 0));
    g.fillStyle = grad;
    g.fillRect(bx, by, bw, bh);
    const cap = g.createRadialGradient(apexX, top + towerH * 0.04, 0, apexX, top + towerH * 0.04, towerH * 0.38);
    cap.addColorStop(0, U.rgba('#0b100e', alpha * 0.30));
    cap.addColorStop(1, U.rgba('#0b100e', 0));
    g.fillStyle = cap;
    g.fillRect(bx, by, bw, bh);
    granulate(g, lp, bx, by, bw, bh, spec.seed * 3, 0.95);

    const dry = new Path2D();
    for (let i = 0; i < 3; i++) {
      const q = 0.30 + i * 0.19 + rnd() * 0.035;
      const cy = floor - towerH * q;
      const cx = x + lp.min * spec.lean * q + (i % 2 ? width * 0.12 : -width * 0.16);
      const direction = i % 2 ? -1 : 1;
      dryBrush(dry, cx, cy, cx + direction * width * (0.22 + rnd() * 0.16), cy + towerH * (0.09 + rnd() * 0.05), width * 0.10, rnd);
    }
    g.globalAlpha = alpha * 0.16;
    g.fillStyle = '#0b110f';
    g.fill(dry);
    g.globalAlpha = 1;
  };

  const P = [
    [-0.030, 0.02, 1.005, 0.16, 0.036],
    [0.026, 0.03, 0.995, 0.18, 0.030],
    [0.008, -0.020, 1.003, 0.14, 0.040],
    [-0.010, 0.03, 1.0, 0.30, 0.022],
    [0.003, 0.05, 0.993, 0.78, 0.014]
  ];
  const passes = P.map(function (p, i) {
    return {
      path: towerPath(left, right, apexX, top, width, spec.seed + i * 3.1, p[0] * width, p[1] * width, p[2], x, floor, p[4] * width),
      alpha: p[3]
    };
  });
  const bleed = { path: towerPath(left, right, apexX, top, width, spec.seed + 17, 0, 0, 1, x, floor, 0.03 * width), alpha: 0.14 };
  const B = inkBlock(lp, bx, by, bw, bh, paint, passes, bleed);

  const g = B.ctx;
  g.save();
  g.translate(-B.x, -B.y);
  const shrubs = new Path2D();
  for (let i = 0; i < 2; i++) {
    const q = 0.40 + i * 0.20;
    const side = i % 2 ? 1 : -1;
    const cy = floor - towerH * q;
    const cx = x + lp.min * spec.lean * q + side * width * (profile[Math.floor(q * (levels - 1))] * 0.82);
    addDab(shrubs, cx, cy - width * 0.025, width * (0.050 + rnd() * 0.025), width * 0.027, side * 0.15);
    addDab(shrubs, cx + side * width * 0.045, cy - width * 0.043, width * 0.038, width * 0.021, -side * 0.20);
  }
  g.globalAlpha = alpha * 0.55;
  g.fillStyle = '#111714';
  g.fill(shrubs);
  g.restore();
  return B;
}

function towerPath(left, right, apexX, top, width, seed, dx, dy, sc, cx, floor, amp) {
  const levels = left.length;
  const T = function (p, side, i) {
    const j = (U.noise1(i * 1.9 + seed * 7.3 + side * 31) - 0.5) * 2 * amp +
      (U.noise1(i * 5.3 + seed * 3.1 + side * 11) - 0.5) * amp * 0.7;
    return { x: cx + (p.x + side * j - cx) * sc + dx, y: floor + (p.y - floor) * sc + dy };
  };
  const L = left.map(function (p, i) { return T(p, -1, i); });
  const R = right.map(function (p, i) { return T(p, 1, i); });
  const ax = cx + (apexX - cx) * sc + dx;
  const ay = floor + (top - floor) * sc + dy;
  const p = new Path2D();
  addSmoothSide(p, L, true);
  p.quadraticCurveTo(ax - width * 0.16, ay - width * 0.08, ax, ay);
  p.quadraticCurveTo(ax + width * 0.25, ay + width * 0.02, R[levels - 1].x, R[levels - 1].y);
  addSmoothSide(p, R.slice().reverse(), false);
  p.lineTo(R[0].x, floor + width * 0.5);
  p.lineTo(L[0].x, floor + width * 0.5);
  p.closePath();
  return p;
}

function buildForeground(lp) {
  const L = U.layer(lp.w, lp.h, lp.dpr);
  const g = L.ctx;
  const reach = Math.min(lp.w * 0.34, lp.min * 0.68);
  const step = Math.max(3, lp.min / 150);
  const points = [];
  for (let x = 0; x <= reach + step; x += step) {
    const u = x / reach;
    const shelf = Math.exp(-Math.pow((u - 0.26) / 0.15, 2)) * 0.065;
    const breakup = (U.fbm2(u * 4.0 + 77, 5.2, 3) - 0.5) * 0.036;
    const y = lp.h * (0.625 + u * 0.305 + Math.pow(u, 4) * 0.125 - shelf + breakup);
    points.push({ x: x, y: y });
  }
  let topY = lp.h;
  for (let i = 0; i < points.length; i++) topY = Math.min(topY, points[i].y);
  const ext = lp.min * 0.03;
  const by = Math.max(0, topY - lp.min * 0.02);
  const bw = points[points.length - 1].x + ext;

  const paint = function (pg) {
    const grad = pg.createLinearGradient(0, lp.h * 0.53, reach, lp.h * 0.90);
    grad.addColorStop(0, 'rgba(10,14,13,0.98)');
    grad.addColorStop(0.62, 'rgba(13,18,16,0.95)');
    grad.addColorStop(1, 'rgba(18,23,21,0.72)');
    pg.fillStyle = grad;
    pg.fillRect(0, by, bw, lp.h - by);
    granulate(pg, lp, 0, by, bw, lp.h - by, 812, 0.6);
    const rockMarks = new Path2D();
    const rnd = U.mulberry32(812);
    for (let i = 0; i < 12; i++) {
      const x = reach * (0.06 + rnd() * 0.76);
      const y = ridgeAt(points, x) + lp.min * (0.035 + rnd() * 0.17);
      dryBrush(rockMarks, x, y, x + lp.min * (0.025 + rnd() * 0.10), y + lp.min * (0.025 + rnd() * 0.09), lp.min * (0.004 + rnd() * 0.005), rnd);
    }
    pg.globalAlpha = 0.30;
    pg.fillStyle = '#2a332e';
    pg.fill(rockMarks);
    pg.globalAlpha = 1;
  };
  const m = lp.min;
  const P = [
    [-0.0018, 0.0010, 0.22, 0.0024],
    [0.0016, 0.0018, 0.22, 0.0018],
    [0.0, 0.0032, 0.93, 0.0010]
  ];
  const passes = P.map(function (p, i) {
    return { path: jitterPolyPath(points, lp.min, 41 + i * 2.3, p[0] * m, p[1] * m, 1, 0, p[3] * m, ext, 0, lp.h + 4), alpha: p[2] };
  });
  const bleed = { path: jitterPolyPath(points, lp.min, 47, 0, 0, 1, 0, 0.002 * m, ext, 0, lp.h + 4), alpha: 0.22 };
  const crag = inkBlock(lp, 0, by, bw, lp.h - by, paint, passes, bleed);
  g.drawImage(crag.canvas, crag.x, crag.y, crag.w, crag.h);

  const anchorX = reach * 0.27;
  const ground = ridgeAt(points, anchorX) - lp.min * 0.002;
  drawPine(g, lp, anchorX, ground);
  return L;
}

