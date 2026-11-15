/*
 * Abyssal Lanterns — translucent bioluminescent drifters glowing in the deep open water.
 *
 * Four original body types (tall bell, flat fringed disc, small round one with two frilly ribbon
 * arms, and an oval comb-drifter with shimmering rows of light) at three depths: tiny faint ones
 * high and far away, mid-size ones throughout, and one or two large, dim, soft ones close to the
 * viewer (drawn into a lower-resolution layer that is upscaled — a free blur).
 *
 * Everything is a pure function of lp.t: creature paths, asymmetric bell pulses (contract
 * narrower/taller, relax wider), tentacles (which sample the creature's own path and pulse a few
 * seconds in the past, so they lag and curl), marine snow and the plankton waves (scheduled per
 * 30 s slot). Static layers (water, dither, shaft sprite) are built in resize().
 */
const U = LivePaper.util;
const TAU = Math.PI * 2;

const PALETTE = ['#5fe8ff', '#6effd2', '#a68cff', '#7fd8ff', '#c49bff', '#5cf0c0', '#8fb4ff'];
const FOG = '#2c4c9a';
// Hex-in, hex-out colour mix (U.rgba/U.glow need hex input).
function mixHex(a, b, t) {
  const A = U.hexToRgb(a), B = U.hexToRgb(b);
  const h = (v) => Math.round(v).toString(16).padStart(2, '0');
  return '#' + h(U.lerp(A[0], B[0], t)) + h(U.lerp(A[1], B[1], t)) + h(U.lerp(A[2], B[2], t));
}

let water = null;      // opaque background (gradient + haze + dither)
let shaftSprite = null;
let shafts = [];
let creatures = [];
let snow = [];         // three layers
const NS = 16;         // lag samples per creature
const LX = new Float32Array(NS + 1), LY = new Float32Array(NS + 1), LP = new Float32Array(NS + 1);
const LC = new Float32Array(NS + 1);
const tmpA = { x: 0, y: 0, u: 0 };
let clockBox = null;   // clock rect expanded by a margin; creatures inside it dim to ~25 %

LivePaper.scene({
  context: '2d',

  resize(lp) {
    water = buildWater(lp);
    shaftSprite = buildShaftSprite();
    shafts = buildShafts(lp);
    creatures = buildCreatures(lp);
    snow = buildSnow(lp);
  },

  draw(lp) {
    const ctx = lp.ctx;
    const t = lp.env.reducedMotion ? lp.t * 0.5 : lp.t;

    ctx.drawImage(water.canvas, 0, 0, lp.w, lp.h);

    ctx.globalCompositeOperation = 'lighter';
    drawShafts(ctx, lp, t);
    drawSnow(ctx, lp, t, 0);
    let i = 0;
    for (; i < creatures.length && !creatures[i].soft; i++) {
      if (creatures[i].z > 0.6) drawCreature(ctx, lp, creatures[i], t);
    }
    drawSnow(ctx, lp, t, 1);
    for (let j = 0; j < i; j++) if (creatures[j].z <= 0.6) drawCreature(ctx, lp, creatures[j], t);
    drawPlankton(ctx, lp, t);
    for (let j = i; j < creatures.length; j++) drawCreature(ctx, lp, creatures[j], t);
    drawSnow(ctx, lp, t, 2);
    ctx.globalCompositeOperation = 'source-over';
  }
});

// ------------------------------------------------------------------------------ background

function buildWater(lp) {
  const L = U.layer(lp.w, lp.h, lp.dpr), g = L.ctx;
  const grad = g.createLinearGradient(0, 0, 0, lp.h);
  grad.addColorStop(0, '#061520');
  grad.addColorStop(0.18, '#050d1e');
  grad.addColorStop(0.45, '#04071a');
  grad.addColorStop(0.75, '#02030d');
  grad.addColorStop(1, '#000002');
  g.fillStyle = grad;
  g.fillRect(0, 0, lp.w, lp.h);
  // Faint teal haze high up at the sides, where the moonlight shafts enter.
  for (const fx of [0.12, 0.88]) {
    const rr = Math.max(lp.w * 0.28, lp.min * 0.7);
    const rg = g.createRadialGradient(lp.w * fx, -lp.h * 0.05, 0, lp.w * fx, -lp.h * 0.05, rr);
    rg.addColorStop(0, 'rgba(40,110,130,0.16)');
    rg.addColorStop(0.5, 'rgba(30,80,110,0.06)');
    rg.addColorStop(1, 'rgba(20,50,90,0)');
    g.fillStyle = rg;
    g.fillRect(0, 0, lp.w, lp.h);
  }
  // Vignette towards the sides/bottom.
  const vg = g.createRadialGradient(lp.cx, lp.h * 0.4, lp.min * 0.3, lp.cx, lp.h * 0.4, lp.max * 0.75);
  vg.addColorStop(0, 'rgba(0,0,3,0)');
  vg.addColorStop(1, 'rgba(0,0,3,0.45)');
  g.fillStyle = vg;
  g.fillRect(0, 0, lp.w, lp.h);
  dither(L);
  return L;
}

