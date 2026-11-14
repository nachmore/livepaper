# LivePaper architecture (v0.1)

LivePaper turns animations and videos into your Mac's screen saver — which on macOS 26 is also the
live lock screen — with AI-authored scenes, a lock hotkey that shows the scene instead of the
plain wallpaper, and a one-step install/uninstall.

This document is the contract between components. Keep it current when interfaces change.

---------------------------------------------------------------------------------------------------

## 1. Ground truth about macOS 26 (verified on 26.7, see docs/RESEARCH.md)

* There is no lock-screen-only wallpaper. The animation on the lock screen is the **screen saver**
  ("Idle" slot of `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`).
* Third-party savers are `.saver` bundles run by `legacyScreenSaver` (sandboxed) hosted by
  `WallpaperAgent`. AppKit reports the host window as occluded, so a `WKWebView` never draws unless
  `_setWindowOcclusionDetectionEnabled:` is set to `false`. `stopAnimation` is unreliable; listen
  for `com.apple.screensaver.willstop` and `exit(0)` (non-preview instances only).
* At lock time `loginwindow` raises a shield window (level 2001) and asks **once**
  (`-[LWDefaultScreenLockUI _load]`) whether a saver is running:
  running → the lock UI is drawn **over the live saver**; not running → the desktop picture.
  A saver started after the lock runs invisibly behind the shield. ⌃⌘Q / Apple-menu lock arrive as
  `kAELockScreenEvent` ("direct lock") and never start a saver.
  ⇒ **LivePaper's lock = start the saver first; the saver locks** (requires "Require password
  after screen saver begins: Immediately", which install verifies).
