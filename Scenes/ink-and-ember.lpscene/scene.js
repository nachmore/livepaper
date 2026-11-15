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
/* The sun crosses from left to right once per SUN_CYCLE seconds. Over the last SUN_FADE of the
   cycle it sinks and fades into the haze, and over the first it rises and fades back in, so the
   wrap back to the left happens while it (and its reflection) is invisible. It starts risen. */
const SUN_CYCLE = 960;
const SUN_FADE = 0.05;

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
let clouds = [];
let skyMottles = [];
let sun = null;
let overlay = null;
let tiles = null;
let trees = [];        // swaying trees drawn after the crag (main pine, small pine)
let ridgeTrees = [];   // per ridge index: list of trees standing on it
let water = null;
let boat = null;
let sunDab = null;
let warmDab = null;
let fogSprite = null;
let crag = null;

/* Ridge parallax: amplitude (CSS px, never scaled up), period (s), phase. Near moves more,
   but the nearest range travels at most ~10 px so the mountains feel solid. */
const PARALLAX = [[1.2, 109, 0.4], [1.8, 97, 1.9], [2.6, 83, 3.1], [3.6, 73, 4.6], [4.8, 61, 0.9]];

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
    const sp = lp.w / 1512;
    // Mist bands: two textures each, cross-fading on long unrelated periods.
    mists = [
      buildMistLayer(lp, 0.548, 0.090, 0.58, 2.6 * sp, 23, 41, 0.13, 101),
      buildMistLayer(lp, 0.620, 0.090, 0.56, -4.2 * sp, 29, 47, 0.31, 202),
      buildMistLayer(lp, 0.690, 0.094, 0.56, 6.0 * sp, 26, 53, 0.49, 303),
      buildMistLayer(lp, 0.755, 0.104, 0.58, -8.5 * sp, 33, 43, 0.68, 404),
      buildMistLayer(lp, 0.820, 0.112, 0.56, 12 * sp, 27, 59, 0.87, 505)
    ];
    clouds = buildWisps(lp);
    skyMottles = [skyMottle(lp, 1201), skyMottle(lp, 1307)];
    sun = buildSun(lp);
    buildTrees(lp);
    water = buildWater(lp, Math.round(lp.h * 0.85));
    boat = buildBoat(lp);
    sunDab = buildDab('#c45a40', '#e08a63');
    warmDab = buildDab('#d98a4a', '#f2c08a');
    fogSprite = U.glowSprite('#a9b1aa', 128, 1.6);
  },

  draw(lp) {
    const ctx = lp.ctx;
    const t = lp.env.reducedMotion ? lp.t * 0.25 : lp.t;
    const phase = (t / SUN_CYCLE + SUN_FADE) % 1;
    const sunVis = U.smoothstep(0, SUN_FADE, phase) * (1 - U.smoothstep(1 - SUN_FADE, 1, phase));
    const arc = Math.sin(Math.PI * phase);
    const sunX = lp.w * (0.34 + 0.36 * phase);
    const sunY = lp.h * (0.555 - 0.070 * arc + 0.025 * (1 - sunVis));
    const sunSize = lp.min * 0.235;
    const sp = lp.w / 1512;
    const ox = [];
    for (let i = 0; i < PARALLAX.length; i++) {
      ox.push(PARALLAX[i][0] * Math.min(1, sp) * Math.sin(t * TAU / PARALLAX[i][1] + PARALLAX[i][2]));
    }

    ctx.drawImage(paper.canvas, 0, 0, lp.w, lp.h);
    drawSkyMottle(ctx, lp, t);
    drawWisps(ctx, lp, t);
    if (sunVis > 0.002) {
      ctx.globalAlpha = 0.94 * sunVis;
      ctx.drawImage(sun.canvas, sunX - sunSize * 0.5, sunY - sunSize * 0.5, sunSize, sunSize);
      ctx.globalAlpha = 1;
    }
    drawBirds(ctx, lp, t);

    drawBlock(ctx, ridges[0], ox[0]);
    drawBlock(ctx, farKarst, (ox[0] + ox[1]) * 0.5);
    drawDrift(ctx, lp, mists[0], t);
    drawBlock(ctx, ridges[1], ox[1]);
    drawDrift(ctx, lp, mists[1], t);
    drawBlock(ctx, ridges[2], ox[2]);
    drawTreeList(ctx, ridgeTrees[2], t, ox[2]);
    drawBlock(ctx, karst, (ox[2] + ox[3]) * 0.5);
    drawDrift(ctx, lp, mists[2], t);
    drawBlock(ctx, ridges[3], ox[3]);
    drawTreeList(ctx, ridgeTrees[3], t, ox[3]);
    drawDrift(ctx, lp, mists[3], t);
    drawBlock(ctx, ridges[4], ox[4]);
    drawTreeList(ctx, ridgeTrees[4], t, ox[4]);
    drawWater(ctx, lp, t, sunX, sunSize, sunVis);
    drawBoat(ctx, lp, t);
    drawDrift(ctx, lp, mists[4], t);
    ctx.drawImage(foreground.canvas, 0, 0, lp.w, lp.h);
    drawTreeList(ctx, trees, t, 0);
    drawFogBank(ctx, lp, t);
    drawLantern(ctx, lp, t);
    ctx.drawImage(overlay.canvas, 0, 0, lp.w, lp.h);
  }
});

