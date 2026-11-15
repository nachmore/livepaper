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
  instances must render nothing until a saver is actually up — the session is locked
  (`CGSSessionScreenIsLocked` / `com.apple.screenIsLocked`), loginwindow posted
  `com.apple.screensaver.didstart` (every start, also while unlocked; verified in disassembly,
  delivery to the sandboxed host unverified), or ScreenSaverEngine runs — and pause on unlock,
  `didstop`, `stopAnimation` and display sleep (Saver/README.md, "The run gate").
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
    .livepaper/                   stdout.log, stderr.log, last-message.txt (codex), render-spool/; agents keep out
    .kiro/agents/                 the restricted agent Kiro sessions run as
  Workspaces/.render-relay/<id>/  scenes compiled by the session runner for relayed render requests
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
                                  (written without slots when LivePaper finds itself already selected)
    wallpaper-store-before-last-change.plist   the exact store bytes LivePaper replaced last (select or
                                  restore), saved before each write; named if a rollback can't be confirmed
  wallpaper-store.lock            flock: one wallpaper-store apply at a time
  helper-launch.json              the app fell back to the helper LaunchAgent because SMAppService refused
                                  (kept to, so no login item is registered next to it)
    changed-defaults.json         every system preference LivePaper changed, with its previous value
                                  (including the lock keys, §7) — restored by uninstall
  render.sock                     RenderService socket (§8)
  render-server.lock              flock held by whichever process serves the socket
  renderd-launch.lock             flock clients hold while deciding whether to start LivePaperRenderd
  renderd.pid                     informational (`livepaper server status`)
  Logs/renderd.log                output of a LivePaperRenderd started by a client
~/Library/Screen Savers/LivePaper.saver           installed saver, published content inside (LIVEPAPER_SAVERS_DIR)
~/Library/LaunchAgents/com.nachmore.livepaper.helper.fallback.plist   only for the LaunchAgent fallback; its own
                                  label, never the login item's (LIVEPAPER_LAUNCH_AGENTS_DIR)
~/Library/Application Support/LivePaper.uninstalled   written by uninstall (outside the data folder): the helper
                                  exits at launch while it exists; installing again removes it