// Fine, irregular dither: two noise tiles of coprime sizes applied in device pixels (one tile
// pixel = one canvas pixel) with offsets, so the combined pattern never visibly repeats.
function noiseTile(size, seed, amp) {
  const tile = document.createElement('canvas');
  tile.width = tile.height = size;
  const tg = tile.getContext('2d'), img = tg.createImageData(size, size), rnd = U.mulberry32(seed);
  for (let i = 0; i < size * size; i++) {
    const n = rnd() + rnd() - 1;                       // triangular, -1..1
    const v = n < 0 ? 0 : 255;
    img.data[i * 4] = img.data[i * 4 + 1] = img.data[i * 4 + 2] = v;
    img.data[i * 4 + 3] = Math.round(Math.abs(n) * amp);
  }
  tg.putImageData(img, 0, 0);
  return tile;
}

function dither(L) {
  const g = L.ctx, W = L.canvas.width, H = L.canvas.height;
  g.save();
  g.setTransform(1, 0, 0, 1, 0, 0);
  const tiles = [[251, 5, 5, 0, 0], [173, 11, 4, 61, 97]];
  for (const [size, seed, amp, ox, oy] of tiles) {
    g.fillStyle = g.createPattern(noiseTile(size, seed, amp), 'repeat');
    g.translate(ox, oy);
    g.fillRect(-ox, -oy, W, H);
    g.setTransform(1, 0, 0, 1, 0, 0);
  }
  g.restore();
}

// ------------------------------------------------------------------------------ light shafts

function buildShaftSprite() {
  const W = 64, H = 256, c = document.createElement('canvas');
  c.width = W; c.height = H;
  const g = c.getContext('2d'), img = g.createImageData(W, H);
  for (let y = 0; y < H; y++) {
    const v = y / (H - 1);
    const wf = 0.18 + 0.22 * v;                         // widens as it falls
    const fall = Math.pow(1 - v, 1.8) * U.smoothstep(0, 0.06, v);
    for (let x = 0; x < W; x++) {
      const u = (x / (W - 1) - 0.5) / wf;
      const a = Math.exp(-u * u * 2.2) * fall;
      const i = (y * W + x) * 4;
      img.data[i] = 150; img.data[i + 1] = 225; img.data[i + 2] = 240;
      img.data[i + 3] = Math.round(a * 255);
    }
  }
  g.putImageData(img, 0, 0);
  return c;
}

function buildShafts(lp) {
  const rnd = U.mulberry32(77);
  const perSide = lp.aspect > 2.4 ? 4 : 3;
  const list = [];
  const clockHalf = lp.clockRect ? lp.clockRect.w * 0.5 + lp.min * 0.12 : lp.w * 0.2;
  const sideW = Math.max(lp.w * 0.12, lp.cx - clockHalf);
  for (const side of [-1, 1]) {
    for (let j = 0; j < perSide; j++) {
      const f = (j + 0.3 + rnd() * 0.4) / perSide;     // 0 = outer edge, 1 = inner
      const x = side < 0 ? f * sideW : lp.w - f * sideW;
      list.push({
        x,
        side,
        angle: side * (0.12 + 0.16 * (1 - f)),
        width: lp.min * (0.10 + 0.08 * rnd()),
        len: lp.h * (0.36 + 0.12 * rnd()),
        alpha: 0.09 + 0.05 * rnd(),
        sw: TAU / (40 + rnd() * 40),
        ph: rnd() * TAU,
        bw: TAU / (25 + rnd() * 30),
        bph: rnd() * TAU,
      });
    }
  }
  return list;
}

function drawShafts(ctx, lp, t) {
  for (let i = 0; i < shafts.length; i++) {
    const s = shafts[i];
    const a = s.angle + 0.035 * Math.sin(t * s.sw + s.ph);
    const alpha = s.alpha * (0.7 + 0.3 * Math.sin(t * s.bw + s.bph));
    ctx.save();
    ctx.translate(s.x, -lp.h * 0.03);
    ctx.rotate(a);
    ctx.globalAlpha = alpha;
    ctx.drawImage(shaftSprite, -s.width * 0.5, 0, s.width, s.len);
    ctx.restore();
  }
  ctx.globalAlpha = 1;
}

// ------------------------------------------------------------------------------ marine snow

function buildSnow(lp) {
  const area = U.clamp((lp.w * lp.h) / (1512 * 982), 0.35, 2.6);
  const k = lp.min / 1000;
  const defs = [
    { n: 240, size: [0.5, 0.9], speed: [2.5, 4.5], sway: [2, 5], drift: 0.6, alpha: 0.30, color: [150, 175, 205] },
    { n: 120, size: [0.9, 1.4], speed: [6, 10], sway: [4, 9], drift: 1.2, alpha: 0.42, color: [175, 200, 220] },
    { n: 45, size: [1.4, 2.3], speed: [12, 18], sway: [7, 14], drift: 2.4, alpha: 0.5, color: [205, 228, 238] },
  ];
  const rnd = U.mulberry32(123);
  return defs.map((d) => {
    const n = Math.round(d.n * area);
    const P = new Float32Array(n * 7);
    for (let i = 0; i < n; i++) {
      const o = i * 7;
      P[o] = rnd();                                         // x fraction
      P[o + 1] = rnd();                                     // y fraction
      P[o + 2] = U.lerp(d.speed[0], d.speed[1], rnd()) * Math.max(0.5, k * 1.0); // px/s
      P[o + 3] = U.lerp(d.sway[0], d.sway[1], rnd()) * Math.max(0.5, k);
      P[o + 4] = TAU / (8 + rnd() * 10);                    // sway freq
      P[o + 5] = rnd() * TAU;
      P[o + 6] = U.lerp(d.size[0], d.size[1], rnd()) * Math.max(0.7, Math.sqrt(k));
    }
    return { n, P, drift: d.drift, alpha: d.alpha, color: d.color };
  });
}