function drawBlock(ctx, b, dx) {
  ctx.drawImage(b.canvas, b.x + (dx || 0), b.y, b.w, b.h);
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
  const pad = ridgePad(lp);
  const first = -Math.ceil(pad / step);
  const count = Math.ceil((lp.w + pad) / step);
  for (let i = first; i <= count; i++) {
    const x = i * step;
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

/* Pre-rendered sprite of whatever fn draws inside the CSS-px box (x0, y0)–(x1, y1). */
function makeSprite(lp, x0, y0, x1, y1, fn) {
  x0 = Math.floor(x0);
  y0 = Math.floor(y0);
  const w = Math.max(2, Math.ceil(x1 - x0));
  const h = Math.max(2, Math.ceil(y1 - y0));
  const L = U.layer(w, h, lp.dpr);
  L.ctx.translate(-x0, -y0);
  fn(L.ctx);
  return { canvas: L.canvas, x: x0, y: y0, w: w, h: h };
}

/*
 * The leaning pine, split into a trunk sprite (skewed about its fixed base) and
 * four branch + needle-pad sprites (each rotated about its root, with a lag).
 */
function buildPine(lp, x, ground) {
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
  const trunkSprite = makeSprite(lp, x - m * 0.04, tip.y - m * 0.03, tip.x + m * 0.04, base.y + 2, function (g) {
    g.fillStyle = ink;
    g.fill(trunk);
  });

  const branches = [
    [knot.x, knot.y + m * 0.010, x - m * 0.030, ground - m * 0.175, x - m * 0.090, ground - m * 0.166, m * 0.0080, m * 0.0020],
    [shoulder.x, shoulder.y + m * 0.008, x + m * 0.150, ground - m * 0.245, x + m * 0.285, ground - m * 0.228, m * 0.0085, m * 0.0022],
    [shoulder.x + m * 0.020, shoulder.y - m * 0.025, x + m * 0.155, ground - m * 0.292, x + m * 0.235, ground - m * 0.288, m * 0.0065, m * 0.0018],
    [tip.x - m * 0.008, tip.y + m * 0.012, x + m * 0.180, ground - m * 0.342, x + m * 0.225, ground - m * 0.350, m * 0.0048, m * 0.0014]
  ];
  const clusters = [
    { x: x - m * 0.078, y: ground - m * 0.177, rx: m * 0.082, ry: m * 0.027 },
    { x: x + m * 0.150, y: ground - m * 0.243, rx: m * 0.105, ry: m * 0.032 },
    { x: x + m * 0.270, y: ground - m * 0.228, rx: m * 0.084, ry: m * 0.029 },
    { x: x + m * 0.205, y: ground - m * 0.294, rx: m * 0.073, ry: m * 0.027 },
    { x: x + m * 0.218, y: ground - m * 0.351, rx: m * 0.056, ry: m * 0.024 }
  ];
  // branch i carries these clusters; root = branch start
  const groups = [[0], [1, 2], [3], [4]];
  const gains = [0.011, 0.009, 0.012, 0.015];
  const lags = [0.18, 0.30, 0.42, 0.55];
  const rnd = U.mulberry32(991);
  const parts = [];
  const pathSets = groups.map(function () {
    return { pads: new Path2D(), cores: new Path2D(), ragged: new Path2D() };
  });
  for (let c = 0; c < clusters.length; c++) {
    const cluster = clusters[c];
    let gi = 0;
    for (let k = 0; k < groups.length; k++) if (groups[k].indexOf(c) >= 0) gi = k;
    const ps = pathSets[gi];
    addCloudPad(ps.pads, cluster.x, cluster.y, cluster.rx, cluster.ry, rnd, 1);
    addCloudPad(ps.cores, cluster.x - cluster.rx * 0.12, cluster.y + cluster.ry * 0.03, cluster.rx * 0.52, cluster.ry * 0.54, rnd, 0.68);
    addCloudPad(ps.cores, cluster.x + cluster.rx * 0.24, cluster.y - cluster.ry * 0.04, cluster.rx * 0.42, cluster.ry * 0.46, rnd, 0.62);
    for (let i = 0; i < 10; i++) {
      const side = rnd() < 0.5 ? -1 : 1;
      const px = cluster.x + side * cluster.rx * (0.62 + rnd() * 0.42);
      const py = cluster.y + (rnd() - 0.5) * cluster.ry * 1.55;
      addDab(ps.ragged, px, py, m * (0.008 + rnd() * 0.015), m * (0.0018 + rnd() * 0.0023), (rnd() - 0.5) * 0.26);
    }
  }
  for (let k = 0; k < groups.length; k++) {
    const b = branches[k];
    let x0 = Math.min(b[0], b[4]) - m * 0.02;
    let x1 = Math.max(b[0], b[4]) + m * 0.02;
    let y0 = Math.min(b[1], b[5]) - m * 0.02;
    let y1 = Math.max(b[1], b[5]) + m * 0.02;
    for (let j = 0; j < groups[k].length; j++) {
      const cl = clusters[groups[k][j]];
      x0 = Math.min(x0, cl.x - cl.rx * 1.12 - m * 0.014);
      x1 = Math.max(x1, cl.x + cl.rx * 1.12 + m * 0.014);
      y0 = Math.min(y0, cl.y - cl.ry * 1.25 - m * 0.006);
      y1 = Math.max(y1, cl.y + cl.ry * 1.05 + m * 0.006);
    }
    const ps = pathSets[k];
    const sprite = makeSprite(lp, x0, y0, x1, y1, function (g) {
      g.fillStyle = ink;
      g.fill(taperedBranch(b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]));
      g.globalAlpha = 0.91;
      g.fillStyle = '#111815';
      g.fill(ps.pads);
      g.globalAlpha = 0.90;
      g.fillStyle = ink;
      g.fill(ps.cores);
      g.fill(ps.ragged);
      g.globalAlpha = 1;
    });
    parts.push({ s: sprite, ax: b[0], ay: b[1], gain: gains[k], lag: lags[k] });
  }
  return { bx: base.x, by: base.y, xn: x / lp.w, skew: 0.0042, trunk: trunkSprite, parts: parts };
}

/*
 * A smaller sumi-e pine in the hand of the hero pine: a crooked, tapering trunk
 * that kinks as it climbs, a branch or two reaching downwind, and flat layered
 * needle pads with bristly dry-brush edges. Its foot sits in a small ink mound
 * of rock so it is rooted in the ridge or crag it stands on.
 */
function buildSmallPine(lp, x, ground, size, seed, ink, padInk, flex, dir, rockInk) {
  const rnd = U.mulberry32(seed);
  const qs = [0, 0.22, 0.45, 0.68, 0.86, 1.0];
  const kink = [0, -0.065, 0.035, 0.125, 0.150, 0.235];
  const spine = qs.map(function (q, i) {
    return {
      x: x + dir * size * (kink[i] + (i ? (rnd() - 0.5) * 0.035 : 0)),
      y: ground - size * 0.70 * q
    };
  });
  const L = [];
  const R = [];
  for (let i = 0; i < spine.length; i++) {
    const w = size * 0.058 * (1 - qs[i] * 0.74) * (i === 0 ? 1.45 : 1);
    L.push({ x: spine[i].x - w, y: spine[i].y });
    R.push({ x: spine[i].x + w, y: spine[i].y });
  }
  const trunkPath = new Path2D();
  addSmoothSide(trunkPath, L, true);
  addSmoothSide(trunkPath, R.slice().reverse(), false);
  trunkPath.closePath();
  const bark = new Path2D();
  for (let i = 1; i < 4; i++) {
    const a = spine[i], b = spine[i + 1];
    dryBrush(bark, a.x, a.y, a.x + (b.x - a.x) * 0.7, a.y + (b.y - a.y) * 0.7, size * 0.012, rnd);
  }
  const mound = new Path2D();
  addCloudPad(mound, x + dir * size * 0.02, ground + size * 0.035, size * 0.20, size * 0.050, rnd, 1.6);
  const roots = new Path2D();
  for (let k = 0; k < 5; k++) {
    const side = k % 2 ? 1 : -1;
    addDab(roots, x + side * size * (0.10 + rnd() * 0.14), ground + size * (0.018 + rnd() * 0.03),
      size * (0.07 + rnd() * 0.09), size * (0.008 + rnd() * 0.008), (rnd() - 0.5) * 0.25);
  }
  const top = spine[spine.length - 1];
  const trunk = makeSprite(lp, x - size * 0.30, top.y - size * 0.05, x + size * 0.34, ground + size * 0.10, function (g) {
    g.fillStyle = rockInk;
    g.fill(mound);
    g.globalAlpha = 0.85;
    g.fill(roots);
    g.globalAlpha = 1;
    g.fillStyle = ink;
    g.fill(trunkPath);
    g.globalAlpha = 0.55;
    g.fillStyle = '#2b3430';
    g.fill(bark);
    g.globalAlpha = 1;
  });

  const at = function (q) {
    for (let i = 1; i < spine.length; i++) {
      if (q <= qs[i]) {
        const f = (q - qs[i - 1]) / (qs[i] - qs[i - 1]);
        return { x: spine[i - 1].x + (spine[i].x - spine[i - 1].x) * f, y: spine[i - 1].y + (spine[i].y - spine[i - 1].y) * f };
      }
    }
    return top;
  };
  // [height on trunk, direction, reach, pad width] — low branch, long downwind limb, a back limb, the crown
  const limbs = [
    [0.38, -dir, 0.24, 0.19],
    [0.56, dir, 0.42, 0.25],
    [0.77, -dir, 0.15, 0.18],
    [0.97, dir, 0.10, 0.19]
  ];
  const parts = [];
  for (let i = 0; i < limbs.length; i++) {
    const lb = limbs[i];
    const root = at(lb[0]);
    const reach = size * lb[2] * (0.85 + rnd() * 0.3);
    const end = { x: root.x + lb[1] * reach, y: root.y - size * (0.02 + rnd() * 0.04) };
    const ctl = { x: root.x + lb[1] * reach * 0.45, y: root.y + size * 0.035 };
    const rx = size * lb[3] * (0.9 + rnd() * 0.2);
    const ry = rx * (0.29 + rnd() * 0.06);
    const cx = end.x + lb[1] * rx * 0.25;
    const cy = end.y - ry * 0.35;
    const pads = new Path2D();
    const cores = new Path2D();
    const needles = new Path2D();
    // two flat tiers: the main pad and a smaller one layered beneath and inward
    addCloudPad(pads, cx, cy, rx, ry, rnd, 0.9);
    addCloudPad(pads, cx - lb[1] * rx * 0.22, cy + ry * 1.05, rx * 0.70, ry * 0.75, rnd, 0.8);
    addCloudPad(cores, cx - rx * 0.08, cy + ry * 0.10, rx * 0.55, ry * 0.50, rnd, 0.6);
    // bristly needle tufts along the top and at the ends of each pad
    const tufts = 12 + Math.floor(rnd() * 6);
    for (let k = 0; k < tufts; k++) {
      const u = (k + rnd() * 0.8) / tufts;
      const px = cx - rx + u * rx * 2;
      const arch = Math.sin(u * Math.PI);
      const py = cy - ry * (0.15 + arch * 0.55);
      const lean = (u - 0.5) * 0.9 + (rnd() - 0.5) * 0.5;
      const ln = size * (0.020 + rnd() * 0.025) * (0.6 + arch * 0.6);
      addBrushSlash(needles, px, py + ry * 0.2, px + Math.sin(lean) * ln, py - Math.cos(lean) * ln * 0.6, size * 0.0035);
    }
    for (let k = 0; k < 7; k++) {
      const side = rnd() < 0.5 ? -1 : 1;
      addDab(needles, cx + side * rx * (0.75 + rnd() * 0.40), cy + (rnd() - 0.3) * ry * 1.6,
        size * (0.035 + rnd() * 0.05), size * (0.004 + rnd() * 0.005), side * (rnd() - 0.3) * 0.25);
    }
    const dry = new Path2D();
    dryBrush(dry, cx - rx * 0.9, cy - ry * 0.05, cx + rx * 0.9, cy + ry * 0.05, ry * 0.55, rnd);
    const branch = taperedBranch(root.x, root.y, ctl.x, ctl.y, end.x, end.y, size * 0.016, size * 0.005);
    const sprite = makeSprite(lp,
      Math.min(root.x, cx - rx * 1.25) - size * 0.05, Math.min(root.y, cy - ry * 1.4) - size * 0.05,
      Math.max(root.x, cx + rx * 1.25) + size * 0.05, Math.max(root.y, cy + ry * 2.2) + size * 0.03,
      function (g) {
        g.fillStyle = ink;
        g.fill(branch);
        g.globalAlpha = 0.92;
        g.fillStyle = padInk;
        g.fill(pads);
        g.globalAlpha = 0.9;
        g.fillStyle = ink;
        g.fill(cores);
        g.globalAlpha = 0.8;
        g.fill(needles);
        // dry-brush streaks: paper showing through the pads
        g.globalCompositeOperation = 'destination-out';
        g.globalAlpha = 0.45;
        g.fill(dry);
        g.globalCompositeOperation = 'source-over';
        g.globalAlpha = 1;
      });
    parts.push({ s: sprite, ax: root.x, ay: root.y, gain: flex * (1 + i * 0.35), lag: 0.15 * (i + 1) });
  }
  return { bx: x, by: ground, xn: x / lp.w, skew: flex * 0.35, trunk: trunk, parts: parts };
}

/* Distant trees: a few short, soft horizontal dabs of ink that melt into the ridge wash. */
function buildInkDabTree(lp, x, ground, hgt, color, alpha, seed) {
  const rnd = U.mulberry32(seed);
  const x0 = Math.floor(x - hgt * 0.8);
  const y0 = Math.floor(ground - hgt * 1.15);
  const w = Math.ceil(hgt * 1.7);
  const h = Math.ceil(hgt * 1.35);
  const L = U.layer(w, h, Math.min(1, lp.dpr) * 0.8);   // low-res: the upscale softens the edges
  const g = L.ctx;
  g.translate(-x0, -y0);
  const p = new Path2D();
  const n = 3 + Math.floor(rnd() * 2);
  const lean = hgt * (rnd() - 0.3) * 0.15;
  for (let k = 0; k < n; k++) {
    const q = (k + 0.4) / n;
    const len = hgt * (0.95 - 0.55 * q) * (0.8 + rnd() * 0.4);
    addDab(p, x + lean * q + (rnd() - 0.5) * hgt * 0.12, ground - hgt * q * 0.9, len, hgt * (0.09 + rnd() * 0.05), (rnd() - 0.5) * 0.18);
  }
  softPuff(g, x, ground - hgt * 0.40, hgt * 0.55, hgt * 0.45, U.hexToRgb(color).join(','), alpha * 0.35, 1e6, 0);
  g.fillStyle = U.rgba(color, alpha);
  g.fill(p);
  return { bx: x, by: ground, xn: x / lp.w, skew: 0.018, trunk: { canvas: L.canvas, x: x0, y: y0, w: w, h: h }, parts: [] };
}

/* Highest point of a ridge within ±span of x: trees are planted on crests. */
function crestNear(points, x, span) {
  let best = { x: x, y: ridgeAt(points, x) };
  for (let i = 0; i < points.length; i++) {
    const p = points[i];
    if (Math.abs(p.x - x) <= span && p.y < best.y) best = { x: p.x, y: p.y };
  }
  return best;
}

function buildTrees(lp) {
  const pts = crag.points;
  const anchorX = crag.reach * 0.27;
  const ground = ridgeAt(pts, anchorX) - lp.min * 0.002;
  const smallX = crag.reach * 0.64;
  trees = [
    buildSmallPine(lp, smallX, ridgeAt(pts, smallX) + lp.min * 0.006, lp.min * 0.105, 77, '#080c0b', '#111815', 0.020, 1, '#0b0f0e'),
    buildPine(lp, anchorX, ground)
  ];
  ridgeTrees = [[], [], [], [], []];
  const tiny = [
    [2, 0.290, 0.020], [2, 0.312, 0.016], [2, 0.622, 0.018],
    [3, 0.432, 0.024], [3, 0.452, 0.019], [3, 0.808, 0.022], [3, 0.950, 0.018]
  ];
  for (let i = 0; i < tiny.length; i++) {
    const r = tiny[i][0];
    const spec = RIDGE_SPECS[r];
    const c = crestNear(ridges[r].points, lp.w * tiny[i][1], lp.w * 0.012);
    ridgeTrees[r].push(buildInkDabTree(lp, c.x, c.y + lp.min * 0.006, lp.min * tiny[i][2], spec.color, spec.alpha * 0.62, 500 + i * 13));
  }
  // two small pines on the crests of the nearest middle ridge
  const mid = [[0.70, 0.060, 31, 1], [0.37, 0.046, 43, -1]];
  for (let i = 0; i < mid.length; i++) {
    const c = crestNear(ridges[4].points, lp.w * mid[i][0], lp.w * 0.03);
    ridgeTrees[4].push(buildSmallPine(lp, c.x, c.y + lp.min * 0.010, lp.min * mid[i][1], mid[i][2],
      '#121816', '#18201d', 0.026, mid[i][3], '#1a211e'));
  }
}

/* ---------- wind ---------- */

function gust(t) {
  const P = 26;
  const k = Math.floor(t / P);
  const u = t - k * P - U.hash2(k, 7) * 10;
  const strength = 0.55 + 0.45 * U.hash2(k, 13);
  return U.smoothstep(0, 4.5, u) * (1 - U.smoothstep(6, 13, u)) * strength;
}

/* Wind at screen position xn (0..1): gusts travel left to right over ~3 s. */
function wind(t, xn) {
  const tt = t - xn * 3.2;
  const base = 0.55 * Math.sin(tt * 0.997) + 0.30 * Math.sin(tt * 1.70 + 1.3) + 0.15 * Math.sin(tt * 2.73 + 0.4);
  const g = gust(tt);
  return base * (0.7 + 1.1 * g) + 2.4 * g;
}

function drawTreeList(ctx, list, t, ox) {
  if (!list) return;
  for (let i = 0; i < list.length; i++) drawTree(ctx, list[i], t, ox);
}

function drawTree(ctx, tree, t, ox) {
  const k = wind(t, tree.xn) * tree.skew;
  const tr = tree.trunk;
  ctx.save();
  ctx.translate(tree.bx + ox, tree.by);
  ctx.transform(1, 0, -k, 1, 0, 0);
  ctx.drawImage(tr.canvas, tr.x - tree.bx, tr.y - tree.by, tr.w, tr.h);
  ctx.restore();
  for (let i = 0; i < tree.parts.length; i++) {
    const p = tree.parts[i];
    const s = p.s;
    const a = wind(t - p.lag, tree.xn) * p.gain;
    ctx.save();
    ctx.translate(p.ax + ox + k * (tree.by - p.ay), p.ay);
    ctx.rotate(a);
    ctx.drawImage(s.canvas, s.x - p.ax, s.y - p.ay, s.w, s.h);
    ctx.restore();
  }
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

/* Soft elliptical puff (radial falloff), drawn with horizontal wrap copies. */
function softPuff(g, cx, cy, rx, ry, rgb, alpha, wrapW, tilt) {
  for (let k = -1; k <= 1; k++) {
    const x = cx + k * wrapW;
    if (x + rx < 0 || x - rx > wrapW) continue;
    g.save();
    g.translate(x, cy);
    if (tilt) g.rotate(tilt);
    g.scale(rx, ry);
    const grad = g.createRadialGradient(0, 0, 0, 0, 0, 1);
    grad.addColorStop(0, 'rgba(' + rgb + ',' + alpha + ')');
    grad.addColorStop(0.45, 'rgba(' + rgb + ',' + (alpha * 0.62) + ')');
    grad.addColorStop(1, 'rgba(' + rgb + ',0)');
    g.fillStyle = grad;
    g.beginPath();
    g.arc(0, 0, 1, 0, TAU);
    g.fill();
    g.restore();
  }
}

/* A horizontally seamless low-res mist band, one screen wide (tiled twice when drawn). */
function mistTexture(lp, hCss, seed) {
  const cw = Math.max(32, Math.ceil(lp.w / 4));
  const ch = Math.max(10, Math.ceil(hCss / 3));
  const L = U.layer(cw, ch, 1);
  const g = L.ctx;
  const veil = g.createLinearGradient(0, 0, 0, ch);
  veil.addColorStop(0, 'rgba(218,222,211,0)');
  veil.addColorStop(0.30, 'rgba(220,224,213,0.05)');
  veil.addColorStop(0.52, 'rgba(229,226,211,0.10)');
  veil.addColorStop(0.74, 'rgba(207,216,210,0.05)');
  veil.addColorStop(1, 'rgba(202,211,205,0)');
  g.fillStyle = veil;
  g.fillRect(0, 0, cw, ch);
  const rnd = U.mulberry32(seed);
  const n = 10 + Math.round(lp.aspect * 4);
  const narrow = Math.min(1.6, 1.78 / lp.aspect + 0.4);
  for (let i = 0; i < n; i++) {
    const cx = (i + rnd() * 0.8) / n * cw;
    const cy = ch * (0.50 + (rnd() - 0.5) * 0.22);
    const rx = cw * (0.05 + rnd() * 0.09) * narrow;
    const ry = ch * (0.20 + rnd() * 0.16);
    softPuff(g, cx, cy, rx, ry, '232,230,216', 0.10 + rnd() * 0.20, cw, 0);
    // smaller wisps give the drift visible texture
    softPuff(g, cx + rx * (rnd() - 0.5) * 1.6, cy + ry * (rnd() - 0.5), rx * 0.32, ry * 0.45, '236,234,222', 0.08 + rnd() * 0.12, cw, 0);
  }
  return L.canvas;
}

function buildMistLayer(lp, yFactor, heightFactor, alpha, speed, periodA, periodB, phase, seed) {
  const h = Math.max(40, lp.min * heightFactor * 1.15);
  return {
    a: mistTexture(lp, h, seed),
    b: mistTexture(lp, h, seed + 37),
    w: lp.w, h: h, y: lp.h * yFactor - h * 0.52,
    alpha: alpha, speed: speed, speedB: speed * 1.32,
    pa: periodA, pb: periodB, ph: phase * 5.7, off: lp.w * phase
  };
}

/*
 * Sky: a handful of separate ink-wash cloud wisps. Each is one dry-brush stroke
 * (a soft feathered wash under broken bristle marks) with its own length,
 * thickness, curve and tilt; it drifts at its own pace and slowly forms and
 * dissolves on its own long cycle, so only three to five show at a time.
 */
const WISPS = [
  // y (share of sky), length, thickness, speed (px/s), cycle (s), phase, alpha, seed
  [0.10, 0.62, 0.045, 1.6, 131, 0.10, 0.55, 11],
  [0.21, 0.44, 0.060, 2.4, 97, 0.55, 0.60, 23],
  [0.33, 0.78, 0.040, 1.9, 149, 0.80, 0.62, 37],
  [0.46, 0.52, 0.070, 3.1, 113, 0.30, 0.72, 41],
  [0.58, 0.36, 0.055, 3.8, 89, 0.68, 0.78, 53],
  [0.70, 0.66, 0.050, 2.8, 127, 0.05, 0.82, 67],
  [0.80, 0.42, 0.065, 4.4, 103, 0.42, 0.80, 79],
  [0.27, 0.30, 0.080, 2.1, 79, 0.92, 0.58, 83]
];

function buildWisp(lp, spec, index) {
  const rnd = U.mulberry32(spec[7] * 31 + 5);
  const len = lp.min * spec[1] * (lp.aspect > 2.2 ? 0.85 : 1);
  const thick = len * spec[2];
  const bow = (rnd() < 0.5 ? -1 : 1) * thick * (0.8 + rnd() * 1.6);
  const tilt = (rnd() - 0.5) * 0.16;
  const W = Math.ceil(len * 1.08);
  const H = Math.ceil(thick * 4.6 +Math.abs(bow) * 2 + len * Math.abs(tilt));
  const L = U.layer(W, H, 1);
  const g = L.ctx;
  const head = 0.12 + rnd() * 0.22;   // where the brush is fullest
  const cy = H * 0.5;
  const mid = function (u) {
    return cy + bow * Math.sin(Math.PI * u) + (u - 0.5) * len * tilt +
      (U.noise1(u * 3.1 + index * 7.7) - 0.5) * thick * 0.9;
  };
  const width = function (u) {
    const s = u < head ? u / head : 1 - (u - head) / (1 - head);
    return thick * Math.pow(Math.max(0, s), u < head ? 0.45 : 0.8) * (0.55 + 0.7 * U.noise1(u * 6.3 + index * 3.3));
  };
  const x0 = len * 0.04;
  // feathered, lumpy wash: dense at the loaded head, thinning along the drag
  for (let i = 0; i < 24; i++) {
    const u = Math.pow((i + rnd() * 0.8) / 24, 1.15);
    const wv = width(u);
    if (wv < 0.6) continue;
    softPuff(g, x0 + u * len, mid(u) + (rnd() - 0.5) * wv * 0.6, len * (0.035 + rnd() * 0.05), wv * (0.8 + rnd() * 0.6),
      '150,158,154', (0.10 + rnd() * 0.10) * (1 - u * 0.45), 1e6, tilt + (rnd() - 0.5) * 0.1);
  }
  // dry-brush bristles: broken streaks at the frayed edges and the drying tail
  const strokes = [new Path2D(), new Path2D(), new Path2D()];
  const bristles = 9 + Math.floor(rnd() * 6);
  for (let b = 0; b < bristles; b++) {
    const off = (b + 0.5) / bristles * 2 - 1 + (rnd() - 0.5) * 0.15;
    const p = strokes[Math.floor(rnd() * 3)];
    let u = head * (0.5 + rnd() * 1.5) + Math.abs(off) * 0.1;
    const uEnd = 1 - rnd() * 0.22 * (0.5 + Math.abs(off));
    while (u < uEnd) {
      const seg = 0.03 + rnd() * 0.14 * (1 - u * 0.6);
      const e = Math.min(uEnd, u + seg);
      if (rnd() < 0.80 - u * 0.30) {
        const n = Math.max(2, Math.ceil((e - u) * 18));
        for (let k = 0; k <= n; k++) {
          const v = u + (e - u) * k / n;
          const x = x0 + v * len;
          const y = mid(v) + off * width(v) * (1.05 + 0.15 * v);
          if (k === 0) p.moveTo(x, y);
          else p.lineTo(x, y);
        }
      }
      u = e + 0.01 + rnd() * 0.05 * (0.5 + u);
    }
  }
  g.lineCap = 'round';
  const widths = [0.7, 1.1, 1.7];
  const alphas = [0.24, 0.17, 0.10];
  for (let k = 0; k < 3; k++) {
    g.lineWidth = widths[k] * Math.max(0.7, lp.min / 900);
    g.strokeStyle = 'rgba(158,166,161,' + alphas[k] + ')';
    g.stroke(strokes[k]);
  }
  return {
    canvas: L.canvas, w: W, h: H,
    yq: spec[0], speed: spec[3], cycle: spec[4], phase: spec[5], alpha: spec[6],
    off: rnd()
  };
}

/* Quiet tonal mottling of the dusk paper: round, soft blotches (never bands), very low contrast. */
function skyMottle(lp, seed) {
  const k = 10;
  const cw = Math.max(16, Math.ceil(lp.w / k));
  const ch = Math.max(8, Math.ceil(lp.h * 0.56 / k));
  const L = U.layer(cw, ch, 1);
  const g = L.ctx;
  const rnd = U.mulberry32(seed);
  const n = Math.round(cw * ch / 90) + 8;
  for (let i = 0; i < n; i++) {
    const r = ch * (0.10 + rnd() * 0.16);
    const light = rnd() < 0.55;
    softPuff(g, rnd() * cw, rnd() * ch, r * (1.1 + rnd() * 0.6), r, light ? '150,158,152' : '0,3,4',
      light ? 0.06 + rnd() * 0.06 : 0.08 + rnd() * 0.08, cw, 0);
  }
  // fade out towards the ridges
  g.globalCompositeOperation = 'destination-in';
  const fade = g.createLinearGradient(0, 0, 0, ch);
  fade.addColorStop(0, 'rgba(0,0,0,1)');
  fade.addColorStop(0.7, 'rgba(0,0,0,0.8)');
  fade.addColorStop(1, 'rgba(0,0,0,0)');
  g.fillStyle = fade;
  g.fillRect(0, 0, cw, ch);
  g.globalCompositeOperation = 'source-over';
  return L.canvas;
}

function drawSkyMottle(ctx, lp, t) {
  const h = lp.h * 0.56;
  const sp = Math.min(1.4, lp.w / 1512);
  const cross = 0.5 + 0.5 * Math.sin(t * TAU / 26 + 0.6);
  const xa = -wrap(t * 1.6 * sp, lp.w);
  const xb = -wrap(t * 2.3 * sp + lp.w * 0.4, lp.w);
  ctx.globalAlpha = cross;
  ctx.drawImage(skyMottles[0], xa, 0, lp.w, h);
  ctx.drawImage(skyMottles[0], xa + lp.w, 0, lp.w, h);
  ctx.globalAlpha = 1 - cross;
  ctx.drawImage(skyMottles[1], xb, 0, lp.w, h);
  ctx.drawImage(skyMottles[1], xb + lp.w, 0, lp.w, h);
  ctx.globalAlpha = 1;
}

function buildWisps(lp) {
  return WISPS.map(function (spec, i) { return buildWisp(lp, spec, i); });
}

function drawWisps(ctx, lp, t) {
  const sp = Math.min(1.4, lp.w / 1512);
  const skyH = lp.h * 0.47;
  const cr = lp.clockRect;
  for (let i = 0; i < clouds.length; i++) {
    const c = clouds[i];
    const life = wrap(t / c.cycle + c.phase, 1);
    const env = U.smoothstep(0.0, 0.32, life) * (1 - U.smoothstep(0.62, 1.0, life));
    if (env < 0.01) continue;
    const grow = 0.86 + 0.20 * life;           // the stroke spreads (about its centre) as it forms and fades
    const w = c.w * grow;
    const h = c.h * (0.9 + 0.25 * life);
    // Wrap over a fixed length (the screen plus the widest stroke): a length that changed with t
    // would bend the drift, slower and then backwards the longer the scene runs.
    const wMax = c.w * 1.06;
    const span = lp.w + wMax;
    const x = wrap(c.off * span + t * c.speed * sp, span) - (wMax + w) * 0.5;
    // a slow rise and fall (a few px over ~20 s) so the horizontal bristles visibly drift
    const y = skyH * c.yq + Math.sin(t * TAU / (17 + i * 2.3) + i * 1.7) * lp.min * 0.007 - h * 0.5;
    let a = c.alpha * env;
    if (cr) {
      // behind the clock the wisps stay very faint
      const pad = lp.min * 0.05;
      const ox = Math.max(0, Math.min(x + w, cr.x + cr.w + pad) - Math.max(x, cr.x - pad));
      const oy = Math.max(0, Math.min(y + h, cr.y + cr.h + pad) - Math.max(y, cr.y - pad));
      const share = Math.min(1, ox / Math.max(1, Math.min(w, cr.w + pad * 2))) * (oy > 0 ? Math.min(1, oy / h * 1.5) : 0);
      a *= 1 - 0.72 * share;
    }
    ctx.globalAlpha = a;
    ctx.drawImage(c.canvas, x, y, w, h);
  }
  ctx.globalAlpha = 1;
}

/* Two textures drifting at different speeds, cross-fading; overall density breathes. */
function drawDrift(ctx, lp, m, t) {
  const cross = 0.5 + 0.5 * Math.sin(t * TAU / m.pa + m.ph);
  const dens = 0.78 + 0.22 * Math.sin(t * TAU / m.pb + m.ph * 1.9);
  const xa = -wrap(t * m.speed + m.off, m.w);
  const xb = -wrap(t * m.speedB + m.off * 1.7 + m.w * 0.5, m.w);
  // the veils breathe: each texture rises and settles a little on its own slow swell
  const ya = m.y + Math.sin(t * TAU / (m.pa * 0.71) + m.ph) * lp.min * 0.008;
  const yb = m.y + Math.sin(t * TAU / (m.pb * 0.43) + m.ph * 2.3) * lp.min * 0.008;
  ctx.globalAlpha = m.alpha * dens * (0.08 + 0.92 * cross);
  ctx.drawImage(m.a, xa, ya, m.w, m.h);
  ctx.drawImage(m.a, xa + m.w, ya, m.w, m.h);
  ctx.globalAlpha = m.alpha * dens * (0.08 + 0.92 * (1 - cross));
  ctx.drawImage(m.b, xb, yb, m.w, m.h);
  ctx.drawImage(m.b, xb + m.w, yb, m.w, m.h);
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

/* A small flock crosses about once a minute (each 64 s cycle: one flight at a varied time). */
function drawBirds(ctx, lp, t) {
  const P = 64;
  const k = Math.floor(t / P);
  const dur = 27 + U.hash2(k, 5) * 9;
  const start = U.hash2(k, 3) * (P - dur - 1);
  const p = (t - k * P - start) / dur;
  if (p <= 0 || p >= 1) return;
  const dir = U.hash2(k, 11) < 0.5 ? 1 : -1;
  const count = 3 + Math.floor(U.hash2(k, 17) * 5);
  const size = lp.min * (0.0062 + U.hash2(k, 23) * 0.0045);
  let yTop = lp.h * 0.33;
  if (lp.clockRect) yTop = Math.max(yTop, lp.clockRect.y + lp.clockRect.h + lp.h * 0.04);
  const baseY = yTop + U.hash2(k, 29) * lp.h * 0.08;
  const span = lp.w + lp.min * 0.4;
  const lead = dir > 0 ? -lp.min * 0.2 + p * span : lp.w + lp.min * 0.2 - p * span;
  const fade = U.smoothstep(0, 0.12, p) * (1 - U.smoothstep(0.88, 1, p));
  const path = new Path2D();
  for (let i = 0; i < count; i++) {
    const row = Math.ceil(i / 2);
    const side = i % 2 ? 1 : -1;
    const x = lead - dir * row * size * (3.2 + U.hash2(k * 7 + i, 41));
    const y = baseY + side * row * size * 1.6 + Math.sin(t * 0.55 + i * 1.9) * size * 0.6;
    const flap = Math.sin(t * TAU * (0.85 + 0.08 * i) + i * 2.1);
    const s = size * (0.85 + U.hash2(i, k) * 0.3);
    const tipY = y - s * (0.10 + 0.42 * flap);
    path.moveTo(x - s, tipY);
    path.quadraticCurveTo(x - s * 0.45, y - s * 0.20 * flap - s * 0.12, x, y);
    path.quadraticCurveTo(x + s * 0.45, y - s * 0.20 * flap - s * 0.12, x + s, tipY);
  }
  ctx.save();
  ctx.strokeStyle = 'rgba(9,13,12,' + (0.55 * fade) + ')';
  ctx.lineWidth = Math.max(0.8, size * 0.16);
  ctx.lineCap = 'round';
  ctx.stroke(path);
  ctx.restore();
}

/* ---------- water ---------- */

function buildWater(lp, top) {
  const W = Math.ceil(lp.w);
  const H = Math.ceil(lp.h - top) + 2;
  const L = U.layer(W, H, 1);
  const g = L.ctx;
  const grad = g.createLinearGradient(0, 0, 0, H);
  grad.addColorStop(0, 'rgba(54,56,51,0)');
  grad.addColorStop(0.04, 'rgba(54,56,51,0.90)');
  grad.addColorStop(0.20, 'rgba(43,46,42,0.97)');
  grad.addColorStop(0.60, 'rgba(27,31,29,0.99)');
  grad.addColorStop(1, 'rgba(16,20,18,1)');
  g.fillStyle = grad;
  g.fillRect(0, 0, W, H);
  const rnd = U.mulberry32(909);
  // mist reflected on the water
  for (let i = 0; i < 16; i++) {
    const cy = H * (0.05 + Math.pow(rnd(), 1.6) * 0.55);
    softPuff(g, rnd() * W, cy, W * (0.05 + rnd() * 0.12), H * (0.025 + rnd() * 0.05), '200,206,196', 0.06 + rnd() * 0.08, W, 0);
  }
  // ripple lines: thin horizontal dabs, denser and finer towards the far shore
  const light = new Path2D();
  const dark = new Path2D();
  const n = Math.round(150 + 70 * lp.aspect);
  for (let i = 0; i < n; i++) {
    const q = Math.pow(rnd(), 1.3);
    const y = H * (0.05 + q * 0.92);
    const len = lp.min * (0.012 + 0.05 * q * rnd() + 0.012 * rnd());
    const wid = 0.35 + q * 1.1;
    const x = rnd() * W;
    const path = rnd() < 0.6 ? light : dark;
    for (let k = -1; k <= 1; k++) addDab(path, x + k * W, y, len, wid, (rnd() - 0.5) * 0.015);
  }
  g.fillStyle = 'rgba(176,184,174,0.16)';
  g.fill(light);
  g.fillStyle = 'rgba(5,8,7,0.36)';
  g.fill(dark);
  // perspective strips, integer edges
  const N = 22;
  const edges = [];
  for (let j = 0; j <= N; j++) edges.push(Math.round(H * Math.pow(j / N, 1.35)));
  return { canvas: L.canvas, w: W, h: H, top: top, edges: edges };
}

function drawWater(ctx, lp, t, sunX, sunSize, sunVis) {
  const wt = water;
  const sp = lp.w / 1512;
  const N = wt.edges.length - 1;
  const step = lp.quality < 0.8 ? 2 : 1;
  for (let j = 0; j < N; j += step) {
    const y0 = wt.edges[j];
    const y1 = wt.edges[Math.min(N, j + step)];
    const hh = Math.min(wt.h - y0, y1 - y0 + 1);
    if (hh <= 0) continue;
    const q = (j + 0.5) / N;
    const wob = (U.noise1(j * 1.37 + t * 0.19) - 0.5) * sp * (4 + 16 * q);
    const x = wrap(t * sp * (1.2 + 6.5 * q) + wob + j * 97, wt.w);
    ctx.drawImage(wt.canvas, 0, y0, wt.w, hh, x - wt.w, wt.top + y0, wt.w, hh);
    ctx.drawImage(wt.canvas, 0, y0, wt.w, hh, x, wt.top + y0, wt.w, hh);
  }
  // the sun's vermilion reflection, broken into shimmering brush strokes (gone while the sun is set)
  const n = 12;
  for (let j = 0; j < n; j++) {
    const q = (j + 0.5) / n;
    const y = wt.top + wt.h * (0.035 + 0.52 * Math.pow(q, 1.25));
    const w = sunSize * (0.40 - 0.16 * q) * (0.55 + 0.8 * U.noise1(j * 2.3 + t * 0.21));
    const h = Math.max(1.6, wt.h * (0.013 + 0.012 * q));
    const x = sunX + (U.noise1(j * 1.91 + t * 0.33 + 4) - 0.5) * sunSize * 0.32 * (0.4 + q);
    const a = 0.85 * sunVis * (1 - q * 0.5) * U.smoothstep(0.18, 0.68, U.noise1(j * 3.7 + t * 0.42 + 9));
    if (a < 0.01) continue;
    ctx.globalAlpha = a;
    ctx.drawImage(sunDab, x - w * 0.5, y - h * 0.5, w, h);
  }
  ctx.globalAlpha = 1;
}

function buildDab(color, core) {
  const L = U.layer(96, 16, 1);
  const g = L.ctx;
  const lg = g.createLinearGradient(0, 0, 96, 0);
  lg.addColorStop(0, U.rgba(color, 0));
  lg.addColorStop(0.18, U.rgba(color, 0.85));
  lg.addColorStop(0.55, U.rgba(core, 1));
  lg.addColorStop(0.85, U.rgba(color, 0.8));
  lg.addColorStop(1, U.rgba(color, 0));
  g.fillStyle = lg;
  g.beginPath();
  g.ellipse(48, 8, 47, 5.5, 0, 0, TAU);
  g.fill();
  g.globalCompositeOperation = 'destination-out';
  g.fillStyle = 'rgba(0,0,0,0.55)';
  g.fillRect(10, 6.5, 30, 0.8);
  g.fillRect(52, 9, 34, 0.8);
  g.globalCompositeOperation = 'source-over';
  return L.canvas;
}

/* ---------- boat with a lantern ---------- */

function buildBoat(lp) {
  const len = lp.min * 0.052;
  const x = lp.w * (lp.aspect < 1.5 ? 0.76 : 0.80);
  const y = water.top + water.h * 0.30;
  const lantern = { x: len * 0.36, y: -len * 0.50 };
  const s = makeSprite(lp, -len * 0.62, -len * 0.62, len * 0.62, len * 0.16, function (g) {
    const hull = new Path2D();
    hull.moveTo(-len * 0.55, -len * 0.10);
    hull.quadraticCurveTo(-len * 0.20, len * 0.10, len * 0.30, len * 0.07);
    hull.quadraticCurveTo(len * 0.50, len * 0.03, len * 0.58, -len * 0.09);
    hull.quadraticCurveTo(len * 0.10, -len * 0.02, -len * 0.55, -len * 0.10);
    hull.closePath();
    g.fillStyle = '#0a0e0d';
    g.fill(hull);
    // a seated figure in a broad hat
    const fig = new Path2D();
    fig.moveTo(-len * 0.10, -len * 0.04);
    fig.quadraticCurveTo(-len * 0.11, -len * 0.16, -len * 0.04, -len * 0.20);
    fig.lineTo(len * 0.02, -len * 0.04);
    fig.closePath();
    fig.moveTo(-len * 0.16, -len * 0.19);
    fig.quadraticCurveTo(-len * 0.05, -len * 0.30, len * 0.06, -len * 0.19);
    fig.closePath();
    g.fill(fig);
    // pole with hanging lantern
    g.fill(taperedBranch(len * 0.30, -len * 0.04, len * 0.33, -len * 0.30, len * 0.40, -len * 0.58, len * 0.012, len * 0.006));
    g.fillRect(lantern.x - len * 0.004, -len * 0.57, len * 0.008, len * 0.05);
    g.fillStyle = '#2b1d14';
    g.fillRect(lantern.x - len * 0.022, lantern.y - len * 0.028, len * 0.044, len * 0.056);
  });
  return { x: x, y: y, len: len, sprite: s, lantern: lantern };
}

function boatPose(lp, t) {
  return {
    x: boat.x + Math.sin(t * TAU / 151) * lp.w * 0.012,
    y: boat.y + Math.sin(t * TAU / 4.7) * boat.len * 0.016,
    a: Math.sin(t * TAU / 5.9 + 0.7) * 0.022
  };
}

function lanternFlicker(t) {
  return 0.80 + 0.20 * (0.7 * U.noise1(t * 1.1) + 0.3 * U.noise1(t * 2.3 + 5));
}

function drawBoat(ctx, lp, t) {
  const p = boatPose(lp, t);
  const s = boat.sprite;
  const f = lanternFlicker(t);
  // reflection: flipped, faint, gently wavering
  ctx.save();
  ctx.globalAlpha = 0.20;
  ctx.translate(p.x + Math.sin(t * 1.3) * 0.6, p.y + boat.len * 0.10);
  ctx.rotate(-p.a);
  ctx.scale(1, -0.8);
  ctx.drawImage(s.canvas, s.x, s.y, s.w, s.h);
  ctx.restore();
  // lantern light on the water
  for (let j = 0; j < 4; j++) {
    const q = (j + 0.5) / 4;
    const w = boat.len * (0.30 - 0.12 * q) * (0.6 + 0.7 * U.noise1(j * 3.1 + t * 0.5));
    const h = Math.max(1.2, boat.len * 0.035);
    const x = p.x + boat.lantern.x + (U.noise1(j * 2.7 + t * 0.6) - 0.5) * boat.len * 0.12;
    const y = p.y + boat.len * (0.16 + 0.17 * j);
    ctx.globalAlpha = 0.5 * f * (1 - q * 0.6) * U.smoothstep(0.2, 0.7, U.noise1(j * 5.3 + t * 0.55 + 2));
    ctx.drawImage(warmDab, x - w * 0.5, y - h * 0.5, w, h);
  }
  ctx.globalAlpha = 1;
  ctx.save();
  ctx.translate(p.x, p.y);
  ctx.rotate(p.a);
  ctx.drawImage(s.canvas, s.x, s.y, s.w, s.h);
  ctx.restore();
}

/* Lantern glow and a few embers drifting up on the wind, fading out. */
function drawLantern(ctx, lp, t) {
  const p = boatPose(lp, t);
  const ca = Math.cos(p.a), sa = Math.sin(p.a);
  const lx = p.x + boat.lantern.x * ca - boat.lantern.y * sa;
  const ly = p.y + boat.lantern.x * sa + boat.lantern.y * ca;
  const f = lanternFlicker(t);
  U.glow(ctx, lx, ly, lp.min * 0.034 * (0.9 + 0.1 * f), '#d9824a', 0.30 * f);
  U.glow(ctx, lx, ly, lp.min * 0.010, '#ffd39c', 0.75 * f);
  const n = lp.quality < 0.8 ? 4 : 7;
  const life = 10;
  for (let i = 0; i < n; i++) {
    const age = wrap(t + i * life / 7, life);
    const cyc = Math.floor((t + i * life / 7) / life);
    const q = age / life;
    const seed = U.hash2(i, cyc);
    const g = gust(t - 1);
    const ex = lx + lp.min * (q * (0.03 + 0.04 * seed + 0.03 * g) + Math.sin(q * 6.5 + i * 2.1) * 0.006);
    const ey = ly - lp.min * 0.01 - q * lp.min * (0.09 + 0.05 * seed);
    const a = U.smoothstep(0, 0.1, q) * Math.pow(1 - q, 1.6) * 0.75;
    U.glow(ctx, ex, ey, lp.min * (0.0035 + 0.002 * seed), '#ff9a52', a);
  }
}

/* ---------- low fog bank curling around the base of the near crag ---------- */

function drawFogBank(ctx, lp, t) {
  const reach = crag.reach;
  const n = lp.quality < 0.8 ? 7 : 11;
  const life = 52;
  for (let i = 0; i < n; i++) {
    const age = wrap(t + i * life / n, life);
    const q = age / life;
    const seed = U.hash2(i, 71);
    const x = -reach * 0.25 + q * reach * 1.75;
    const y = lp.h * (0.80 + 0.16 * seed) + lp.min * 0.028 * Math.sin(q * 5.2 + i * 2.3);
    const r = lp.min * (0.09 + 0.06 * seed) * (0.85 + 0.3 * q);
    const a = Math.pow(Math.sin(Math.PI * q), 1.3) * (0.20 + 0.10 * seed);
    ctx.globalAlpha = a;
    ctx.drawImage(fogSprite, x - r * 1.6, y - r * 0.7, r * 3.2, r * 1.4);
  }
  ctx.globalAlpha = 1;
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
  const pad = ridgePad(lp);
  const px0 = points[0].x;
  const px1 = points[points.length - 1].x;
  const paint = function (g) {
    const body = g.createLinearGradient(0, topY, 0, footY);
    body.addColorStop(0, U.rgba(spec.color, a * 0.36));
    body.addColorStop(0.5, U.rgba(spec.color, a * 0.24));
    body.addColorStop(1, U.rgba(spec.color, 0));
    g.fillStyle = body;
    g.fillRect(-pad - ext, by, lp.w + (pad + ext) * 2, lp.h - by);
    const step = 2;
    let k = 1;
    for (let x = -Math.ceil((pad + ext) / step) * step; x < lp.w + pad + ext; x += step) {
      const px = Math.min(px1, Math.max(px0, x + step * 0.5));
      while (k < points.length - 1 && points[k].x < px) k++;
      const p0 = points[k - 1];
      const p1 = points[k];
      const q = Math.min(1, Math.max(0, (px - p0.x) / Math.max(1, p1.x - p0.x)));
      const y = p0.y + (p1.y - p0.y) * q;
      g.drawImage(strip, x, y - lead, step, depth);
    }
    granulate(g, lp, -pad - ext, by, lp.w + (pad + ext) * 2, lp.h - by, 300 + index * 17, 0.8 + index * 0.08);

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
  const block = inkBlock(lp, -pad, by, lp.w + pad * 2, lp.h - by, paint, passes, bleed);
  block.points = points;
  return block;
}

function ridgePad(lp) {
  return Math.ceil(Math.max(lp.min * 0.03, lp.w * 0.0125));
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
  const block = inkBlock(lp, 0, by, bw, lp.h - by, paint, passes, bleed);
  g.drawImage(block.canvas, block.x, block.y, block.w, block.h);
  crag = { points: points, reach: reach };
  return L;
}

