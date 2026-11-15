/*
 * Liquid Glass — deep colour fields seen through a thick, softly curved pane of glass.
 *
 * Three WebGL passes:
 *   0. Caustics into a tiny framebuffer (about 1/7 of the canvas): a domain-warped cellular net,
 *      so the filaments are curved, and the low resolution plus upscale keeps them soft.
 *   1. A fragment shader paints the whole picture into a small framebuffer (about 1/3.4 of the
 *      canvas in each direction): drifting colour fields blended into one sheet, a slow
 *      refraction wobble, faint partial chromatic arcs, soft specular streaks, and the caustic
 *      texture (tent-filtered) masked by slow noise over the lower half.
 *   2. That texture is stretched over the screen with linear filtering (the upscale is the
 *      softness) and dithered to hide banding in the dark gradients.
 *
 * Every moving quantity is a pure function of lp.t. Anything the shader sees is bounded: blob
 * positions and noise offsets are sines computed in JS (double precision), and the caustic phase
 * is wrapped to [0, 2π) and only used with integer multiples, so the wrap is seamless.
 */
const U = LivePaper.util;

const DOWNSCALE = 3.4;
const CAUSTIC_DOWNSCALE = 7.0;       // at dpr 2; scaled with dpr so the softness is in CSS px
const BLOBS = 7;
const FLOW = 3.0;                    // colour-field speed multiplier
const CAUSTIC_PERIOD = 70;           // seconds for the caustic phase to go round once
const STREAK1_PERIOD = 110;          // seconds for a specular streak to cross the frame
const STREAK2_PERIOD = 150;
const REFL_PERIOD = 80;              // second reflection drifting across the upper part
const GLINT_PERIOD = 55;             // glint sliding along the first streak

// Palette: midnight blue, ink violet, deep teal. The ember is no longer a blob but a ribbon.
const PALETTE = [
  [0.07, 0.16, 0.42],   // midnight blue
  [0.25, 0.10, 0.42],   // ink violet
  [0.03, 0.30, 0.34],   // deep teal
  [0.10, 0.20, 0.50],   // brighter blue
  [0.06, 0.22, 0.40],   // blue-teal (fills the lower right)
  [0.18, 0.09, 0.36],   // violet
  [0.04, 0.24, 0.32],   // teal
];
const EMBER = [0.46, 0.24, 0.13];    // a little desaturated amber
// Base layout per blob: x as a fraction of width, y as a fraction of height, radius (× height),
// motion speeds and phases. Spread over the full width, corners included, so ultra-wides are filled.
const LAYOUT = [
  { x: 0.06, y: 0.74, r: 0.42, sx: 0.013, sy: 0.010, p: 0.3 },
  { x: 0.27, y: 0.48, r: 0.38, sx: 0.009, sy: 0.014, p: 1.7 },
  { x: 0.46, y: 0.80, r: 0.40, sx: 0.011, sy: 0.008, p: 2.9 },
  { x: 0.64, y: 0.55, r: 0.36, sx: 0.015, sy: 0.011, p: 4.2 },
  { x: 0.80, y: 0.95, r: 0.40, sx: 0.010, sy: 0.013, p: 5.1 },
  { x: 0.95, y: 0.64, r: 0.42, sx: 0.012, sy: 0.009, p: 0.9 },
  { x: 0.30, y: 1.02, r: 0.44, sx: 0.008, sy: 0.012, p: 3.6 },
];

const VERT = `
attribute vec2 a_pos;
varying vec2 v_uv;
void main() { v_uv = a_pos * 0.5 + 0.5; gl_Position = vec4(a_pos, 0.0, 1.0); }
`;

const NOISE_GLSL = `
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
vec2 hash2(vec2 p) {
  p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
  return fract(sin(p) * 43758.5453);
}
float vnoise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
             mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}
float fbm(vec2 p) { return 0.65 * vnoise(p) + 0.35 * vnoise(p * 2.03 + 7.1); }
`;

