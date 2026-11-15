# LivePaper architecture (v0.1)

LivePaper turns animations and videos into your Mac's screen saver — which on macOS 26 is also the
live lock screen — with AI-authored scenes, lock keys that show the scene instead of the plain
wallpaper, and a one-step install/uninstall.

This document is the contract between components. Keep it current when interfaces change.

---------------------------------------------------------------------------------------------------

## 1. Ground truth about macOS 26 (verified on 26.7)

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
  `kAELockScreenEvent` ("direct lock") and never start a saver by default.
  ⇒ **LivePaper's lock = start the saver first; the saver locks** (requires "Require password
  after screen saver begins: Immediately", which setup checks).
* **`defaults write com.apple.loginwindow immediateLockLaunchesScreenSaver -bool true`** (user
  domain, default off, not MDM-managed here) makes ⌃⌘Q, Apple-menu *Lock Screen* and the Touch ID /
  lock key start the saver first (`screenSaverStartNow` → lock → "Screen saver IS running").
  **Verified live on 26.7, takes effect without logout, password prompt still required.** Not
  covered: lid close / display-sleep locks (still the wallpaper). Idle-timeout path unchanged.
  ⇒ This is LivePaper's "lock keys show the scene" toggle: no Accessibility/Input Monitoring needed.
* **Prewarm:** after every unlock WallpaperAgent spawns a hidden, never-presented saver instance.
  With WebKit occlusion detection disabled it would animate forever (~45 % of a core). Non-preview
  instances must render nothing until `CGSSessionScreenIsLocked` is true / `com.apple.screenIsLocked`
  arrives, and pause on `com.apple.screenIsUnlocked`.