function drawSnow(ctx, lp, t, li) {
  const L = snow[li];
  const n = Math.floor(L.n * lp.quality);
  const H = lp.h + 8, W = lp.w + 8;
  const p0 = new Path2D(), p1 = new Path2D(), p2 = new Path2D();
  const P = L.P;
  for (let i = 0; i < n; i++) {
    const o = i * 7;
    let y = (P[o + 1] * H + t * P[o + 2]) % H;
    let x = (P[o] * W + t * L.drift) % W;
    x += P[o + 3] * Math.sin(t * P[o + 4] + P[o + 5]);
    x -= 4; y -= 4;
    if (x < -4) x += W; else if (x > lp.w + 4) x -= W;
    const yf = y / lp.h;
    const path = yf < 0.38 ? p0 : (yf < 0.7 ? p1 : p2);
    const s = P[o + 6];
    if (s < 1.2) path.rect(x - s * 0.5, y - s * 0.5, s, s);
    else { path.moveTo(x + s * 0.5, y); path.arc(x, y, s * 0.5, 0, TAU); }
  }
  const c = L.color;
  ctx.fillStyle = `rgba(${c[0]},${c[1]},${c[2]},${L.alpha})`;
  ctx.fill(p0);
  ctx.fillStyle = `rgba(${c[0]},${c[1]},${c[2]},${L.alpha * 0.7})`;
  ctx.fill(p1);
  ctx.fillStyle = `rgba(${c[0]},${c[1]},${c[2]},${L.alpha * 0.42})`;
  ctx.fill(p2);
}

// ------------------------------------------------------------------------------ creatures

// Per-type body proportions (in units of r). rimW/H are relaxed values; the pulse contracts the
// rim (kW) and stretches the height (kH).
const TYPES = {
  bell:   { rimW: 0.74, topW: 0.70, H: 1.6, kW: 0.24, kH: 0.16, nf: 7, flen: [4.0, 5.6], arms: 3 },
  disc:   { rimW: 1.35, topW: 0.95, H: 0.42, kW: 0.13, kH: 0.55, nf: 24, flen: [0.7, 1.3], arms: 4 },
  ribbon: { rimW: 0.56, topW: 0.62, H: 0.92, kW: 0.20, kH: 0.16, nf: 5, flen: [1.6, 2.4], arms: 0 },
  comb:   { rimW: 0.5, topW: 0.5, H: 1.3, kW: 0, kH: 0, nf: 2, flen: [2.6, 3.6], arms: 0 },
};