const CAUSTIC_FRAG = `
precision highp float;
varying vec2 v_uv;
uniform float u_aspect;
uniform float u_T;                // caustic phase in [0, 2pi)
uniform vec4 u_cw;                // bounded warp-noise offsets
uniform vec2 u_cd;                // bounded drift of the whole net
${NOISE_GLSL}
// Pool caustics: a cellular net whose coordinates are domain-warped by slow noise, so the cell
// edges become gently curved filaments; brighter knots where three cells meet. Cell points orbit
// with integer multiples of u_T, so the wrap of u_T is seamless.
float caustic(vec2 x) {
  vec2 w = vec2(vnoise(x * 0.23 + u_cw.xy), vnoise(x * 0.23 + u_cw.zw + 4.3)) - 0.5;
  x += 1.8 * w;
  vec2 w2 = vec2(vnoise(x * 0.61 + u_cw.yx + 9.0), vnoise(x * 0.61 + u_cw.wz + 2.0)) - 0.5;
  x += 0.55 * w2;
  float T = u_T;
  vec2 n = floor(x), f = fract(x);
  float f1 = 8.0, f2 = 8.0, f3 = 8.0;
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      vec2 g = vec2(float(i), float(j));
      vec2 h = hash2(n + g);
      vec2 o = 0.5 + 0.34 * vec2(sin(T + 6.2831 * h.x), cos(T + 6.2831 * h.y));
      float dd = length(g + o - f);
      if (dd < f1) { f3 = f2; f2 = f1; f1 = dd; }
      else if (dd < f2) { f3 = f2; f2 = dd; }
      else if (dd < f3) { f3 = dd; }
    }
  }
  float e = (f2 - f1) / 0.075;
  float line = exp(-e * e);
  float k = (f3 - f1) / 0.20;
  float node = exp(-k * k);
  // Filament strength varies a lot along the net: many strands faint, a few bright.
  float vary = smoothstep(0.12, 0.95, vnoise(x * 0.33 + u_cw.zx + 1.7));
  return line * (0.18 + 0.95 * vary) * (0.55 + 2.2 * node) + 0.15 * node * vary;
}
void main() {
  vec2 p = vec2(v_uv.x * u_aspect, 1.0 - v_uv.y);
  // Slightly stretched horizontally, as a pool floor seen at an angle.
  vec2 cp = p * vec2(9.5, 14.0) + u_cd;
  float c = caustic(cp);
  // Soft shimmer: a slow travelling brightness swell over the net.
  c *= 0.80 + 0.55 * vnoise(cp * 0.42 + u_cw.yz * 0.5 + vec2(u_cd.y, -u_cd.x) * 0.6);
  gl_FragColor = vec4(vec3(c * 0.4), 1.0);
}
`;

