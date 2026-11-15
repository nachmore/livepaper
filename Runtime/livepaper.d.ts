// Type definitions for the LivePaper scene runtime, API version 1 (Runtime/runtime.js).
// Scenes are plain JavaScript; these typings document the API and let editors check scene.js.
// Human-readable guide: SCENE_API.md.

declare namespace LivePaper {
  /** Runtime version string, e.g. "1.0.0". */
  const version: string;
  /** Runtime API major version (matches "runtime" in scene.json). */
  const api: 1;

  /** Registers the scene. Call exactly once, at the top level of scene.js. */
  function scene(definition: SceneDefinition): void;

  /** Lock-screen style clock text for scenes that draw their own clock (`clock: 'none'`). */
  function clockParts(date?: Date): ClockParts;

  /** data: URL of a file in the package's assets/ folder (path relative to assets/), or null. */
  function asset(name: string): string | null;
  /** Decoded image from assets/ (ready before setup() runs), or null. */
  function image(name: string): HTMLImageElement | null;
  /** Text content of a file in assets/ (JSON, GLSL, SVG source…), or null. */
  function text(name: string): string | null;

  const util: Util;
  /** Called by the native host (screen saver, app, render server). Scenes never call these. */
  const host: Host;
  /** Inspection hooks used by the render server and debugging tools. */
  const debug: Debug;

  type ContextKind = '2d' | 'webgl' | 'webgl2';
  /** Where the runtime draws its clock. 'none': the scene draws its own (or none at all). */
  type ClockPosition = 'top' | 'bottom-left' | 'bottom-right' | 'none';
  type Mode = 'live' | 'still' | 'bench' | 'manual';

  interface SceneDefinition {
    /** Canvas context to create. Default '2d'. 'webgl2' falls back to 'webgl' if unavailable. */
    context?: ContextKind;
    /** Passed to getContext(). Default for 2d: {alpha: false}; for WebGL: {alpha: false, antialias: true,
     *  premultipliedAlpha: false, powerPreference: 'low-power'}. */
    contextOptions?: CanvasRenderingContext2DSettings | WebGLContextAttributes;
    /** Overrides "clock.position" from scene.json. */
    clock?: ClockPosition;
    /** CSS colour of the runtime clock text. Default 'rgba(255,255,255,0.9)'. Keep it light. */
    clockColor?: string;
    /** Once, after the canvas exists and before the first resize(). `this` is the definition object. */
    setup?(this: SceneDefinition, lp: Frame): void;
    /** After setup() and whenever lp.w / lp.h / lp.dpr change (window resize, governor scale steps).
     *  The canvas has been resized (and cleared): rebuild size-dependent layers here. */
    resize?(this: SceneDefinition, lp: Frame): void;
    /** Advances the simulation by dt seconds (lp.t already includes dt). Keep it cheap and use only
     *  dt/lp.t for timing: stills replay it in 1/30 s steps from t = 0. */
    update?(this: SceneDefinition, lp: Frame, dt: number): void;
    /** Paints one frame. Required. The 2D transform is reset to scale(lp.dpr) before each call, so
     *  draw in CSS pixels; globalAlpha = 1 and composite = 'source-over'. */
    draw(this: SceneDefinition, lp: Frame): void;
    [key: string]: unknown;
  }

  /** The frame API passed to every scene callback (one object, updated in place). */
  interface Frame {
    /** The full-viewport stage canvas. */
    readonly canvas: HTMLCanvasElement;
    /** 2D context (null for WebGL scenes). */
    readonly ctx: CanvasRenderingContext2D | null;
    /** WebGL context (null for 2D scenes). The viewport is set to the full canvas before draw(). */
    readonly gl: WebGLRenderingContext | WebGL2RenderingContext | null;
    /** The context actually created. */
    readonly context: ContextKind;
    /** Viewport size in CSS pixels. Draw in these units (2D contexts are pre-scaled by dpr). */
    readonly w: number;
    readonly h: number;
    /** Canvas pixels per CSS pixel: display density × governor scale (e.g. 2 × 0.75 = 1.5). */
    readonly dpr: number;
    /** Canvas size in device pixels (w × dpr, h × dpr). Use for WebGL. */
    readonly pw: number;
    readonly ph: number;
    /** Centre, short side, long side, aspect ratio (w / h), in CSS pixels. */
    readonly cx: number;
    readonly cy: number;
    readonly min: number;
    readonly max: number;
    readonly aspect: number;
    /** Render scale chosen by the performance profile and governor (0.6–1). Already in dpr. */
    readonly scale: number;
    /** Scene time in seconds (starts at the requested t in stills/benches, 0 live). */
    readonly t: number;
    /** Seconds since the previous frame (clamped to 0.1). */
    readonly dt: number;
    /** Frames rendered so far. */
    readonly frame: number;
    readonly mode: Mode;
    /** Seeded PRNG in [0, 1): the same sequence on every run. Use it instead of Math.random(). */
    readonly rand: () => number;
    /** 0.5–1. Drops when the governor detects frames over budget; draw fewer particles when < 1. */
    readonly quality: number;
    /** Where the runtime clock is (CSS px), or null if the runtime draws no clock. Keep it calm. */
    readonly clockRect: Rect | null;
    /** False while no clock should be visible: the user hid it, or the macOS lock UI (with Apple's
     *  clock) is on screen. Scenes that draw their own clock must hide it then. */
    readonly clockVisible: boolean;
    /** 0–1, eased over 300 ms when clockVisible changes. Multiply your own clock's alpha by it. */
    readonly clockAlpha: number;
    readonly env: Environment;
    /** The effective runtime configuration (read-only for scenes). */
    readonly cfg: Readonly<Config>;
    /** Same object as LivePaper.util. */
    readonly util: Util;
  }