function buildCreatures(lp) {
  const rnd = U.mulberry32(2024);
  const nNear = lp.aspect > 2.2 ? 2 : 1;
  const nMid = U.clamp(Math.round(3.6 + lp.aspect * 1.0), 5, 7);
  const nFar = U.clamp(Math.round(3.4 + lp.aspect * 1.3), 5, 8);
  const roles = [];
  const nearTypes = ['bell', 'disc'];
  const midTypes = ['disc', 'ribbon', 'comb', 'bell', 'ribbon', 'comb', 'disc'];
  const farTypes = ['bell', 'comb', 'disc', 'ribbon', 'bell', 'disc', 'comb', 'bell'];
  for (let i = 0; i < nNear; i++) roles.push({ role: 'near', type: nearTypes[i], i });
  for (let i = 0; i < nMid; i++) roles.push({ role: 'mid', type: midTypes[i], i });
  for (let i = 0; i < nFar; i++) roles.push({ role: 'far', type: farTypes[i], i });

  // Clock fade box (CSS px), expanded by a margin.
  const cr = lp.clockRect;
  const cm = lp.min * 0.05;
  clockBox = cr
    ? { x0: cr.x - cm, x1: cr.x + cr.w + cm, y0: cr.y - cm, y1: cr.y + cr.h + cm }
    : { x0: lp.w * 0.32, x1: lp.w * 0.68, y0: 0, y1: lp.h * 0.32 };

  // Journeys. Every depth group shares one crossing period (far slowest), its members evenly
  // staggered in phase and each given its own vertical lane, with lanes permuted so that
  // creatures adjacent in phase are far apart sideways: the group never clumps, and the number on
  // screen stays nearly constant. Most rise; one per group sinks.
  const GROUP = {
    near: { P: 200, n: nNear, sink: -1 },
    mid: { P: 310, n: nMid, sink: 2 },
    far: { P: 460, n: nFar, sink: 1 },
  };
  const GOFF = { near: 0.13, mid: 0.0, far: 0.37 };   // de-sync groups from each other

  const list = [];
  let colIdx = 0;
  for (const R of roles) {
    const G = GROUP[R.role];
    let z, r, wx, wy;
    if (R.role === 'near') {
      z = -0.35;
      r = lp.min * (0.15 + 0.04 * rnd());
      wx = lp.min * 0.02; wy = lp.h * 0.015;
    } else if (R.role === 'mid') {
      z = 0.3 + 0.25 * rnd();
      r = lp.min * (0.042 + 0.032 * rnd());
      wx = lp.min * 0.025; wy = lp.h * 0.02;
    } else {
      z = 0.75 + 0.25 * rnd();
      r = lp.min * (0.014 + 0.011 * rnd());
      wx = lp.min * 0.015; wy = lp.h * 0.012;
    }
    const T = TYPES[R.type];
    if (R.type === 'disc') r *= 0.85;
    if (R.type === 'ribbon') r *= 0.8;
    const flen = r * U.lerp(T.flen[0], T.flen[1], rnd());
    const extUp = r * (T.H * 1.25 + 1.6) + wy;
    const extDown = (R.type === 'ribbon' ? r * 5.4 : flen * 1.05) + wy;

    // Lane order: creatures adjacent in phase sit far apart sideways.
    const n = G.n;
    const lane = (LANES[n] || LANES[8])[R.i] % n;
    const x0 = 0.07, x1 = 0.93;
    const laneW = lp.w * (x1 - x0) / n;
    const laneX = lp.w * x0 + laneW * (lane + 0.5);

    const baseCol = PALETTE[(colIdx++ * 3 + 1) % PALETTE.length];
    const col = mixHex(baseCol, FOG, Math.max(0, z) * 0.55);
    const fade = R.role === 'near' ? 0.42 : R.role === 'mid' ? 0.95 - 0.3 * (z - 0.3) : 0.6 - 0.25 * (z - 0.75);
    const c = {
      type: R.type, T, role: R.role, soft: R.role === 'near',
      z, r, fade, col,
      fil: U.rgba(mixHex(col, '#ffffff', 0.18), 1),
      rimCol: U.rgba(mixHex(col, '#ffffff', 0.35), 1),
      core: mixHex(col, '#ffffff', 0.35),
      alt: mixHex(PALETTE[(colIdx * 5 + 2) % PALETTE.length], '#ffffff', 0.3),
      id: list.length + 1, near: R.role === 'near',
      P: G.P, ph0: U.fract(R.i / n + GOFF[R.role] + (rnd() - 0.5) * 0.25 / n),
      dir: R.i === G.sink ? 1 : -1,
      yTop: -extDown, yBot: lp.h + extUp, span: lp.h + extUp + extDown,
      W: lp.w, laneX, laneW, mA: Math.min(laneW * 0.2, lp.min * 0.12),
      mw1: TAU / (110 + rnd() * 90), mp1: rnd() * TAU,
      mw2: TAU / (45 + rnd() * 30), mp2: rnd() * TAU,
      wxA: wx, wyA: wy,
      wx1: TAU / (170 + rnd() * 160), px1: rnd() * TAU,
      wx2: TAU / (70 + rnd() * 60), px2: rnd() * TAU,
      wy1: TAU / (140 + rnd() * 140), py1: rnd() * TAU,
      wy2: TAU / (55 + rnd() * 50), py2: rnd() * TAU,
      per: 6 + rnd() * 6, pph: rnd(),
      nf: R.role === 'far' ? Math.max(2, Math.round(T.nf * 0.55)) : T.nf,
      flen: flen / r,
      lag: 3 + rnd() * 2.5,
      ww: TAU / (6 + rnd() * 4),
      wk: 1.0 + rnd() * 0.8,
      seed: rnd() * 100,
      tilt: (rnd() - 0.5) * 0.6,
      segs: (R.role === 'far' ? 6 : (R.role === 'near' ? 16 : 12)) * (R.type === 'disc' ? 0.5 : 1),
    };
    // Body gradient in unit (r = 1) space.
    const gctx = lp.ctx;
    let rg;
    if (c.type === 'comb') {
      rg = gctx.createRadialGradient(0, 0, 0, 0, 0, 1.35);
      rg.addColorStop(0, U.rgba(c.col, 0.10));
      rg.addColorStop(0.7, U.rgba(c.col, 0.12));
      rg.addColorStop(1, U.rgba(c.col, 0.30));
    } else {
      const cy = -T.H * 0.45;
      rg = gctx.createRadialGradient(0, cy, 0, 0, cy * 0.8, Math.max(T.rimW, T.H) * 1.15);
      rg.addColorStop(0, U.rgba(c.col, 0.12));
      rg.addColorStop(0.55, U.rgba(c.col, 0.15));
      rg.addColorStop(0.88, U.rgba(c.col, 0.32));
      rg.addColorStop(1, U.rgba(c.col, 0.46));
    }
    c.grad = rg;
    list.push(c);
  }
  // Far ones first; soft near ones last (they go into their own layer).
  list.sort((a, b) => b.z - a.z);
  return list;
}

const LANES = {
  1: [0], 2: [0, 1], 3: [0, 2, 1], 4: [0, 2, 1, 3], 5: [0, 2, 4, 1, 3], 6: [0, 3, 1, 4, 2, 5],
  7: [0, 3, 6, 2, 5, 1, 4], 8: [0, 4, 1, 5, 2, 6, 3, 7],
};

// Pass index of a creature at time t: which crossing it is on.
function passOf(c, t) { return Math.floor(c.ph0 + t / c.P); }