const SCENE_FRAG = `
precision highp float;
varying vec2 v_uv;
uniform float u_aspect;
uniform vec4 u_blob[${BLOBS}];     // x, y (aspect space, y down), radius, unused
uniform vec3 u_col[${BLOBS}];
uniform vec3 u_ember;
uniform vec4 u_off;               // bounded noise offsets
uniform float u_T;                // caustic phase in [0, 2pi)
uniform vec4 u_rib;               // ember ribbon: centre x, centre y, phase a, phase b (bounded)
uniform float u_ribLen;           // ribbon half length
uniform vec4 u_st;                // streaks: x1, alpha1, x2, alpha2
uniform vec4 u_wob;               // refraction wobble phases (bounded)
uniform sampler2D u_caus;         // low-res caustic texture
uniform vec2 u_ctx;               // one caustic texel in uv
uniform vec4 u_wisp;              // top wisps: bounded warp offsets
uniform vec4 u_wisp2;             // top wisps: scroll x, scroll y, fold phase, unused
uniform vec4 u_rip;               // ripple phases (wrapped), glint phase, ribbon wave phase
uniform vec4 u_mote;              // motes: drift x (wrapped), drift y, phase, unused
uniform vec4 u_rf;                // second reflection x, alpha; streak glint x, unused
${NOISE_GLSL}
float field(vec2 q, out vec3 col) {
  float d = 0.0, cs = 0.0; vec3 c = vec3(0.0);
  for (int i = 0; i < ${BLOBS}; i++) {
    vec2 e = q - u_blob[i].xy;
    float r = u_blob[i].z;
    float w = exp(-dot(e, e) / (r * r));
    d += w; float cw = w * sqrt(w); c += cw * u_col[i]; cs += cw;
  }
  col = c / max(cs, 1e-4);
  return d;
}
float density(vec2 q) {
  float d = 0.0;
  for (int i = 0; i < ${BLOBS}; i++) {
    vec2 e = q - u_blob[i].xy;
    float r = u_blob[i].z;
    d += exp(-dot(e, e) / (r * r));
  }
  return d;
}

// One broad curved streak: an arc of radius R about C, tapering from thin to wide along x.
float streak(vec2 p, vec2 C, float R, float halfLen, float wThin, float wWide, float dir) {
  float along = (p.x - C.x) / halfLen;
  float w = mix(wThin, wWide, smoothstep(-1.0, 1.0, along * dir));
  float dr = (length(p - C) - R) / w;
  return exp(-dr * dr) * exp(-along * along * 1.6);
}

void main() {
  vec2 p = vec2(v_uv.x * u_aspect, 1.0 - v_uv.y);   // y = 0 at the top
  float cx = 0.5 * u_aspect;

  // The pane: a gentle lens curvature plus slow liquid warping.
  vec2 lens = (p - vec2(cx, 0.55));
  vec2 q = p - lens * 0.06 * dot(lens, lens);
  q += 0.10 * (vec2(fbm(p * 1.3 + u_off.xy), fbm(p * 1.3 + u_off.zw + 5.0)) - 0.5);
  // Very gentle large-scale refraction wobble of the thick sheet: boundaries bend slowly.
  q += 0.040 * vec2(sin(p.y * 1.7 + p.x * 0.45 + u_wob.x), sin(p.x * 1.25 - p.y * 0.6 + u_wob.y))
     + 0.022 * vec2(sin(p.x * 0.9 - p.y * 1.1 + u_wob.z), sin(p.y * 1.4 + p.x * 0.7 + u_wob.w));
  // Finer ripples running across the whole pane.
  q += 0.011 * vec2(sin(dot(p, vec2(5.2, 3.1)) - u_rip.x), sin(dot(p, vec2(-3.4, 4.6)) - u_rip.y))
     + 0.006 * vec2(sin(dot(p, vec2(-7.9, 2.3)) - u_rip.y * 2.0), sin(dot(p, vec2(2.7, 8.4)) - u_rip.x * 2.0));

  vec3 fc;
  float d = field(q, fc);
  // Gradient of the density (for the ember's bend and the chromatic rim).
  const float h = 0.012;
  vec2 grad = vec2(density(q + vec2(h, 0.0)) - d, density(q + vec2(0.0, h)) - d) / h;
  float gl = length(grad) + 1e-3;

  // Ember ribbon: a long, thin, flowing band that bends with the fields' flow.
  vec2 rq = q - u_rib.xy + grad * 0.012;
  float u = rq.x;
  float cy = 0.10 * sin(u * 2.3 + u_rib.z) + 0.05 * sin(u * 4.7 - u_rib.w) - 0.22 * u
           + 0.020 * sin(u * 6.5 - u_rip.w) + 0.008 * sin(u * 11.0 + u_rip.w * 2.0);
  float th = 0.022 + 0.026 * (0.5 + 0.5 * sin(u * 2.6 + u_rib.w + 1.0));
  float dy = (rq.y - cy) / th;
  float ul = u / u_ribLen;
  float rib = exp(-dy * dy) * exp(-ul * ul * ul * ul * 1.5);
  float ribHalo = exp(-dy * dy * 0.08) * exp(-ul * ul * 2.0);
  // Flow along the ribbon: soft brighter pulses travelling its length.
  rib *= 0.78 + 0.30 * (0.5 + 0.5 * sin(u * 9.0 - u_rip.w * 2.0));

  vec3 base = mix(vec3(0.012, 0.014, 0.034), fc * 0.55, clamp(d * 0.85, 0.0, 1.0));
  float m = smoothstep(0.25, 1.45, d);
  vec3 glass = fc * (1.15 + 0.6 * smoothstep(0.9, 1.8, d));
  vec3 col = mix(base, glass, m);
  // The ember lives inside the glass: strongest where the glass is, a soft halo around.
  col = mix(col, u_ember * (1.0 + 0.4 * m), clamp(rib * (0.45 + 0.35 * m), 0.0, 1.0));
  col += u_ember * ribHalo * 0.10 * m;

  // Chromatic glass edge: a faint warm/cool fringe along an iso-level of the glass, but only on
  // short arcs. A slow noise mask switches the fringe on along parts of the edge, so each arc
  // fades in and out along its length instead of closing into an outline.
  vec3 rim = vec3(0.0);
  for (int k = 0; k < 2; k++) {
    float level = k == 0 ? 0.85 : 1.40;
    float sd = (d - level) / gl;
    float wa = (sd + 0.011) / 0.011, wb = (sd - 0.011) / 0.011;
    vec2 ao = k == 0 ? u_off.xz : u_off.wy;
    float arc = smoothstep(0.62, 0.86, vnoise(q * 2.6 + ao * 0.35 + float(k) * 13.0));
    float a = k == 0 ? 1.0 : 0.7;
    rim += a * arc * (vec3(0.30, 0.12, 0.05) * exp(-wa * wa) + vec3(0.05, 0.13, 0.32) * exp(-wb * wb));
  }
  // Specular glints sliding slowly along the edge arcs.
  float glide = pow(0.5 + 0.5 * sin(q.x * 6.0 + q.y * 2.5 - u_rip.z), 6.0);
  rim *= smoothstep(0.5, 1.4, gl) * (0.55 + 2.2 * glide);
  col += rim * 0.20 * (0.4 + 0.6 * smoothstep(0.1, 0.7, p.y));

  // Fade the top band, darkest at top centre where the clock sits.
  float topFade = smoothstep(0.02, 0.62, p.y);
  float cdx = (p.x - cx) / max(0.6, u_aspect * 0.22);
  float clockDark = 1.0 - 0.55 * exp(-cdx * cdx * 2.0) * (1.0 - smoothstep(0.0, 0.5, p.y));
  float shade = mix(0.30, 1.0, topFade) * clockDark;
  col *= shade;

  // Top band: faint dark colour wisps far behind the glass, drifting and folding.
  float wmask = 1.0 - smoothstep(0.20, 0.58, p.y);
  if (wmask > 0.0) {
    vec2 wp = p * vec2(1.25, 2.6);
    vec2 wa = vec2(fbm(wp * 0.8 + u_wisp.xy), fbm(wp * 0.8 + u_wisp.zw + 3.1)) - 0.5;
    float n = vnoise(wp * 1.7 + 2.2 * wa + u_wisp2.xy + vec2(0.0, 0.35 * sin(wp.x * 1.3 + u_wisp2.z)));
    float ridge = 1.0 - abs(2.0 * n - 1.0);
    ridge = ridge * ridge * ridge;
    float n2 = vnoise(wp * 1.1 - 1.6 * wa.yx - u_wisp2.yx * 0.7 + 7.0);
    float ridge2 = 1.0 - abs(2.0 * n2 - 1.0);
    ridge2 *= ridge2 * ridge2 * ridge2;
    vec3 wc = mix(vec3(0.16, 0.06, 0.30), vec3(0.03, 0.20, 0.24), smoothstep(0.3, 0.7, wa.x + 0.5));
    float wClock = 1.0 - 0.55 * exp(-cdx * cdx * 2.0);
    col += (wc * ridge * 0.42 + vec3(0.06, 0.08, 0.20) * ridge2 * 0.30) * wmask * wClock;
  }

  // A faint second reflection drifting across the upper part.
  float r2a = u_rf.y * smoothstep(0.10, 0.24, p.y) * (1.0 - smoothstep(0.42, 0.62, p.y));
  if (r2a > 0.001) {
    float rx2 = p.x - u_rf.x + 0.45 * (p.y - 0.35) + 0.08 * sin(p.y * 6.0);
    float rr = exp(-rx2 * rx2 / 0.0040) * 0.7 + exp(-(rx2 - 0.07) * (rx2 - 0.07) / 0.0004) * 0.5;
    col += vec3(0.42, 0.50, 0.75) * rr * r2a * 0.10 * clockDark * clockDark;
  }

  // Tiny warm motes suspended in the glass around the ember ribbon, drifting along it.
  float mdy = (rq.y - cy) / 0.085;
  float mm = exp(-mdy * mdy) * exp(-ul * ul * 1.5);
  if (mm > 0.02) {
    vec2 mg = rq * vec2(15.0, 21.0) + u_mote.xy;
    vec2 mc = floor(mg), mf = fract(mg);
    vec2 mh = hash2(vec2(mod(mc.x, 64.0), mc.y));
    vec2 mj = hash2(vec2(mod(mc.x, 64.0), mc.y) + 31.7);
    vec2 mp = 0.25 + 0.5 * mj + 0.12 * vec2(sin(u_mote.z + 6.2831 * mh.x), cos(2.0 * u_mote.z + 6.2831 * mh.y));
    vec2 md = mf - mp;
    float tw = 0.5 + 0.5 * sin(u_mote.z * 3.0 + 6.2831 * mh.y);
    float mote = exp(-dot(md, md) / 0.008) * step(0.62, mh.x) * (0.3 + 0.7 * tw);
    col += vec3(0.95, 0.55, 0.26) * mote * mm * 0.45;
  }

  // Caustics over the whole lower half: a soft low-res texture (tent-filtered here), refracted
  // with the glass, at low opacity under a slow noise mask that strengthens and fades it in places.
  vec2 cuv = v_uv + (q - p) * vec2(1.0 / u_aspect, -1.0) * 0.6;
  vec2 o = u_ctx * 0.7;
  float cs = 0.625 * (texture2D(u_caus, cuv + o).r + texture2D(u_caus, cuv - o).r
                    + texture2D(u_caus, cuv + vec2(o.x, -o.y)).r + texture2D(u_caus, cuv + vec2(-o.x, o.y)).r);
  float lower = smoothstep(0.40, 0.92, p.y);
  float patch = smoothstep(0.32, 0.80, fbm(p * vec2(0.8, 1.3) + u_off.yx * 0.25 + 3.0));
  float lum = dot(fc, vec3(0.3, 0.5, 0.2));
  col += cs * lower * (0.22 + 0.68 * patch) * (0.08 + 0.80 * lum) * (0.6 + 0.4 * smoothstep(0.3, 1.2, d)) * (fc * 1.3 + 0.14);

  // Specular streaks: window reflections on the curved pane, slowly sliding, fading at path ends.
  float sm = smoothstep(0.30, 0.55, p.y) * clockDark;
  float s1 = streak(p, vec2(u_st.x, 0.56 + 1.7), 1.7, 0.75, 0.010, 0.060, 1.0);
  float s2 = streak(p, vec2(u_st.z, 0.84 + 2.4), 2.4, 0.95, 0.008, 0.045, -1.0);
  float g1 = (p.x - u_rf.z) / 0.16;
  float s = s1 * u_st.y * 0.16 * (0.7 + 1.6 * exp(-g1 * g1)) + s2 * u_st.w * 0.11 * (0.7 + 0.9 * glide);
  col += vec3(0.78, 0.85, 1.0) * s * (0.55 + 0.45 * m) * sm;

  // Soft vignette, lighter along x so ultra-wide ends stay rich.
  vec2 vv = (v_uv - 0.5) * vec2(0.8, 1.2);
  col *= 1.0 - 0.35 * dot(vv, vv);

  gl_FragColor = vec4(col, 1.0);
}
`;

