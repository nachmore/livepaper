/*
 * Rain on the River — a generic night skyline in soft, steady rain, seen across a wide black river.
 *
 * Everything static (sky, buildings, windows, bridge, streetlights, the reflection light-map) is
 * built in resize(). draw() only composites: sky, drifting clouds, the city layer, a far-shore mist
 * band, a few fading windows, aviation lights, the blurred reflection cut into ~34 wobbling strips,
 * a ripple mask, river mist, a few rain rings and three scrolled rain tiles. The picture is a pure
 * function of lp.t.
 */
const U = LivePaper.util;

const WATER = 0.6;            // waterline as a fraction of the height
const SEED = 7177;

const WIN_COLORS = ['#ffb35c', '#ffd08f', '#fff0d6', '#7fe0d8', '#a3c6ff'];

// Building layers, sizes in units of the screen height. top/bottom = body gradient inside a tower.
const LAYERS = [
  { name: 'far',  minW: 0.020, maxW: 0.048, minH: 0.10, maxH: 0.36, gapMin: -0.006, gapMax: 0.006,
    top: '#0a0d15', bottom: '#1c212d', cell: 0.0036, winW: 0.5, winAlpha: 0.26, winTint: 0.5,
    haze: 0.5, spire: 0.10, seed: 1 },
  { name: 'mid',  minW: 0.028, maxW: 0.070, minH: 0.05, maxH: 0.25, gapMin: 0.002, gapMax: 0.03,
    top: '#080a11', bottom: '#171b26', cell: 0.0060, winW: 0.55, winAlpha: 0.8, winTint: 0,
    haze: 0.2, spire: 0.14, seed: 2 },
  { name: 'near', minW: 0.040, maxW: 0.12, minH: 0.02, maxH: 0.105, gapMin: 0.0, gapMax: 0.045,
    top: '#040508', bottom: '#0b0c12', cell: 0.0088, winW: 0.55, winAlpha: 0.95, winTint: 0,
    haze: 0, spire: 0, seed: 3 },
];

let S = null; // everything built per size