// Position on the journey at time t, measured within pass k (so lagged samples across the wrap
// continue smoothly off-screen instead of jumping). u: 0 = entering, 1 = gone.
function creaturePos(c, t, out, k) {
  const u = c.ph0 + t / c.P - k;
  out.u = u;
  let y = c.dir < 0 ? c.yBot - u * c.span : c.yTop + u * c.span;
  let x;
  if (c.near) {
    // The near one glides diagonally across the frame, alternating direction per pass.
    const side = ((k + c.id) & 1) ? 1 : -1;
    const a = 0.5 - side * (0.2 + 0.14 * U.hash2(k, c.id * 7 + 1));
    const b = 0.5 + side * (0.2 + 0.14 * U.hash2(k, c.id * 7 + 2));
    const e = U.clamp(u, -0.2, 1.2);
    x = (a + (b - a) * e) * c.W;
  } else {
    x = c.laneX + (U.hash2(k, c.id * 13 + 5) - 0.5) * c.laneW * 0.3;
  }
  x += c.mA * (0.7 * Math.sin(t * c.mw1 + c.mp1) + 0.3 * Math.sin(t * c.mw2 + c.mp2));
  x += c.wxA * (0.72 * Math.sin(t * c.wx1 + c.px1) + 0.28 * Math.sin(t * c.wx2 + c.px2));
  y += c.wyA * (0.72 * Math.sin(t * c.wy1 + c.py1) + 0.28 * Math.sin(t * c.wy2 + c.py2));
  out.x = x; out.y = y;
}

// Asymmetric pulse, 0 = relaxed, 1 = fully contracted: contracts over ~30 % of the cycle,
// relaxes slowly over the rest.
function pulseAt(c, t) {
  if (c.type === 'comb') return 0.5 + 0.5 * Math.sin(t * TAU / (c.per * 1.4) + c.pph * TAU);
  let f = (t / c.per + c.pph) % 1;
  if (f < 0) f += 1;
  if (f < 0.3) { const e = f / 0.3; return e * e * (3 - 2 * e); }
  const e = (f - 0.3) / 0.7;
  return 1 - e * e * (3 - 2 * e);
}

// Body path in unit space, origin at the rim centre (comb: body centre).
function bodyPath(c, p) {
  const T = c.T, path = new Path2D();
  if (c.type === 'comb') {
    const wd = T.rimW * (1 + 0.05 * p), lh = T.H;
    path.ellipse(0, 0, wd, lh, 0, 0, TAU);
    return path;
  }
  const W = T.rimW * (1 - T.kW * p), Wt = T.topW * (1 - T.kW * 0.5 * p), H = T.H * (1 + T.kH * p);
  if (c.type === 'disc') {
    path.moveTo(-W, 0);
    path.bezierCurveTo(-W * 1.02, -H * 0.75, -Wt * 0.7, -H, 0, -H);
    path.bezierCurveTo(Wt * 0.7, -H, W * 1.02, -H * 0.75, W, 0);
    path.quadraticCurveTo(0, -H * 0.5, -W, 0);
    path.closePath();
    return path;
  }
  const bulge = c.type === 'ribbon' ? 1.3 : 1.1;
  path.moveTo(-W, 0);
  path.bezierCurveTo(-W * bulge, -H * 0.45, -Wt, -H, 0, -H);
  path.bezierCurveTo(Wt, -H, W * bulge, -H * 0.45, W, 0);
  const lobes = c.type === 'ribbon' ? 6 : 8;
  for (let i = 0; i < lobes; i++) {
    const x0 = W - (i / lobes) * 2 * W, x1 = W - ((i + 1) / lobes) * 2 * W;
    path.quadraticCurveTo((x0 + x1) * 0.5, 0.13, x1, 0);
  }
  path.closePath();
  return path;
}

function innerPath(c, p) {
  const T = c.T, path = new Path2D();
  const W = T.rimW * (1 - T.kW * p) * 0.78, H = T.H * (1 + T.kH * p) * 0.74;
  path.moveTo(-W, 0.02);
  path.bezierCurveTo(-W * 1.08, -H * 0.5, -W * 0.75, -H, 0, -H);
  path.bezierCurveTo(W * 0.75, -H, W * 1.08, -H * 0.5, W, 0.02);
  return path;
}

