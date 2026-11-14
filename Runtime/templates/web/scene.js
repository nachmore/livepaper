/*
 * Quiet Aurora — the LivePaper starter scene.
 *
 * Slow northern lights over a still mountain lake, under a drifting starfield. It is written to be
 * copied: it shows the pieces most scenes need and the habits that keep a scene cheap enough to run
 * for hours on battery.
 *
 *   - Everything that does not move (sky, mountains, lake) is drawn ONCE per size, in resize(), into
 *     offscreen layers. draw() then only composites a handful of images.
 *   - The aurora is drawn into a tiny canvas (1/6 of the screen) and scaled up: the upscale is the
 *     blur, so there is no shadowBlur or ctx.filter anywhere.
 *   - The picture is a pure function of lp.t (no state accumulated in update()), so any moment can
 *     be rendered directly and the scene looks the same after ten minutes as after ten hours.
 *   - The top-centre band stays dark: that is where the clock sits (ours, and Apple's lock-screen
 *     clock when the user wakes the screen).
 *
 * See SCENE_API.md for the full API.
 */
const U = LivePaper.util;

// Tunables. Positions are fractions of the screen height so the scene works at any aspect ratio.
const HORIZON = 0.68;          // where sky meets lake
const AURORA_SCALE = 6;        // CSS px per aurora-canvas pixel (bigger = softer and cheaper)
const RIBBONS = [
  // base: lower edge of the curtain; height: how far it reaches up; drift: horizontal speed
  { base: 0.57, height: 0.30, drift: 0.018, wave: 0.060, seed: 1, alpha: 0.78, low: '#4dffb0', high: '#3ab8ff' },
  { base: 0.47, height: 0.22, drift: 0.011, wave: 0.050, seed: 2, alpha: 0.40, low: '#3ce8d0', high: '#9a7cff' },
];

const stars = U.makeStars({ count: 420, seed: 11, glow: 0.975 });
let sky = null;        // opaque background: sky gradient + reflected sky in the lake
let front = null;      // transparent foreground: mountains, their reflection, lake darkening
let aurora = null;     // the small canvas the aurora is drawn into every frame
let rays = null;       // 1-px-tall strip of curtain "rays", stretched vertically

LivePaper.scene({
  context: '2d',

  // Called once the canvas exists, then resize() follows. Nothing here depends on the size.
  setup(lp) {},

  // Called whenever the size or pixel density changes (including governor scale steps).
  resize(lp) {
    const horizon = lp.h * HORIZON;
    sky = buildSky(lp, horizon);
    front = buildForeground(lp, horizon);
    const aw = Math.max(8, Math.ceil(lp.w / AURORA_SCALE));
    const ah = Math.max(8, Math.ceil(horizon / AURORA_SCALE));
    aurora = U.layer(aw, ah, 1);
    rays = buildRays(aw);
  },

  // This scene derives everything from lp.t, so it needs no update(). Simulations that do keep
  // state should advance it here using dt only (stills replay update() in 1/30 s steps).

  draw(lp) {
    const ctx = lp.ctx;
    const horizon = lp.h * HORIZON;
    // Reduced motion: same picture, a quarter of the speed.
    const t = lp.env.reducedMotion ? lp.t * 0.25 : lp.t;

    ctx.drawImage(sky.canvas, 0, 0, lp.w, lp.h);

    // Stars only above the horizon; a slow sideways drift reads as the sky turning. When the
    // governor lowers lp.quality on a struggling Mac, draw fewer of them.
    stars.draw(ctx, lp, { h: horizon * 0.98, dx: -t * 1.2, fraction: lp.quality, brightness: 0.9 });

    drawAurora(aurora, rays, t);
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';
    ctx.globalCompositeOperation = 'lighter';
    ctx.drawImage(aurora.canvas, 0, 0, lp.w, horizon);
    // Reflection: mirrored about the horizon, squashed and faint.
    ctx.save();
    ctx.translate(0, horizon * 1.55);
    ctx.scale(1, -0.55);
    ctx.globalAlpha = 0.28;
    ctx.drawImage(aurora.canvas, 0, 0, lp.w, horizon);
    ctx.restore();
    ctx.globalCompositeOperation = 'source-over';

    ctx.drawImage(front.canvas, 0, 0, lp.w, lp.h);
  }
});