LivePaper.scene({
  context: '2d',

  resize(lp) {
    S = build(lp);
  },

  draw(lp) {
    if (!S) return;
    const ctx = lp.ctx, w = lp.w, h = lp.h, H = h, Y = S.Y;
    const t = lp.env.reducedMotion ? lp.t * 0.35 : lp.t;
    ctx.imageSmoothingEnabled = true;

    // Sky + water base (opaque).
    ctx.drawImage(S.sky.canvas, 0, 0, w, h);

    // Low clouds, drifting very slowly back and forth.
    const cdx = -S.cloudPad * (0.5 + 0.5 * Math.sin((t % 1400) / 1400 * U.TAU));
    ctx.drawImage(S.clouds, cdx, 0, w + S.cloudPad, Y);

    // City.
    ctx.drawImage(S.city.canvas, 0, S.cityTop, w, Y - S.cityTop);

    // Faint mist band drifting along the far shore.
    const fdx = -S.farPad * (0.5 + 0.5 * Math.sin((t % 1700) / 1700 * U.TAU + 0.4));
    ctx.drawImage(S.farMist, fdx, S.farMistY, w + S.farPad, S.farMistH);

    // Windows that slowly fade on/off.
    const fl = S.flick;
    let lastC = -1;
    for (let i = 0; i < fl.length; i++) {
      const f = fl[i];
      const p = U.fract(t / f.period + f.ph);
      const e = 3.5 / f.period;
      const a = U.smoothstep(0, e, p) * (1 - U.smoothstep(f.duty, f.duty + e, p));
      if (a < 0.004) continue;
      if (f.c !== lastC) { ctx.fillStyle = WIN_COLORS[f.c]; lastC = f.c; }
      ctx.globalAlpha = a * f.alpha;
      ctx.fillRect(f.x, f.y, f.w, f.h);
    }
    ctx.globalAlpha = 1;

    // Water reflections: strips of the blurred, mirrored light map, wobbling sideways.
    const R = S.refl, waterH = h - Y;
    ctx.globalCompositeOperation = 'lighter';
    // Thin slices sized from the height (thinner near the shore), with a smooth, gentle
    // sideways wobble that varies continuously with depth so each light column stays vertical.
    const ampK = H / 900;
    const ph = (t % 6283);
    const qk = 1 / Math.max(0.5, lp.quality);
    const sh0 = S.sliceH0 * qk, sh1 = S.sliceH1 * qk;
    const pad = 3 * ampK + 2;
    let y0 = Y;
    while (y0 < h - 0.01) {
      const fm = (y0 - Y) / waterH;
      const y1 = Math.min(h, y0 + sh0 + (sh1 - sh0) * fm);
      const u = (y0 - Y) / H;
      const amp = (0.25 + 2.2 * fm) * ampK;
      const dx = amp * (0.6 * Math.sin(u * 55 + ph * 0.45) + 0.4 * Math.sin(u * 131 - ph * 0.71));
      const a = 1 - (0.05 + 0.16 * fm) * (0.5 + 0.5 * Math.sin(u * 83 + ph * 0.38));
      const sy0 = fm * R.h, sy1 = (y1 - Y) / waterH * R.h;
      ctx.globalAlpha = a;
      ctx.drawImage(R.canvas, 0, sy0, R.w, Math.max(0.01, sy1 - sy0), dx - pad, y0, w + pad * 2, y1 - y0 + 0.5);
      y0 = y1;
    }
    ctx.globalAlpha = 1;
    ctx.globalCompositeOperation = 'source-over';

    // Aviation lights (and their soft reflections).
    for (const L of S.avi) {
      const c = 0.5 - 0.5 * Math.cos(((t + L.ph) % L.period) / L.period * U.TAU);
      const a = 0.12 + 0.88 * c * c;
      U.glow(ctx, L.x, L.y, L.r, '#ff3a2e', a * 0.85);
      ctx.globalAlpha = a;
      ctx.fillStyle = '#ffb0a0';
      ctx.fillRect(L.x - L.s / 2, L.y - L.s / 2, L.s, L.s);
      ctx.globalAlpha = 1;
      const ry = Y + (Y - L.y) * S.stretch;
      if (ry < h) {
        ctx.globalCompositeOperation = 'lighter';
        ctx.globalAlpha = a * 0.3;
        ctx.drawImage(S.redSprite, L.x - L.r * 0.4, ry - L.r * 1.2, L.r * 0.8, L.r * 5.5);
        ctx.globalAlpha = 1;
        ctx.globalCompositeOperation = 'source-over';
      }
    }

    // Ripple mask: slow horizontal dark bands breaking the columns (device-space pattern),
    // lighter near the shore so the reflections stay most continuous there.
    const dpr = lp.dpr;
    ctx.save();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.beginPath();
    ctx.rect(0, Math.floor((Y + waterH * 0.04) * dpr), lp.pw, lp.ph);
    ctx.clip();
    ctx.fillStyle = S.ripplePat;
    const rox = mod(Math.sin((t % 900) / 900 * U.TAU) * 40 * dpr, S.rippleW);
    const roy = mod(t * 6 * dpr * ampK, S.rippleH);
    ctx.translate(rox, Y * dpr + roy);
    ctx.fillRect(-S.rippleW, -S.rippleH * 2, lp.pw + S.rippleW * 2, lp.ph + S.rippleH * 2);
    ctx.restore();

    // Mist hugging the river.
    const mdx = -S.mistPad * (0.5 + 0.5 * Math.sin((t % 900) / 900 * U.TAU + 1.3));
    ctx.drawImage(S.mist, mdx, Y - S.mistAbove, w + S.mistPad, S.mistAbove + S.mistBelow);

    // Rain-drop rings on the near water.
    ctx.strokeStyle = '#a8b8d0';
    ctx.lineWidth = Math.max(0.6, H / 1100);
    for (let k = 0; k < S.ringCount; k++) {
      const P = 2.1 + k * 0.37;
      const tt = (t + k * 1.91) % (P * 1000);
      const cyc = Math.floor(tt / P), f = tt / P - cyc;
      const rx = U.hash2(k * 17 + 3, cyc) * w;
      const fy = 0.25 + 0.75 * U.hash2(k * 31 + 7, cyc + 991);
      const ry = Y + waterH * fy;
      const rmax = (0.006 + 0.03 * fy * fy) * H;
      const r = rmax * U.ease.outCubic(f);
      const a = (1 - f) * (1 - f) * 0.32 * fy;
      if (a < 0.01) continue;
      ctx.globalAlpha = a;
      ctx.beginPath();
      ctx.ellipse(rx, ry, r, r * 0.22, 0, 0, U.TAU);
      ctx.stroke();
    }
    ctx.globalAlpha = 1;

    // Rain: three pre-rendered tiles scrolled at different speeds.
    ctx.save();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    for (const r of S.rain) {
      const d = t * r.speed * dpr;
      const ox = mod(-d * r.slant, r.size), oy = mod(d, r.size);
      ctx.setTransform(1, 0, 0, 1, ox, oy);
      ctx.fillStyle = r.pat;
      ctx.fillRect(-r.size, -r.size, lp.pw + r.size, lp.ph + r.size);
    }
    ctx.restore();
  }
});

function mod(a, m) { return ((a % m) + m) % m; }

// ======================================================================================= build