* When the user touches a key/mouse while the saver runs, the lock UI (with Apple's own clock) is
  drawn over the saver. Distributed notifications `com.apple.screenLockUIIsShown` / `com.apple.screenLockUIIsHidden`
  (object = uid string) bracket that (verified). ⇒ scenes must hide their own clock then (no double clock).
* AppKit suspends distributed-notification delivery for inactive apps. A saver host, the helper
  and a menu-bar app are (almost) never active, so LivePaper observers use
  `suspensionBehavior: .deliverImmediately` and posters pass `deliverImmediately: true`.
* Video-call apps holding display-sleep assertions block every screen saver. Expected.
* Idle time may be MDM-managed (e.g. 900 s); we never touch it.

## 2. Components

```
LivePaper.app                      SwiftUI app: menu-bar extra + main window (library, create, settings)
 ├─ Contents/MacOS/LivePaper       app executable (SwiftPM product LivePaperApp, renamed by scripts/build.sh;
 │                                 also hosts the RenderService)
 ├─ Contents/Helpers/LivePaperHelper            login-item agent: lock shortcut, Lock Now, open-app relay
 ├─ Contents/Helpers/livepaper                  CLI (used by AI agents and power users)
 ├─ Contents/Helpers/LivePaperRenderd           headless render server (used when the app isn't running)
 ├─ Contents/Library/LaunchAgents/com.nachmore.livepaper.helper.plist   (SMAppService)
 └─ Contents/Resources/
      ├─ LivePaper.saver           template saver bundle (installed into ~/Library/Screen Savers)
      ├─ Runtime/                  runtime.js, livepaper.d.ts, SCENE_API.md, AGENTS.md, templates/
      └─ Scenes/                   built-in example scenes (*.lpscene)
```
The app executable is renamed because `LivePaper` and `livepaper` clash on case-insensitive disks
when both sit in one build directory.

| Component | Language | Process | Talks to |
|---|---|---|---|
| App | Swift/SwiftUI | user app (LSUIElement menu-bar app + window) | Core, RenderService (in-process), helper (no XPC: state.json + distributed notifications) |
| Saver | Swift | `legacyScreenSaver` (sandboxed!) | reads ONLY its own bundle; distributed notifications |
| Helper | Swift | LaunchAgent (SMAppService, fallback plist) | ScreenSaverEngine, state.json, distributed notifications |
| CLI `livepaper` | Swift | short-lived, **no AppKit** | RenderService over a Unix socket |
| RenderService / `LivePaperRenderd` | Swift + WebKit | inside the app, or one headless daemon (`.prohibited`, App-Nap-proof) | serves the socket |
| Runtime | JS | inside WKWebView | host bridge (`webkit.messageHandlers.livepaper`) |

### Focus-stealing rule (hard requirement)
Nothing in LivePaper's tooling may launch GUI-registered processes repeatedly. All rendering
(thumbnails, AI validation stills, benches, power tests) goes through **one** long-lived
RenderService: in the app process when it runs, otherwise a single `LivePaperRenderd` that exits
after 15 idle minutes. The CLI is a plain process and never links AppKit. Developer tools that must
show UI (the app's `--snapshot` mode, `scripts/dev/saverhost*.swift`) use the `.prohibited`
activation policy, off-screen windows and one launch per run.

## 3. Repository layout

```
Package.swift                     SwiftPM (tools 6.0, Swift 6 toolchain, language mode 5, macOS 14+);
                                  the Command Line Tools are enough, Xcode works too
Sources/LivePaperCore/            models, paths, the playlist contract, library, compile/check, publish,
                                  AI sessions + harness adapters, install manager, wallpaper-store access.
                                  Foundation plus AVFoundation / CoreGraphics / ImageIO /
                                  UniformTypeIdentifiers (video import) and ServiceManagement (helper
                                  login item) — never AppKit or WebKit: the CLI links it.
  Services/ServiceProtocols.swift the service API the app and CLI program against (+ LivePaperServices.live())
  Playlist/PlaylistModel.swift    Codable playlist + notification names, compiled into BOTH Core and the
                                  saver (keep it Foundation-only and self-contained)
Sources/LivePaperRenderKit/       off-screen WKWebView renderer + socket server (AppKit/WebKit)
Sources/LivePaperApp/             SwiftUI app (+ embeds the RenderKit server)
  Entry/ Model/ Logic/ Mocks/     app entry, AppModel, Foundation-only logic, mock services
  Views/ Snapshot/                SwiftUI views; `--snapshot` harness (debug builds)
Sources/LivePaperHelper/          helper agent
Sources/LivePaperCLI/             `livepaper` CLI (Foundation + Core only)
Sources/LivePaperRenderd/         headless render daemon (thin wrapper over RenderKit)
Sources/LivePaperSelfTest/        `swift run LivePaperSelfTest [filter]` — a tiny custom test runner (no
                                  XCTest). AppLogic/ and SaverLogic.swift are symlinks that compile the
                                  app's Logic/Model/Mocks files and the saver's pure logic into the tests.
Saver/                            LivePaper.saver sources (compiled with swiftc -Xlinker -bundle by
                                  scripts/build-saver.sh; self-contained, no dependency on Core except
                                  PlaylistModel.swift). See Saver/README.md.
Runtime/                          runtime.js, livepaper.d.ts, SCENE_API.md, AGENTS.md (agent guide), templates/
Scenes/                           built-in example scenes (original work only — the repo is public)
App/                              Info.plist (document type, LSUIElement), icon sources
scripts/build.sh                  builds everything into build/LivePaper.app (universal, ad-hoc signed)
scripts/build-saver.sh            builds build/LivePaper.saver
scripts/dev/                      focus-safe dev hosts (saverhost*.swift), test playlists/videos
docs/
```
Tests never launch GUI processes or touch real user state: they point `LIVEPAPER_HOME`,
`LIVEPAPER_SAVERS_DIR`, `LIVEPAPER_LAUNCH_AGENTS_DIR` and `LIVEPAPER_WALLPAPER_STORE` at temp
directories and inject fakes for commands, preferences and login items.

## 4. Data model

### 4.1 Locations
```
~/Library/Application Support/LivePaper/          (LIVEPAPER_HOME)
  Library/<id>.lpscene/           user scenes (created, cloned, AI-generated, imported)
  Workspaces/<session-id>/        AI sessions (§10), kept 7 days for debugging, then pruned
    AGENTS.md, CLAUDE.md          identical agent guide (Runtime/AGENTS.md + this session's task)
    TASK.md                       the user's request (reaches the harness only through this file)
    sdk/  scene/  bin/livepaper   API docs + examples, the candidate package, CLI shim
    .livepaper/                   stdout.log, stderr.log, last-message.txt (codex); agents keep out
  state.json                      app → helper shared state (§4.4)
  playlist-settings.json          PlaylistSettings: what to publish (mode, cycle, clock, profile, scenes)
  ai-settings.json                AISettings: Settings › AI (shared by the app, the CLI and sessions)
  publish.lock                    flock: one publish / saver install at a time (app and CLI may race)
  backups/
    wallpaper-store-Index.plist   raw copy of the wallpaper store before LivePaper's first selection
                                  (forensics only — NEVER restored wholesale; WallpaperAgent rewrites the
                                  file constantly and a stale copy would clobber newer Desktop choices)
    wallpaper-selection.json      per-slot manifest of the Idle slots LivePaper changed (original provider +
                                  configuration); uninstall restores only slots that still point at LivePaper
  wallpaper-store.lock            flock: one wallpaper-store apply at a time
    changed-defaults.json         every system preference LivePaper changed, with its previous value
                                  (including the lock keys, §7) — restored by uninstall
  render.sock                     RenderService socket (§8)
  render-server.lock              flock held by whichever process serves the socket
  renderd-launch.lock             flock clients hold while deciding whether to start LivePaperRenderd
  renderd.pid                     informational (`livepaper server status`)
  Logs/renderd.log                output of a LivePaperRenderd started by a client
~/Library/Screen Savers/LivePaper.saver           installed saver, published content inside (LIVEPAPER_SAVERS_DIR)
~/Library/LaunchAgents/com.nachmore.livepaper.helper.plist    only for the unbundled fallback (LIVEPAPER_LAUNCH_AGENTS_DIR)
~/Library/Application Support/com.apple.wallpaper/Store/Index.plist   read via WallpaperStore (LIVEPAPER_WALLPAPER_STORE)
$TMPDIR/LivePaperPreviews/                        compiled preview HTML (the app clears it at launch)
```
Uninstall keeping the scenes keeps `Library/`, `state.json`, `playlist-settings.json` and
`ai-settings.json`; everything else in the support directory goes (backups only after a successful
restore). Other overrides: `LIVEPAPER_RESOURCES` (app resources), `LIVEPAPER_SOURCE_ROOT`
(`swift run` from the source tree), `LIVEPAPER_CLI` (the CLI the workspace shim execs).
The saver keeps its own session bookkeeping in ScreenSaverDefaults (inside its sandbox).

### 4.2 Scene package `<id>.lpscene/` (a directory; a document type, §11)
```
scene.json        manifest (schema below)
scene.js          web scenes: the scene code (one classic script)
assets/           optional small static assets (images/fonts/text), inlined at compile time, offline only
video.mov|mp4|m4v video scenes (other containers are remuxed to .mov on import)
thumbnail.jpg     generated by the RenderService (16:10, 640×400)
.check/           last `livepaper check` output (report.json, scene.html, PNGs); never published
history.jsonl     provenance: one line per create/clone/modify/replace {date, action, harness, model, prompt, summary}
history/<stamp>/  previous versions kept by "Replace" (AI modify accept)
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
  "parent": "aurora-lake",                   // when cloned: the id it was cloned from
  "tags": ["night"],
  "performance": { "benchMs": 1.4, "energyMw": 60, "checkedAt": "…" }   // written by check
}
```

### 4.3 Playlist (published into the saver; `Sources/LivePaperCore/Playlist/PlaylistModel.swift`)
`LivePaper.saver/Contents/Resources/Playlist/playlist.json`:
```json
{ "schema": 1, "generation": 42,
  "mode": "shuffle",                 // shuffle | sequence | single
  "cycleMinutes": 5,                 // 0 = never change while running
  "showClock": true,
  "performance": "automatic",        // automatic | best | balanced | battery
  "scenes": [ { "id": "aurora-lake", "name": "Aurora Lake", "kind": "web", "file": "aurora-lake.html", "clock": "top" },
              { "id": "beach", "name": "Beach", "kind": "video", "file": "beach.mov", "fit": "fill", "clock": "top" } ] }
```
Web scenes are compiled to single self-contained HTML (runtime and assets inlined) at publish time.
Supported files: `html`/`htm` for web scenes, `mov`/`mp4`/`m4v` for video
(`LPPlaylistEntry.webExtensions` / `.videoExtensions`; the saver skips anything else, so publish
reports such scenes as skipped). Publishing writes `Playlist.new/`, then atomically swaps it in
(under `publish.lock`) and posts `com.nachmore.livepaper.published`. Scenes that fail to compile or
have no playable video are left out and reported (`PublishResult.skipped`); if none is publishable
the previous playlist stays. The saver reads the playlist at start only (previews also on
`published`). (The saver is sandboxed and can read only its own bundle — that's why content is
published *into* it.)

### 4.4 `state.json` (app → helper)
```json
{ "schema": 1,
  "lock": { "hotkey": {"keyCode": 37, "modifiers": ["control","command"]}, "lockKeysShowScene": true },
  "installedAt": "…", "appVersion": "0.1.0" }
```
* `hotkey`: LivePaper's own lock shortcut (absent = none). Default ⌃⌘L.
* `lockKeysShowScene`: mirror of `immediateLockLaunchesScreenSaver` (§7), written by the app after it
  changes the preference through `InstallServicing.setLockKeysShowScene`. Informational: loginwindow
  acts on the system preference by itself. Files from before the single toggle carry
  `takeOverSystemLock` / `takeOverLockKey`; they decode as `lockKeysShowScene = either`.

The app writes it and posts `com.nachmore.livepaper.stateChanged` (distributed); the helper reloads.

### 4.5 Distributed notifications (`LPNotification`)
| Name (`com.nachmore.livepaper.*`) | From → to | userInfo |
|---|---|---|
| `stateChanged` | app → helper | — |
| `lockNow` | app → helper ("Lock Now") | `requestID` |
| `lockNowAccepted` | helper → app (the lock flow runs) | the request's `requestID` |
| `hotkeyRecording` | app → helper (suspend the shortcut while re-recording it) | `active`: Bool |
| `openApp` | saver → helper (open the app; the sandboxed saver can't) | none (sandboxed posters may not attach any) |
| `published` | app/CLI → saver previews (reload) | — |

## 5. Runtime v1 (JS) — `Runtime/runtime.js`, typed in `Runtime/livepaper.d.ts`

A scene calls `LivePaper.scene({...})` exactly once (full guide: `Runtime/SCENE_API.md`):

```js
LivePaper.scene({
  context: '2d',                     // '2d' (default) | 'webgl' | 'webgl2'
  clock: 'top',                      // optional override of scene.json
  setup(lp) {}, resize(lp) {}, update(lp, dt) {}, draw(lp) {}
});
```
`lp` (frame API): `canvas, ctx|gl, context, w, h, dpr, pw, ph, cx, cy, min, max, aspect, scale
(render scale from profile + governor, already in dpr), t, dt, frame, mode ('live'|'still'|'bench'|
'manual'), rand (seeded), quality (0.5…1, set by the governor), clockRect ({x,y,w,h}|null),
clockVisible, clockAlpha (eased 0–1 opacity of any clock), env {power: 'ac'|'battery', lowPower,
reducedMotion, preview}, cfg, util`. `LivePaper.util` (clamp, lerp, smoothstep, ease.*,
noise1/2, fbm2, mulberry32, rgba/mix, glowSprite/glow, makeStars), `LivePaper.clockParts()` for
scenes that draw their own clock (`clock: 'none'`; must fade it by `lp.clockAlpha` and hide it when
`lp.clockVisible` is false), and assets from `assets/`: `LivePaper.image(name)` (decoded
`HTMLImageElement`), `LivePaper.text(name)` (file text), `LivePaper.asset(name)` (`data:` URL);
fonts register under their file name.

Host responsibilities (the scene never implements these):
* canvas/DPR/resize, frame loop with fps cap (30/60), pause on hidden / display sleep / lock UI
  idle, dt clamping, deterministic **still** (`#still=1&t=12`), **bench** (`#bench=120&t=26`),
  **manual** (frame-stepping capture) modes.
* clock overlay (Apple-like style, top-centre by default) and **clock hand-off**: host calls
  `LivePaper.host.lockUI(true|false)`; the runtime fades its clock out/in over 300 ms and updates
  `lp.clockVisible` / `lp.clockAlpha`.
* performance governor: `performance` profile → fps cap + render scale; adaptive step-down when
  measured frame time exceeds budget; exposes `lp.quality` so scenes can thin particles.
* error reporting to the host (`{type:'error'}`), `{type:'ready'}`, `{type:'stats'}`.

Configuration, lowest to highest precedence: defaults < `window.LIVEPAPER_CONFIG` (user script at
document start) < URL hash (development) < `LivePaper.host.config({...})`. Keys (runtime.js `TYPES`;
unknown keys are ignored, so hosts must use these): `still, t, bench, manual, clock, clockPosition,
hour12, clockTime, fps, scale, dprMax, performance, power, lowPower, reducedMotion, preview, lockUI,
seed, debug, governor, budgetMs, statsEvery`. `lockUI: true` starts a scene with its clock hidden
(the saver sets it when it creates a scene while the lock UI is up); `preview: true` marks small
previews (the app's library and detail previews) and becomes `lp.env.preview`.

Bridge messages host→page: `LivePaper.host.config(obj)`, `.pause()`, `.resume()`, `.lockUI(bool)`,
`.power(obj)`, `.advance(dt)` (manual mode). Page→host via `webkit.messageHandlers.livepaper.postMessage({...})`.

## 6. Saver (`Saver/`, details in `Saver/README.md`)
* **Prewarm gate:** a non-preview instance loads nothing until the session is locked
  (`CGSSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`, else wait for
  `com.apple.screenIsLocked`); `com.apple.screenIsUnlocked` pauses everything. Previews
  (`isPreview || width < 500` — `isPreview` is unreliable in the macOS 26 host) render at once.
* Reads `Playlist/playlist.json`; keeps entries whose file is a plain name with a supported
  extension (§4.3) that exists; picks a scene (shuffle with no-repeat across sessions and displays
  agreeing per 30 s epoch); crossfades every `cycleMinutes`; fallback scene when nothing plays.
* **Web scenes:** `WKWebView` (`PassiveWebView`: no hit-testing), `loadHTMLString(baseURL: nil)`,
  non-persistent data store, `window.LIVEPAPER_CONFIG = {clock, clockPosition, fps, scale, seed,
  power, lowPower, lockUI}` injected at document start, occlusion detection disabled, failure
  recovery with backoff.
* **Video scenes:** native `AVPlayerLayer` + `AVPlayerLooper` (hardware decode, lowest power),
  native clock overlay (`CATextLayer`s) styled like the runtime clock.
* **Clock hand-off:** observe `com.apple.screenLockUIIsShown|IsHidden` →
  `lockUI(true/false)` (web) / fade native clock (video); state that changed while a page loads is
  re-applied on `ready`.
* **Immediate delivery:** every distributed observer uses `.deliverImmediately` (§1).
* Power: pause on `screensDidSleep`, resume on wake; `Automatic` profile = battery saver on battery
  or Low Power Mode; exit host process 0.5 s after `com.apple.screensaver.willstop` (non-preview only).
* Options sheet: summary + "Open LivePaper…" (posts `openApp`, which the helper turns into launching
  the app — the sandboxed saver can't launch apps itself).
* **Publishing after signing:** publish rewrites `Contents/Resources/Playlist/` of the installed,
  already-signed bundle. That breaks the resource seal (`codesign --verify` fails) but the bundle
  still loads and plays the new content: the load-time signature covers the executable, which
  publishing never touches (verified with `scripts/dev/saverhost-lp.swift`). So: resources may
  change after signing; never distribute a bundle modified that way; don't "fix" the seal by
  re-signing an installed Developer-ID copy ad hoc (that replaces the Developer ID signature) —
  simply don't verify the seal of the installed copy.

## 7. Helper (`Sources/LivePaperHelper`)
* **Lock keys (no permissions):** `InstallServicing.setLockKeysShowScene(_:)` sets
  `com.apple.loginwindow immediateLockLaunchesScreenSaver`, recording the value from before
  LivePaper's first change in `backups/changed-defaults.json`; returning to that value restores it
  and drops the backup, and asking for the current value changes nothing. Uninstall restores it
  (its own step, then every other changed preference). ⌃⌘Q, Apple-menu
  Lock Screen and the Touch ID / lock key then show the scene. Fails safe: if the saver can't run,
  loginwindow still locks. This is the app's job, not the helper's; an event-tap route
  (Accessibility) is NOT needed and not planned.
* **Optional extra shortcut:** Carbon `RegisterEventHotKey` (no TCC) for `state.lock.hotkey`
  (default ⌃⌘L). Suspended while `hotkeyRecording` says `active: true`.
* **Lock flow** (shortcut or `lockNow`): if a saver is already running → nothing; else launch
  `/System/Library/CoreServices/ScreenSaverEngine.app` (the saver locks immediately).
  If "Require password … Immediately" is off, fall back to `SACLockScreenImmediate` after start.
* **Lock Now:** the app posts `lockNow` with a `requestID`; the helper answers `lockNowAccepted`
  with the same `requestID` (deliverImmediately) and runs the lock flow. Without an answer within
  1 s the app launches ScreenSaverEngine itself (explicit user action only).
* Watches `state.json` / `stateChanged`; relays `openApp` from the saver.
* Idle footprint: zero timers; wakes only on events.

## 8. RenderService (`Sources/LivePaperRenderKit`)
JSON-lines protocol over `~/Library/Application Support/LivePaper/render.sock` (one request per
connection; the server renders strictly one request at a time on the main thread):
```
→ {"op":"still","html":"/abs/scene.html","width":1512,"height":982,"dpr":2,"t":8,"out":"/abs/out.png","clock":true}
→ {"op":"bench","html":…,"width":5120,"height":1440,"dpr":1,"t":14,"frames":120}
→ {"op":"live","html":…,"width":1512,"height":982,"dpr":2,"fps":30,"scale":0.75,"seconds":12,"warmup":3}
→ {"op":"thumbnail","scene":"/abs/x.lpscene","out":"/abs/thumbnail.jpg"}
→ {"op":"ping"}  |  {"op":"shutdown"}                     (answered without queuing)
← {"ok":true,"ready":true,"errors":[],"bench_ms":1.4,"out":"…","fps":30,"cpu_mW":61,"mean_luma":…,"clock_luma":…}
```
* **Who serves:** the process holding `render-server.lock` (flock; dies with its process). The app
  starts an embedded server at launch; if `LivePaperRenderd` serves, the app asks it to `shutdown`
  and takes over when it exits. Clients start at most one daemon (`renderd-launch.lock`) and retry
  requests refused during a hand-over.
* `shutdown` drains the queue, then stops (requests arriving meanwhile are refused with a note).
  **The app's embedded server refuses `shutdown`** ("quit the app to stop it").
* `LivePaperRenderd --replace` takes over from a running server (e.g. after installing a new
  version); otherwise it refuses to start while another server serves. It exits after 15 idle
  minutes, on SIGTERM/SIGINT, or after `shutdown`.
* Pages load with a real origin, `livepaper-render://scene/`, served by a scheme handler that refuses
  every request: WebKit hides error details from opaque-origin scripts ("Script error."), and check
  must report syntax errors with message and line. Nothing can load through it, so scenes stay as
  offline as in the saver.
* `devicePixelRatio` is emulated per request; App Nap is disabled while serving (else fps caps at 30).

## 9. CLI `livepaper` (`Sources/LivePaperCLI`, Foundation + Core only)
```
livepaper check <dir.lpscene> [--quick] [--power] [--json]   build + validate a scene (used by AI agents)
livepaper still <dir.lpscene> [--t 8] [--size 1512x982] [--dpr 2] [--out x.png] [--no-clock] [--json]
livepaper bench <dir.lpscene> [--t 0] [--size 1512x982] [--dpr 2] [--frames 120] [--json]
livepaper live  <dir.lpscene> [--size …] [--dpr 2] [--fps 30] [--scale 0.75] [--seconds 10] [--json]   fps, CPU %, mW
livepaper compile <dir.lpscene> [--out file.html|-]
livepaper server status|start|stop
livepaper new <id> [--from <scene-id>] | list | publish | doctor                (planned)
```
`check` = compile → stills at 1512×982@2 for t = 0, 4, 12, 30, 90, 240, 600, plus 32:9 (2560×720
@1, t = 12/90/600), 5:4 (1280×1024 @1, t = 12/90) and thumbnail size (320×200 @2, t = 12) →
JS-error check → short probe benches (30 frames) at every sampled time but the last, to find the
heaviest phase → full benches (120 frames) at that time at 1512×982@2 and 5120×1440@1 →
luminance checks → optional live energy run (`--power`, battery profile: 30 fps, 75 %) → writes
`.check/report.json` + PNGs, prints a short summary for humans and agents; exit 0 only if it passes.
`--quick`: three stills + one 32:9, one 60-frame bench at 1512×982@2, no ultra-wide bench.

Budgets (`CheckBudgets`):

| Check | Problem (fails) | Warning |
|---|---|---|
| JS errors | any | |
| Frame time at 1512×982@2 (heaviest phase) | > 4 ms | > 75 % of budget |
| Frame time at 5120×1440@1 | > 6 ms | > 75 % of budget |
| Mean frame luma (Rec. 709, 0–255) | > 165 | |
| Mean luma behind the clock | > 120 | spread across times > 50 (busy) |
| Black frames | every still < 2, or black at t = 600 when earlier stills aren't | |
| CPU energy, battery profile (`--power`) | > 300 mW | > 150 mW, or live fps < 85 % of 30 |

`report.json` `benchMs` keys are `"<w>x<h>@<dpr> t=<t>"`; probe benches carry the suffix `" probe"`
(`"1512x982@2 t=30 probe"`) so consumers can tell them from the full benches.

## 10. AI authoring (`LivePaperCore/AI`)
* **Harnesses** (auto-detected on the user's login-shell PATH plus common install directories;
  each probed with `--version`). Every harness runs in the workspace (cwd), in its own process
  group, with `bin/` first on PATH; the prompt only ever travels in TASK.md. `[--model M]` comes from
  the session or `AISettings.models[kind]`; `<extra>` from `AISettings.extraArguments[kind]`.
  * Claude Code: `claude -p --output-format stream-json --verbose --permission-mode acceptEdits
    --allowedTools "Read,Write,Edit,Glob,Grep,Bash(livepaper:*)" [--model M] <extra>`, TASK.md on stdin.
  * Codex: `codex exec -C <ws> -s workspace-write --skip-git-repo-check --json -o
    <ws>/.livepaper/last-message.txt -c sandbox_workspace_write.network_access=true [-m M] <extra> -`,
    TASK.md on stdin (`network_access` because workspace-write blocks the Unix socket `livepaper check` needs).
  * Kiro CLI: `kiro-cli chat --no-interactive --trust-tools=fs_read,fs_write,execute_bash
    --output-format stream-json [--model M] <extra> "<bootstrap>"` (`--wrap never` instead of
    stream-json for versions whose `chat --help` doesn't offer it).
  * Custom: a template such as `mytool --prompt-file {prompt_file} --cwd {workspace}`; placeholders
    `{prompt_file}` `{workspace}` `{scene}` `{model}` `{instructions}` (a lone `{model}` token is dropped
    without a model); POSIX-style quoting, no shell; TASK.md also on stdin. Validated by
    `CustomAdapter.templateProblem`.
  * `<bootstrap>` / `{instructions}`: "Read TASK.md in the current directory and carry out the task it
    describes, following AGENTS.md."
* **Workspace** per session (§4.1): `AGENTS.md` + `CLAUDE.md` (identical: scene rules, API, budgets,
  validation loop, "only edit ./scene"), `TASK.md`, `sdk/` (livepaper.d.ts, SCENE_API.md, templates,
  3 example scenes), `scene/` (template for *create*, a copy of the scene for *modify*), `bin/livepaper`
  (shim to the bundled CLI), `.livepaper/` (logs).
* **Flow:** create/modify → workspace → harness → stdout parsed into events (text, tool calls) and
  `scene/.check/*.png` reported as stills while the agent iterates → on exit LivePaper runs the
  check itself (never trusts the agent's word) → preview → "Add to library" / "Replace" (modify keeps
  history; previous version kept in `history/`).
* **A session fails when:** the harness can't be found or the template is invalid; it is cancelled
  ("Cancelled."); it runs past the timeout (`AISettings.timeoutMinutes`, default 20, clamped
  1–240; the process group is killed); it exits non-zero (message = exit status/signal + last stderr
  lines or its final message); it exits 0 without changing `scene/scene.js`; the check can't run; or
  the check doesn't pass (first three problems quoted). Only a passing check yields `.finished`.
* Settings (`AISettings` in `ai-settings.json`, via `AIServicing.loadSettings/saveSettings`):
  preferred harness, per-harness model, extra arguments, custom template, timeout.

## 11. App UX (`Sources/LivePaperApp`)
* **Menu-bar extra:** Lock Now (shows the extra shortcut) · what the screen saver plays · Next
  Scene · AI jobs (open / stop all) · Open LivePaper · Settings… · Quit.
  Lock Now posts `lockNow` and falls back to ScreenSaverEngine after 1 s (§7).
* **Main window (NavigationSplitView):**
  * *Library* — grid of live thumbnails (hover = live preview), badges (video/web/AI, energy class).
  * *Scene detail* — full live preview (16:10 and 32:9), Use as Screen Saver / Add to Playlist,
    Clone, Modify with AI…, Export, Delete, check report and provenance.
  * *Create* — **Video** (drop a file; optional "optimise for battery" HEVC transcode) and
    **Describe it** (prompt, agent + model picker) → live session view.
  * *Screen Saver* — the playlist draft (scenes, order, cycle, clock, profile) → Save & Publish; a
    publish that left scenes out lists them with the reason (and a banner says so).
* *Settings* — Screen Saver (status, setup), Lock (**one** toggle "Use ⌃⌘Q and the lock key for
  LivePaper lock" + the optional extra shortcut recorder + helper status), Performance (profile),
  AI (default agent, per-agent model, time limit, custom command), About (+ Uninstall).
* **Onboarding** (first launch; re-runnable, every step idempotent and showing live status), 4
  steps: Welcome → Screen saver (install, select — with backup, or a guided one-click step in
  System Settings) → Locking (lock keys toggle, "require password immediately", helper login item,
  including "waiting for approval in Login Items") → First scene (pick what plays).
* **Uninstall** (Settings › About): shows exactly what will happen, then runs
  `InstallServicing.performUninstall` and shows the step log (done / nothing to do / failed with the
  reason). Steps: unregister the helper, restore the previous screen-saver choice, restore the lock
  keys, restore other changed preferences, remove the saver, delete LivePaper's data (optionally the
  library). Failures can be retried (finished steps are skipped); on success the app moves itself
  to the Trash and quits.
* **Document type:** `.lpscene` (`com.nachmore.livepaper.scene`, a package conforming to
  `com.apple.package`); opening one imports it into the library.
* **Developer modes:** `LIVEPAPER_MOCK=1` runs on sample data in a temp directory with mock
  services (nothing on the system changes; Lock Now only shows a notice). Debug builds:
  `.build/debug/LivePaperApp --snapshot <dir> [--only name,…]` renders every key screen with mock
  data to PNGs and exits (`.prohibited` activation policy, off-screen windows, no live previews).

## 12. Performance & battery policy
* Budgets enforced by `livepaper check` (§9), shown in the UI as energy badges.
* Automatic profile: 60 fps full-res on AC; 30 fps @ 75 % on battery / Low Power Mode.
* Pause when displays sleep; exit the saver host on willstop; video scenes use hardware decode.
* Governor steps render scale down (to 0.6) if frame time stays over budget for 2 s.

## 13. Milestones
1. Core + runtime + RenderService + CLI `check` (AI-ready framework).
2. Saver (web + video + clock hand-off) and publish pipeline.
3. Helper (shortcut + Lock Now + open-app relay).
4. App: library, create (video, AI), clone, modify, settings, onboarding, uninstall.
5. Built-in example scenes generated through LivePaper's own AI pipeline.