// ------------------------------------------------------------------------------------ aurora

function drawAurora(layer, rayStrip, t) {
  const g = layer.ctx, w = layer.w, h = layer.h;
  g.globalCompositeOperation = 'source-over';
  g.clearRect(0, 0, w, h);
  g.globalCompositeOperation = 'lighter';
  const points = 64;
  for (const r of RIBBONS) {
    // Gentle breathing so the curtains never look frozen, never flash.
    const alpha = r.alpha * (0.78 + 0.22 * Math.sin(t * 0.07 + r.seed * 2.1));
    const base = r.base / HORIZON * h, reach = r.height / HORIZON * h;
    const top = [], bottom = [];
    for (let i = 0; i <= points; i++) {
      const x = i / points * w;
      const u = i / points * 3 + r.seed * 10;
      // Lower edge: slow, wide folds drifting sideways.
      const yb = base + (U.fbm2(u * 0.6 + t * r.drift, r.seed * 7.3, 3) - 0.5) * r.wave / HORIZON * h * 4;
      // The top edge varies (rays reaching up to different heights). It only ever cuts the faint
      // upper part of the gradient below, so it never shows as a hard edge.
      const lift = reach * (0.55 + 0.45 * U.fbm2(u * 2.6 - t * r.drift * 2.2, r.seed * 3.1, 2));
      bottom.push(x, yb);
      top.push(x, yb - lift);
    }
    const body = new Path2D(), rim = new Path2D();
    body.moveTo(top[0], top[1]);
    for (let i = 2; i < top.length; i += 2) body.lineTo(top[i], top[i + 1]);
    for (let i = bottom.length - 2; i >= 0; i -= 2) body.lineTo(bottom[i], bottom[i + 1]);
    body.closePath();
    rim.moveTo(bottom[0], bottom[1]);
    for (let i = 2; i < bottom.length; i += 2) rim.lineTo(bottom[i], bottom[i + 1]);
    // Curtain body: transparent at the top, brightest at the base line, then a gentle continuous
    // ramp below it so lower folds never meet a hard edge in the gradient.
    const fold = r.wave / HORIZON * h * 1.2;
    const pb = reach / (reach + fold);
    const grad = g.createLinearGradient(0, base - reach, 0, base + fold);
    grad.addColorStop(0, U.rgba(r.high, 0));
    grad.addColorStop(pb * 0.4, U.rgba(r.high, alpha * 0.05));
    grad.addColorStop(pb * 0.65, U.rgba(r.high, alpha * 0.25));
    grad.addColorStop(pb * 0.88, U.rgba(r.low, alpha * 0.8));
    grad.addColorStop(pb, U.rgba(r.low, alpha));
    grad.addColorStop(1, U.rgba(r.low, alpha * 0.6));
    g.fillStyle = grad;
    g.fill(body);
    // The bright lower rim follows the folds exactly.
    g.strokeStyle = U.rgba(r.low, alpha * 0.4);
    g.lineWidth = 1.2;
    g.stroke(rim);
  }
  // Cut vertical rays out of the curtains; the strip scrolls slowly so the rays shimmer.
  g.globalCompositeOperation = 'destination-out';
  const off = ((t * 0.9) % w + w) % w;
  g.drawImage(rayStrip, -off, 0, w, h);
  g.drawImage(rayStrip, w - off, 0, w, h);
  g.globalCompositeOperation = 'source-over';
}