function build(lp) {
  const w = lp.w, h = lp.h, H = h, dpr = lp.dpr;
  const Y = Math.round(h * WATER);
  const s = { Y };

  // Quiet zone under the clock: keep towers low there.
  const cr = lp.clockRect;
  const qc = cr ? cr.x + cr.w / 2 : w / 2;
  const qHalf = Math.min(w * 0.3, (cr ? cr.w / 2 : 0.18 * H) + 0.05 * H);
  const quiet = (x) => U.lerp(0.32, 1, U.smoothstep(qHalf, qHalf + 0.16 * H, Math.abs(x - qc)));

  // Bridge: from the right edge out over the river.
  const bridgeL = Math.min(0.9 * H, 0.36 * w);
  const bx0 = w - bridgeL - 0.02 * H, bx1 = w + 10;

  const embH = Math.max(1.5, 0.007 * H);

  // ---------------------------------------------------------------- buildings + windows
  s.cityTop = Math.floor(Y - 0.5 * H);
  const city = U.layer(w, Y - s.cityTop, dpr);
  s.city = city;
  const g = city.ctx;
  g.translate(0, -s.cityTop);

  const winPaths = LAYERS.map(() => WIN_COLORS.map(() => [new Path2D(), new Path2D()]));
  const flick = [];
  const avi = [];
  const silhouettes = [];

  LAYERS.forEach((L, li) => {
    const lr = U.mulberry32(SEED + L.seed * 101);
    const near = L.name === 'near', far = L.name === 'far';
    const sil = new Path2D();
    const mull = new Path2D();
    const blds = [];
    let x = -lr() * L.maxW * H;
    while (x < w + 0.02 * H) {
      const bw = (L.minW + (L.maxW - L.minW) * lr()) * H;
      const cx = x + bw / 2;
      let env;
      if (near) {
        env = 0.08 + 0.92 * Math.pow(lr(), 1.6);
      } else {
        const n = U.noise1(cx / H * 1.7 + L.seed * 13.1);
        env = 0.16 + 0.84 * Math.pow(U.smoothstep(0.2, 0.85, n), 1.3);
        env *= 0.45 + 0.55 * lr();
      }
      let bh = (L.minH + (L.maxH - L.minH) * env) * H * quiet(cx);
      if (L.name === 'mid' && bh > 0.5 * L.maxH * H) bh *= 0.85 + 0.25 * lr();
      const inBridge = cx > bx0 + 0.02 * H && cx < bx1;
      let skip = false;
      if (near) {
        if (inBridge) skip = true;
        if (lr() < 0.12) skip = true; // open waterfront gap
      }
      if (!skip) blds.push({ x, bw, bh });
      x += bw + (L.gapMin + (L.gapMax - L.gapMin) * lr()) * H;
    }

    // ---- silhouettes: body, crown, spire/mast; each tower filled with its own gradient
    for (const b of blds) {
      const top = Y - b.bh;
      const bp = new Path2D();
      b.rects = [{ x: b.x, y: top, w: b.bw, h: b.bh }];
      b.top = top; b.topW = b.bw;
      let slanted = false;
      const style = lr();
      if (!near && b.bh > 0.07 * H) {
        if (style < 0.26) {
          // single set-back tier
          const tw = b.bw * (0.5 + 0.25 * lr()), th = b.bh * (0.08 + 0.12 * lr());
          b.rects.push({ x: b.x + (b.bw - tw) / 2, y: top - th, w: tw, h: th });
          b.top = top - th; b.topW = tw;
        } else if (style < 0.44) {
          // stepped crown, 2–3 tiers
          const n = 2 + (lr() < 0.5 ? 1 : 0);
          let yy = top;
          for (let k = 1; k <= n; k++) {
            const tw = b.bw * (1 - 0.24 * k), th = b.bh * (0.04 + 0.04 * lr());
            yy -= th;
            b.rects.push({ x: b.x + (b.bw - tw) / 2, y: yy, w: tw, h: th });
            b.topW = tw;
          }
          b.top = yy;
        } else if (style < 0.58) {
          // slanted roof
          const sh = b.bw * (0.25 + 0.45 * lr());
          const leftHigh = lr() < 0.5;
          bp.moveTo(b.x, top + 0.5);
          bp.lineTo(b.x + b.bw, top + 0.5);
          if (leftHigh) bp.lineTo(b.x, top - sh); else bp.lineTo(b.x + b.bw, top - sh);
          bp.closePath();
          slanted = true;
          b.top = top - sh * 0.5;
        }
      }
      for (const r of b.rects) bp.rect(r.x, r.y, r.w, r.h + 1);
      const tall = b.bh > (far ? 0.22 : 0.15) * H;
      if (L.spire && tall && !slanted && lr() < 0.45) {
        const sh = (0.03 + 0.06 * lr()) * H, sw = Math.max(1, b.topW * 0.18);
        const mx = b.x + b.bw / 2;
        bp.moveTo(mx - sw / 2, b.top + 0.5);
        bp.lineTo(mx, b.top - sh);
        bp.lineTo(mx + sw / 2, b.top + 0.5);
        bp.closePath();
        avi.push({ x: mx, y: b.top - sh, layer: li, h: b.bh + sh });
      } else if (!near && !slanted && lr() < 0.2) {
        // antenna mast with a small cross-bar
        const mh = (0.025 + 0.035 * lr()) * H, mw = Math.max(0.8, H * 0.0014);
        const mx = b.x + b.bw * (0.3 + 0.4 * lr());
        bp.rect(mx, b.top - mh, mw, mh + 1);
        bp.rect(mx - mw * 2, b.top - mh * 0.62, mw * 5, mw);
        if (tall) avi.push({ x: mx + mw / 2, y: b.top - mh, layer: li, h: b.bh + mh * 0.6 });
      }
      sil.addPath(bp);

      const gr = g.createLinearGradient(0, b.top - 0.02 * H, 0, Y);
      gr.addColorStop(0, L.top);
      gr.addColorStop(0.55, U.mix(L.top, L.bottom, 0.45));
      gr.addColorStop(1, L.bottom);
      g.fillStyle = gr;
      g.fill(bp);
    }
    silhouettes.push(sil);

    // ---- windows, in several architectural styles
    const cellW = Math.max(1.2, L.cell * H), cellH = Math.max(1.6, L.cell * H * 1.35);
    const ww = cellW * L.winW, wh = cellH * 0.52;
    const P = winPaths[li];
    const shopZone = near ? embH + 0.016 * H : 0;
    for (const b of blds) {
      const k = lr();
      let type;
      if (far) type = k < 0.2 ? 'dark' : k < 0.55 ? 'grid' : k < 0.8 ? 'bands' : 'resid';
      else if (near) type = k < 0.15 ? 'dark' : k < 0.62 ? 'resid' : 'grid';
      else type = k < 0.08 ? 'dark' : k < 0.34 ? 'resid' : k < 0.54 ? 'grid' : k < 0.77 ? 'bands' : 'glass';
      if (type === 'glass' && b.bw < 0.035 * H) type = 'bands';
      const warmBias = lr();
      const coolOffice = lr() < 0.55;
      for (let ri = 0; ri < b.rects.length; ri++) {
        const r = b.rects[ri];
        const rh = ri === 0 ? r.h - shopZone : r.h;
        const cols = Math.floor((r.w - cellW * 0.8) / cellW);
        const rows = Math.floor((rh - cellH * 1.2) / cellH);
        if (cols < 1 || rows < 1) continue;
        const ox = r.x + (r.w - cols * cellW) / 2 + (cellW - ww) / 2;
        const oy = r.y + cellH * 0.6;
        const bandX0 = r.x + cellW * 0.45, bandW = r.w - cellW * 0.9;

        if (type === 'bands') {
          const bc = coolOffice ? (lr() < 0.6 ? 3 : 4) : 2;
          for (let j = 0; j < rows; j++) {
            if (lr() > 0.48) continue;
            let bx = bandX0, bwid = bandW;
            if (lr() < 0.35) { const f = 0.3 + 0.5 * lr(); if (lr() < 0.5) bx += bwid * (1 - f); bwid *= f; }
            P[lr() < 0.4 ? bc : 2][lr() < 0.4 ? 1 : 0].rect(bx, oy + j * cellH, bwid, wh * 0.8);
          }
          continue;
        }
        if (type === 'glass') {
          const step = cellW * 1.6;
          for (let mx = r.x + step * 0.5; mx < r.x + r.w - 1; mx += step) mull.rect(mx, r.y + 1, Math.max(0.5, 0.0006 * H), r.h - 1);
          for (let j = 0; j < rows; j++) {
            const yy = oy + j * cellH;
            if (lr() < 0.16) { P[lr() < 0.6 ? 3 : 4][1].rect(bandX0, yy, bandW, wh * 0.6); continue; }
            for (let i = 0; i < cols; i++) if (lr() < 0.035) P[lr() < 0.5 ? 2 : 4][0].rect(ox + i * cellW, yy, ww, wh);
          }
          continue;
        }
        for (let j = 0; j < rows; j++) {
          let floorLit, floorColor;
          const fr = lr();
          if (type === 'dark') { floorLit = 0.04; floorColor = fr < 0.5 ? 0 : 1; }
          else if (type === 'resid') {
            floorLit = 0.08 + 0.24 * lr();
            floorColor = fr < 0.5 + warmBias * 0.3 ? 0 : fr < 0.9 ? 1 : 2;
          } else {
            const on = fr < 0.42;
            floorLit = on ? 0.8 : 0.04;
            floorColor = coolOffice ? (lr() < 0.6 ? 3 : 4) : (lr() < 0.6 ? 2 : 1);
            if (!on) floorColor = 1;
          }
          if (far && lr() < 0.4) floorLit *= 0.5;
          const yy = oy + j * cellH;
          for (let i = 0; i < cols; i++) {
            const xx = ox + i * cellW;
            const q = lr();
            if (li > 0 && q < 0.0032) {
              let c = floorColor;
              if (type === 'grid' && floorLit < 0.5) c = 2;
              flick.push({ x: xx, y: yy, w: ww, h: wh, c, alpha: L.winAlpha * 0.95 });
              continue;
            }
            if (lr() >= floorLit) continue;
            let c = floorColor;
            if (type === 'resid' && lr() < 0.05) c = 4;
            P[c][lr() < 0.35 ? 1 : 0].rect(xx, yy, ww, wh);
          }
        }
      }

      // Ground-floor shop fronts on the waterfront blocks.
      if (near && type !== 'dark') {
        const shopH = 0.009 * H, sy = Y - embH - shopH - 0.003 * H;
        const nseg = Math.max(1, Math.round(b.bw / (0.022 * H)));
        const segW = b.bw / nseg, pad = segW * 0.12;
        for (let i = 0; i < nseg; i++) {
          if (lr() > 0.45) continue;
          const c = lr() < 0.55 ? 0 : lr() < 0.7 ? 1 : 2;
          P[c][lr() < 0.3 ? 1 : 0].rect(b.x + i * segW + pad, sy, segW - pad * 2, shopH);
        }
      }
    }

    // Glass mullions: faint vertical lines.
    if (!far) {
      g.fillStyle = 'rgba(120,140,175,0.13)';
      g.fill(mull);
    }

    for (let c = 0; c < WIN_COLORS.length; c++) {
      g.fillStyle = L.winTint ? U.mix(WIN_COLORS[c], '#5c6684', L.winTint) : WIN_COLORS[c];
      g.globalAlpha = L.winAlpha;
      g.fill(P[c][0]);
      g.globalAlpha = L.winAlpha * 0.55;
      g.fill(P[c][1]);
    }
    g.globalAlpha = 1;

    // Rain haze in front of this layer: strongest near the waterline, gone by the tower tops.
    if (L.haze > 0) {
      const hz = g.createLinearGradient(0, Y - 0.36 * H, 0, Y);
      hz.addColorStop(0, 'rgba(30,34,48,0)');
      hz.addColorStop(0.6, `rgba(36,40,54,${L.haze * 0.4})`);
      hz.addColorStop(1, `rgba(52,52,66,${L.haze})`);
      g.fillStyle = hz;
      g.fill(sil);
    }

    // After the far towers: the city-glow haze band (bright just above the waterline, fading
    // up into the dark cloud ceiling), which pushes the far layer back.
    if (far) {
      const hb = g.createLinearGradient(0, Y - 0.3 * H, 0, Y);
      hb.addColorStop(0, 'rgba(40,36,52,0)');
      hb.addColorStop(0.55, 'rgba(46,40,56,0.18)');
      hb.addColorStop(0.85, 'rgba(62,52,66,0.36)');
      hb.addColorStop(1, 'rgba(74,60,70,0.46)');
      g.fillStyle = hb;
      g.fillRect(0, Y - 0.3 * H, w, 0.3 * H);
    }
  });

  // Flickering windows: period scales with count so ~0.4 changes per second overall.
  const fr = U.mulberry32(SEED + 55);
  const meanPeriod = Math.max(60, flick.length * 5);
  for (const f of flick) {
    f.period = meanPeriod * (0.6 + 0.8 * fr());
    f.ph = fr();
    f.duty = 0.3 + 0.45 * fr();
  }
  flick.sort((a, b) => a.c - b.c);
  s.flick = flick;

  // Embankment along the waterline, with a row of warm streetlights.
  g.fillStyle = '#05060a';
  g.fillRect(0, Y - embH, w, embH + 1);
  const lampPath = new Path2D(), polePath = new Path2D(), reflLamps = new Path2D();
  const lampStep = 0.034 * H, poleH = 0.012 * H, ls = Math.max(1, 0.0024 * H);
  const lsR = 0.0024 * H; // reflection size: no pixel floor, so small screens stay proportional
  const lamps = [];
  for (let x = U.mulberry32(SEED + 1234)() * lampStep; x < bx0; x += lampStep) {
    const ly = Y - embH - poleH;
    polePath.rect(x, ly, Math.max(0.7, 0.0009 * H), poleH);
    lampPath.rect(x - ls * 0.3, ly - ls * 0.5, ls, ls * 0.8);
    reflLamps.rect(x - lsR * 1.5, ly - lsR, lsR * 3.6, lsR * 1.6);
    lamps.push({ x: x + ls * 0.2, y: ly });
  }
  g.fillStyle = '#0d0e14';
  g.fill(polePath);

  // Bridge
  const deckY = Y - 0.034 * H, deckT = Math.max(2, 0.0065 * H);
  const bPath = new Path2D();
  bPath.rect(bx0, deckY, bx1 - bx0, deckT);
  const piers = 6;
  for (let i = 0; i <= piers; i++) {
    const px = bx0 + 0.01 * H + i * (bridgeL / piers);
    bPath.rect(px - 0.004 * H, deckY, 0.008 * H, Y - deckY);
  }
  const pyX = bx0 + bridgeL * 0.42, pyH = 0.15 * H, pyW = Math.max(1.5, 0.006 * H);
  bPath.moveTo(pyX - pyW, deckY);
  bPath.lineTo(pyX - pyW * 0.3, deckY - pyH);
  bPath.lineTo(pyX + pyW * 0.3, deckY - pyH);
  bPath.lineTo(pyX + pyW, deckY);
  bPath.closePath();
  g.fillStyle = '#080a10';
  g.fill(bPath);
  // Cables
  g.strokeStyle = 'rgba(90,100,125,0.35)';
  g.lineWidth = Math.max(0.5, 0.0008 * H);
  g.beginPath();
  for (let i = 1; i <= 8; i++) {
    const k = i / 8;
    g.moveTo(pyX, deckY - pyH * (0.92 - 0.25 * k));
    g.lineTo(pyX - bridgeL * 0.4 * k, deckY);
    g.moveTo(pyX, deckY - pyH * (0.92 - 0.25 * k));
    g.lineTo(pyX + bridgeL * 0.45 * k, deckY);
  }
  g.stroke();
  avi.push({ x: pyX, y: deckY - pyH - 0.002 * H, layer: 1, h: 1e9 });
  // Deck lamps
  const deckLamps = new Path2D(), reflDeck = new Path2D();
  const nLamps = Math.round(bridgeL / (0.018 * H));
  const dls = Math.max(1.2, 0.0028 * H), dlsR = 0.0028 * H;
  for (let i = 0; i <= nLamps + 2; i++) {
    const lx = bx0 + i * (bridgeL / nLamps);
    deckLamps.rect(lx - dls / 2, deckY - dls * 1.2, dls, dls);
    reflDeck.rect(lx - dlsR * 0.8, deckY - dlsR * 1.5, dlsR * 1.6, dlsR * 1.6);
  }
  g.fillStyle = '#ffd9a0';
  g.fill(deckLamps);
  g.fillStyle = '#ffc070';
  g.fill(lampPath);
  // soft lamp glows (static)
  g.globalCompositeOperation = 'lighter';
  for (let i = 0; i <= nLamps + 2; i += 1) {
    U.glow(g, bx0 + i * (bridgeL / nLamps), deckY - dls, 0.012 * H, '#ffb060', 0.25);
  }
  for (const L of lamps) U.glow(g, L.x, L.y, 0.011 * H, '#ffa850', 0.3);
  g.globalCompositeOperation = 'source-over';

  // Aviation lights: keep a few, tallest first, outside the quiet zone.
  const nAvi = Math.max(2, Math.min(7, Math.round(w / H * 2)));
  const aviR = U.mulberry32(SEED + 9);
  avi.sort((a, b) => b.h - a.h);
  s.avi = avi.filter((a) => Math.abs(a.x - qc) > qHalf * 0.9).slice(0, nAvi).map((a) => ({
    x: a.x, y: a.y, r: (a.layer === 0 ? 0.011 : 0.016) * H, s: Math.max(1.2, 0.0028 * H),
    period: 2.4 + aviR() * 0.8, ph: aviR() * 3,
  }));
  s.redSprite = U.glowSprite('#ff4030');

  // ---------------------------------------------------------------- sky + water base
  const sky = U.layer(w, h, dpr), sg = sky.ctx;
  s.sky = sky;
  const sgr = sg.createLinearGradient(0, 0, 0, Y);
  sgr.addColorStop(0, '#030409');
  sgr.addColorStop(0.45, '#080915');
  sgr.addColorStop(0.75, '#16131f');
  sgr.addColorStop(0.92, '#261d2a');
  sgr.addColorStop(1, '#30232c');
  sg.fillStyle = sgr;
  sg.fillRect(0, 0, w, Y);
  const wgr = sg.createLinearGradient(0, Y, 0, h);
  wgr.addColorStop(0, '#1d1720');
  wgr.addColorStop(0.12, '#0e0c14');
  wgr.addColorStop(0.45, '#05060a');
  wgr.addColorStop(1, '#010103');
  sg.fillStyle = wgr;
  sg.fillRect(0, Y, w, h - Y);
  // Dark reflected silhouettes of the city in the water.
  sg.save();
  sg.translate(0, Y);
  sg.scale(1, -0.75);
  sg.translate(0, -Y);
  sg.fillStyle = 'rgba(4,5,9,0.55)';
  for (let i = 1; i < silhouettes.length; i++) sg.fill(silhouettes[i]);
  sg.restore();
  dither(sg, w, h);

  // ---------------------------------------------------------------- clouds
  s.cloudPad = Math.round(0.08 * w);
  s.clouds = buildClouds(w + s.cloudPad, Y, H, qc, qHalf);

  // ---------------------------------------------------------------- reflection map
  // City lights mirrored and stretched into a small canvas, smeared into long columns,
  // blurred sideways, faded toward the viewer; drawn scaled up in strips.
  const waterH = h - Y, ST = 1.7;
  s.stretch = ST;
  // Map resolution scales with the height so the pixel-sized blurs stay proportional on small screens.
  const rk = Math.min(4, Math.max(0.75, H / 245));
  const RW = Math.max(32, Math.ceil(w / rk)), RH = Math.max(32, Math.ceil(waterH / (rk * 0.75)));
  const rc = document.createElement('canvas');
  rc.width = RW; rc.height = RH;
  const rg = rc.getContext('2d');
  const syk = ST * RH / waterH;
  rg.setTransform(RW / w, 0, 0, -syk, 0, Y * syk);
  rg.globalCompositeOperation = 'lighter';
  LAYERS.forEach((L, li) => {
    const k = (li === 0 ? 0.08 : li === 1 ? 0.38 : 0.85) * Math.min(1, 0.55 + H / 900);
    for (let c = 0; c < WIN_COLORS.length; c++) {
      rg.fillStyle = WIN_COLORS[c];
      rg.globalAlpha = k;
      rg.fill(winPaths[li][c][0]);
      rg.globalAlpha = k * 0.55;
      rg.fill(winPaths[li][c][1]);
    }
  });
  rg.globalAlpha = 1;
  rg.fillStyle = '#ffb460';
  rg.fill(reflLamps);
  rg.fill(reflLamps);
  rg.fillStyle = '#ffd9a0';
  rg.globalAlpha = 0.55;
  rg.fill(reflDeck);
  rg.globalAlpha = 1;
  rg.globalAlpha = 0.5;
  rg.fillStyle = '#ff5a40';
  for (const a of s.avi) rg.fillRect(a.x - a.s * 1.5, a.y - a.s, a.s * 3, a.s * 2);
  rg.globalAlpha = 1;
  rg.setTransform(1, 0, 0, 1, 0, 0);

  const tmp = document.createElement('canvas');
  tmp.width = RW; tmp.height = RH;
  const tg = tmp.getContext('2d');
  // Long vertical columns: repeated averaging copies shifted downward (energy-preserving).
  for (const [off, a] of [[1, 0.5], [2, 0.5], [4, 0.5], [8, 0.5], [16, 0.45], [32, 0.4]]) {
    tg.globalCompositeOperation = 'copy';
    tg.drawImage(rc, 0, 0);
    rg.globalCompositeOperation = 'source-over';
    rg.globalAlpha = a;
    rg.drawImage(tmp, 0, Math.max(1, Math.round(off * RH / 110)));
  }
  // Sideways blur so neighbouring windows merge into soft columns.
  tg.globalCompositeOperation = 'copy';
  tg.globalAlpha = 1;
  tg.drawImage(rc, 0, 0);
  rg.globalAlpha = 1;
  rg.globalCompositeOperation = 'source-over';
  rg.clearRect(0, 0, RW, RH);
  rg.globalCompositeOperation = 'lighter';
  for (const [dx, a] of [[-2, 0.2], [-1, 0.34], [0, 0.46], [1, 0.34], [2, 0.2]]) {
    rg.globalAlpha = a;
    rg.drawImage(tmp, dx, 0);
  }
  // a little vertical softening too
  tg.globalCompositeOperation = 'copy';
  tg.globalAlpha = 1;
  tg.drawImage(rc, 0, 0);
  rg.globalAlpha = 0.5;
  rg.drawImage(tmp, 0, 1);
  rg.globalAlpha = 1;
  // darker toward the viewer
  rg.globalCompositeOperation = 'destination-in';
  const fade = rg.createLinearGradient(0, 0, 0, RH);
  fade.addColorStop(0, 'rgba(0,0,0,0.54)');
  fade.addColorStop(0.15, 'rgba(0,0,0,0.36)');
  fade.addColorStop(0.35, 'rgba(0,0,0,0.17)');
  fade.addColorStop(0.6, 'rgba(0,0,0,0.06)');
  fade.addColorStop(1, 'rgba(0,0,0,0.015)');
  rg.fillStyle = fade;
  rg.fillRect(0, 0, RW, RH);
  rg.globalCompositeOperation = 'source-over';
  s.refl = { canvas: rc, w: RW, h: RH };
  s.sliceH0 = Math.max(0.5, 0.0035 * H); // slice thickness at the shore …
  s.sliceH1 = Math.max(1, 0.009 * H);    // … and at the bottom edge

  // ---------------------------------------------------------------- ripple mask (device px)
  {
    const RWd = Math.max(64, Math.round(520 * dpr * H / 900)), RHd = Math.max(32, Math.round(160 * dpr * H / 900));
    const c = document.createElement('canvas');
    c.width = RWd; c.height = RHd;
    const q = c.getContext('2d'), r = U.mulberry32(SEED + 77);
    q.fillStyle = 'rgba(2,3,7,0.3)';
    const n = 110;
    for (let i = 0; i < n; i++) {
      const y = r() * RHd;
      const len = (40 + 220 * r()) * dpr * H / 900, th = Math.max(0.7, (0.4 + 1.1 * r()) * dpr * H / 900);
      const x = r() * RWd;
      for (const ox of [-RWd, 0, RWd]) q.fillRect(x + ox, y, len, th);
    }
    s.ripplePat = lp.ctx.createPattern(c, 'repeat');
    s.rippleW = RWd; s.rippleH = RHd;
  }

  // ---------------------------------------------------------------- mist
  s.mistPad = Math.round(0.1 * w);
  s.mistAbove = 0.035 * H; s.mistBelow = 0.06 * H;
  s.mist = buildMist(w + s.mistPad, s.mistAbove, s.mistBelow, H, '#8a8aa6', 0.3, 50);
  // far-shore band, in front of the far towers
  s.farPad = Math.round(0.14 * w);
  const fa = 0.03 * H, fb = 0.02 * H;
  s.farMistY = Y - 0.025 * H - fa; s.farMistH = fa + fb;
  s.farMist = buildMist(w + s.farPad, fa, fb, H, '#7c7f98', 0.2, 120);

  s.ringCount = Math.max(5, Math.min(16, Math.round(w / H * 5)));

  // ---------------------------------------------------------------- rain tiles (device px)
  s.rain = [
    { count: 300, len: 0.012, width: 1.0, alpha: 0.13, speed: 0.36, slant: 0.12, size: 0.42 },
    { count: 100, len: 0.026, width: 1.0, alpha: 0.16, speed: 0.62, slant: 0.14, size: 0.55 },
    { count: 30,  len: 0.05,  width: 1.6, alpha: 0.18, speed: 1.05, slant: 0.16, size: 0.7 },
  ].map((spec, i) => buildRain(spec, i, H, dpr, lp.ctx));

  return s;
}