  interface Rect { x: number; y: number; w: number; h: number; }

  interface Environment {
    /** 'battery' when the Mac runs on battery. */
    power: 'ac' | 'battery';
    /** Low Power Mode is on. */
    lowPower: boolean;
    /** The user asked for reduced motion: slow down, avoid flashes and fast camera moves. */
    reducedMotion: boolean;
    /** Rendering in a small preview (System Settings thumbnail, library grid). */
    preview: boolean;
  }

  interface ClockParts {
    /** "9:41" — hour and minute in the user's 12/24-hour preference, no AM/PM (like macOS). */
    time: string;
    /** "Thursday, 13 November" — localised weekday, month, day. */
    date: string;
    hours: number;
    minutes: number;
    seconds: number;
    now: Date;
  }

  interface Layer {
    canvas: HTMLCanvasElement;
    /** Pre-scaled by dpr: draw in CSS pixels. */
    ctx: CanvasRenderingContext2D;
    w: number;
    h: number;
    dpr: number;
  }

  interface StarsOptions {
    /** Default 400. */
    count?: number;
    /** Default 7. Same seed, same sky. */
    seed?: number;
    /** Slight blue/warm tints. Default true. */
    tint?: boolean;
    /** Twinkle amount 0–1. Default 1. */
    twinkle?: number;
    /** Depth (0–1) above which stars get a glow sprite. Default 0.93 (about 7 % of stars). */
    glow?: number;
  }

  interface StarsDrawOptions {
    /** Region to fill (CSS px). Default: the whole viewport. */
    x?: number; y?: number; w?: number; h?: number;
    /** Parallax offset in CSS px (near stars move more). Animate it for drift. */
    dx?: number; dy?: number;
    /** Overall brightness multiplier. Default 1. */
    brightness?: number;
    /** Fraction of stars to draw (pass lp.quality). Default 1. */
    fraction?: number;
    /** Star size multiplier. Default 1. */
    size?: number;
  }

  interface Stars {
    readonly stars: ReadonlyArray<{ x: number; y: number; z: number; tw: number; hue: number }>;
    /** Draws the field in a handful of batched fills (not one call per star). */
    draw(ctx: CanvasRenderingContext2D, lp: Frame, options?: StarsDrawOptions): void;
  }

  interface Easing {
    linear(t: number): number;
    inQuad(t: number): number;
    outQuad(t: number): number;
    inOutQuad(t: number): number;
    inCubic(t: number): number;
    outCubic(t: number): number;
    inOutCubic(t: number): number;
    inOutSine(t: number): number;
    outExpo(t: number): number;
    outBack(t: number): number;
  }

  interface Util {
    readonly TAU: number;
    clamp(x: number, min: number, max: number): number;
    lerp(a: number, b: number, t: number): number;
    invLerp(a: number, b: number, x: number): number;
    fract(x: number): number;
    smoothstep(edge0: number, edge1: number, x: number): number;
    readonly ease: Easing;
    /** Seedable PRNG factory: returns a function producing [0, 1). */
    mulberry32(seed: number): () => number;
    /** Integer lattice hash in [0, 1). */
    hash2(x: number, y: number): number;
    /** Smooth value noise in [0, 1]. Deterministic. */
    noise1(x: number): number;
    noise2(x: number, y: number): number;
    /** Fractal noise in [0, 1] (default 4 octaves). */
    fbm2(x: number, y: number, octaves?: number): number;
    hexToRgb(hex: string): [number, number, number];
    /** '#46ffb4' + alpha → 'rgba(70,255,180,0.5)'. */
    rgba(hex: string, alpha?: number): string;
    /** Mix two hex colours → 'rgb(r,g,b)'. */
    mix(hexA: string, hexB: string, t: number): string;
    /** Offscreen canvas for pre-rendered layers (build in resize(), drawImage in draw()). */
    layer(cssWidth: number, cssHeight: number, dpr?: number): Layer;
    /** Cached radial glow sprite (a canvas). Far cheaper than shadowBlur or ctx.filter. */
    glowSprite(color: string, size?: number, falloff?: number): HTMLCanvasElement;
    /** Additive glow blob of radius r (CSS px) at (x, y), using a cached sprite. */
    glow(ctx: CanvasRenderingContext2D, x: number, y: number, r: number, color: string, alpha: number, falloff?: number): void;
    /** A deterministic parallax starfield. */
    makeStars(options?: StarsOptions): Stars;
  }