* When the user touches a key/mouse while the saver runs, the lock UI (with Apple's own clock) is
  drawn over the saver. Distributed notifications `com.apple.screenLockUIIsShown` / `com.apple.screenLockUIIsHidden`
  (object = uid string) bracket that (verified). ⇒ scenes must hide their own clock then (no double clock).
* Video-call apps holding display-sleep assertions block every screen saver. Expected.
* Idle time may be MDM-managed (e.g. 900 s); we never touch it.

## 2. Components

```
LivePaper.app                      SwiftUI app: menu-bar extra + main window (library, create, settings)
 ├─ Contents/MacOS/LivePaper       app executable (also hosts the RenderService)
 ├─ Contents/Helpers/LivePaperHelper            login-item agent: hotkeys, lock takeover, lock flow
 ├─ Contents/Helpers/livepaper                  CLI (used by AI agents and power users)
 ├─ Contents/Helpers/LivePaperRenderd           headless render server (used when the app isn't running)
 ├─ Contents/Library/LaunchAgents/com.nachmore.livepaper.helper.plist   (SMAppService)
 └─ Contents/Resources/
      ├─ LivePaper.saver           template saver bundle (installed into ~/Library/Screen Savers)
      ├─ Runtime/                  runtime.js, livepaper.d.ts, SCENE_API.md, templates/
      └─ Scenes/                   built-in example scenes (*.lpscene)
```

| Component | Language | Process | Talks to |
|---|---|---|---|
| App | Swift/SwiftUI | user app (LSUIElement menu-bar app + window) | Core, RenderService (in-process), helper (XPC-free: shared state file + distributed notifications) |
| Saver | Swift | `legacyScreenSaver` (sandboxed!) | reads ONLY its own bundle; distributed notifications |
| Helper | Swift | LaunchAgent (SMAppService, fallback plist) | ScreenSaverEngine, state file, distributed notifications |
| CLI `livepaper` | Swift | short-lived, **no AppKit** | RenderService over a Unix socket |
| RenderService / `LivePaperRenderd` | Swift + WebKit | inside the app, or one headless daemon (`.prohibited`, App-Nap-proof) | serves the socket |
| Runtime | JS | inside WKWebView | host bridge (`webkit.messageHandlers.livepaper`) |

### Focus-stealing rule (hard requirement)
Nothing in LivePaper's tooling may launch GUI-registered processes repeatedly. All rendering
(thumbnails, AI validation stills, benches, power tests) goes through **one** long-lived
RenderService: in the app process when it runs, otherwise a single `LivePaperRenderd` that exits
after 15 idle minutes. The CLI is a plain process and never links AppKit.

## 3. Repository layout

```
Package.swift                     SwiftPM (macOS 14+, Swift 6 toolchain, language mode 5)
Sources/LivePaperCore/            models, paths, settings, library, packaging/publish, harness adapters,
                                  AI sessions, install manager, wallpaper-store access   (Foundation only)
Sources/LivePaperRenderKit/       off-screen WKWebView renderer + socket server (AppKit/WebKit)
Sources/LivePaperApp/             SwiftUI app (+ embeds RenderKit server)
Sources/LivePaperHelper/          helper agent
Sources/LivePaperCLI/             `livepaper` CLI (Foundation only)
Sources/LivePaperRenderd/         headless render daemon (thin wrapper over RenderKit)
Saver/                            LivePaper.saver sources (compiled with swiftc -Xlinker -bundle by the
                                  build script; self-contained, NO dependency on LivePaperCore)
Shared/PlaylistModel.swift        Codable playlist model compiled into BOTH Core and Saver
Runtime/                          runtime.js, livepaper.d.ts, SCENE_API.md, AGENTS.md template, templates/
Scenes/                           built-in example scenes (original work only — repo is public)
scripts/build.sh                  builds everything into build/LivePaper.app (universal, ad-hoc signed)
scripts/dev-install.sh            copies build/LivePaper.app to ~/Applications and runs first-launch install
Tests/                            unit tests (swift test; must not launch GUI processes)
docs/
```

## 4. Data model

### 4.1 Locations
```
~/Library/Application Support/LivePaper/
  Library/<id>.lpscene/           user scenes (created, cloned, AI-generated, imported)
  Workspaces/<session-id>/        AI sessions (kept 7 days for debugging)
  state.json                      app/helper shared state (see 4.4)
  backups/                        wallpaper-store + hotkey/settings backups for uninstall
  render.sock                     RenderService socket
~/Library/Screen Savers/LivePaper.saver        installed saver (published content lives inside)
```

### 4.2 Scene package `<id>.lpscene/` (a directory)
```
scene.json        manifest (schema below)
scene.js          web scenes: the scene code (one file; may be large)
assets/           optional small static assets (images/fonts), offline only
video.mov|mp4     video scenes
poster.jpg        video scenes: poster frame (generated)
thumbnail.jpg     generated by the RenderService (16:10, 640×400)
.check/           last `livepaper check` output (report.json + PNGs); not published
history.jsonl     AI provenance: one line per create/modify {date, harness, model, prompt, summary}
```
`scene.json`:
```json
{
  "schema": 1,
  "id": "aurora-lake",                       // kebab-case, unique in the library
  "name": "Aurora Lake",
  "description": "One sentence.",
  "kind": "web",                             // "web" | "video"
  "runtime": 1,                              // web: runtime API major version
  "clock": { "position": "top" },            // top | bottom-left | bottom-right | none (scene draws its own)
  "video": { "file": "video.mov", "fit": "fill", "loop": true },   // video only
  "author": "you", "created": "2026-11-13T…Z", "updated": "…",
  "parent": "voltron-five-lions",            // when cloned
  "tags": ["space"],
  "performance": { "benchMs": 1.4, "energyMw": 60, "checkedAt": "…" }   // written by check
}
```

### 4.3 Playlist (published into the saver; `Shared/PlaylistModel.swift`)
`LivePaper.saver/Contents/Resources/Playlist/playlist.json`:
```json
{ "schema": 1, "generation": 42,
  "mode": "shuffle",                 // shuffle | sequence | single
  "cycleMinutes": 5,                 // 0 = never change while running
  "showClock": true, "clockStyle": "system",
  "performance": "automatic",        // automatic | best | balanced | battery
  "scenes": [ { "id": "aurora-lake", "kind": "web", "html": "aurora-lake.html", "clock": "top" },
              { "id": "beach", "kind": "video", "video": "beach.mov", "fit": "fill", "clock": "top" } ] }
```
Web scenes are compiled to single self-contained HTML (runtime inlined) at publish time.
Publishing writes `Playlist.new/`, then atomically swaps it in. The saver reads it at start only.
(The saver is sandboxed and can read only its own bundle — that's why content is published *into* it.)

### 4.4 `state.json` (app ⇄ helper)
```json
{ "schema": 1,
  "lock": { "hotkey": {"keyCode": 12, "modifiers": ["control","command"]}, "takeOverSystemLock": false,
            "takeOverTouchIDKey": false },
  "installedAt": "…", "helperVersion": "0.1.0" }
```
The app writes it and posts `com.nachmore.livepaper.stateChanged` (distributed notification); the
helper reloads.

## 5. Runtime v1 (JS) — `Runtime/runtime.js`, typed in `Runtime/livepaper.d.ts`

Evolved from the Voltron prototype runtime. A scene calls `LivePaper.scene({...})` exactly once:

```js
LivePaper.scene({
  context: '2d',                     // '2d' (default) | 'webgl' | 'webgl2'
  clock: 'top',                      // optional override of scene.json
  setup(lp) {}, resize(lp) {}, update(lp, dt) {}, draw(lp) {}
});
```
`lp` (frame API): `canvas, ctx|gl, w, h, dpr, pw, ph, cx, cy, min, max, aspect, t, dt, frame,
rand (seeded), quality (0.5…1, set by the governor), clockRect ({x,y,w,h}|null), env {power:
'ac'|'battery', lowPower, reducedMotion}, cfg`, plus `LivePaper.util` (clamp, lerp, smoothstep,
ease.*, noise1/2, fbm2, mulberry32, rgba/mix, glowSprite/glow, makeStars) and
`LivePaper.clockParts()` for scenes that draw their own clock (`clock: 'none'`; must hide it when
`lp.clockVisible` is false).

Host responsibilities (the scene never implements these):
* canvas/DPR/resize, frame loop with fps cap (30/60), pause on hidden / display sleep / lock UI
  idle, dt clamping, deterministic **still** (`#still=1&t=12`), **bench** (`#bench=120&t=26`),
  **manual** (frame-stepping capture) modes.
* clock overlay (Apple-like style, top-centre by default) and **clock hand-off**: host calls
  `LivePaper.host.lockUI(true|false)`; the runtime fades its clock out/in over 300 ms and sets
  `lp.clockVisible`.
* performance governor: `performance` profile → fps cap + render scale; adaptive step-down when
  measured frame time exceeds budget; exposes `lp.quality` so scenes can thin particles.
* error reporting to the host (`{type:'error'}`), `{type:'ready'}`, `{type:'stats'}`.

Bridge messages host→page: `LivePaper.host.config(obj)`, `.pause()`, `.resume()`, `.lockUI(bool)`,
`.power(obj)`. Page→host via `webkit.messageHandlers.livepaper.postMessage({...})`.

## 6. Saver (`Saver/`)
* Reads `Playlist/playlist.json`; picks a scene (shuffle with no-repeat across sessions and
  displays agreeing per 30 s epoch); crossfades every `cycleMinutes`.
* **Web scenes:** `WKWebView` (`PassiveWebView`: no hit-testing), `loadHTMLString(baseURL: nil)`,
  config injected as a user script, occlusion detection disabled, failure recovery with backoff.
* **Video scenes:** native `AVPlayerLayer` + `AVPlayerLooper` (hardware decode, lowest power),
  native clock overlay (`CATextLayer`s) styled like the runtime clock.
* Clock hand-off: observe `com.apple.screenLockUIIsShown|IsHidden` →
  `lockUI(true/false)` (web) / fade native clock (video).
* Power: pause on `screensDidSleep`, resume on wake; `Automatic` profile = battery saver on battery
  or Low Power Mode; exit host process on `com.apple.screensaver.willstop` (non-preview only).
* Options sheet: summary + "Open LivePaper…" (posts a distributed notification the helper turns into
  launching the app — the sandboxed saver can't launch apps itself).

## 7. Helper (`Sources/LivePaperHelper`)
* Lock hotkey via Carbon `RegisterEventHotKey` (no TCC). Default proposed: ⌃⌘L (configurable).
* Lock flow: if a saver is already running → nothing; else launch
  `/System/Library/CoreServices/ScreenSaverEngine.app` (the saver locks immediately).
  If "Require password … Immediately" is off, fall back to `SACLockScreenImmediate` after start.
* **System-lock takeover (opt-in, needs Accessibility):** active `CGEventTap` swallowing ⌃⌘Q and
  (if feasible) the Touch ID / lock key, replacing them with the LivePaper lock flow. Must fail
  safe: if the tap is disabled by the system, or the helper is stopping, it must never leave the
  user without a working lock gesture. Details pending docs/RESEARCH.md.
* Watches `state.json` / `com.nachmore.livepaper.stateChanged`; relays "open app" requests from
  the saver.
* Idle footprint: zero timers; wakes only on events.

## 8. RenderService (`Sources/LivePaperRenderKit`)
JSON-lines protocol over `~/Library/Application Support/LivePaper/render.sock` (one request per
connection; server serialises work):
```
→ {"op":"still","html":"/abs/scene.html","width":1512,"height":982,"dpr":2,"t":8,"out":"/abs/out.png","clock":true}
→ {"op":"bench","html":…,"width":5120,"height":1440,"dpr":1,"t":14,"frames":120}
→ {"op":"live","html":…,"width":1512,"height":982,"dpr":2,"fps":30,"scale":0.75,"seconds":12,"warmup":3}
→ {"op":"thumbnail","scene":"/abs/x.lpscene","out":"/abs/thumbnail.jpg"}
← {"ok":true,"ready":true,"errors":[],"bench_ms":1.4,"out":"…","fps":30,"cpu_mW":61,…}
```
`devicePixelRatio` is emulated per request; App Nap is disabled while serving (else fps caps at 30).

## 9. CLI `livepaper` (`Sources/LivePaperCLI`, Foundation only)
```
livepaper check <dir.lpscene> [--quick] [--power]   build + validate a scene (used by AI agents)
livepaper still <dir.lpscene> --t 8 --size 1512x982 --dpr 2 --out x.png
livepaper bench <dir.lpscene> [--t T]
livepaper new <id> [--from <scene-id>]              scaffold or clone into the library
livepaper list | publish | doctor
```
`check` = compile scene → stills at 32:9 / 16:10 / 5:4 / thumbnail × sampled times + t=600 →
JS-error check → bench (heaviest sampled phase) at 1512×982@2 and 5120×1440@1 → luminance checks
(overall brightness, clock region calm) → writes `.check/report.json` + PNGs, prints a short
human/AI-readable summary, exit code 0 only if within budgets
(bench ≤ 4 ms at 1512×982@2, no JS errors, clock region mean luminance ≤ threshold, …).

## 10. AI authoring (`LivePaperCore/AI`)
* **Harness adapters** (auto-detected via the user's login shell PATH): Claude Code
  (`claude -p … --output-format stream-json --verbose --permission-mode acceptEdits
  --allowedTools "Read,Write,Edit,Glob,Grep,Bash(livepaper:*)"`), Codex (`codex exec -C <ws>
  -s workspace-write --skip-git-repo-check --json -o last.txt`), Kiro CLI (`kiro-cli chat
  --no-interactive --trust-tools=fs_read,fs_write,execute_bash`), plus a user-defined custom
  command template. Model selection optional per harness.
* **Workspace** per session: `AGENTS.md` + `CLAUDE.md` (identical: scene rules, API, budgets,
  validation loop, "only edit ./scene"), `sdk/` (livepaper.d.ts, SCENE_API.md, 2–3 example
  scenes), `scene/` (template for *create*, a copy of the scene for *modify*), `bin/livepaper`
  (shim to the bundled CLI, put first on PATH).
* **Flow:** create/modify → app writes workspace → runs harness with the user's prompt + fixed
  instructions → streams events into the UI (thinking/tool calls/stills as they appear) → on exit
  the app runs `livepaper check` itself (never trusts the agent's word) → preview → "Add to
  library" / "Replace" (modify keeps history; previous version kept as `history/`).
* Cancellation kills the harness process group. Timeouts configurable (default 20 min).

## 11. App UX (`Sources/LivePaperApp`)
* **Menu-bar extra:** Lock now · current scene · Next scene · Open LivePaper · Pause AI jobs.
* **Main window (NavigationSplitView):**
  * *Library* — grid of live thumbnails (hover = live preview), badges (video/web, energy class).
  * *Scene detail* — full live preview (16:10 and 32:9 toggles), Use as screen saver / add to
    playlist, Clone, Modify with AI…, Export, Delete, performance report.
  * *Create* — two cards: **Video** (drop a file; optional "optimise for battery" HEVC transcode)
    and **Describe it** (prompt box, harness picker, optional reference image) → live session view.
  * *Settings* — Screen saver (playlist mode, cycle, clock), Lock (hotkey recorder, take over ⌃⌘Q,
    Touch ID key), Performance (profile), AI (harness, model, timeout), About / Uninstall.
* **Onboarding** (first launch): explains → installs saver → selects it (wallpaper store, with
  backup; falls back to a one-click guided step) → registers helper → verifies "require password
  immediately" → optional Accessibility for lock takeover → done. Every step idempotent.
* **Uninstall** (Settings › About): unregisters helper, removes the saver, restores the previous
  screen-saver choice and any changed settings from `backups/`, optionally deletes the library,
  then moves the app to the Trash.

## 12. Performance & battery policy
* Budgets enforced by `livepaper check` (bench + optional live energy), shown in the UI.
* Automatic profile: 60 fps full-res on AC; 30 fps @ 75 % on battery / Low Power Mode.
* Pause when displays sleep; exit the saver host on willstop; video scenes use hardware decode.
* Governor steps render scale down (to 0.6) if frame time stays over budget for 2 s.

## 13. Milestones
1. Core + runtime + RenderService + CLI `check` (AI-ready framework).
2. Saver (web + video + clock hand-off) and publish pipeline.
3. Helper (hotkey + lock flow; takeover behind a flag).
4. App: library, create (video, AI), clone, modify, settings, onboarding, uninstall.
5. Built-in example scenes generated through LivePaper's own AI pipeline.