function drawCreature(ctx, lp, c, t) {
  const T = c.T, r = c.r;
  const p = pulseAt(c, t);
  const isComb = c.type === 'comb';
  const thrust = isComb ? 0 : 0.2;

  const pass = passOf(c, t);
  creaturePos(c, t, tmpA, pass);
  // Fade in/out near the top and bottom edges (by body centre); skip when invisible.
  const by0 = tmpA.y - T.H * r * 0.5;
  const edge = U.smoothstep(-0.03 * lp.h, 0.14 * lp.h, by0) * (1 - U.smoothstep(0.86 * lp.h, 1.03 * lp.h, by0));
  if (edge <= 0.002) return;
  // Dim to ~25 % inside the (expanded) clock box.
  const cb = clockBox;
  const ddx = Math.max(cb.x0 - tmpA.x, 0, tmpA.x - cb.x1), ddy = Math.max(cb.y0 - by0, 0, by0 - cb.y1);
  const dOut = Math.hypot(ddx, ddy) - r * Math.max(T.rimW, T.H * 0.5) * 1.2;
  const clockF = 0.25 + 0.75 * U.smoothstep(0, lp.min * 0.08, dOut);

  // Lagged samples of the creature's own path (including its pulse "thrust") and pulse.
  for (let k = 0; k <= NS; k++) {
    const tl = t - (k / NS) * c.lag;
    creaturePos(c, tl, tmpA, pass);
    const pl = pulseAt(c, tl);
    LX[k] = tmpA.x; LY[k] = tmpA.y - r * thrust * pl;
    LP[k] = pl;
    LC[k] = pulseAt(c, tl - 1.1);
  }
  const x = LX[0], y = LY[0];
  const vx = (LX[0] - LX[NS >> 1]) / (c.lag * 0.5);
  let ang = U.clamp(vx / (lp.min * 0.004), -1, 1) * 0.2;
  if (isComb) ang += c.tilt + 0.25 * Math.sin(t * c.wx2 + c.py1);
  const ca = Math.cos(ang), sa = Math.sin(ang);
  const depthDim = 1 - 0.3 * U.smoothstep(lp.h * 0.55, lp.h, y);
  const A = c.fade * depthDim * edge * clockF;
  const bright = 0.62 + 0.38 * p;
  const H = T.H * (1 + T.kH * p);
  const far = c.role === 'far';

  // Halo (stronger, soft).
  const coreLy = isComb ? 0 : -H * 0.52;
  const hxp = x - sa * coreLy * r, hyp = y + ca * coreLy * r;
  U.glow(ctx, hxp, hyp, r * (isComb ? 4.6 : 4.4), c.col, 0.26 * A * bright);

  // ---- tentacles / fringe
  const segs = Math.max(4, Math.round(c.segs * (lp.quality < 1 ? 0.7 : 1)));
  const pa = new Path2D(), pb = new Path2D(), pc = new Path2D();
  const nf = c.nf;
  const W0 = T.rimW;
  for (let f = 0; f < nf; f++) {
    let u, ax0, ay0 = 0.03, len, ph = f * 1.7 + c.seed;
    if (isComb) {
      u = f === 0 ? -0.35 : 0.35; ax0 = u * 0.5; ay0 = T.H * 0.85;
      len = c.flen;
    } else {
      u = nf === 1 ? 0 : (f + (c.type === 'disc' ? 0.5 * U.hash2(f, 3) : 0)) / (nf - 1) * 2 - 1;
      u = U.clamp(u, -1, 1);
      if (c.type === 'disc') ay0 = -T.H * 0.5 * 0.5 * (1 - u * u) * 0.9;
      len = c.flen * (0.75 + 0.25 * Math.cos(u * 2.1 + c.seed + f * (c.type === 'disc' ? 2.3 : 0)));
    }
    let prevX = 0, prevY = 0, prevBand = -1;
    for (let k = 0; k <= segs; k++) {
      const s = k / segs;
      const fi = s * NS, i0 = Math.min(NS - 1, fi | 0), fr = fi - i0;
      const px = LX[i0] + (LX[i0 + 1] - LX[i0]) * fr, py = LY[i0] + (LY[i0 + 1] - LY[i0]) * fr;
      const pd = LP[i0] + (LP[i0 + 1] - LP[i0]) * fr;
      const pcurl = LC[i0] + (LC[i0 + 1] - LC[i0]) * fr;
      let lx, ly;
      if (isComb) {
        lx = ax0 + Math.sin(s * 7 - t * 0.5 + ph) * 0.45 * s + Math.sin(s * 2.4 - t * 0.2 + ph) * 0.5 * s
          + u * s * 1.4;
        ly = ay0 + s * len;
      } else {
        // Anchors follow the (delayed) rim; contraction pulls in, relaxation flares out.
        const rimW = W0 * (1 - T.kW * pd);
        lx = u * rimW * (1 - 0.3 * s)
          + u * 0.35 * s * s * (1 - pd)
          + Math.sin(s * c.wk * TAU - t * c.ww + ph) * 0.22 * s
          + pcurl * Math.sin(s * 5.2 + ph) * 0.45 * s * s;
        ly = ay0 + s * len * (1 - 0.14 * pd);
      }
      lx *= r; ly *= r;
      const wx = px + ca * lx - sa * ly;
      const wy = py + sa * lx + ca * ly;
      if (k > 0) {
        const band = s <= 0.34 ? 0 : (s <= 0.68 ? 1 : 2);
        const path = band === 0 ? pa : (band === 1 ? pb : pc);
        if (band !== prevBand) { path.moveTo(prevX, prevY); prevBand = band; }
        path.lineTo(wx, wy);
      }
      prevX = wx; prevY = wy;
    }
  }
  ctx.strokeStyle = c.fil;
  ctx.lineCap = 'butt';
  const fine = c.type === 'disc' ? 0.012 : 0.022;
  ctx.lineWidth = Math.max(0.45, r * fine);
  const ta = c.type === 'disc' ? 0.8 : (isComb ? 0.45 : 1);
  if (c.soft) {
    // Near and out of focus: a wide faint stroke under a softened thin one.
    const lw = ctx.lineWidth;
    ctx.lineWidth = lw * 2.6;
    ctx.globalAlpha = 0.06 * A * bright * ta; ctx.stroke(pa); ctx.stroke(pb);
    ctx.lineWidth = lw * 1.2;
    ctx.globalAlpha = 0.28 * A * bright * ta; ctx.stroke(pa);
    ctx.globalAlpha = 0.16 * A * bright * ta; ctx.stroke(pb);
    ctx.globalAlpha = 0.08 * A * bright * ta; ctx.stroke(pc);
  } else {
    ctx.globalAlpha = 0.44 * A * bright * ta; ctx.stroke(pa);
    ctx.globalAlpha = 0.25 * A * bright * ta; ctx.stroke(pb);
    ctx.globalAlpha = 0.11 * A * bright * ta; ctx.stroke(pc);
  }

  // ---- oral arms (bell, disc) / ribbon arms
  if (T.arms && !far) {
    const arms = new Path2D();
    const L2 = r * (c.type === 'disc' ? 1.1 : 1.8);
    for (let f = 0; f < T.arms; f++) {
      const u = (f - (T.arms - 1) / 2) * 0.2;
      const ph = f * 2.3 + c.seed;
      for (let k = 0; k <= 8; k++) {
        const s = k / 8, i0 = Math.round(s * NS * 0.4);
        const lx = (u + Math.sin(s * 5 - t * c.ww * 0.7 + ph) * 0.12 * s + LC[i0] * 0.15 * s * Math.sin(ph)) * r;
        const ly = s * L2 * (1 - 0.1 * LP[i0]);
        const wx = LX[i0] + ca * lx - sa * ly, wy = LY[i0] + sa * lx + ca * ly;
        if (k === 0) arms.moveTo(wx, wy); else arms.lineTo(wx, wy);
      }
    }
    ctx.lineWidth = Math.max(0.8, r * 0.07);
    ctx.globalAlpha = 0.17 * A * bright; ctx.stroke(arms);
  }
  if (c.type === 'ribbon') drawRibbonArms(ctx, c, t, ca, sa, A * bright, far ? 18 : 34);

  // ---- body
  ctx.save();
  ctx.translate(x, y);
  ctx.rotate(ang);
  ctx.scale(r, r);
  const body = bodyPath(c, p);
  ctx.fillStyle = c.grad;
  ctx.globalAlpha = A * (0.82 + 0.18 * p);
  ctx.fill(body);
  ctx.strokeStyle = c.rimCol;
  if (!far) {
    ctx.lineWidth = c.soft ? 0.12 : 0.14;                // soft wide rim glow
    ctx.globalAlpha = 0.10 * A * bright;
    ctx.stroke(body);
    if (c.soft) { ctx.lineWidth = 0.05; ctx.globalAlpha = 0.16 * A * bright; ctx.stroke(body); }
  }
  ctx.lineWidth = c.soft ? 0.02 : Math.max(0.6 / r, 0.03);
  ctx.globalAlpha = (c.soft ? 0.3 : 0.55) * A * bright;
  ctx.stroke(body);
  if (!far && !isComb) {
    ctx.strokeStyle = c.fil;
    ctx.lineWidth = c.soft ? 0.05 : Math.max(0.5 / r, 0.022);
    ctx.globalAlpha = (c.soft ? 0.1 : 0.18) * A;
    ctx.stroke(innerPath(c, p));
  }
  ctx.restore();

  if (isComb) drawCombRows(ctx, c, t, x, y, ca, sa, A, p, far);

  // ---- core glow + rim glow + nucleus
  const cxp = x - sa * coreLy * r, cyp = y + ca * coreLy * r;
  U.glow(ctx, cxp, cyp, r * (isComb ? 1.4 : 1.2), c.col, 0.5 * A * bright);
  U.glow(ctx, cxp, cyp, r * 0.42, c.core, 0.5 * A * bright);
  if (!far && !isComb) U.glow(ctx, x, y, r * W0 * 1.5, c.col, 0.16 * A * bright);
  ctx.globalAlpha = 1;
}