~/Library/Application Support/com.apple.wallpaper/Store/Index.plist   read via WallpaperStore (LIVEPAPER_WALLPAPER_STORE)
$TMPDIR/LivePaperPreviews/                        compiled preview HTML (the app clears it at launch)
```
Uninstall keeping the scenes keeps `Library/`, `state.json`, `playlist-settings.json` and
`ai-settings.json`; everything else in the support directory goes (backups only when no step failed).
Other overrides: `LIVEPAPER_RESOURCES` (app resources), `LIVEPAPER_SOURCE_ROOT`
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
| `lockNowAccepted` | helper → app (the request was handled; sent before the lock flow runs) | the request's `requestID` |
| `lockRefused` | helper → app (the lock was refused: the password isn't required immediately) | `reason`: an `LPLockRefusal` raw value |
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
* **Run gate** (`SaverRunGate`, switches in `SaverGatePolicy`): a non-preview instance renders only
  while started (startAnimation, no stopAnimation/willstop) **and** a saver is up (session locked,
  `didstart` since the last unlock/`didstop`, or ScreenSaverEngine running) **and** the displays are
  awake. It loads nothing before that (also not while the displays sleep) and frees its scenes 5 s
  after its gate closes (unlock, `didstop`, stopAnimation). Previews (`isPreview || width < 500` —
  `isPreview` is unreliable in the macOS 26 host) render once started but pause while locked, while
  the displays sleep, while System Settings isn't frontmost and while their window is hidden; web
  previews run at 15 fps. Every lifecycle step is logged (os_log category `lifecycle`, notice level).
* Reads `Playlist/playlist.json`; keeps entries whose file is a plain name with a supported
  extension (§4.3) that exists; picks a scene (shuffle with no-repeat across recent sessions, an
  ended session is never rejoined, displays agreeing per 30 s epoch from what the session froze at
  its start); crossfades every `cycleMinutes`; fallback scene when nothing plays.
* **Web scenes:** `WKWebView` (`PassiveWebView`: no hit-testing), `loadHTMLString(baseURL: nil)`
  (the only navigation `SceneNavigationGate` lets through; no new windows or downloads),
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
  or Low Power Mode; previews at 15 fps; exit host process 0.5 s after `com.apple.screensaver.willstop`
  (non-preview only).
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
* **Lock flow** (shortcut or `lockNow`): if the session is locked or a saver is already running →
  nothing; else read the password policy (`sysadminctl -screenLock status`, right before every
  lock) and launch `/System/Library/CoreServices/ScreenSaverEngine.app` (the saver locks
  immediately). **If "Require password … Immediately" is off, set to a delay, or can't be read,
  starting the saver wouldn't lock the Mac, so nothing is started:** the helper posts `lockRefused`
  (the app shows why, with a button to System Settings › Lock Screen) and, when the app isn't
  running, opens it with `--lock-refused <reason>`. No private lock API is ever used
  (`LPLockRefusal`, `HelperLockPolicy.decide`).
* **Lock Now:** the app re-reads the install status; if the password isn't required immediately it
  refuses itself (banner, no request). Otherwise it posts `lockNow` with a `requestID`; the helper
  answers `lockNowAccepted` with the same `requestID` (deliverImmediately) as soon as the request
  arrives — also when its lock flow then skips or refuses — and runs the lock flow. Without an
  answer within 1 s the app launches ScreenSaverEngine itself (explicit user action only).
* **Uninstall:** if `LPPaths.uninstallMarker` exists at launch, the agent exits 0 before it creates
  anything (launchd's KeepAlive restarts it only after a crash).
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
→ {"op":"motion","html":…,"width":1280,"height":720,"dpr":0.5,"times":[3,17,41,120],"gaps":[0.5,2,5],"grid":[16,9],
   "out":"/abs/.check/motion-1280x720@0.5.png"}
→ {"op":"ping"}  |  {"op":"shutdown"}                     (answered without queuing)
← {"ok":true,"ready":true,"errors":[],"bench_ms":1.4,"out":"…","fps":30,"cpu_mW":61,"mean_luma":…,"clock_luma":…,
   "motion":{"width":640,"height":360,"cols":16,"rows":9,"samples":[{"t":3,"gaps":[{"gap":0.5,"tiles":{"level":[…],"area":[…]}},…],
             "flicker":{"level":[…],"area":[…]}},…]}}
```
* **`motion`** (`MotionAnalysis.swift` in Core): one page per sampled moment in manual mode (the
  runtime steps to t in 1/30 s steps exactly like a still, clock overlay hidden, clock time fixed),
  snapshots at 0, 1, 3, 7, 15 frames and every gap later, and per tile of the grid compares the
  frame at t with each gap (`level`: mean of max(0, d − 2), d = largest channel difference;
  `area`: share of pixels with d ≥ 8) and successive burst frames (`flicker`: the largest step).
  `out` (optional) gets a heat map PNG. The verdict (coverage, regions, busy, flicker) is computed
  by the client from these maps (`MotionAnalysis.summarize`/`verdict`).
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
* **Navigation policy** (`SceneNavigationGate`, also used by the app's previews and the saver): a
  page may perform only the one load its host started. The scene setting `location`, links,
  forms, subframes, `window.open` and downloads are cancelled — the CSP has no navigation
  directive and the source scanner only sees literal URLs — and the attempt is reported as a
  JavaScript error ("the scene tried to navigate to …"), so check fails the scene.
* `devicePixelRatio` is emulated per request; App Nap is disabled while serving (else fps caps at 30).
* **Outputs are confined** (`RenderOutputPolicy`): the server runs outside any agent's sandbox, so it
  writes a still (or motion heat map) only as a `.png` into the `.check` folder holding the request's html, a thumbnail
  only as a `.jpg` into the scene package it renders, or either into `<support>/Workspaces` or a
  temporary folder. Symlinks are resolved at write time (the parent folder is opened and its real
  path checked, the file is created and renamed relative to it); an existing destination must be a
  regular file. Anything else is refused before rendering. `livepaper still|thumbnail --out
  <elsewhere>` renders into the package's `.check` and moves the file itself, with the caller's
  own permissions.

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
JS-error check → motion at 1280×720@0.5 and 1024×820@0.5 (t = 3, 17, 41, 120; gaps 0.5/2/5 s;
16 tiles across; heat maps `.check/motion-<size>.png`) → short probe benches (30 frames) at every
sampled time but the last, to find the heaviest phase → full benches (120 frames) at that time at
1512×982@2 and 5120×1440@1 → luminance checks → optional live energy run (`--power`, battery
profile: 30 fps, 75 %) → writes `.check/report.json` (+ `motion[]`: coverage, regions, busy,
flicker, map per size) + PNGs, prints a short summary for humans and agents (with the motion map
when motion needs attention); exit 0 only if it passes.
`--quick`: three stills + one 32:9, motion at 16:9 only, one 60-frame bench at 1512×982@2, no
ultra-wide bench.

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
| Motion within 5 s (`MotionBudgets`; a tile moves at level ≥ 0.5 or area ≥ 3 %) | < 25 % of the frame, or motion in < 5 of the 9 regions (thirds × thirds) | < 50 % within 5 s or < 25 % within 2 s; any still region |
| Busy: tiles with level ≥ 16 within 0.5 s | > 50 % of the frame | |
| Flicker: tiles with a frame-to-frame step ≥ 10 | > 30 % of the frame | |
| Motion not measured (render server too old) | | always |

Motion calibration (2026-11, the built-ins as they were before their motion pass, at 16:9 / 5:4;
docs/SCENES.md has the current numbers): Ringed Giant 7 / 9 % in 2 / 1 regions
and Ink and Ember 2 / 2 % in 0 / 0 regions (both judged too static by a person) fail; Abyssal
Lanterns 30 / 41 % (6 / 6), Liquid Glass 47 / 45 % (7 / 7) and Rain on the River 100 % (9) pass.
Busy and flicker stay at 0–1 % for all five (falling rain included); strobing and fast pans
measure 100 %. `LIVEPAPER_SELFTEST_E2E=1 swift run LivePaperSelfTest runtime.e2e.motionBuiltins`
prints the numbers of the built-ins as they are now (`LIVEPAPER_MOTION_DUMP=<dir>` saves the raw maps).

`report.json` `benchMs` keys are `"<w>x<h>@<dpr> t=<t>"`; probe benches carry the suffix `" probe"`
(`"1512x982@2 t=30 probe"`) so consumers can tell them from the full benches.

## 10. AI authoring (`LivePaperCore/AI`)
* **Harnesses** (auto-detected on the user's login-shell PATH plus common install directories;
  each probed with `--version`). Every harness runs in the workspace (cwd), in its own process
  group, with `bin/` first on PATH; the prompt only ever travels in TASK.md. `[--model M]` comes from
  the session or `AISettings.models[kind]`; `<extra>` from `AISettings.extraArguments[kind]`.
  * Claude Code: `claude -p --output-format stream-json --verbose --permission-mode dontAsk
    --allowedTools "Read(./**),Edit(./scene/**),Bash(livepaper check *),…" --disallowedTools
    "WebFetch,WebSearch,Edit(./bin/**),…" [--model M] <extra>`, TASK.md on stdin. `dontAsk` denies
    whatever the rules don't allow: reading the workspace, editing ./scene, and `livepaper
    check|still|bench|live|thumbnail|compile|help` (Claude Code checks each part of a compound
    command). `acceptEdits` is not used: it auto-approves edits and mv/cp anywhere in the workspace.
  * Codex: `codex exec -C <ws> -s workspace-write --skip-git-repo-check --json -o
    <ws>/.livepaper/last-message.txt [-m M] <extra> -`, TASK.md on stdin. The sandbox keeps its
    defaults (writes only in the workspace, no network). It also blocks the Unix socket `livepaper
    check` needs, so the CLI falls back to the **render spool**: in a session, when the socket
    can't be reached, `RenderClient` writes `<id>.request.json` into `LIVEPAPER_RENDER_SPOOL`
    (`<ws>/.livepaper/render-spool`) and waits for `<id>.response.json`; it never starts a daemon
    itself. `RenderRelay` (in the session runner, outside the sandbox, polling every 0.1 s)
    claims each request and forwards it only if it is a still/bench/live/thumbnail/ping on a
    package and outputs inside the workspace (`.png`/`.jpg`); for still/bench/live it compiles the
    package itself into `<Workspaces>/.render-relay/<session>/`, where the agent can't write, so
    the server never renders HTML the agent wrote. It touches the spool only through a descriptor
    whose real path it checked, never through links.
  * Kiro CLI: `kiro-cli chat --no-interactive --agent livepaper-session [--trust-workspace]
    --output-format stream-json [--model M] <extra> "<bootstrap>"` (`--wrap never` instead of
    stream-json, and no `--trust-workspace`, for versions whose `chat --help` doesn't offer them).
    No `--trust-tools`: the session runs as the workspace's own agent,
    `.kiro/agents/livepaper-session.json` (`KiroAgentConfig`), which trusts reads, allows writes
    only under `scene/**` and shell commands only of the form `livepaper <scene command> <plain
    words>` — V2 engine: `toolsSettings` (anchored regex, `denyByDefault`); V3 engine:
    `permissions.rules` (globs, everything else denied) — with no MCP servers or hooks. Anything
    else would need approval, which a non-interactive run can't give.
  * Custom: a template such as `mytool --prompt-file {prompt_file} --cwd {workspace}`; placeholders
    `{prompt_file}` `{workspace}` `{scene}` `{model}` `{instructions}` (a lone `{model}` token is dropped
    without a model); POSIX-style quoting, no shell; TASK.md also on stdin. Validated by
    `CustomAdapter.templateProblem`.
  * `<bootstrap>` / `{instructions}`: "Read TASK.md in the current directory and carry out the task it
    describes, following AGENTS.md."
* **Workspace** per session (§4.1): `AGENTS.md` + `CLAUDE.md` (identical: scene rules, API, budgets,
  validation loop, "only edit ./scene"), `TASK.md`, `sdk/` (livepaper.d.ts, SCENE_API.md, templates,
  3 example scenes), `scene/` (template for *create*, a copy of the scene for *modify* without hidden
  entries, agent instruction files or links), `bin/livepaper` (shim to the bundled CLI),
  `.livepaper/` (logs). A modified scene is named by its id; its manifest name only appears as one
  quoted, length-limited line marked as data.
* **What an agent may run** (`AISessionPolicy`): every harness process carries
  `LIVEPAPER_AI_SESSION`, `LIVEPAPER_AI_WORKSPACE` and `LIVEPAPER_RENDER_SPOOL` (and not
  `LIVEPAPER_CLI`/`LIVEPAPER_RENDERD`). The shim sets them again and passes on only `check`,
  `still`, `bench`, `live`, `thumbnail`, `compile` (and help/version); the CLI itself, with the
  variables set, refuses every other command (exit 2) and any scene path or `--out` outside the
  workspace (symlinks resolved). So `uninstall`, `publish`, `import`, `new`, nested `ai` sessions
  and `server` control are out of reach whatever the harness's own rules let through.
* **Flow:** create/modify → workspace → harness → stdout parsed into events (text, tool calls) and
  `scene/.check/*.png` reported as stills while the agent iterates (again each time a later check
  rewrites a file; the session view reloads that tile) → on exit LivePaper runs the
  check itself (never trusts the agent's word) → preview → "Add to library" / "Replace" (modify keeps
  history; previous version kept in `history/`).
* **Stopping:** the harness runs in its own process group, which doesn't die with LivePaper. Cancel
  and the timeout send SIGTERM to the group and SIGKILL 3 s later; whatever the harness leaves in
  its group when it exits gets 1 s. `AISessionTerminating.terminateNow(grace:)` does the same
  synchronously and returns once the group is empty: quitting the app (`applicationShouldTerminate`
  → `.terminateLater`, at most 3 s) and uninstalling (before anything is deleted) use it.
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
  Lock Now posts `lockNow` and falls back to ScreenSaverEngine after 1 s (§7). While the password
  isn't required immediately, Lock Now is disabled with a one-line explanation and an "Open Lock
  Screen Settings…" item (the status is re-read when the user leaves System Settings).
* **Main window (NavigationSplitView):**
  * *Library* — grid of live thumbnails (hover = live preview), badges (video/web/AI, energy class).
  * *Scene detail* — full live preview (16:10 and 32:9), Use as Screen Saver / Add to Playlist,
    Clone, Modify with AI…, Export, Delete, check report and provenance.
  * *Create* — **Video** (drop a file; optional "optimise for battery" HEVC transcode) and
    **Describe it** (prompt, agent + model picker) → live session view.
  * *Screen Saver* — the playlist draft (scenes, order, cycle, clock, profile) → Save & Publish; a
    publish that left scenes out lists them with the reason (and a banner says so).
* **Full-screen preview** (`Views/FullScreen/`): one borderless black window on one screen (the
  main window's, or the one under the pointer from the menu bar) at status-bar level, menu bar and
  Dock hidden. It renders exactly like the saver: web scenes get the saver's own
  `LIVEPAPER_CONFIG` (SaverWebConfig — playlist clock, profile fps/scale, seed, power) and video
  scenes the saver's AVPlayerLayer + native clock; `SaverShared/` symlinks Saver/SaverLogic.swift
  and Saver/ClockOverlay.swift into the app for that. Entry points: the scene detail button and
  double-click, a card's hover button, context menu and Space, the Screen Saver screen's "Preview
  Playlist", the menu-bar extra, an AI session's result panel (before accepting — modifying shows
  the new version first and ← → compare it with the current one; once accepted, the library scene,
  as soon as the library has it), and ⇧⌘F (whatever the focused view publishes as
  `FullScreenPreviewAction`). Keys: Esc / click / Space / ⌘. close, ← → step (library order,
  playlist order, or new/current; a scene deleted meanwhile is skipped over, not stepped past), C
  clock, L simulated lock UI. Each key acts once per press (a held key's repeats do nothing), and
  the press that closed the preview is swallowed until its key is released, so a held Space or
  ⇧⌘F can't reopen it and doesn't type into the app that gets focus back. Playlist previews also
  advance on the playlist's cadence. Web scenes follow AC ⇄ battery and Low Power Mode changes like
  the saver (`LivePaper.host.power`); video scenes play only a file publishing would accept (a
  plain name inside the package, a regular file, a format the saver plays). It runs only while
  visible and while it has the keyboard: deactivation, another LivePaper window becoming key,
  hiding, display sleep, a session switch, a lock or a saver start close it and nothing keeps
  running afterwards.
* **Changes made elsewhere** (the CLI, Finder, an editor) show up without a relaunch:
  `LibraryWatcher` watches the support directory with one FSEvents stream (`Workspaces/`, `Logs/`
  and `backups/` excluded). Only `Library/<id>.lpscene` entries, their `scene.json`,
  `thumbnail.jpg`, `history.jsonl` and `.check/report.json`, and `playlist-settings.json` count;
  a burst becomes one refresh about 0.5 s after the last change (FSEvents latency 0.2 s + a 0.3 s
  debounce, at most 2 s). Becoming active and opening the main window refresh too, as a safety
  net. Refreshes are quiet: no loading state, unchanged data isn't reassigned (selection, scroll
  position and an edited playlist draft stay put), and nothing runs while nothing changes.
* *Settings* — Screen Saver (status, setup), Lock (**one** toggle "Use ⌃⌘Q and the lock key for
  LivePaper lock" + the optional extra shortcut recorder + helper status), Performance (profile),
  AI (default agent, per-agent model, time limit, custom command), About (+ Uninstall).
* **Onboarding** (first launch; re-runnable, every step idempotent and showing live status), 4
  steps: Welcome → Screen saver (install, select — with backup, or a guided one-click step in
  System Settings) → Locking (lock keys toggle, "require password immediately", helper login item,
  including "waiting for approval in Login Items") → First scene (pick what plays).
* **Uninstall** (Settings › About): shows exactly what will happen, then runs
  `InstallServicing.performUninstall` and shows the step log (done / nothing to do / failed with the
  reason). Steps: mark LivePaper as uninstalled (`LivePaper.uninstalled`, §4.1), unregister and stop
  the helper, switch every screen-saver slot that still names LivePaper.saver back (recorded
  original, else the placeholder, else for SystemDefault the pre-LivePaper choice or macOS's Message
  saver — docs/RESEARCH.md §5.7), restore the lock keys, restore other changed preferences, remove the
  saver (only once the store, re-read, no longer points at it), delete LivePaper's data (optionally
  the library; backups/ stay if any step failed). If the screen saver can't be switched back
  automatically the step fails and says to pick another saver in System Settings and run uninstall
  again. Failures can be retried (finished steps are skipped); on success the app moves itself to
  the Trash and quits.
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