function buildRain(spec, idx, H, dpr, ctx) {
  const size = Math.max(96, Math.min(1400, Math.round(spec.size * H * dpr)));
  const c = document.createElement('canvas');
  c.width = c.height = size;
  const g = c.getContext('2d'), r = U.mulberry32(SEED + 300 + idx);
  const len = spec.len * H * dpr;
  g.lineCap = 'round';
  g.lineWidth = Math.max(0.8, spec.width * dpr * 0.7);
  const count = spec.count;
  for (let i = 0; i < count; i++) {
    const x = r() * size, y = r() * size;
    const l = len * (0.6 + 0.8 * r());
    const a = spec.alpha * (0.4 + 0.6 * r());
    const dx = -spec.slant * l;
    for (const ox of [-size, 0, size]) for (const oy of [-size, 0, size]) {
      const x0 = x + ox, y0 = y + oy;
      if (x0 + dx > size + 4 || x0 < -4 - Math.abs(dx) || y0 > size + 4 || y0 + l < -4) continue;
      const gr = g.createLinearGradient(x0, y0, x0 + dx, y0 + l);
      gr.addColorStop(0, 'rgba(190,205,230,0)');
      gr.addColorStop(1, `rgba(200,214,236,${a})`);
      g.strokeStyle = gr;
      g.beginPath();
      g.moveTo(x0, y0);
      g.lineTo(x0 + dx, y0 + l);
      g.stroke();
    }
  }
  return { pat: ctx.createPattern(c, 'repeat'), size, speed: spec.speed * H, slant: spec.slant };
}