// Two long, frilly ribbon arms: a soft spine plus two ruffled edges.
function drawRibbonArms(ctx, c, t, ca, sa, AB, M) {
  const r = c.r, spine = new Path2D(), frill = new Path2D(), frill2 = new Path2D();
  const len = r * 5.2;
  for (let side = -1; side <= 1; side += 2) {
    const ph = c.seed + side * 1.3;
    for (let k = 0; k <= M; k++) {
      const s = k / M;
      const fi = s * NS, i0 = Math.min(NS - 1, fi | 0), fr = fi - i0;
      const px = LX[i0] + (LX[i0 + 1] - LX[i0]) * fr, py = LY[i0] + (LY[i0 + 1] - LY[i0]) * fr;
      const pcurl = LC[i0] + (LC[i0 + 1] - LC[i0]) * fr;
      const lx = (side * (0.14 + 0.3 * s) + side * 0.55 * s * Math.sin(s * 2.6 + t * 0.17 + ph)
        + pcurl * 0.35 * s * s * side) * r;
      const ly = (0.05 + s * len / r * (1 - 0.08 * pcurl)) * r;
      const wx = px + ca * lx - sa * ly, wy = py + sa * lx + ca * ly;
      const wdt = r * 0.16 * (1 - 0.65 * s);
      const fo = Math.sin(s * 30 - t * 0.9 + ph) * wdt;
      const ax = wx + ca * fo, ay = wy + sa * fo;
      const bx = wx - ca * fo * 0.7, by = wy - sa * fo * 0.7;
      if (k === 0) { spine.moveTo(wx, wy); frill.moveTo(ax, ay); frill2.moveTo(bx, by); }
      else { spine.lineTo(wx, wy); frill.lineTo(ax, ay); frill2.lineTo(bx, by); }
    }
  }
  ctx.strokeStyle = c.fil;
  ctx.lineWidth = Math.max(1, r * 0.16);
  ctx.globalAlpha = 0.11 * AB; ctx.stroke(spine);
  ctx.lineWidth = Math.max(0.6, r * 0.025);
  ctx.globalAlpha = 0.4 * AB; ctx.stroke(frill);
  ctx.globalAlpha = 0.2 * AB; ctx.stroke(frill2);
}