const BLIT_FRAG = `
precision highp float;
varying vec2 v_uv;
uniform sampler2D u_tex;
float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void main() {
  vec3 c = texture2D(u_tex, v_uv).rgb;
  // Gentle tone curve, then a whisper of noise to break up 8-bit banding.
  c = c / (1.0 + 0.25 * c);
  float n = hash(gl_FragCoord.xy) + hash(gl_FragCoord.yx + 17.0) - 1.0;
  c += n * (1.5 / 255.0);
  gl_FragColor = vec4(c, 1.0);
}
`;

let gl = null, quad = null, sceneProg = null, blitProg = null;
let fbo = null, tex = null, fw = 0, fh = 0;
let causProg = null, cfbo = null, ctex = null, cw = 0, ch = 0;
const blobData = new Float32Array(BLOBS * 4);
const colData = new Float32Array(BLOBS * 3);
for (let i = 0; i < BLOBS; i++) colData.set(PALETTE[i], i * 3);

function compile(type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
  return s;
}
function program(fsrc) {
  const p = gl.createProgram();
  gl.attachShader(p, compile(gl.VERTEX_SHADER, VERT));
  gl.attachShader(p, compile(gl.FRAGMENT_SHADER, fsrc));
  gl.bindAttribLocation(p, 0, 'a_pos');
  gl.linkProgram(p);
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
  const u = {};
  const n = gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS);
  for (let i = 0; i < n; i++) {
    const info = gl.getActiveUniform(p, i);
    const name = info.name.replace(/\[0\]$/, '');
    u[name] = gl.getUniformLocation(p, info.name);
  }
  return { p, u };
}