function buildRays(width) {
  const c = document.createElement('canvas');
  c.width = width;
  c.height = 1;
  const g = c.getContext('2d');
  const img = g.createImageData(width, 1);
  for (let x = 0; x < width; x++) {
    // Seamless across the wrap: noise on a circle.
    const a = x / width * U.TAU;
    const n = U.fbm2(Math.cos(a) * 14 + 20, Math.sin(a) * 14 + 20, 3);
    img.data[x * 4 + 3] = Math.round(U.smoothstep(0.3, 0.8, n) * 105);
  }
  g.putImageData(img, 0, 0);
  return c;
}

// ------------------------------------------------------------------------------------ layers

function buildSky(lp, horizon) {
  const L = U.layer(lp.w, lp.h, lp.dpr), g = L.ctx;
  const grad = g.createLinearGradient(0, 0, 0, horizon);
  grad.addColorStop(0, '#02040a');
  grad.addColorStop(0.55, '#050c1c');
  grad.addColorStop(0.86, '#0a1a2e');
  grad.addColorStop(1, '#10283a');
  g.fillStyle = grad;
  g.fillRect(0, 0, lp.w, horizon);
  // The lake mirrors the sky, darker.
  const lake = g.createLinearGradient(0, horizon, 0, lp.h);
  lake.addColorStop(0, '#0b1e2c');
  lake.addColorStop(0.35, '#050d18');
  lake.addColorStop(1, '#010306');
  g.fillStyle = lake;
  g.fillRect(0, horizon, lp.w, lp.h - horizon);
  dither(g, lp);
  return L;
}

function buildForeground(lp, horizon) {
  const L = U.layer(lp.w, lp.h, lp.dpr), g = L.ctx;
  // Ridge heights in units of the screen height, so mountains keep their shape at any aspect.
  const ridge = (x, seed, scale) => U.fbm2(x / lp.h * scale, seed, 4);
  const ranges = [
    { seed: 4.2, scale: 2.4, lift: 0.13, color: '#0a1726' },
    { seed: 9.7, scale: 4.1, lift: 0.075, color: '#04090f' },
  ];
  const step = Math.max(2, lp.w / 360);
  for (const r of ranges) {
    for (const dir of [1, -1]) {          // the range, then its reflection
      g.beginPath();
      g.moveTo(0, horizon);
      for (let x = 0; x <= lp.w + step; x += step) {
        const y = (0.25 + 0.75 * ridge(x, r.seed, r.scale)) * r.lift * lp.h;
        g.lineTo(x, horizon - dir * y * (dir < 0 ? 0.55 : 1));
      }
      g.lineTo(lp.w, horizon);
      g.closePath();
      g.fillStyle = dir > 0 ? r.color : U.rgba(r.color, 0.85);
      g.fill();
    }
  }
  // Darken the water towards the viewer; keeps the bottom calm for a bottom clock.
  const shade = g.createLinearGradient(0, horizon, 0, lp.h);
  shade.addColorStop(0, 'rgba(1,3,6,0)');
  shade.addColorStop(1, 'rgba(1,3,6,0.75)');
  g.fillStyle = shade;
  g.fillRect(0, horizon, lp.w, lp.h - horizon);
  return L;
}

// Dark gradients band visibly on 8-bit displays; a whisper of noise hides the steps.
function dither(g, lp) {
  const size = 128, tile = document.createElement('canvas');
  tile.width = tile.height = size;
  const tg = tile.getContext('2d'), img = tg.createImageData(size, size), rnd = U.mulberry32(5);
  for (let i = 0; i < size * size; i++) {
    const v = rnd() < 0.5 ? 0 : 255;
    img.data[i * 4] = img.data[i * 4 + 1] = img.data[i * 4 + 2] = v;
    img.data[i * 4 + 3] = Math.round(rnd() * 5);
  }
  tg.putImageData(img, 0, 0);
  g.fillStyle = g.createPattern(tile, 'repeat');
  g.fillRect(0, 0, lp.w, lp.h);
}