// Comb rows: meridians of a slowly turning oval, with light travelling along them.
function drawCombRows(ctx, c, t, x, y, ca, sa, A, p, far) {
  const r = c.r, T = c.T, rows = far ? 6 : 8, dots = far ? 7 : 15;
  const wd = T.rimW * (1 + 0.05 * p), lh = T.H;
  const hi = new Path2D(), lo = new Path2D(), lines = new Path2D();
  const rot = t * 0.06 + c.seed;
  const ds = Math.max(0.9, r * 0.035);
  for (let i = 0; i < rows; i++) {
    const th = rot + (i / rows) * TAU;
    const front = Math.cos(th);
    if (front < -0.1) continue;                       // rows on the far side are hidden
    const kx = Math.sin(th);
    for (let j = 0; j < dots; j++) {
      const v = (j + 0.5) / dots * 1.7 - 0.85;
      const lx = kx * wd * Math.sqrt(1 - v * v) * r, ly = v * lh * r;
      const wx = x + ca * lx - sa * ly, wy = y + sa * lx + ca * ly;
      if (j === 0) lines.moveTo(wx, wy); else lines.lineTo(wx, wy);
      const b = 0.5 + 0.5 * Math.sin(v * 7 - t * 1.4 + i * 0.9);
      if (b * (0.5 + 0.5 * front) > 0.55) hi.rect(wx - ds * 0.5, wy - ds * 0.5, ds, ds);
      else if (b > 0.3) lo.rect(wx - ds * 0.4, wy - ds * 0.4, ds * 0.8, ds * 0.8);
    }
  }
  ctx.strokeStyle = c.fil;
  ctx.lineWidth = Math.max(0.4, r * 0.012);
  ctx.globalAlpha = 0.18 * A; ctx.stroke(lines);
  ctx.fillStyle = c.alt;
  ctx.globalAlpha = 0.75 * A; ctx.fill(hi);
  ctx.fillStyle = c.core;
  ctx.globalAlpha = 0.32 * A; ctx.fill(lo);
}

// ------------------------------------------------------------------------------ plankton waves

// One wave per 30 s slot, starting 22–27 s into the slot, so a front is on screen around each
// multiple of 30 s.
const SLOT = 30, TRAVEL = 5.5, FADE = 6.5;

function drawPlankton(ctx, lp, t) {
  const K = Math.floor(t / SLOT);
  for (let k = K - 1; k <= K; k++) {
    if (k < 0) continue;
    const start = k * SLOT + 22 + U.hash2(k, 1) * 5;
    const age = t - start;
    if (age <= 0 || age > TRAVEL + FADE + 3) continue;
    drawWave(ctx, lp, k, age);
  }
}

function drawWave(ctx, lp, k, age) {
  const h = (n) => U.hash2(k, n + 10);
  const len = Math.min(lp.w * 0.7, lp.min * (1.0 + 0.6 * h(0)));
  const margin = lp.w * 0.04 + len * 0.5;
  const mx = U.lerp(margin, Math.max(margin, lp.w - margin), h(1));
  const my = lp.h * (0.5 + 0.32 * h(2));
  const tilt = (h(3) - 0.5) * 0.5;
  const bow = (h(4) - 0.5) * 0.5 * len;
  const dir = h(5) < 0.5 ? 1 : -1;
  const cx = Math.cos(tilt), sx = Math.sin(tilt);
  const M = Math.round((lp.aspect > 2.4 ? 260 : 200) * lp.quality);
  const p0 = new Path2D(), p1 = new Path2D(), p2 = new Path2D();
  const env = 1 - U.smoothstep(TRAVEL + FADE - 2, TRAVEL + FADE + 3, age);
  let gx = 0, gy = 0, gn = 0;
  const drift = age * lp.min * 0.004;
  const sz = U.clamp(lp.min / 700, 0.5, 1.6);
  for (let i = 0; i < M; i++) {
    const u = (i + U.hash2(k * 7 + i, 3)) / M;
    const tau = age - u * TRAVEL;
    if (tau <= 0) continue;
    const b = (1 - Math.exp(-tau / 0.7)) * Math.exp(-tau / 2.6) * env;
    if (b < 0.04) continue;
    const along = (dir > 0 ? u : 1 - u) - 0.5;
    const off = (U.hash2(i, k * 3 + 1) - 0.5) + (U.hash2(i, k * 3 + 2) - 0.5);
    const lx = along * len;
    const ly = bow * (1 - 4 * along * along) + off * len * 0.06 + Math.sin(along * 9 + k) * len * 0.02;
    const x = mx + cx * lx - sx * ly + drift;
    const y = my + sx * lx + cx * ly - drift * 0.3;
    const s = (0.6 + 0.9 * U.hash2(i, k + 5)) * sz;
    const path = b > 0.4 ? p0 : (b > 0.2 ? p1 : p2);
    path.moveTo(x + s, y);
    path.arc(x, y, s, 0, TAU);
    if (b > 0.35 && (i & 7) === 0) { gx += x; gy += y; gn++; }
  }
  ctx.fillStyle = 'rgba(120,255,225,0.85)'; ctx.fill(p0);
  ctx.fillStyle = 'rgba(90,215,255,0.55)'; ctx.fill(p1);
  ctx.fillStyle = 'rgba(70,170,230,0.32)'; ctx.fill(p2);
  if (gn > 0) {
    // A soft luminous swath around the brightest part of the front.
    U.glow(ctx, gx / gn, gy / gn, lp.min * 0.14, '#40e0c8', 0.08 * Math.min(1, gn / 4) * env);
  }
}