function buildClouds(W, Y, H, qc, qHalf) {
  const k = 6;
  const cw = Math.max(8, Math.ceil(W / k)), ch = Math.max(8, Math.ceil(Y / k));
  const c = document.createElement('canvas');
  c.width = cw; c.height = ch;
  const g = c.getContext('2d'), img = g.createImageData(cw, ch), d = img.data;
  const top = U.hexToRgb('#2a1c34'), low = U.hexToRgb('#7a4a48');
  for (let y = 0; y < ch; y++) {
    const yn = y / (ch - 1);                         // 0 top … 1 waterline
    const band = U.smoothstep(0.38, 0.72, yn) * (1 - 0.6 * U.smoothstep(0.9, 1, yn));
    const lit = Math.pow(U.smoothstep(0.4, 1.0, yn), 1.5);
    for (let x = 0; x < cw; x++) {
      const X = x * k / H;
      const n = U.fbm2(X * 2.0 + 11.3, yn * 5.5 + X * 0.25, 4);
      const n2 = U.fbm2(X * 6.5 + 3.1, yn * 14.0, 2);
      let dens = U.smoothstep(0.42, 0.78, n * 0.8 + n2 * 0.25) * band;
      // lit undersides: brighter where the cloud thins out below
      const under = U.smoothstep(0.3, 0.9, U.fbm2(X * 2.0 + 11.3, (yn + 0.06) * 5.5 + X * 0.25, 3));
      const shade = lit * (0.55 + 0.45 * (1 - under));
      const i4 = (y * cw + x) * 4;
      d[i4] = top[0] + (low[0] - top[0]) * shade;
      d[i4 + 1] = top[1] + (low[1] - top[1]) * shade;
      d[i4 + 2] = top[2] + (low[2] - top[2]) * shade;
      d[i4 + 3] = Math.min(255, dens * 235);
    }
  }
  g.putImageData(img, 0, 0);
  // general city glow under the clouds
  const glow = g.createLinearGradient(0, ch * 0.55, 0, ch);
  glow.addColorStop(0, 'rgba(90,55,80,0)');
  glow.addColorStop(1, 'rgba(110,64,72,0.22)');
  g.fillStyle = glow;
  g.fillRect(0, 0, cw, ch);
  return c;
}

function buildMist(W, above, below, H, color, alpha, seedX) {
  const k = 6;
  const mw = Math.max(8, Math.ceil(W / k)), mh = Math.max(6, Math.ceil((above + below) / k));
  const c = document.createElement('canvas');
  c.width = mw; c.height = mh;
  const g = c.getContext('2d'), img = g.createImageData(mw, mh), d = img.data;
  const col = U.hexToRgb(color);
  const cy = above / (above + below);
  for (let y = 0; y < mh; y++) {
    const yn = y / (mh - 1);
    const prof = yn < cy ? U.smoothstep(0, cy, yn) : 1 - U.smoothstep(cy, 1, yn);
    for (let x = 0; x < mw; x++) {
      const n = U.fbm2(x * k / H * 4.0 + seedX, yn * 2.0, 3);
      const a = prof * (0.3 + 0.7 * U.smoothstep(0.35, 0.75, n)) * alpha;
      const i4 = (y * mw + x) * 4;
      d[i4] = col[0]; d[i4 + 1] = col[1]; d[i4 + 2] = col[2];
      d[i4 + 3] = a * 255;
    }
  }
  g.putImageData(img, 0, 0);
  return c;
}

function dither(g, w, h) {
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
  g.fillRect(0, 0, w, h);
}