  /** Runtime configuration: defaults < window.LIVEPAPER_CONFIG < URL hash < host.config(). */
  interface Config {
    /** Render one frame at t and stop (deterministic capture). */
    still: boolean;
    /** Scene time to start at (still/bench/manual) in seconds. */
    t: number;
    /** Render this many frames synchronously and report ms/frame. 0 = off. */
    bench: number;
    /** Frame-by-frame capture: the host calls host.advance(dt). */
    manual: boolean;
    /** Show a clock at all (playlist setting). */
    clock: boolean;
    /** Host override of the clock position (normally scene.json decides). */
    clockPosition: ClockPosition | null;
    /** Force 12/24-hour time; null follows the system. */
    hour12: boolean | null;
    /** Fixed clock time (ISO date or epoch ms) for reproducible captures; null = now. */
    clockTime: string | null;
    /** fps cap and render scale; null = from the performance profile. */
    fps: number | null;
    scale: number | null;
    /** Upper bound for devicePixelRatio. Default 2. */
    dprMax: number;
    performance: 'automatic' | 'best' | 'balanced' | 'battery';
    power: 'ac' | 'battery';
    lowPower: boolean;
    reducedMotion: boolean;
    preview: boolean;
    /** The macOS lock UI is already showing when the scene loads. */
    lockUI: boolean;
    /** Seed of lp.rand (and of Math.random in capture modes). */
    seed: number;
    /** Show JS errors on screen. */
    debug: boolean;
    /** Adaptive render-scale governor (live mode). Default true. */
    governor: boolean;
    /** Frame budget for the governor in ms; 0 = half the frame interval. */
    budgetMs: number;
    /** Post a 'stats' message every N seconds; 0 = never. */
    statsEvery: number;
  }

  interface Host {
    /** Change configuration at run time (capture keys still/bench/manual/t are ignored). */
    config(changes: Partial<Config>): void;
    /** Stop / restart the frame loop (display sleep, hidden previews). */
    pause(): void;
    resume(): void;
    /** The macOS lock UI is (true) / is no longer (false) drawn over the scene: fades the runtime clock
     *  out/in over 300 ms and updates lp.clockVisible / lp.clockAlpha. */
    lockUI(showing: boolean): void;
    /** Power state changed: {power, lowPower, reducedMotion, fps, scale, performance}. */
    power(state: Partial<Pick<Config, 'power' | 'lowPower' | 'reducedMotion' | 'fps' | 'scale' | 'performance'>>): void;
    /** Manual mode only: advance by dt seconds and render one frame. */
    advance(dt: number): void;
  }

  interface Stats {
    type: 'stats';
    reason: string;
    mode: Mode;
    frame: number;
    t: number;
    fps: number;
    frameMs: number;
    budgetMs: number;
    targetFps: number;
    scale: number;
    quality: number;
    level: number;
    running: boolean;
    w: number;
    h: number;
    dpr: number;
    errors: number;
  }

  interface Debug {
    /** The clock region that must stay calm: the runtime clock, or (for clock 'none' or a hidden
     *  clock) the top-centre spot where Apple's lock-screen clock appears. */
    clockRect(): (Rect & { kind: 'runtime' | 'system'; position: ClockPosition }) | null;
    stats(): Stats;
    /** Errors reported so far (deduplicated). */
    errors(): string[];
    /** Show/hide the runtime clock overlay instantly (luminance measurements). */
    overlay(visible: boolean): void;
  }

  /** Messages posted to the native host via webkit.messageHandlers.livepaper.postMessage(). */
  type HostMessage =
    | { type: 'ready'; mode: Mode; scene: string | null; t: number; errors: number;
        clockRect: ReturnType<Debug['clockRect']>; bench?: number; frames?: number; failed?: boolean }
    | { type: 'error'; message: string }
    | Stats;
}

interface Window {
  LivePaper: typeof LivePaper;
  /** Injected by the host before the runtime runs. */
  LIVEPAPER_CONFIG?: Partial<LivePaper.Config>;
  /** Injected by the compiler: manifest metadata. */
  LIVEPAPER_SCENE?: { id: string; name: string; clock: LivePaper.ClockPosition; runtime: number; line: number };
  /** Injected by the compiler: assets/ as data: URLs. */
  LIVEPAPER_ASSETS?: Record<string, string>;
}