function target(t, f, w, h) {
  gl.bindTexture(gl.TEXTURE_2D, t);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.bindFramebuffer(gl.FRAMEBUFFER, f);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t, 0);
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
}

LivePaper.scene({
  context: 'webgl2',

  setup(lp) {
    gl = lp.gl;
    quad = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    sceneProg = program(SCENE_FRAG);
    blitProg = program(BLIT_FRAG);
    causProg = program(CAUSTIC_FRAG);
    tex = gl.createTexture();
    fbo = gl.createFramebuffer();
    ctex = gl.createTexture();
    cfbo = gl.createFramebuffer();
  },

  resize(lp) {
    fw = Math.max(16, Math.ceil(lp.pw / DOWNSCALE));
    fh = Math.max(16, Math.ceil(lp.ph / DOWNSCALE));
    target(tex, fbo, fw, fh);
    const cds = CAUSTIC_DOWNSCALE * Math.max(0.5, lp.dpr) / 2;
    cw = Math.max(16, Math.ceil(lp.pw / cds));
    ch = Math.max(16, Math.ceil(lp.ph / cds));
    target(ctex, cfbo, cw, ch);
  },

  draw(lp) {
    const t = lp.env.reducedMotion ? lp.t * 0.4 : lp.t;
    const aspect = lp.w / lp.h;

    // Blob positions: slow Lissajous drift around their base layout (aspect space, y down).
    for (let i = 0; i < BLOBS; i++) {
      const L = LAYOUT[i];
      const ax = 0.07 * Math.max(1, aspect * 0.5), sx = L.sx * FLOW, sy = L.sy * FLOW;
      blobData[i * 4] = L.x * aspect + ax * Math.sin(t * sx + L.p) + 0.03 * Math.sin(t * sx * 2.3 + L.p * 1.7);
      blobData[i * 4 + 1] = L.y + 0.07 * Math.sin(t * sy + L.p * 2.1) + 0.02 * Math.cos(t * sy * 2.7 + L.p);
      blobData[i * 4 + 2] = L.r * (0.9 + 0.25 * Math.max(0, aspect - 1.6)) * (0.92 + 0.08 * Math.sin(t * 0.017 + L.p * 3.0));
      blobData[i * 4 + 3] = 0;
    }
    const T = ((t / CAUSTIC_PERIOD) % 1) * U.TAU;

    // Streaks: each crosses the frame once per period, fading in and out at the ends.
    const s1 = (t / STREAK1_PERIOD + 0.35) % 1, s2 = (t / STREAK2_PERIOD + 0.70) % 1;
    const span = aspect + 1.2;
    const x1 = -0.6 + s1 * span, x2 = aspect + 0.6 - s2 * span;
    const a1 = Math.pow(Math.sin(Math.PI * s1), 2), a2 = Math.pow(Math.sin(Math.PI * s2), 2);

    // Ember ribbon placement: lower right of centre, drifting slowly.
    const rx = aspect * (0.70 + 0.06 * Math.sin(t * 0.010 + 1.0));
    const ry = 0.76 + 0.05 * Math.sin(t * 0.013 + 0.4);
    const ribLen = 0.55 * Math.min(1.6, Math.max(1, aspect * 0.6));

    gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);

    // Pass 0: caustics into the tiny framebuffer.
    gl.bindFramebuffer(gl.FRAMEBUFFER, cfbo);
    gl.viewport(0, 0, cw, ch);
    gl.useProgram(causProg.p);
    const cu = causProg.u;
    gl.uniform1f(cu.u_aspect, aspect);
    gl.uniform1f(cu.u_T, T);
    gl.uniform4f(cu.u_cw,
      4.0 * Math.sin(t * 0.021), 4.0 * Math.cos(t * 0.018 + 0.7),
      4.0 * Math.sin(t * 0.016 + 2.2), 4.0 * Math.cos(t * 0.024 + 1.4));
    gl.uniform2f(cu.u_cd,
      9.0 * Math.sin(t * 0.0061 + 0.5) + 4.0 * Math.sin(t * 0.0043 + 2.6),
      7.0 * Math.sin(t * 0.0057 + 2.0) - 1.2 * Math.cos(t * 0.011));
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);

    // Pass 1: the scene into the small framebuffer.
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    gl.viewport(0, 0, fw, fh);
    gl.useProgram(sceneProg.p);
    const u = sceneProg.u;
    gl.uniform1f(u.u_aspect, aspect);
    gl.uniform4fv(u.u_blob, blobData);
    gl.uniform3fv(u.u_col, colData);
    gl.uniform4f(u.u_off,
      3.0 * Math.sin(t * 0.027), 3.0 * Math.cos(t * 0.023),
      3.0 * Math.sin(t * 0.021 + 2.0), 3.0 * Math.cos(t * 0.029 + 1.0));
    gl.uniform1f(u.u_T, T);
    gl.uniform3f(u.u_ember, EMBER[0], EMBER[1], EMBER[2]);
    gl.uniform4f(u.u_rib, rx, ry, t * 0.060 % U.TAU, t * 0.043 % U.TAU);
    gl.uniform4f(u.u_wisp,
      9.0 * Math.sin(t * 0.0013 + 0.4) + 3.0 * Math.sin(t * 0.0041), 7.0 * Math.cos(t * 0.0011 + 1.2),
      8.0 * Math.sin(t * 0.0009 + 2.5), 6.0 * Math.cos(t * 0.0017 + 0.3) + 2.0 * Math.sin(t * 0.0053));
    gl.uniform4f(u.u_wisp2,
      14.0 * Math.sin(t * 0.0008 + 0.9) + 5.0 * Math.sin(t * 0.0023 + 2.0),
      4.0 * Math.sin(t * 0.0019 + 0.2), t * 0.09 % U.TAU, 0);
    gl.uniform4f(u.u_rip, t * 0.24 % U.TAU, t * 0.19 % U.TAU, t * 0.16 % U.TAU, t * 0.32 % U.TAU);
    gl.uniform4f(u.u_mote, -(t * 0.28 % 64), 0.5 * Math.sin(t * 0.07), t * 0.25 % U.TAU, 0);
    const sr = (t / REFL_PERIOD + 0.15) % 1, sg = (t / GLINT_PERIOD + 0.5) % 1;
    gl.uniform4f(u.u_rf, -0.5 + sr * (aspect + 1.0), Math.pow(Math.sin(Math.PI * sr), 2),
      -0.4 + sg * (aspect + 0.8), 0);
    gl.uniform1f(u.u_ribLen, ribLen);
    gl.uniform4f(u.u_st, x1, a1, x2, a2);
    gl.uniform4f(u.u_wob, t * 0.029 % U.TAU, t * 0.023 % U.TAU, t * 0.017 % U.TAU, t * 0.021 % U.TAU);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, ctex);
    gl.uniform1i(u.u_caus, 0);
    gl.uniform2f(u.u_ctx, 1 / cw, 1 / ch);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);

    // Pass 2: stretch over the screen, dither.
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, lp.pw, lp.ph);
    gl.useProgram(blitProg.p);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.uniform1i(blitProg.u.u_tex, 0);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }
});
