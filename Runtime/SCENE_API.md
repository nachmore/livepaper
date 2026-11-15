# LivePaper scene API (runtime v1)

A LivePaper **web scene** is one JavaScript file that draws on a full-screen canvas. LivePaper runs
it as your Mac's screen saver — which on macOS 26 is also the live lock screen — for hours at a
time, on battery as often as on power. This guide is for people and for AI coding agents alike.
Exact types: `livepaper.d.ts`. A complete example: `templates/web/`.

## Contents

1. [Quick start](#1-quick-start)
2. [The scene package](#2-the-scene-package)
3. [Lifecycle](#3-lifecycle)
4. [The frame object `lp`](#4-the-frame-object-lp)
5. [Time and determinism](#5-time-and-determinism)
6. [Long-run rules](#6-long-run-rules)
7. [Make it feel alive](#7-make-it-feel-alive)
8. [The clock](#8-the-clock)
9. [Performance in WebKit](#9-performance-in-webkit)
10. [Utilities](#10-utilities-livepaperutil)
11. [Assets](#11-assets)
12. [WebGL scenes](#12-webgl-scenes)
13. [Rules](#13-rules)
14. [Checking a scene](#14-checking-a-scene-livepaper-check)
15. [Host bridge (for host developers)](#15-host-bridge-for-host-developers)

## 1. Quick start

`scene.json`:

```json
{
  "schema": 1,
  "id": "night-drift",
  "name": "Night Drift",
  "description": "Slow stars and drifting haze over a dark gradient.",
  "kind": "web",
  "runtime": 1,
  "clock": { "position": "top" },
  "tags": ["night"]
}
```

`scene.js`:

```js
const U = LivePaper.util;
const stars = U.makeStars({ count: 300, seed: 3 });
let sky = null;

LivePaper.scene({
  resize(lp) {                       // build what doesn't move, once per size
    sky = U.layer(lp.w, lp.h, lp.dpr);
    const g = sky.ctx.createLinearGradient(0, 0, 0, lp.h);
    g.addColorStop(0, '#02040a');
    g.addColorStop(1, '#0b1a2e');
    sky.ctx.fillStyle = g;
    sky.ctx.fillRect(0, 0, lp.w, lp.h);
  },
  draw(lp) {                         // composite a few images per frame
    lp.ctx.drawImage(sky.canvas, 0, 0, lp.w, lp.h);
    stars.draw(lp.ctx, lp, { dx: -lp.t * 2, fraction: lp.quality });
    for (let i = 0; i < 7; i++) {    // soft haze drifting across the whole sky, each band at its own speed
      const span = lp.w + lp.min, x = (i * 0.37 * span + lp.t * (8 + 3 * i)) % span - lp.min / 2;
      U.glow(lp.ctx, x, lp.h * (i + 0.5) / 7, lp.min * 0.35, '#4a6fa8', 0.3);
    }
  }
});
```

Then run `livepaper check <scene-dir>` and look at the PNGs it writes to `<scene-dir>/.check/`.
(Without the haze, only scattered stars would move and the check would call the scene too static:
see §7.)

## 2. The scene package

A scene is a directory (`<id>.lpscene` in the library):

| File | |
|---|---|
| `scene.json` | Manifest. `id` is kebab-case (`a-z`, `0-9`, inner `-`, ≤ 64 chars). `clock.position` is `top`, `bottom-left`, `bottom-right` or `none`. `performance` is written by `livepaper check`; don't edit it. |
| `scene.js` | All the code. A classic script (not an ES module): no `import`/`export`, no other files are loaded. |
| `assets/` | Optional small images, fonts, JSON or shader sources, inlined at compile time (§11). |
| `.check/` | Output of the last `livepaper check` (report + PNGs). Not published. |

LivePaper compiles the package into **one self-contained HTML file** (runtime + `scene.js` + assets
inlined, network blocked by a Content-Security-Policy). The same file is what `livepaper check`
renders and what the screen saver shows, so a scene that passes the check behaves the same on the
lock screen.

## 3. Lifecycle

```js
LivePaper.scene({
  context: '2d',          // '2d' (default) | 'webgl' | 'webgl2'
  clock: 'top',           // optional: overrides scene.json
  setup(lp) {},           // once, after the canvas exists
  resize(lp) {},          // after setup, and whenever w/h/dpr change
  update(lp, dt) {},      // advance state by dt seconds (optional)
  draw(lp) {}             // paint one frame (required)
});
```

* Call `LivePaper.scene()` **exactly once**, at the top level of `scene.js`.
* Order: `setup` → `resize` → (`update` → `draw`) every frame. `resize` runs again when the window
  size, the pixel density, or the governor's render scale changes; the canvas has been resized and
  cleared by then.
* In all callbacks `this` is your definition object, so `this.particles = …` works; module-level
  `let`/`const` variables work just as well.
* Before each `draw` the runtime resets the 2D context to `setTransform(lp.dpr, 0, 0, lp.dpr, 0, 0)`,
  `globalAlpha = 1` and `globalCompositeOperation = 'source-over'`: draw in CSS pixels and restore
  anything else you change (`save()`/`restore()`).
* Assets in `assets/` are decoded before `setup` runs.
* An exception in a callback is reported (to `livepaper check`, and in red on screen in debug mode)
  but does not stop the loop; fix every reported error.

## 4. The frame object `lp`

One object, updated in place and passed to every callback.

| Field | Meaning |
|---|---|
| `canvas` | The full-viewport stage canvas. |
| `ctx` / `gl` | The 2D context, or the WebGL context (the other is `null`). `context` says which. |
| `w`, `h` | Viewport size in **CSS pixels**. Lay out in these units. |
| `dpr` | Canvas pixels per CSS pixel = display density × render scale (e.g. 2 × 0.75 = 1.5). |
| `pw`, `ph` | Canvas size in device pixels (`w × dpr`, `h × dpr`). Use for WebGL. |
| `cx`, `cy`, `min`, `max`, `aspect` | Centre, short side, long side, `w / h`. Screens range from 32:9 ultra-wides to 5:4. |
| `scale` | Render scale from the performance profile and governor (already included in `dpr`). |
| `t`, `dt`, `frame` | Scene time (s), seconds since the last frame (≤ 0.1), frame counter. |
| `mode` | `'live'`, `'still'`, `'bench'` or `'manual'`. |
| `rand()` | Seeded PRNG in [0, 1). Same sequence every run. |
| `quality` | 0.5–1. Lowered by the governor when frames run over budget: draw less when < 1. |
| `clockRect` | `{x, y, w, h}` of the runtime clock in CSS px, or `null` when the runtime draws none. |
| `clockVisible`, `clockAlpha` | Whether any clock should show now, and its eased 0–1 opacity (§8). |
| `env` | `{power: 'ac'\|'battery', lowPower, reducedMotion, preview}`. |
| `cfg` | The effective runtime configuration (read-only). |
| `util` | Same as `LivePaper.util`. |

Adapt to `env` where it matters: slow down and avoid flashes when `env.reducedMotion`; consider
fewer particles when `env.power === 'battery'` or `env.lowPower` (the host already lowers fps and
resolution then).

## 5. Time and determinism

LivePaper renders scenes at arbitrary moments — `livepaper check` takes stills at t = 0 … 600 s,
the library renders thumbnails, the screen saver may start any scene at any time — so a scene must
produce the same picture for the same `t`.

* **Prefer pure functions of `lp.t`.** Positions, phases and colours computed from `lp.t` are
  exact at any t, cost nothing to "skip ahead", and never drift. The template scene has no
  `update()` at all.
* **If you simulate, step with `dt` only.** Stills and benches replay `update(lp, dt)` in fixed
  1/30 s steps from t = 0 up to the requested time, so a still at t = 600 runs `update()` 18,000
  times before the frame is drawn. Keep `update()` cheap (O(particles), no allocation, no drawing).
* **Randomness:** use `lp.rand()` or `LivePaper.util.mulberry32(seed)`. In capture modes
  `Math.random` is seeded too, but live it is not: never let live-only randomness change layout.
* Never read `Date.now()` / `performance.now()` for animation; use `lp.t`. (The clock is the only
  thing that shows wall-clock time, via `LivePaper.clockParts()`.)
* Don't use `setTimeout`/`setInterval`/`requestAnimationFrame` yourself: the runtime owns the loop,
  pauses it when the display sleeps, and caps the frame rate.

## 6. Long-run rules

The screen saver runs for hours. Things that are fine in a 30-second demo break overnight:

* **Bounded state.** No arrays that grow forever, no counters or accumulated floats without a
  wrap. Wrap phases (`(lp.t * speed) % period`) or recycle particles in place.
* **No slow decay.** Fades, zooms and camera moves must loop or settle, not run off to black, to
  white, or out of the frame. `livepaper check` compares t = 600 with earlier stills.
* **Precision.** `Math.sin(lp.t * 0.01)` is fine for days; feeding a huge `lp.t * 1000` into noise or
  `sin` loses smoothness after hours. Keep arguments moderate or wrap them.
* **No per-frame allocation** in hot paths (new arrays/objects/Path2D for thousands of items every
  frame). Garbage collection pauses show up as stutter. Reuse buffers.
* **Calm by default.** Lock screens are seen in the dark and at a glance: no strobing, no flashes,
  no fast full-screen motion.

## 7. Make it feel alive

A LivePaper scene is a **live wallpaper**, in the spirit of Apple's: glance at the lock screen and
the whole picture is quietly alive — mist drifting, leaves stirring, water shimmering, the view
itself slowly breathing — yet nothing asks for attention. A still picture with one thing moving (a
sun on a slow arc, a single moon) reads as a static image. `livepaper check` measures this (§14)
and fails scenes that are too static, too busy or that flicker.

**Principles**

1. **Every region, all the time.** Think of the frame as thirds × thirds: each of the nine regions
   should have something gently moving at every moment, so that wherever you look you see change
   within 1–2 s. Motion is the ambient state of the scene, not one hero element.
2. **Layers at different speeds.** Depth reads as parallax: far layers (sky, nebula, distant hills)
   drift slowest, middle layers faster, near layers (foreground mist, foliage, water) fastest.
   As a guide, on a 1512-px-wide screen: far 1–3 CSS px/s, middle 3–8, near 8–20 (scale with `lp.w`).
3. **Atmosphere moves.** Fog, mist, haze, clouds, smoke, aurora curtains and light shafts drift,
   thin and thicken. Two to four large, soft, low-alpha layers moving in slightly different
   directions are the cheapest way to bring every region to life.
4. **Nature moves.** Foliage and grass sway (a sine of `lp.t` with a per-element phase, amplitude of
   a few px); water shimmers and ripples (reflections offset by noise, glints that come and go);
   flames and lanterns flicker *softly* (smooth noise, never random per frame); particles drift
   (dust, pollen, snow, embers, plankton, rain, fireflies).
5. **A slow camera.** A gentle drift or zoom of the whole composition — a few % over 1–2 minutes,
   looping with sin/cos — moves every textured edge in the frame for one `drawImage`. (Smooth
   gradients don't visibly change when shifted: the layers on top must carry the motion.)
6. **Calm.** Nothing large moves fast: no element crosses the screen in less than ~20 s, no
   whole-frame brightness or colour change faster than a couple of seconds, no flashes or
   strobing, no per-frame random values. Behind the clock keep motion dark and low-contrast.
7. **Occasional moments.** On top of the ambient motion, rare events reward a longer look: a shooting
   star every ~40 s, a fish rising, a gust through the grass, a bird crossing, a distant light
   passing. Ease them in and out over a second or more and derive them from `lp.t`
   (`const k = Math.floor(lp.t / 37), p = (lp.t % 37) / 37;` plus `util.hash2(k, 1)` to vary them).
8. **Seamless loops.** Scroll layers with `(lp.t * speed) % width` and draw them twice (tiled);
   sway and camera moves with sin/cos; mix long, unrelated periods (47 s, 73 s, 131 s) so the
   combination never visibly repeats. Nothing may jump when a period wraps.

**Doing it cheaply** (the frame budget and battery still apply, §9):

* Paint each layer once in `resize()` into `util.layer()` canvases — oversized by a few % for a
  camera drift, or two screens wide for a scrolling band — and per frame just `drawImage` them at
  an offset or scale. A handful of full-screen `drawImage` calls costs almost nothing.
* Particles: one cached `util.glow` sprite per particle (a few hundred are fine), positions as pure
  functions of `lp.t` (`x = (x0 + lp.t * vx) % lp.w`), fewer when `lp.quality < 1`.
* Sway: rotate or skew a few pre-rendered strips or sprites with `ctx.setTransform`, not every blade.
* Water: draw the reflection layer in 20–40 horizontal strips, each offset by
  `util.noise1(y * k + lp.t * s)`.
* WebGL: two or three octaves of value noise / fbm for fog, water and light, animated by moving
  (and slowly warping) the noise coordinates with `lp.t`; render at reduced resolution if heavy.
* Avoid per-pixel JavaScript loops, `getImageData`, `shadowBlur`/`ctx.filter` and re-painting
  static layers every frame.

The pattern, complete (a night valley: static scenery with a slow camera drift, two mist bands at
different speeds, motes everywhere — 0.3 ms per frame; within 5 s about 60 % of the frame changes,
in all nine regions):

```js
const U = LivePaper.util;
const R = U.mulberry32(11);
const MOTES = Array.from({ length: 140 }, () => [R(), R(), 0.5 + R(), R() * U.TAU]);   // x0, y0, speed, phase
let scenery, mist;

LivePaper.scene({
  resize(lp) {
    // Everything static, painted once and a little oversized so the camera can drift.
    scenery = U.layer(lp.w * 1.08, lp.h * 1.08, lp.dpr);
    const s = scenery.ctx, g = s.createLinearGradient(0, 0, 0, scenery.h);
    g.addColorStop(0, '#060b18'); g.addColorStop(0.6, '#142238'); g.addColorStop(1, '#1d2b3c');
    s.fillStyle = g; s.fillRect(0, 0, scenery.w, scenery.h);
    for (const [base, amp, color] of [[0.62, 0.06, '#1a2536'], [0.74, 0.05, '#121b28'], [0.86, 0.04, '#0b121c']]) {
      s.fillStyle = color; s.beginPath(); s.moveTo(0, scenery.h);
      for (let x = 0; x <= scenery.w; x += 8) s.lineTo(x, scenery.h * (base - amp * U.fbm2(x * 0.004, base * 9, 3)));
      s.lineTo(scenery.w, scenery.h); s.fill();
    }
    // One soft mist band, two screens wide, seamless at its ends, tiled while it scrolls.
    mist = U.layer(lp.w * 2, lp.h * 0.35, lp.dpr);
    for (let i = 0; i < 40; i++) {
      const x = (i / 40) * mist.w, y = mist.h * (0.3 + 0.4 * U.noise1(i * 0.7));
      for (const dx of [0, mist.w, -mist.w]) U.glow(mist.ctx, x + dx, y, lp.h * 0.12, '#8fa6c4', 0.18);
    }
  },
  draw(lp) {
    const c = lp.ctx, t = lp.t;
    // Slow camera drift (±3 % over ~1.5 min): the whole picture is alive for one drawImage.
    const dx = (Math.sin(t * U.TAU / 97) - 1) * lp.w * 0.03, dy = (Math.sin(t * U.TAU / 71) - 1) * lp.h * 0.03;
    c.drawImage(scenery.canvas, dx, dy, scenery.w, scenery.h);
    // Two mist layers at different heights and speeds (parallax).
    for (const [y, speed, alpha] of [[0.42, 5, 0.8], [0.66, 12, 0.6]]) {
      const x = -((t * speed) % mist.w);
      c.globalAlpha = alpha;
      c.drawImage(mist.canvas, x, lp.h * y, mist.w, mist.h);
      c.drawImage(mist.canvas, x + mist.w, lp.h * y, mist.w, mist.h);
    }
    c.globalAlpha = 1;
    // Motes everywhere, as pure functions of t; fewer when the governor lowers lp.quality.
    const n = Math.floor(MOTES.length * lp.quality);
    for (let i = 0; i < n; i++) {
      const [x0, y0, s, ph] = MOTES[i];
      const x = (x0 * lp.w + t * 6 * s) % lp.w, y = y0 * lp.h + Math.sin(t * 0.4 + ph) * 10;
      U.glow(c, x, y, 3 + 2 * s, '#cfe0ff', 0.35 + 0.25 * Math.sin(t * 0.7 + ph));
    }
  }
});
```

**How the check measures it.** It lays the scene out at 1280×720 and 1024×820 (analysed at 640×360
and 512×410 px), renders it at t = 3, 17, 41 and 120 s, and compares each of those frames with the
frames 1, 3, 7 and 15 frames (1/30 s each), 0.5 s, 2 s and 5 s later, tile by tile (16 tiles
across). A tile *moves* when it visibly changes: ignoring differences of up to 2/255 (dithering),
its pixels change by at least 0.5/255 on average, or at least 3 % of them by 8/255 or more. A very
faint haze or a single tiny dot crossing a big empty tile barely registers — make motion visible.

| Measure | Fails when | Aim |
|---|---|---|
| Coverage: share of the frame that moves within 5 s | < 25 % | ≥ 50 % |
| Coverage within 2 s | | ≥ 25 % |
| Regions (thirds × thirds) with motion | fewer than 5 of 9 | all 9 |
| Busy: share of the frame changing strongly within 0.5 s | > 50 % | close to 0 |
| Flicker: share of the frame jumping between successive frames | > 30 % | close to 0 |

`report.json` has them under `motion` (one entry per size): `coverage5s`, `coverage2s`, `spread`
(regions with motion / 9), `stillRegions`, `busy`, `flicker`, `map` — one string per tile row, top
first: `#` moves at most sampled moments, `+` at some, `.` never — and `heatmap`, a picture of the
frame with moving tiles tinted (amber: most of the time, blue: sometimes, grey: still; red outline:
flicker), also as `.check/previews/motion-<size>.jpg`.

### Animating a still picture

Sometimes the user hands you a photo or painting and asks you to *animate this exact image*
(TASK.md › Reference images says so, and LivePaper has put a full-resolution copy in
`scene/assets/reference.jpg` — `.png` when it has transparency). The scene must show **that
picture**, recognisably the same, on every screen shape — and bring it to life subtly:

* **Cover-fit, every frame.** `s = Math.max(lp.w / img.width, lp.h / img.height)`, centred: the
  picture fills 16:10, 32:9 (a horizontal band of it) and 5:4 (the sides cropped) with no bars,
  stretching or mirroring. Draw it once per frame with the 9-argument `drawImage` as the base layer.
* **Keep it the same picture.** Composition, colours and details stay; don't redraw, restyle,
  recolour or replace it. If it is too bright for the budgets (TASK.md gives its brightness and a
  `darkenTo` factor), darken it *evenly* (black at a low alpha over it) and/or add a soft dark
  gradient behind the clock — the check compares structure and hue, so even darkening is fine.
* **Motion that belongs to what it shows:** water shimmering (horizontal strips of the picture,
  each offset by smooth noise), clouds, mist or fog drifting (soft low-alpha layers), foliage
  swaying (strips or cut-outs), particles that fit (snow, rain, dust, fireflies, embers), slow light
  changes (a glint, a glow — never flashing), and a slow Ken Burns camera (≤ 6 % zoom/pan,
  periods ≥ 60 s, seamless sin/cos), which moves every textured part of the picture at once.
* **Everywhere, cheaply.** The camera reaches the detailed parts; smooth areas (sky, still water,
  shadows) need local motion of their own (mist, shimmer, motes) — the motion check counts regions.
  One `drawImage` of the picture plus ≤ 40 strips, layers pre-rendered in `resize()`, no per-frame
  `getImageData`/`filter`/`shadowBlur`, and fewer strips and particles when `lp.quality < 1`.
* **Leave the asset alone.** Don't edit, re-encode, rename or delete `assets/reference.jpg`;
  LivePaper puts it back when the session ends and checks the scene with it. A 3840-px picture is
  about 40 MB once decoded, so draw it, don't copy it into more canvases than you need.

`livepaper check` then also compares its stills with the picture (cover-fit, allowing for the
slow camera; §14): a scene that doesn't load it, or whose stills don't show it, fails.

The pattern, complete (a lake photo: Ken Burns camera, shimmering water in the lower part, even
darkening and a soft shade behind the clock, two mist layers, motes — 0.4 ms per frame, motion in all
nine regions at 16:9 and 5:4, similarity to the picture about 0.9 at every size; LivePaper's
self-test runs exactly this code through the check):

```js
const U = LivePaper.util;
const R = U.mulberry32(5);
const MOTES = Array.from({ length: 80 }, () => [R(), R(), 0.5 + R(), R() * U.TAU]);   // x0, y0, speed, phase
let img, mist, shade;

LivePaper.scene({
  setup() { img = LivePaper.image('reference.jpg'); },     // decoded before setup runs
  resize(lp) {
    mist = U.layer(lp.w * 2, lp.h * 0.4, lp.dpr);           // two screens wide, seamless at its ends
    for (let i = 0; i < 36; i++) {
      const x = (i / 36) * mist.w, y = mist.h * (0.3 + 0.4 * U.noise1(i * 0.9));
      for (const dx of [0, mist.w, -mist.w]) U.glow(mist.ctx, x + dx, y, lp.h * 0.14, '#c8d2e0', 0.12);
    }
    shade = U.layer(lp.w, lp.h, lp.dpr);                    // dark gradient behind the clock
    const g = shade.ctx.createLinearGradient(0, 0, 0, lp.h * 0.45);
    g.addColorStop(0, 'rgba(0,0,0,0.45)'); g.addColorStop(1, 'rgba(0,0,0,0)');
    shade.ctx.fillStyle = g; shade.ctx.fillRect(0, 0, lp.w, lp.h * 0.45);
  },
  draw(lp) {
    const c = lp.ctx, t = lp.t;
    // Cover-fit with a slow Ken Burns camera: zoom 1–5 %, panning only within the margin the zoom
    // adds, so the view never leaves the cover-fit framing (at 32:9 that framing is a narrow band).
    const fit = Math.max(lp.w / img.width, lp.h / img.height), z = 1.025 + 0.025 * Math.sin(t * U.TAU / 97);
    const s = fit * z, w = img.width * s, h = img.height * s;
    const x = (lp.w - w) / 2 + (w - img.width * fit) * 0.4 * Math.sin(t * U.TAU / 131);
    const y = (lp.h - h) / 2 + (h - img.height * fit) * 0.4 * Math.sin(t * U.TAU / 113);
    c.drawImage(img, 0, 0, img.width, img.height, x, y, w, h);
    // Water shimmer: strips of the picture's lower part (image coordinates), each nudged ≤ 2 CSS px.
    const y0 = img.height * 0.62, n = Math.round(32 * lp.quality), sh = (img.height - y0) / n;
    for (let i = 0; i < n; i++) {
      const sy = y0 + i * sh, off = (U.noise1(i * 0.37 + t * 0.6) - 0.5) * 4;
      c.drawImage(img, 0, sy, img.width, sh, x + off, y + sy * s, w, sh * s + 1);
    }
    // Brightness budgets: an even darkening (TASK.md's darkenTo) and the shade behind the clock,
    // under the effects so they stay visible.
    c.fillStyle = 'rgba(0,0,0,0.15)'; c.fillRect(0, 0, lp.w, lp.h);
    c.drawImage(shade.canvas, 0, 0, lp.w, lp.h);
    // Two mist layers at different heights and speeds.
    for (const [my, speed, alpha] of [[0, 4, 0.9], [0.45, 9, 0.7]]) {
      const mx = -((t * speed) % mist.w);
      c.globalAlpha = alpha;
      c.drawImage(mist.canvas, mx, lp.h * my, mist.w, mist.h);
      c.drawImage(mist.canvas, mx + mist.w, lp.h * my, mist.w, mist.h);
    }
    c.globalAlpha = 1;
    // Motes drifting everywhere; fewer when the governor lowers lp.quality.
    for (let i = 0; i < Math.floor(MOTES.length * lp.quality); i++) {
      const [x0, y0m, sp, ph] = MOTES[i];
      U.glow(c, (x0 * lp.w + t * 5 * sp) % lp.w, y0m * lp.h + Math.sin(t * 0.4 + ph) * 8, 2.5 + 1.5 * sp, '#fff4dc', 0.35);
    }
  }
});
```

Adapt the regions to the picture (where its water, sky or foliage is), not the numbers to the
example. In WebGL, upload the picture once as a texture and offset the lookup in the shader with a
masked noise (`uv += mask(uv) * (noise(uv * k + t * s) - 0.5) * amp`) for water and heat haze; the
same rules apply.

## 8. The clock

LivePaper draws an Apple-style lock-screen clock (date above a large time, SF font) over the scene.
`scene.json` `"clock": {"position": …}` chooses where:

| Position | |
|---|---|
| `top` (default) | Top centre — where macOS draws its own lock-screen clock. |
| `bottom-left`, `bottom-right` | Bottom corners. |
| `none` | The runtime draws no clock; the scene may draw its own. |

**Keep the clock region dark and calm.** The clock is white; `livepaper check` measures the
scene's brightness behind it (with the clock hidden) and fails scenes that make it hard to read.
`lp.clockRect` tells you where it is, e.g. to keep particles or bright features out of it.

**The hand-off.** When the user touches the keyboard or mouse on the lock screen, macOS draws its
own lock UI — including Apple's clock at **top centre** — over the running scene. LivePaper then
fades its clock out over 300 ms and sets `lp.clockVisible = false` (and `lp.clockAlpha` eases to 0);
when the lock UI goes away it fades back. So:

* With the runtime clock you need to do nothing.
* With `clock: 'none'` and your own clock, draw it only while `lp.clockVisible` is true and multiply
  its opacity by `lp.clockAlpha` — otherwise two clocks appear. Use `LivePaper.clockParts()` for
  the text (`{time: "9:41", date: "Thursday, 13 November", hours, minutes, seconds, now}`), which
  follows the user's locale and 12/24-hour setting.
* Even with `clock: 'none'`, keep the **top-centre** region calm: Apple's clock appears there.

```js
LivePaper.scene({
  clock: 'none',
  draw(lp) {
    // … scene …
    if (lp.clockVisible) {
      const p = LivePaper.clockParts();
      lp.ctx.globalAlpha = lp.clockAlpha;
      lp.ctx.fillStyle = '#fff';
      lp.ctx.font = '600 72px -apple-system';
      lp.ctx.fillText(p.time, 48, lp.h - 64);
      lp.ctx.globalAlpha = 1;
    }
  }
});
```

## 9. Performance in WebKit

Budgets (enforced by `livepaper check`): **≤ 4 ms per frame at 1512×982 @2x** (a MacBook Pro
screen) and ≤ 6 ms at 5120×1440 @1x, measured at the heaviest sampled moment; with `--power`,
CPU energy at the battery profile (30 fps, 75 % resolution) should stay under 150 mW.

What is expensive in this WebKit build is not what you might expect from Chrome:

* **2D canvas cost tracks the number of draw calls**, much more than the number of pixels. One
  `drawImage` of a full-screen layer is cheap; 3,000 `arc()` + `fill()` calls are not.
  * Pre-render everything static (sky, terrain, vignettes, text) into `util.layer()` canvases in
    `resize()`, then `drawImage` them in `draw()`.
  * Batch shapes: build one `Path2D` per colour/alpha and `fill` it once (`util.makeStars` does
    this — a few fills for hundreds of stars).
  * Draw small things into a small offscreen canvas and scale it up: the upscale is a free blur.
* **No `shadowBlur`, no `ctx.filter`** (blur, drop-shadow) in per-frame drawing — both are very
  slow. Use `util.glow()` / `util.glowSprite()` (one cached radial-gradient sprite, one `drawImage`).
* **Avoid read-backs and cross-context copies:** no `getImageData`, `toDataURL` or
  `putImageData` of large areas per frame, and no drawing a WebGL canvas into a 2D canvas every frame
  (a GPU→GPU copy plus synchronisation). Pick one context for the scene.
* Gradients are cheap to *use*; creating hundreds per frame is not. Create them in `resize()` when
  they don't move.
* `lp.quality` < 1 means the governor already lowered the render scale because frames were over
  budget: thin particles, skip secondary effects.

The runtime does the rest: fps cap (60 on power, 30 on battery; a 60 fps cap renders every other
frame on 120 Hz displays), render scale per performance profile, a governor that steps the scale
down (×0.85 per step, floor 0.6) when update+draw stays over budget for ~2 s and back up when there
is headroom, and pausing when the display sleeps or the page is hidden.

## 10. Utilities (`LivePaper.util`)

| | |
|---|---|
| `TAU`, `clamp(x,a,b)`, `lerp(a,b,t)`, `invLerp(a,b,x)`, `fract(x)`, `smoothstep(e0,e1,x)` | Maths. |
| `ease.linear / inQuad / outQuad / inOutQuad / inCubic / outCubic / inOutCubic / inOutSine / outExpo / outBack` | Easing curves on t ∈ [0, 1]. |
| `mulberry32(seed)` | Seeded PRNG factory → `() => [0, 1)`. |
| `hash2(x, y)` | Integer lattice hash → [0, 1). |
| `noise1(x)`, `noise2(x, y)`, `fbm2(x, y, octaves = 4)` | Smooth deterministic value noise → [0, 1]. |
| `hexToRgb('#rrggbb')`, `rgba('#rrggbb', a)`, `mix('#a', '#b', t)` | Colours. |
| `layer(w, h, dpr)` | Offscreen canvas `{canvas, ctx, w, h, dpr}`, `ctx` pre-scaled: draw in CSS px. |
| `glowSprite(color, size?, falloff?)`, `glow(ctx, x, y, r, color, alpha, falloff?)` | Cached soft glows (additive). |
| `makeStars({count, seed, tint, twinkle, glow})` | Parallax starfield; `.draw(ctx, lp, {x, y, w, h, dx, dy, brightness, fraction, size})`. |

Also on `LivePaper`: `clockParts(date?)` (§8), `asset(name)`, `image(name)`, `text(name)` (§11).

## 11. Assets

Put small files in `assets/` (subfolders allowed). They are inlined into the compiled HTML as
`data:` URLs, so they work offline and inside the sandboxed screen saver.

* `LivePaper.image('sprites/moon.png')` — an `HTMLImageElement`, already decoded.
* `LivePaper.text('palette.json')` — the file's text (`JSON.parse` it yourself); also for GLSL.
* `LivePaper.asset('x.webp')` — the raw `data:` URL.
* Fonts (`.woff2`, `.woff`, `.ttf`, `.otf`) are registered automatically under their file name
  without extension: `assets/Inter.woff2` → `ctx.font = '600 40px Inter'`.

Allowed types: png, jpg/jpeg, webp, gif, avif, svg, woff, woff2, ttf, otf, json, txt, csv, glsl,
vert, frag, bin. Limits: 4 MB per file, 8 MB in total — and every byte is loaded each time the scene
starts, so prefer drawing procedurally. Text assets (SVG, JSON, shaders) must not reference external
URLs either.

**The picture to animate.** A scene made to animate one of the user's pictures has it as
`assets/reference.jpg` (`reference.png` when it has transparency), written by LivePaper at up to
3840 px and sized to fit these limits next to the scene's other assets; load it with
`LivePaper.image('reference.jpg')` and leave the file as it is (§7, "Animating a still picture").
It makes the compiled scene a few MB larger, and the screen saver holds it decoded (about 40 MB).

## 12. WebGL scenes

```js
LivePaper.scene({
  context: 'webgl2',               // falls back to 'webgl' if unavailable
  setup(lp) { /* compile shaders, create buffers */ },
  draw(lp) {
    const gl = lp.gl;              // viewport already set to (0, 0, lp.pw, lp.ph)
    // … uniforms: resolution = [lp.pw, lp.ph], time = lp.t
  }
});
```

* Use `lp.pw`/`lp.ph` for the drawing-buffer size; the runtime resizes the canvas.
* A full-screen fragment shader runs for every pixel: 6 million per frame at 1512×982 @2x. Keep
  shaders short (few noise octaves), or render to a smaller framebuffer and upscale.
* Don't set `preserveDrawingBuffer: true`, and don't mix WebGL with a per-frame 2D canvas copy.
* Handle `webglcontextlost` if you allocate GPU resources lazily (rare; the scene is reloaded on
  failures anyway).

## 13. Rules

* **Offline only.** No `fetch`, `XMLHttpRequest`, `WebSocket`, `EventSource`, `import()`, beacons
  or external URLs; the compiler rejects them and the page's security policy blocks them anyway.
  Put files in `assets/`.
* **No storage.** `localStorage`, `sessionStorage`, `indexedDB` and cookies are not available in
  the screen saver. Derive everything from `lp.t` and seeds.
* **One classic script.** No ES modules, no extra script files, no workers loaded from files.
* **Original work only.** Scenes are shared publicly: no copyrighted characters, logos, artwork,
  photos, fonts or text you don't have the rights to. Procedural art is ideal. The one exception is
  the user's own pictures: reference images they attached to an AI session are a brief to work from
  (draw procedurally), and the one picture they asked to animate is shown as
  `assets/reference.jpg`. Add no other third-party material.
* **Don't touch the page around you.** No DOM elements, CSS or event listeners of your own: the
  runtime owns the page (and there is no input — the screen saver never receives clicks or keys).

## 14. Checking a scene: `livepaper check`

```
livepaper check <scene-dir> [--quick] [--power] [--json]
```

It compiles the scene, renders stills at 1512×982 @2x (t = 0, 4, 12, 30, 90, 240, 600 s), 2560×720
(32:9), 1280×1024 (5:4) and 320×200 @2x, collects JavaScript errors, benchmarks the heaviest moment
at 1512×982 @2x and 5120×1440, measures brightness (whole frame, and behind the clock with the
clock hidden), measures how alive the scene is (motion coverage, spread, busyness and flicker at
16:9 and 5:4, §7), optionally measures live CPU energy (`--power`), and writes:

* `<scene-dir>/.check/report.json` — `passed`, `problems` (each an actionable sentence; all must be
  fixed), `warnings` (advice), `jsErrors`, `stills` (path, size, t, `meanLuma`, `clockLuma`),
  `benchMs` (`"1512x982@2 t=30": 1.4`; entries ending in ` probe` are short runs that only locate the
  heaviest moment), `energyMw`, `motion` (§7: `coverage5s`, `coverage2s`, `spread`, `regions`,
  `stillRegions`, `busy`, `flicker`, `map`, `heatmap` per size), and for a scene animating the
  user's picture `reference` (`asset`, `assetIntact`, `referencedInScene`, `similarity` per still,
  `median`).
* `<scene-dir>/.check/motion-<W>x<H>@<dpr>.png` — the motion heat maps (also in `previews/` as JPEGs).
* `<scene-dir>/.check/<W>x<H>@<dpr>-t<T>.png` — the stills. Look at them: they are what users see.
  `<scene-dir>/.check/previews/<W>x<H>@<dpr>-t<T>.jpg` are the same stills as small JPEGs (at most
  1280 px wide), for image viewers and AI tools that can't take multi-megabyte images.
* On success, `performance` in `scene.json`.

Exit status: 0 passed · 1 the scene has problems · 2 usage error · 3 LivePaper itself could not
render (render server unavailable). `--quick` renders fewer stills, measures motion at 16:9 only
and skips the ultra-wide bench — for fast iteration; finish with a full check.

Other commands: `livepaper still <dir> --t 8 --size 1512x982 --dpr 2 --out x.png`, `livepaper bench
<dir> --t 30`, `livepaper live <dir>` (fps, CPU %, mW), `livepaper compile <dir>`, `livepaper
thumbnail <dir> [--t 8]` (the 640×400 library thumbnail, `thumbnail.jpg`; the app makes these for
your own scenes, built-in scenes ship theirs).

Thresholds: frame brightness ≤ 165/255 on average; behind the clock ≤ 120/255; not black at every
sampled time; not black at t = 600 when earlier stills aren't; motion within 5 s over ≥ 25 % of the
frame and in ≥ 5 of its 9 regions; ≤ 50 % of the frame changing strongly within 0.5 s; ≤ 30 %
jumping between successive frames (§7).

**Animating a picture.** In an AI session that animates one of the user's pictures, the check also
compares 7 stills (1512×982 at t = 4, 12, 90, 600; 2560×720 at t = 12, 90; 1280×1024 at t = 12; the
quick check: 3) with the cover-fit picture on a coarse grid, allowing a slow camera (zoom ≤ 16 %,
offset ≤ 6 %) and ignoring the clock and even darkening: similarity 0–1, where the picture shown
as described in §7 scores about 0.8–1. It **fails** when scene.js never loads `reference.jpg`, or
when the median similarity is below 0.35 (the stills don't show the picture); it **warns** below
0.70 at 16:10, when 32:9 or 5:4 fall far below 16:10 (stretched or letterboxed instead of
cover-fit), and when `assets/reference.jpg` was changed. `livepaper check` prints a `picture` line.

## 15. Host bridge (for host developers)

Configuration precedence: built-in defaults < `window.LIVEPAPER_CONFIG` (inject with a user script
at document start) < URL hash (`#still=1&t=12&clock=0&debug=1`, for development) <
`LivePaper.host.config({...})` at run time. Keys: `still`, `t`, `bench`, `manual`, `clock`,
`clockPosition`, `hour12`, `clockTime`, `fps`, `scale`, `dprMax`, `performance`, `power`,
`lowPower`, `reducedMotion`, `preview`, `lockUI`, `seed`, `debug`, `governor`, `budgetMs`,
`statsEvery` (see `livepaper.d.ts`).

Host → page: `LivePaper.host.config(obj)`, `.pause()`, `.resume()`, `.lockUI(bool)`,
`.power({power, lowPower, reducedMotion, fps, scale, performance})`, `.advance(dt)` (manual mode).

Page → host, via `webkit.messageHandlers.livepaper.postMessage(...)`:
`{type: 'ready', mode, scene, t, errors, clockRect, bench?, frames?, failed?}` once the first frame
is drawn (`failed: true` if the scene never registered), `{type: 'error', message}` per distinct
error (repeats are capped), `{type: 'stats', …}` on governor changes or every `statsEvery` seconds.

Modes: **still** (`still: true, t`) steps to `t` and draws one frame; **bench** (`bench: N, t`)
steps to `t`, warms up, renders N frames synchronously and reports ms/frame; **manual**
(`manual: true`) draws on `host.advance(dt)` for frame-by-frame capture; otherwise **live**.
`LivePaper.debug.clockRect()` / `.stats()` / `.errors()` / `.overlay(bool)` serve the render server.
