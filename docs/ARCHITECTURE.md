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
* **Display sleep before the screen saver** (docs/RESEARCH.md §7): when `pmset displaysleep` of the
  power source in use is shorter than the screen saver's idle time (managed here: screens off after
  5 min on battery, saver after 15), macOS locks at display sleep with no saver running → the desktop
  picture. The displays dim when the last `UserIsActive` assertion times out (they carry the
  display-sleep time and are re-armed by activity) and turn off ~10 s later (pmset log). ⇒ LivePaper's
  optional "Show your scene when the screens turn off first" starts the saver 8 s before the dim
  (§7).
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
                                  UniformTypeIdentifiers (video import), ServiceManagement (helper
                                  login item) and IOKit (power sources, assertions) — never AppKit or
                                  WebKit: the CLI links it.
  Services/ServiceProtocols.swift the service API the app and CLI program against (+ LivePaperServices.live())
  Collections/                    collections of scenes: the model and collections.json (CollectionStore), the
                                  ordering rules (CollectionOrder), editing, export and import (CollectionService, §4.6)
  Power/                          display-sleep timers, screen-saver idle time, assertions and the
                                  "before screens off" decision, schedule and status text (§7)
  Playlist/PlaylistModel.swift    Codable playlist + notification names, compiled into BOTH Core and the
                                  saver (keep it Foundation-only and self-contained)
  Playlist/DisplayLayout.swift    display keys, arrangement, main display, virtual canvas (also in the saver)
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
                                  PlaylistModel.swift, DisplayLayout.swift and SceneNavigationGate.swift).
                                  See Saver/README.md.
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
    references/                   only with reference images (§10): ref-01.jpg … (copies LivePaper made: ≤ 2000 px,
                                  sRGB, no metadata, 0o444; ref-01 is the picture to animate, if any), ref-01.json
                                  (ReferenceSummary), references.json (index: file, role, size, the animate asset and
                                  its SHA-256); pruned with .check after a day (the workspace keeps its date, so it
                                  still goes after 7 days)
    .livepaper/                   stdout.log, stderr.log, last-message.txt (codex), render-spool/; agents keep out
    .kiro/agents/                 the restricted agent Kiro sessions run as
  Workspaces/.render-relay/<id>/  scenes compiled by the session runner for relayed render requests
  Workspaces/.sessions/<id>/      the session's record (§10 "Session records and recovery"), next to its
                                  workspace and outside every agent's reach: session.json, plus LivePaper's
                                  copies of its images (ref-01.jpg …, asset.jpg|png: the picture to animate as
                                  the scene got it) while it may still be reviewed; goes with its workspace
  Workspaces/.sessions/.lock      flock: one change to a record at a time (app and CLI)
  state.json                      app → helper shared state (§4.4)
  collections.json                collections of scenes (§4.6); collections.lock: flock for its read-modify-writes
                                  (app and CLI); collections.unreadable-<time>.json: a file that wasn't JSON, set
                                  aside by the next change instead of being overwritten
  playlist-settings.json          PlaylistSettings: what to publish (mode, cycle, clock, profile, scenes,
                                  displays: mode / per-display scenes / battery, §4.3), plus `displayNames`
                                  (display id → last seen name, for assigned displays; app UI only, never
                                  published) and `collectionID` (the collection the playlist follows, §4.6;
                                  absent when none). Decoded field by field: a missing or malformed field gets
                                  its default, the rest is kept (old files, newer versions)
  ai-settings.json                AISettings: Settings › AI (shared by the app, the CLI and sessions)
  publish.lock                    flock: one publish / saver install, update or removal at a time (app and CLI
                                  may race)
  backups/
    wallpaper-store-Index.plist   raw copy of the wallpaper store before LivePaper's first selection
                                  (forensics only — NEVER restored wholesale; WallpaperAgent rewrites the
                                  file constantly and a stale copy would clobber newer Desktop choices)
    wallpaper-selection.json      per-slot manifest of the Idle slots LivePaper changed (original provider +
                                  configuration, the placeholder of a display record LivePaper filled
                                  included; a placeholder never replaces an original recorded earlier),
                                  plus `agentSlot` where WallpaperAgent wrote its own choice into a planned
                                  SystemDefault / Space Default; uninstall restores only slots that are
                                  still LivePaper's (written without slots when LivePaper finds itself
                                  already selected), and deletes it only once the restore is confirmed. Its
                                  existence means LivePaper owns the selection: the app's quiet re-apply
                                  (§11) runs only then, and only while LivePaper is still chosen somewhere
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
$TMPDIR/LivePaperPreviews/                        compiled preview HTML (the app clears it at launch; named
                                  `<id>-<updated>-<hash of location, id, sources>.html`, `scene-…` when the
                                  id isn't a valid scene id, e.g. an agent-written candidate's)
```
Uninstall keeping the scenes keeps `Library/`, `collections.json`, `state.json`, `playlist-settings.json`
and `ai-settings.json`; everything else in the support directory goes (backups only when no step failed).
Other overrides: `LIVEPAPER_RESOURCES` (app resources), `LIVEPAPER_SOURCE_ROOT`
(`swift run` from the source tree), `LIVEPAPER_CLI` (the CLI the workspace shim execs).
The saver keeps its own session bookkeeping in ScreenSaverDefaults (inside its sandbox).

### 4.2 Scene package `<id>.lpscene/` (a directory; a document type, §11)
```
scene.json        manifest (schema below)
scene.js          web scenes: the scene code (one classic script)
assets/           optional small static assets (images/fonts/text), inlined at compile time, offline only;
                  assets/reference.jpg|png is the user's picture an "animate" AI session brought to life
                  (written by LivePaper, ≤ 3840 px, sized to fit the asset limits; agents leave it alone)
video.mov|mp4|m4v video scenes (other containers are remuxed to .mov on import)
thumbnail.jpg     generated by the RenderService (16:10, 640×400)
.check/           last `livepaper check` output (report.json, scene.html, PNGs); never published
history.jsonl     provenance: one line per create/clone/modify/replace {date, action, harness, model, prompt, summary,
                  references?} — `references` {"reference": n, "animate": n} counts a session's reference images
                  (never names or paths; the prompt is recorded with attached paths replaced by references/ref-NN…)
history/<stamp>/  previous versions kept by "Replace" (AI modify accept, Replace with This Version)
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
  "performance": { "benchMs": 1.4, "energyMw": 60, "checkedAt": "…" },  // written by check
  "span": true                               // optional: may stretch across displays (below)
}
```
`"span": true` means "this web scene is a pure function of lp.t, the seed and the canvas size, and may
stretch across displays" ("Span across displays", §6; SCENE_API.md §16; `livepaper check` verifies it).
Videos span unless they say `"span": false` (one shared player shows every display its crop, exact by
construction). Decoded tolerantly (a non-bool is ignored); `SceneManifest.spans` is the effective value.

### 4.3 Playlist (published into the saver; `Sources/LivePaperCore/Playlist/PlaylistModel.swift`)
`LivePaper.saver/Contents/Resources/Playlist/playlist.json`:
```json
{ "schema": 1, "generation": 42,
  "mode": "shuffle",                 // shuffle | sequence | single
  "cycleMinutes": 5,                 // 0 = never change while running
  "showClock": true,
  "performance": "automatic",        // automatic | best | balanced | battery
  "displays": { "mode": "choose",    // same | different | choose | span (multiple displays, §6)
                "assignments": { "37D8832A-2D66-02CA-B9F7-8F30A301B230": "ringed-giant" },   // choose only
                "onBattery": "still" },          // live | still | off: what non-main displays show on battery
  "displayScenes": [ { "id": "ringed-giant", "name": "Ringed Giant", "kind": "web", "file": "ringed-giant.html",
                       "clock": "top", "span": true } ],   // published only for a display assigned to it
  "scenes": [ { "id": "aurora-lake", "name": "Aurora Lake", "kind": "web", "file": "aurora-lake.html", "clock": "top", "span": true },
              { "id": "beach", "name": "Beach", "kind": "video", "file": "beach.mov", "fit": "fill", "clock": "top", "span": true } ] }
```
Multiple displays (`LPDisplaySettings`, `Playlist/DisplayLayout.swift` for keys and arrangement):
`displays` defaults to `{same, {}, live}` — exactly the behaviour before display modes — and so does a
file without it. Assignment keys are display UUIDs, uppercase (`CGDisplayCreateUUIDFromDisplayID`, the
form the wallpaper store uses; "DISPLAY-<id>" for a display without one). Publish writes `mode` and
`onBattery` always, assignments only in `choose` mode and only to scenes it published — a deck scene, or
a library scene staged once into `displayScenes` (one that fails to stage is reported in `skipped`; an
unknown one is dropped) — and every entry's `span` (`SceneManifest.spans`). `schema` stays 1: the seven
original keys are required as before (unreadable → the saver's fallback), the new ones are optional and
tolerant both ways (an unknown mode or battery value → the default, a broken `displayScenes` item is
dropped; an older saver ignores them all and plays "same").
Web scenes are compiled to single self-contained HTML (runtime and assets inlined) at publish time.
Supported files: `html`/`htm` for web scenes, `mov`/`mp4`/`m4v` for video
(`LPPlaylistEntry.webExtensions` / `.videoExtensions`; the saver skips anything else, so publish
reports such scenes as skipped). Publishing writes `Playlist.new/`, then atomically swaps it in
(under `publish.lock`) and posts `com.nachmore.livepaper.published`. Scenes that fail to compile or
have no playable video are left out and reported (`PublishResult.skipped`); if none is publishable
the previous playlist stays. The app saves `playlist-settings.json` before publishing and puts the
previous settings back when its publish fails while a saver is installed, so the stored settings
always describe what the saver plays (without a saver they stay stored: installing publishes them).
Skipped scenes are reported after every app publish, including the republish of setup and of the
launch-time saver update (§11). The saver reads the playlist at start only (previews also on
`published`). (The saver is sandboxed and can read only its own bundle — that's why content is
published *into* it.)

### 4.4 `state.json` (app → helper)
```json
{ "schema": 1,
  "lock": { "hotkey": {"keyCode": 37, "modifiers": ["control","command"]}, "lockKeysShowScene": true,
            "showSceneBeforeDisplaySleep": false },
  "installedAt": "…", "appVersion": "0.1.0" }
```
* `hotkey`: LivePaper's own lock shortcut (absent = none). Default ⌃⌘L.
* `lockKeysShowScene`: mirror of `immediateLockLaunchesScreenSaver` (§7), written by the app after it
  changes the preference through `InstallServicing.setLockKeysShowScene`. Informational: loginwindow
  acts on the system preference by itself. Files from before the single toggle carry
  `takeOverSystemLock` / `takeOverLockKey`; they decode as `lockKeysShowScene = either`.
* `showSceneBeforeDisplaySleep`: "Show your scene when the screens turn off first" (§7), **off by
  default**; the helper acts on it. Always written; absent (files from before the option), `null` or
  anything but a Bool decodes as off — in LPSharedState and in the helper's fallback reader, which
  only turns it on for a JSON `true`.

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

### 4.6 Collections (`Sources/LivePaperCore/Collections/`)
A collection is a named, ordered set of scenes — user and built-in; a scene can be in any number of
collections, at most once in each. `collections.json` (CollectionStore):
```json
{ "schema": 1,
  "collections": [ { "id": "3129b068-b7a3-4eae-9627-a6021cb4e6bc", "name": "Night Skies",
                     "scenes": ["ember", "aurora-lake", "glow"],       // scene ids, in order
                     "created": "2026-11-16T12:45:00Z", "updated": "…" } ] }
```
* **Identity:** `id` is a lowercase UUID for collections LivePaper creates (1–64 letters, digits, dashes
  are accepted from other writers). It never changes — renaming keeps it — and travels with an export,
  so importing the same collection again finds it. **Names** are unique in a library ignoring letter case
  and accents (`SceneCollection.nameKey`), so the CLI can name collections; LivePaper lists them by name.
* **Scenes are referenced, never owned:** renaming or deleting a collection never touches a scene.
  Deleting a scene in LivePaper removes it from every collection (`CollectionServicing.removeSceneEverywhere`,
  one write, after the scene is gone; the delete sheet and banner name the collections). An id whose scene
  is gone some other way (moved to the Trash in Finder) stays in the file, is skipped wherever the
  collection is shown, played, previewed or exported, and is back if the scene is — the playlist's
  `sceneIDs` work the same way.
* **Writing:** every change is a read-modify-write under the in-process lock and `collections.lock`
  (flock), written atomically; an edit that changes nothing doesn't write. Reads take no lock.
* **Tolerant decoding:** a collection that can't be read is dropped; a field that can't be read gets its
  default (blank name → "Untitled Collection"); scene ids that aren't valid ids are dropped, repeated
  ones kept once; a collection without a usable id gets `c-<slug of its name>` (the same on every read),
  repeated ids get `-2`, …; a bare array of collections is read too; unknown keys and a newer `schema` are
  read past (and not written back). A file that isn't JSON at all reads as no collections and is moved
  aside as `collections.unreadable-<time>.json` by the next change (never silently overwritten).
* **Editing** (`CollectionOrder`, shared by the service, the app and the CLI): adding skips scenes the
  collection has and puts the others at a placement (`start`, `end`, a 0-based index, `before`/`after` a
  scene); removing reports what it removed; moving keeps the moved scenes' relative order and places them
  against the others. Grid drag and drop (`dropPlacement`): scenes dropped onto a card take its place —
  after it when all of them come from before it, before it otherwise — so a card dropped on its
  neighbour swaps with it. Adding needs scenes the library has (`CollectionError.unknownScenes`).
* **The screen saver following a collection** (a live link, not a copy): `PlaylistSettings.collectionID`.
  `PlaylistSettings.following(_:)` gives the playlist as it plays — the collection's scenes, in its order;
  an empty collection plays every scene, like an empty selection — and PublishService resolves it at every
  publish. `sceneIDs` keeps the collection's scenes as they were when the settings were last saved: what an
  older LivePaper (which ignores `collectionID`) plays, and what plays when the collection is gone. Whoever
  changes the followed collection publishes it again when a saver is installed (the app quietly; the CLI's
  `collection add|remove|move|import` print "updated the screen saver"); the app doesn't publish for
  changes it only reads from disk. Deleting the followed collection turns the playlist into a list of its
  scenes (`collectionID` cleared, nothing republished: the saver already plays them). "Use as Screen Saver"
  on a single scene, "Play: All scenes / Scenes you choose", `publish --scenes` and `--collection none`
  stop following. While following, Next Scene is off (the order is the collection's) and "Add to Playlist"
  adds to the collection.
* **Export** (`CollectionService.export`): one file, `<name>.lpcollection` (`CollectionArchive.suggestedFileName`:
  `/`, `:` and `\` become `-`) — a zip (`ditto -c -k --sequesterRsrc`, without `--keepParent`, built next to
  the destination and renamed into place) whose root holds:
  ```
  collection.json   {"schema":1, "format":"livepaper-collection", "id", "name", "created", "updated", "exported",
                     "scenes":[{"id":"ember","name":"Ember","builtin":false,"package":"scenes/ember.lpscene"},
                               {"id":"aurora-lake","name":"Aurora Lake","builtin":true}]}   // the collection's order
  scenes/<id>.lpscene/  every user scene, exactly as `LibraryServicing.exportPackage` writes it
  ```
  Built-in scenes are referenced by id, never copied (every LivePaper has them); scenes no longer in the
  library are left out and reported.
* **Import** (`CollectionService.importCollection(at:mode:)`, one at a time per process): a `.lpcollection`
  file is unpacked with `ditto -x -k` into a temporary folder (ditto drops `..` and leading `/` from entry
  names and writes link entries as plain files — docs/RESEARCH.md §9 — so nothing lands outside it); an
  unpacked one (a folder) is read in place. The root is the folder with collection.json, or its only
  subfolder that has one. collection.json: at most 4 MB and 5,000 scenes, entries decoded one by one (an
  unreadable or repeated entry is dropped). Each entry, in order: a **built-in** is used when this
  LivePaper has it as a built-in (not when a scene of yours has its id, not when this version lacks it:
  both reported); a **user scene** must be `scenes/<plain name>.lpscene`, a real folder in the file (else
  reported); `LibraryServicing.existingScene(matching:)` — the scene itself, or one with the same contents
  (ScenePackageComparison) — is used, otherwise the package is imported (`openPackage`, under the
  library's lock; another version of one of your scenes is imported next to it, never over it), so ids
  that clash with unrelated scenes get `-2`, … and nothing is imported twice. Every scene failing is an
  error (no empty collection); a file with no scenes makes an empty one. Then the collection:
  * **new to this library** (no collection with its id): created with the file's id and name (made unique:
    "Night Skies 2"), `created` from the file;
  * **already here** (`.automatic`): nothing is changed or imported — the result lists the file's scenes
    the collection doesn't have (`lacking`), so a re-import never puts back what was removed; `.merge`
    adds those at the end (importing what isn't in the library yet), `.copy` makes another collection with
    a new id. The app's banner offers "Add N Scenes" / "Import as a Copy", the CLI `--merge` / `--copy`.

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
reducedMotion, preview}, cfg, util`, and for spanning displays `viewport ({x,y,w,h}: this page's part
of the canvas), span, fragOffset ([x, y] device px, GL bottom-left), clockBox`. `LivePaper.util` (clamp, lerp, smoothstep, ease.*,
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
* **spanning displays** (SCENE_API.md §16): with `spanW`/`spanH` > 0 the page shows the viewport
  (`spanX`, `spanY`, window size) of a virtual canvas; `lp.w/h` are the canvas, `lp.pw/ph` its device
  pixels, the stage only the viewport. The stage context's absolute transforms
  (`setTransform`/`resetTransform`, `getTransform` un-offset) and, in WebGL, `viewport`/`scissor` on
  the default framebuffer are offset by the viewport's device-pixel origin, so scenes drawing the
  whole canvas draw their slice. While spanning the governor is off, canvas-sized `util.layer`s are
  capped at 16 MP, a WebGL page lowers its density to stay within `MAX_VIEWPORT_DIMS`, and the clock
  is laid out in the clock box (`spanClock*`: the main display's viewport) in canvas coordinates and
  drawn only by the page whose viewport holds it. `timeOrigin` (ms since 1970, live mode) makes
  `lp.t` the wall-clock time since then, monotonic, the same on every page; `paused` loads the page
  paused (one frame, no frame loop, no clock timer).

Configuration, lowest to highest precedence: defaults < `window.LIVEPAPER_CONFIG` (user script at
document start) < URL hash (development) < `LivePaper.host.config({...})`. Keys (runtime.js `TYPES`;
unknown keys are ignored, so hosts must use these): `still, t, bench, manual, clock, clockPosition,
hour12, clockTime, fps, scale, dprMax, performance, power, lowPower, reducedMotion, preview, lockUI,
seed, debug, governor, budgetMs, statsEvery, spanW, spanH, spanX, spanY, spanClockX, spanClockY,
spanClockW, spanClockH, timeOrigin, paused`. `lockUI: true` starts a scene with its clock hidden
(the saver sets it when it creates a scene while the lock UI is up); `preview: true` marks small
previews (the app's library and detail previews) and becomes `lp.env.preview`.

Bridge messages host→page: `LivePaper.host.config(obj)`, `.pause()`, `.resume()`, `.lockUI(bool)`,
`.power(obj)`, `.advance(dt)` (manual mode). Page→host via `webkit.messageHandlers.livepaper.postMessage({...})`;
`ready` carries `viewport`, `span` and `hasUpdate` (the scene defines `update()`).

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
  power, lowPower, lockUI}` (+ the span keys and `timeOrigin` for a spanning step, `paused` for a
  still display) injected at document start, occlusion detection disabled, failure recovery with
  backoff.
* **Video scenes:** native `AVPlayerLayer` + `AVPlayerLooper` (hardware decode, lowest power),
  native clock overlay (`CATextLayer`s) styled like the runtime clock.
* **Clock hand-off:** observe `com.apple.screenLockUIIsShown|IsHidden` →
  `lockUI(true/false)` (web) / fade native clock (video); state that changed while a page loads is
  re-applied on `ready`.
* **Immediate delivery:** every distributed observer uses `.deliverImmediately` (§1).
* Power: pause on `screensDidSleep`, resume on wake; `Automatic` profile = battery saver on battery
  or Low Power Mode; previews at 15 fps; exit host process 0.5 s after `com.apple.screensaver.willstop`
  (non-preview only).
* Options sheet: summary (+ the display mode when it isn't the default) + "Open LivePaper…" (posts
  `openApp`, which the helper turns into launching the app — the sandboxed saver can't launch apps
  itself).
* **Multiple displays** (`playlist.displays`; `SaverDisplayPlan` in `SaverLogic.swift`): every
  display's view runs in one `legacyScreenSaver` process (verified). Each finds its display
  (`window.screen` → `NSScreenNumber` → `CGDisplayCreateUUIDFromDisplayID`, uppercase; "DISPLAY-<id>"
  without a UUID), the arrangement (`NSScreen.screens`, converted to top-left global points;
  `Playlist/DisplayLayout.swift`), its index in the stable order (left edge, then top edge, then key)
  and the **main** display (the built-in one if it is on, else the menu-bar screen, else the first),
  re-read at every start, on `NSApplication.didChangeScreenParameters` and when its window changes
  screen. A view starting while another view of the process runs **joins that view's session**
  whatever its age (a display connected mid-run shares the time origin); the store-based join (45 s)
  stays the fallback. Modes (all keep the session's seed, schedule and no-repeat rules):
  *same* — today's behaviour; *different* — display k plays deck step s + k, with the deck's
  `spread` = the display count so any d consecutive steps are distinct (across reshuffles too), the
  first d positions avoid the recent scenes, and no display starts with what it showed last
  (`shownOn` in the session record); only the last display in order that shows anything writes
  `lastShown` (sequence continues after it); *choose* — a display with an assignment whose scene is
  playable shows it (no cycling, no history; repeated failures fall back to the playlist), the others
  play the playlist; *span* — a step whose entry has `span: true` spans: each display renders its
  viewport of the union of all frames (web: the runtime's span keys, §5; video: one shared player, the
  player layer framed as the whole canvas offset by −viewport and clipped by the host view), with the
  time base and seed shared and exactly one clock, on the main display; other steps play as *same*.
  Different and span need two displays (else *same*). Previews and a display whose key isn't in the
  arrangement always play as *same*, live (never black on uncertainty).
* **Shared video decode:** one `AVQueuePlayer` + `AVPlayerLooper` per (file, publish generation) per
  process (`SharedVideoPlayers`), leased by every display's `AVPlayerLayer` that shows that file; it
  plays while any lease runs and is dropped with the last; a looper failure fails every leaseholder.
* **Battery** (`onBattery`): on battery or in Low Power Mode every display but the main one shows the
  scene live, a **still** (the page loaded paused: one frame, no frame loop or clock timer, clock
  hidden; a video's frame at the shared player's time in a plain layer, no player) or **nothing** (no
  scene host, no timers: black). Span with `off` shows the whole scene on the main display. Followed
  live on power changes, like the fps/scale profile.
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
* **Login item and its repair** (`InstallService`, `Install/HelperJob.swift`, `Install/HelperProbe.swift`):
  the app registers the helper with `SMAppService.agent` (the LaunchAgent fallback, with its own label,
  for unbundled builds or when SMAppService refuses for good). launchd only starts it as the code
  recorded at registration — for ad-hoc builds the helper's cdhash — and an update can leave it unable
  to start the helper at all while SMAppService still says `.enabled` (docs/RESEARCH.md §6.1). Registering
  again fixes that but isn't free: it ends the running helper, and every new registration makes macOS
  post "“LivePaper” can run in the background". So LivePaper registers again only on **positive
  evidence** that launchd can't run this build's helper, and decides by the helper's code, not by file
  times or build numbers:
  * `InstallStatus.helperProblem` (the CLI sees it too): `cannotStart` (spawn failed, EX_CONFIG, needs
    LWCR update, a launch-constraint exit), `notLoaded` (launchctl's exit 113 — a timeout or any other
    error is no answer and changes nothing), `stopped`, `outdated` (its process runs code that is no
    longer this copy's helper on disk: `SecCodeCheckValidity` says errSecCSStaticCodeChanged, or its
    executable is gone or in the Trash), `otherCopy` (it runs another copy of LivePaper's helper: reported
    only) and `unregistered` (a re-registration that didn't finish). A job counts as running when the
    `pid` launchd shows is alive, whatever its `state` line says (`launchctl print` is "NOT API").
  * `HelperRegistrationRecord` (`helper-registration.json` in the support directory, removed with the
    login item): which copy registered it, its build and its helper's signature (cdhash, Team ID).
    `pendingSince` is written right before the unregister of a re-registration and cleared once
    registering worked, so a register that fails after the unregister is retried at the next launch
    (and reported) instead of leaving the helper unregistered and taken for "not set up".
  * `HelperJobAssessment` decides: a helper that runs this copy's current code is left alone (an update
    that leaves the helper byte-identical changes nothing); one that runs older code, or whose
    executable is gone or in the Trash, is only restarted (`launchctl kickstart -k`) when this copy
    registered it and the recorded signature covers this copy's helper — the same Team ID, or for
    ad-hoc code the same cdhash (an update by Finder's Replace or trash-and-copy with an unchanged
    helper: the old process runs from the Trash, as `proc_pidpath` follows the file) — and registered
    again otherwise; a stopped job is started (`launchctl kickstart`) when the recorded
    signature still covers this helper, and registered again when it doesn't (without a record: when an
    older build registered it). A start or restart that launchd then refuses — or a restart after which
    the old copy's helper runs again — is registered again; a start counts as done when the job then
    runs another copy's helper (that copy's job, started from this one); one
    that just doesn't show a running helper is reported, not registered again, and a helper that still
    runs is never ended for a registration this copy's own signature would make fail (a quick
    `SecStaticCodeCheckValidity` of the app). Registering again:
    unregister, waiting for its completion, then register, as SMAppService.h asks for after the
    executable changed — retried once when SMAppService still has the item (a late unregister), then
    waiting up to 10 s for smd to submit the job (the fallback: plist rewritten, bootout + bootstrap).
  * The app runs `InstallServicing.recoverHelper` by itself **once per launch**, the first time a read
    of the status shows a problem (at launch, later, or as soon as other install work ends — it never
    runs alongside it), and only for a helper that is set up (an enabled login item, the fallback's
    plist, or an unfinished re-registration) — never after an uninstall, never while macOS waits for
    approval. Registering moves the login item to the copy that registers, so the automatic repair only
    runs in the **copy that registered it** (or, without a record or when that copy is gone, a copy in
    /Applications or ~/Applications): opening a download, a translocated copy, a disk image or a build
    folder never takes the helper away from the installed app. It is quiet when it works (logged with
    NSLog and the install Logger). A re-registration that ends in `.requiresApproval` gets a banner
    with "Open Login Items" and nothing else (no fallback behind the user's back); a failure gets an
    error banner with Try Again. Both go once a status read shows the helper running.
  * Settings › Lock and onboarding show "LivePaper helper can't start" with **Repair Helper** (otherwise
    Start Helper): `registerHelper`, the same logic on the user's request — which may take the helper
    over from another copy. While another copy's helper runs (the row is done), Settings › Lock and
    onboarding say so and offer **Use This Copy's Helper**: `registerHelper` then registers the login
    item from this copy (the only way to move it while that helper works; the automatic repair never
    does).
  * `livepaper doctor` reports "can't start: launchd reports …" or an unfinished re-registration with
    the fix (open LivePaper; else Login Items off/on or log out and in), and warns about an outdated
    running helper or another copy's. `scripts/dev-install.sh` can't use SMAppService: it compares the
    new helper with the **running** process (`codesign --verify <pid>`; `codesign -dvvv <pid>` would
    describe the new file), restarts only a Team ID-signed login item, never starts a stopped ad-hoc
    one, and says when launching the app is needed (with `--launch` it waits up to 30 s for the new
    helper to run).
* **Before screens off** (`state.lock.showSceneBeforeDisplaySleep`, off by default;
  `Agent/PreSleepWatcher.swift` over Core's `Power/` — `LPPreSleepPolicy`, `LPPreSleepSchedule`,
  `LPPowerProbe`; docs/RESEARCH.md §7). When the displays are set to turn off before the screen saver
  would start, macOS locks at display sleep with no saver running (desktop picture). With the option
  on, the helper starts the saver through the **lock flow** (`HelperLockTrigger.beforeDisplaySleep`:
  same `HelperLockPolicy.decide`, so the saver locks and its run gate opens) `lead` = **8 s** before
  the displays would dim; macOS then dims them and turns them off on its own schedule (the saver holds
  no display assertion) and the saver resumes by itself after the wake (Saver/README.md). A refusal is
  only logged (never `lockRefused`, never opens the app).
  * **Only when** (`LPPreSleepPolicy.decide`): the option is on; the session is unlocked; no screen
    saver runs; the password is required immediately (`HelperPasswordPolicy`, read at every
    evaluation — otherwise starting early changes nothing security-wise and only shows the saver
    sooner than expected); the power source in use (`IOPSGetProvidingPowerSourceType`) has a
    non-zero display-sleep time (`pmset -g custom`, else /Library/Preferences/com.apple.PowerManagement.plist)
    **shorter** than the screen saver's idle time (loginwindow's: a profile's forced `idleTime`, the
    user's current-host / any-host value, else EngineDefaults.plist's, else 1200 s; 0 = never counts
    as longer); and nothing keeps the displays on — an untimed `PreventUserIdleDisplaySleep`,
    `NoDisplaySleepAssertion` or `InternalPreventDisplaySleep` (a call) means `.blocked`: look again
    after one threshold and when powerd's assertion summary changes. Timed preventers (powerd's
    5-minute "delay display off" after such an assertion ends) only move the moment.
  * **When** (`LPPreSleepSchedule.next`): the displays dim at max(display sleep − HID idle time
    (`CGEventSourceSecondsSinceLastEventType(.hidSystemState, any input)`), the end of the last
    `UserIsActive` assertion, the end of the last timed preventer) — assertions from
    `IOPMCopyAssertionsByProcess` (`AssertTimeoutUpdateTime` + `AssertTimeoutTimeLeft`), so apps that
    declare user activity (rcd, Bluetooth HID, capture apps) push it later. More than `lead` + 1 s
    away → arm the timer for (that − `lead`); within [−4 s, `lead` + 1 s] → start; later → "missed"
    (the displays may already be off): don't start, look again after one threshold
    (display sleep − `lead`, the earliest the idle time can reach it again).
  * **Battery:** nothing at all runs while the option is off (no observers, no timer). While on, one
    one-shot `DispatchSource` timer (strict, 0.5 s leeway); when it fires the facts are read again
    (sysadminctl + `pmset -g custom`, ~40 ms, off the main thread) and after activity it is armed
    again — about once per display-sleep period while the Mac is in use, never per second. Disarmed
    while the displays or the Mac sleep, while the session is locked (`com.apple.screenIsLocked` —
    observed only for this, never to start a saver) or switched out; re-evaluated on the screens /
    Mac waking, unlock, session switch-in, power-source change (`kIOPSNotifyPowerSource`), energy
    settings change (`com.apple.system.powermanagement.prefschange`), the option, and — only while
    `.blocked` — `com.apple.system.powermanagement.assertions` (checked with a cheap assertion read
    first). Evaluations that overlap are merged; one that started before a disarm is dropped.
  * **Logged** (os_log category `helper`, "before screens off (<event>): …"): state changes, every
    start and every "missed" at notice level with the numbers (power source, display sleep, idle time
    and its source, HID idle, when user activity / prevention ends, who keeps the displays on);
    routine re-arms at info: `/usr/bin/log show --info --last 2h --predicate 'subsystem ==
    "com.nachmore.livepaper" && category == "helper"' | grep 'before screens off'`.
  * `--print-config` reports `preSleep` {enabled, appliesOn, status, now, powerSource,
    displaySleepSeconds, screenSaverIdleSeconds/Source, leadSeconds, preventedBy}; `--self-check`
    prints a "before screens off" line.
* **Uninstall:** if `LPPaths.uninstallMarker` exists at launch, the agent exits 0 before it creates
  anything (launchd's KeepAlive restarts it only after a crash).
* Watches `state.json` / `stateChanged`; relays `openApp` from the saver.
* Idle footprint: zero timers and no power observers unless "before screens off" is on; otherwise
  it wakes only on events.

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
→ {"op":"still","html":…,"width":2560,"height":1440,"dpr":1,"t":12,"clock":false,
   "span":{"canvasW":4072,"canvasH":1440,"x":1512,"y":0,"clockX":0,"clockY":458,"clockW":1512,"clockH":982}}
→ {"op":"ping"}  |  {"op":"shutdown"}                     (answered without queuing)
← {"ok":true,"ready":true,"errors":[],"bench_ms":1.4,"out":"…","fps":30,"cpu_mW":61,"mean_luma":…,"clock_luma":…,
   "motion":{"width":640,"height":360,"cols":16,"rows":9,"samples":[{"t":3,"gaps":[{"gap":0.5,"tiles":{"level":[…],"area":[…]}},…],
             "flicker":{"level":[…],"area":[…]}},…]}}
```
* **`motion`** (`MotionAnalysis.swift` in Core): one page per sampled moment in manual mode (the
  runtime steps to t in 1/30 s steps exactly like a still, clock overlay hidden, clock time fixed),
  snapshots at 0, 1, 3, 7, 15 frames and every gap later, and per tile of the grid compares the
  frame at t with each gap (`level`: mean of max(0, d − 2), d = largest channel difference;
  `area`: share of pixels with d ≥ 8) and successive burst frames (`flicker`: the largest step,
  over spans of 1, 2, 4 and 8 frames). Each frame is compared as it arrives, so only the frame at t
  and the previous burst frame are kept (`MotionAnalysis.SampleBuilder`). `out` (optional) gets a
  heat map PNG. The verdict (coverage, regions, busy, flicker) is computed by the client from these
  maps (`MotionAnalysis.summarize`/`verdict`). The answer is one line, so cols × rows × times ×
  (gaps + 1) may be at most 65,536 (`MotionAnalysis.maxTileValues`; the check uses 2,304–3,328); a
  failure names the moment it happened at ("… (at t = 41 s)").
* **`span`** (still and bench; `RenderSpan`): the page is the viewport (`width`×`height`) of a
  spanning canvas — the runtime's span keys merged into its config (`RenderSpan.config`). Span stills
  skip the clock-luma measurement (the clock rect is in canvas coordinates). The answer echoes the
  page's `span` and `hasUpdate` from its ready message; a server without span support ignores the
  key (and echoes nothing), which `SpanCheck` reports as "not checked". `SpanCheck.swift` (Core)
  renders an arrangement once as a whole and once per display and compares each slice with its crop:
  strictly at equal densities (mean ≤ 1.5/255, ≤ 0.5 % of pixels over 8/255), after averaging over
  8-point cells at mixed densities (mean ≤ 4/255).
* **Time limits** (`RenderLimits`): every request runs under the server's own deadline — 60 s, bench
  90 s, motion 150 s, live its (clamped) warm-up and run + 30 s. A request's `timeout` can set
  another, but at most 15 minutes: the server has one render slot for every client on the Mac.
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
livepaper ai create ["<prompt>"] [--ref <image|folder>]… [--animate <image>] [--harness claude|codex|kiro|custom]
                    [--command <template>] [--model <name>] [--timeout <minutes>] [--yes] [--json]
livepaper ai modify <scene-id> ["<prompt>"] [--ref …]… [--animate <image>] …      (same options)
livepaper ai harnesses [--json]
livepaper ai sessions [--json]                     the last week's sessions (app and CLI) and what became of them
livepaper server status|start|stop
livepaper new <id> [--from <scene-id>] | list
livepaper doctor [--no-ai] [--json] | select | uninstall [--yes] [--keep-scenes] [--dry-run]
livepaper publish [--scenes <id,…>|all | --collection <collection>|none] [--mode shuffle|sequence|single] [--cycle <min>]
                  [--performance …] [--clock|--no-clock] [--displays same|different|choose|span]
                  [--display <display-uuid>=<scene-id>|playlist]… [--battery-displays live|still|off] [--json]
livepaper import <video | .lpscene | .zip | .lpcollection> [--name <name>] [--battery] [--json]
livepaper collection list [--json]
livepaper collection show <collection> [--json]
livepaper collection new <name> [<scene-id>…] [--json]
livepaper collection rename <collection> <new-name> [--json]
livepaper collection delete <collection> [--json]
livepaper collection add <collection> <scene-id>… [--at <position>] [--json]
livepaper collection remove <collection> <scene-id>… [--json]
livepaper collection move <collection> <scene-id>… (--to <position>|first|last | --before <scene-id> | --after <scene-id>) [--json]
livepaper collection export <collection> [--out <file.lpcollection>|<folder>] [--force] [--json]
livepaper collection import <file.lpcollection> [--merge|--copy] [--json]
```
`collection` (§4.6): `<collection>` is a name (any letter case), an id, or the start of an id (≥ 4
characters, when only one id starts so); a name several collections share is refused with their ids.
Positions are 1-based. Scene ids must exist (exit 2, like `publish --scenes`); an unknown collection is
exit 2, a taken name or a file that isn't a collection exit 1. `add` skips scenes the collection has
("already in it"), `remove` ones it doesn't. `export` writes `./<name>.lpcollection` by default (a folder
as `--out` gets that name inside it) and refuses to replace a file without `--force`; it reports the user
scenes it included, the built-ins it referenced and the scenes it left out. `import` (also `livepaper
import x.lpcollection`) creates the collection, or — when the library has it — says so and lists what
the file has that the collection doesn't, unless `--merge` / `--copy`. `delete` never deletes scenes. When
the screen saver follows the collection, `add|remove|move|import` keep playlist-settings.json's copy of its
scenes current and publish again if a saver is installed ("updated the screen saver …"; a failed publish
is exit 1), and `delete` leaves the playlist playing its scenes as a list. `--json` prints the collection
`{id, name, scenes, count, missing, playing, created, updated}` (with `changed` and `screenSaver`:
updated / stored / failed for edits; `outcome` created / merged / alreadyPresent, `added`, `lacking`,
`importedScenes`, `existingScenes`, `missing` for imports). `list` marks the collection the screen saver
plays (●). Refused in AI sessions (AISessionPolicy).
`publish --collection <collection>` makes the playlist follow it (a live link, §4.6; "One scene" becomes
"In order" for several scenes), `--collection none` stops following (its scenes stay, as a list);
`--scenes` stops following too, and the two don't mix (exit 2). `--json` adds `collection` and
`collectionName`; the summary says "plays the collection “X” (changes to it update the screen saver)".
`select` is the installer's own selection (`InstallService.selectSaver`, docs/RESEARCH.md §5.6):
`SystemDefault`, every explicit Idle slot and the placeholder of every display record, originals
backed up; nothing is written when every display record already shows the installed saver from a
display's own record (System Settings' selection, whose display placeholders inherit `SystemDefault`,
gets them filled); exit 3 when LivePaper refuses to touch the store (the reason is printed). `doctor`'s
"selected" row is OK only when every display resolves to LivePaper; "N of your M connected displays"
(the store's display records when the connected displays aren't known) or not selected at all is a
problem whose fix it names: `livepaper select`; a store in a format LivePaper doesn't know that names
LivePaper is a warning ("can't tell which displays use it"), never OK.
`publish --display` (repeatable) assigns a scene to a display (UUID, any case, stored uppercase;
"display-<n>" for one without a UUID), `<uuid>=playlist` removes the assignment and `all=playlist` all
of them; scene ids must exist (exit 2, like `--scenes`). Assignments are kept in the settings in every
mode but published only with `--displays choose` (a note on stderr says so when they won't apply).
`--json` adds `displays {mode, onBattery, assignments}` (as published), `displayScenes` and
`spanScenes`; the human summary names the display mode and the battery behaviour when they aren't the
defaults.
`doctor`'s Lock screen section also reports the screen saver's idle time and where it comes from
("idle timeout"), each power source's display-sleep time ("screens off") and "before screens off":
the option from state.json and `LPPreSleepStatus`'s line (OK when on and it applies somewhere, info
otherwise, with a hint to turn it on when it would apply).
`check` = compile → stills at 1512×982@2 for t = 0, 4, 12, 30, 90, 240, 600, plus 32:9 (2560×720
@1, t = 12/90/600), 5:4 (1280×1024 @1, t = 12/90) and thumbnail size (320×200 @2, t = 12) →
JS-error check → motion at 1280×720@0.5 and 1024×820@0.5 (t = 3, 17, 41, 120; gaps 0.5/2/5 s;
16 tiles across; heat maps `.check/motion-<size>.png`) → short probe benches (30 frames) at every
sampled time but the last, to find the heaviest phase → full benches (120 frames) at that time at
1512×982@2 and 5120×1440@1 → luminance checks → (with a reference target, below) resemblance → (for
`"span": true`, not `--quick`) the span check: arrangement B of `SpanCheck.standard` (a 1512×982 laptop
bottom-aligned left of a 2560×1440 display, a 4072×1440 canvas) at 1×, t = 12, clock off, rendered as a
whole and per display (`.check/span-B-t12-*.png`, `span[]` in the report) → optional
live energy run (`--power`, battery profile: 30 fps, 75 %) → writes `.check/report.json` (+ `motion[]`:
coverage, regions, busy, flicker, map per size; + `reference` for animate scenes) + PNGs, prints a short
summary for humans and agents (with the motion map when motion needs attention, and a `picture` line);
exit 0 only if it passes.

`ai sessions` lists the session records (§10), newest first: state (`running` — its agent runs and
the app or CLI that started it is still there; `recovered` — a later LivePaper took it over and nobody
has decided yet; `orphaned` — the agent runs but nothing watches it; `unreviewed` — finished or left
behind without a decision; `accepted`, `discarded`, `failed`, `cancelled`), start, agent, request,
the prompt's first line and the session id; a closing line says that LivePaper offers unreviewed and
orphaned sessions for review the next time it starts. `--json`: an array of {id, state, origin,
startedAt, finishedAt, request, sceneID, prompt, feedback, references (a count), harness, harnessName,
model, workspace, agentPID (while it runs), outcome, message, acceptedID}.

`ai create|modify` without `--ref`/`--animate` prints a note (a `note` event with `--json`) for up to
3 image or folder paths typed into the prompt, suggesting `--ref`/`--animate`: the agent can't open
them. Paths in Desktop/Documents/Downloads/iCloud Drive/cloud storage/volumes (any letter case) are
judged by syntax alone — never looked up, so the terminal gets no privacy prompt for a hint; other
paths get a note only if they exist. Unquoted paths with plain spaces (Finder's Copy as Pathname,
screenshot names) are read whole when the words say where they end — an image name ("Screenshot
2026-11-15 at 10.41.23.png", "heron copy 2.png") or a folder name ending in "/" (not the shorthand
"w/"); otherwise the mention is the shorter path with the longer readings to the end of its clause
(`PromptPaths`): a path that may be looked up gets its note from the reading that exists
(`resolveReadings`; "~/Pictures/Summer Trip for the palette" → `--ref '~/Pictures/Summer Trip'`), and a
protected one, which can't be looked up, says to quote the whole path. `--ref` on a file the terminal
may not open (Files and Folders access) says so (`ReferenceError.notPermitted`) rather than "doesn't
exist".

**Resemblance** (`ReferenceResemblance.swift`; only when `CheckOptions.reference` is set: LivePaper's
final check of a session that animates a picture, and `livepaper check` run inside such a session on its
own candidate, `ReferenceWorkspace.checkTarget`): 7 of the stills (1512×982 t = 4, 12, 90, 600;
2560×720 t = 12, 90; 1280×1024 t = 12; quick: 1512×982 t = 4, 30 and 2560×720 t = 30), decoded at
≤ 192 px, are compared with the picture's cover-fit crop for each still's aspect on a 48-column grid
(cells averaged exactly from summed-area tables), trying 125 framings (zoom 1–1.16, offsets ±6 % of the
crop) so a slow camera is allowed. The clock's cells (its rect + one cell) are filled with the grid's
mean on both sides. For a transparent picture (a cut-out, kept as PNG) the cells of each framing whose
mean opacity is under 0.9 are left out the same way, on both sides, so whatever the scene draws behind
it isn't compared (a picture with less than 20 % of its grid opaque warns "check by eye"). Per framing:
low = Pearson of the 5×5-cell blurred luma, band = Pearson of luma − blur (undefined for a flat
picture), colour = cosine of the blurred chroma (R−G, (R+G)/2−B; undefined for a grey picture, 0 for a
grey still); score = (0.25·low + 0.5·band + 0.25·colour) over the defined parts, negatives as 0; the
best framing counts. A still is flat and scores 0 when its luma std is under max(1, min(3, 0.2 × the
cover-fit picture's own)) — relative, so a soft, bright picture darkened by TASK.md's darkenTo (≥ 0.42)
still counts. Even darkening and contrast changes don't move it. Deterministic checks: scene.js has a
string naming the asset; the asset's SHA-256 is the one LivePaper wrote.
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
| Flicker: tiles whose largest step between successive burst frames (1–8 frames apart: within ¼ s) is ≥ 10 — flashes, strobing, fast whole-frame fades | > 30 % of the frame | |
| Motion not measured (render server too old) | | always |
| `"span": true`: a slice doesn't match its crop of the whole canvas; the scene defines `update()`; scene.js calls `Math.random()` | any | span not checked (render server too old); `gl_FragCoord` without `lp.fragOffset` |
| Animate scenes: scene.js loads `assets/reference.*` (`ReferenceBudgets`) | no string names it | |
| Animate scenes: resemblance to the cover-fit picture (0–1) | median < 0.35 (most stills flat: "too flat", darkened or fogged too much) | a 16:10 still < 0.70; 32:9 or 5:4 median < 0.70 and ≥ 0.25 under 16:10 (stretched / letterboxed); median colour match of the 16:10 stills < 0.3 (desaturated, tinted, recoloured); asset changed; picture too flat to compare (luma std < 4) or < 20 % opaque |

Motion calibration (2026-11, the built-ins as they were before their motion pass, at 16:9 / 5:4;
docs/SCENES.md has the current numbers): Ringed Giant 7 / 9 % in 2 / 1 regions
and Ink and Ember 2 / 2 % in 0 / 0 regions (both judged too static by a person) fail; Abyssal
Lanterns 30 / 41 % (6 / 6), Liquid Glass 47 / 45 % (7 / 7) and Rain on the River 100 % (9) pass.
Busy and flicker stay at 0–1 % for all five (falling rain included); strobing and fast pans
measure 100 %. `LIVEPAPER_SELFTEST_E2E=1 swift run LivePaperSelfTest runtime.e2e.motionBuiltins`
prints the numbers of the built-ins as they are now (`LIVEPAPER_MOTION_DUMP=<dir>` saves the raw maps).

Resemblance calibration (2026-11, `runtime.reference.calibration` on generated pictures — lake, city,
portrait, flowers — at 16:10 / 32:9 / 5:4, the white clock drawn on top): the picture cover-fit with a
camera of up to 12 % zoom and 3 % offset 0.77–1.00, darkened to 55 % 0.95–1.00, with particles
0.87–0.99, fog 0.70–0.96, a dark gradient over the top 45 % 0.76–0.92; greyscale 0.74–0.75; another
picture with the same layout 0.39–0.66 (city, portrait; the lake generator's seeds stay ≈ 0.8, its
layout dominates); mirrored 0.24–0.94 (symmetric pictures stay high); an unrelated aurora 0.01–0.28;
stretched / letterboxed to 32:9 0.13–0.62 against 0.84–1.00 at 16:10. Colour match: greyscale 0
(it warns; its score stays 0.74–0.75, which alone wouldn't), while the camera, darkening, fog,
particles and the gradient keep it at 0.94–1.00; a colour wash that shifts the hue (a warm dusk grade
at 35–60 % over the cool lake, city and portrait, a blue one over the warm flowers) −0.38–0.12 at 16:10
(it warns, at scores of 0.75–0.77), the other washes 0.36–0.83 (no warning). Cut-outs (a dark and a bright one, of the city and the
flowers) shown exactly over black, grey, blue, a dusk gradient or a light sky 0.97–1.00, an unrelated
aurora 0.00–0.14 (compared over black only, the lighter backdrops had scored 0.2–0.3 and failed). A soft,
bright picture (mean 212, contrast 4.4) darkened by its own darkenTo 0.50: 1.00, with fog 0.87–0.96 (0
under the earlier absolute flat-still rule of std < 3); with so little detail an unrelated scene scores
0.36–0.42 there (a warning, not a failure). The design started with 0.4/0.4/0.2
weights; detail now counts most because blurred luma alone correlated 0.69 between the sunset lake and
the unrelated aurora. SCENE_API's example through the real render server (`LIVEPAPER_SELFTEST_E2E=1 …
runtime.e2e.animateScene`): 0.89–0.95 at every size, motion 9/9 regions, 0.4 ms per frame.

`report.json` `benchMs` keys are `"<w>x<h>@<dpr> t=<t>"`; probe benches carry the suffix `" probe"`
(`"1512x982@2 t=30 probe"`) so consumers can tell them from the full benches.

## 10. AI authoring (`LivePaperCore/AI`)
* **Harnesses** (auto-detected on the user's login-shell PATH plus common install directories;
  each probed with `--version`). Every harness runs in the workspace (cwd), in its own process
  group, with `bin/` first on PATH; the prompt only ever travels in TASK.md. `[--model M]` comes from
  the session or `AISettings.models[kind]`; `<extra>` from `AISettings.extraArguments[kind]`.
  * **Login shell** (`LoginShell`, once per process): the user's shell (`pw_shell` if it is a POSIX
    shell, else /bin/zsh) runs `-ilc '<command -v lookups>; env -0'` like VS Code, so it reads what a
    new Terminal window reads: zsh ~/.zprofile and ~/.zshrc; bash ~/.bash_profile (or ~/.bash_login
    or ~/.profile — not ~/.bashrc unless that sources it, as in Terminal). It runs in a session of
    its own (`POSIX_SPAWN_SETSID`: no controlling terminal — from the CLI in a terminal, an
    interactive shell in our session would open the terminal and be stopped by SIGTTOU/SIGTTIN),
    stdin /dev/null, without `TERM_PROGRAM`/`TERM_SESSION_ID` (it isn't that Terminal tab's
    session) and with `LIVEPAPER_RESOLVING_ENVIRONMENT=1`, so rc files can skip terminal-only lines
    (`exec tmux`). Only our marked output counts. If that run prints no marker within 10 s (an rc
    file that execs another program, hangs or is slow), `-lc` is asked the same way (≤ 10 s), so
    ~/.zprofile's PATH still counts.
  * Claude Code: `claude -p --output-format stream-json --verbose --permission-mode dontAsk
    --allowedTools "Read(./**),Edit(./scene/**),Bash(livepaper check *),…" --disallowedTools
    "WebFetch,WebSearch,Edit(./bin/**),…,Edit(./references/**),Edit(./scene/assets/reference.*)"
    --strict-mcp-config --disable-slash-commands [--model M] <extra>`, TASK.md on stdin (none of the
    user's MCP servers, skills or commands are loaded into a session). `dontAsk` denies
    whatever the rules don't allow: reading the workspace, editing ./scene, and `livepaper
    check|still|bench|live|thumbnail|compile|help` (Claude Code checks each part of a compound
    command). `acceptEdits` is not used: it auto-approves edits and mv/cp anywhere in the workspace.
    Claude Code has no image option: its Read tool returns image files to the model as images, and
    `Read(./**)` covers ./references; the deny rules protect the copies and the picture to animate.
  * Codex: `codex exec [-i references/ref-01.jpg]… -C <ws> -s workspace-write --skip-git-repo-check
    --json -o <ws>/.livepaper/last-message.txt [-m M] <extra> -`, TASK.md on stdin. `-i` takes any
    number of values (comma-split), so every `-i` comes straight after `exec`, with workspace-relative
    paths: the longest prefix of ref-01, ref-02, … (ref-01 is the picture to animate) whose total stays
    ≤ 6 MB (`CodexAdapter.maxAttachedBytes`; some providers fail whole turns past a few MB). Codex
    labels attachments by position only ("[Image #1]"), so a prefix keeps "[Image #k]" = ref-0k, which
    is what TASK.md says; it lists them all and Codex's view_image opens the rest. Without references
    the arguments are unchanged. The sandbox keeps its
    defaults (writes only in the workspace, no network). It also blocks the Unix socket `livepaper
    check` needs, so the CLI falls back to the **render spool**: in a session, when the socket
    can't be reached, `RenderClient` writes `<id>.request.json` into `LIVEPAPER_RENDER_SPOOL`
    (`<ws>/.livepaper/render-spool`) and waits for `<id>.response.json`; it never starts a daemon
    itself. `RenderRelay` (in the session runner, outside the sandbox, polling every 0.1 s)
    claims each request and forwards it only if it is a still/bench/live/motion/thumbnail/ping on a
    package inside the workspace; for still/bench/live/motion it compiles the package itself into
    `<Workspaces>/.render-relay/<session>/`, where the agent can't write, so the server never
    renders HTML the agent wrote. Outputs: still and motion (its heat map) keep an `out` that must
    be a `.png` inside the workspace, thumbnail one that must be a `.jpg`/`.jpeg` there; bench and
    live have theirs dropped (the server checks again: RenderOutputPolicy, §8). The server writes
    images there too, never into the workspace (its own rules admit every AI workspace, so a folder
    swapped for a link after the relay's check could aim it at another session): the relay copies
    each one to the agent's `out` itself, through the folder it opened and whose real path it
    checked inside the workspace (`RenderOutputPolicy`, write time). Motion's times, gaps and grid
    pass through unchanged (the server caps them: §8). It drops `timeout` (no scene command sets
    it; the server's own limits apply) and touches the spool only through a descriptor whose real
    path it checked, never through links.
  * Kiro CLI: `kiro-cli chat --no-interactive --agent livepaper-session [--trust-workspace]
    --output-format stream-json [--model M] <extra> "<bootstrap>"` (`--wrap never` instead of
    stream-json, and no `--trust-workspace`, for versions whose `chat --help` doesn't offer them).
    No `--trust-tools`: the session runs as the workspace's own agent,
    `.kiro/agents/livepaper-session.json` (`KiroAgentConfig`), which trusts reads, allows writes
    only under `scene/**` and shell commands only of the form `livepaper <scene command> <plain
    words>` — V2 engine: `toolsSettings` (anchored regex, `denyByDefault`); V3 engine:
    `permissions.rules` (globs, everything else denied) — with no MCP servers or hooks. Anything
    else would need approval, which a non-interactive run can't give. `chat` has no image option
    (`/paste` is interactive only); Kiro sees reference images through its read tool in Image mode
    (TASK.md says so). In sessions with references the write rules also exclude `references/**` and
    `scene/assets/reference.*` (relative, absolute and real paths; V2 `deniedPaths`, V3 an `exclude`
    on the fs_write rule — the V3 form is unverified, LivePaper's restore of the picture is the real
    guarantee).
  * Custom: a template such as `mytool --prompt-file {prompt_file} --cwd {workspace}`; placeholders
    `{prompt_file}` `{workspace}` `{scene}` `{model}` `{instructions}` `{references}` (a lone `{model}`
    token is dropped without a model; a lone `{references}` token becomes one argument per reference
    image — absolute paths of the workspace copies, ref-01 (the one to animate) first — or nothing, and inside a
    longer token the paths joined with commas); POSIX-style quoting, no shell; TASK.md also on stdin.
    Validated by `CustomAdapter.templateProblem`.
  * `<bootstrap>` / `{instructions}`: "Read TASK.md in the current directory and carry out the task it
    describes, following AGENTS.md."
* **Workspace** per session (§4.1): `AGENTS.md` + `CLAUDE.md` (identical: scene rules, API, budgets,
  validation loop, "only edit ./scene"), `TASK.md`, `sdk/` (livepaper.d.ts, SCENE_API.md, templates,
  3 example scenes), `scene/` (template for *create*, a copy of the scene for *modify* without hidden
  entries, agent instruction files or links), `bin/livepaper` (shim to the bundled CLI),
  `.livepaper/` (logs). A modified scene is named by its id; its manifest name only appears as one
  quoted, length-limited line marked as data.
* **References** (`AI/References/`): up to 10 images per session (`ReferenceLimits`), each a
  `reference` (inspiration) or — at most one — `animate` ("animate this exact image"). The app's tray
  and the CLI (`--ref`/`--animate`; folders expand in Finder order, 3 levels deep, links to folders never
  followed) prepare them once, when added, into `PreparedReference`s held in memory
  (`ReferenceImporter`: realpath + lstat, regular files ≤ 100 MB checked before opening, ≤ 120 MP from
  the header, an ImageIO-thumbnail decode at ≤ 3840 px so huge pictures are never decoded in full, a
  redraw into 8-bit sRGB that drops all metadata, re-encoded from the pixels: a master ≤ 3840 px and a
  vision copy ≤ 2000 px / 3.5 MB, JPEG, or PNG when meaningfully transparent — over 0.5 % of the pixels
  not opaque and some clearly see-through; a photo with soft corners or a stray pixel stays JPEG, those
  pixels black — plus a `ReferenceSummary` whose brightness covers the clock at each of the check's
  screen shapes: 16:10, 32:9, 5:4, and `darkenTo` the brightest; the top clock, or for a scene being
  changed that keeps its clock at the bottom, that corner, measured again when the session starts).
  Starting a session numbers them —
  the picture to animate is always ref-01, so the files, the rewritten prompt and the harnesses'
  attachments agree — and writes `references/` (§4.1) and, for the picture to animate,
  `scene/assets/reference.jpg|png` — the master if it fits the compiler's limits next to the scene's
  other assets, else a smaller re-encode (a transparent picture stays PNG down to 2048 px, then
  becomes a sharp JPEG flattened over black; at least 300 KB, else the session is refused:
  `noRoomForAsset` when the scene's other assets take the room, `pictureTooDetailed` otherwise). That
  decodes the picture for its fingerprint and may re-encode it (up to about a second), so the app
  builds the workspace off the main thread. TASK.md gets "Reference images" (what each is, how to look
  at it per harness and which attachment is which, the table of sizes/brightness/palette, and for
  animate: open it first, the cover-fit rules worded by the picture's orientation, brightness per
  screen shape, and what goes behind transparent areas); attached paths typed into the prompt read
  `references/ref-NN…` there (`PromptPaths.rewrite`, no file-system access: the mentions or one of their
  longer readings, and every literal occurrence of an attached file's path or of a folder it came from
  below the home folder — as given, real, `~/…`, with `\ ` escapes, as a file URL, a folder with or
  without its "/" — so "use ~/Desktop/Summer Trip for the palette" reads `references/` (ref-01 …)),
  others are named as not attached. When the harness exits LivePaper puts the picture back if it changed
  (and says so), and the final check compares the stills with it (`CheckOptions.reference`, kept in
  memory — the index in the workspace is in the agent's reach). Nothing is fetched or uploaded; pasted or dropped
  image data stays in memory — LivePaper writes no temporary files (a drop that macOS hands over as a
  file, such as a Photos file promise, is read from macOS's own temporary copy, size-checked first,
  which macOS deletes as soon as it has been read); the attached images' names and paths never reach
  the workspace, logs or history (a path typed into the prompt that names nothing attached stays as
  typed, and TASK.md says it wasn't attached).
* **What an agent may run** (`AISessionPolicy`): every harness process carries
  `LIVEPAPER_AI_SESSION`, `LIVEPAPER_AI_WORKSPACE` and `LIVEPAPER_RENDER_SPOOL` (and not
  `LIVEPAPER_CLI`/`LIVEPAPER_RENDERD`). The shim sets them again and passes on only `check`,
  `still`, `bench`, `live`, `thumbnail`, `compile` (and help/version); the CLI itself, with the
  variables set, refuses every other command (exit 2) and any scene path or `--out` outside the
  workspace (symlinks resolved). So `uninstall`, `publish`, `import`, `new`, nested `ai` sessions
  and `server` control are out of reach whatever the harness's own rules let through.
* **Flow:** create/modify → workspace (+ the session's record) → harness → stdout parsed into events
  (text, tool calls) and `scene/.check/*.png` reported as stills while the agent iterates (again each
  time a later check rewrites a file; the session view reloads that tile) → on exit LivePaper runs the
  check itself (never trusts the agent's word) → preview → "Add to library" / "Replace" (modify keeps
  history; previous version kept in `history/`). Every accept — the app's, a recovered session's,
  `livepaper ai`'s — goes through `AICandidate.accept`: a created scene's id is its name's slug
  (`SceneManifest.slug`, made unique by the library) whatever the candidate's scene.json says (the
  template's "quiet-aurora", an id the agent typed), a modified one keeps its id; the history entry is
  the one the session's finish wrote (`create`/`modify`, harness, model, prompt, summary, reference counts).
* **Stopping:** the harness runs in its own process group, which doesn't die with LivePaper. Cancel
  and the timeout send SIGTERM to the group and SIGKILL 3 s later; whatever the harness leaves in
  its group when it exits gets 1 s. `AISessionTerminating.terminateNow(grace:)` does the same
  synchronously and returns once the group is empty: quitting the app (`applicationShouldTerminate`
  → `.terminateLater`, at most 3 s) and uninstalling (before anything is deleted) use it
  (`AppModel.stopAllAgents`). Both first refuse new sessions and wait (at most 3 s) for sessions still
  being started — their workspaces are built off the main thread and their harnesses launch as the
  start returns — so those agents are stopped too (a start that finishes after that stops its own
  agent); an uninstall that didn't finish allows new sessions again. A cancel
  or terminateNow while the launch is still warming up (login shell, Kiro capability probe, render
  server) never waits for it: the launch stops at its next step and the harness is never started
  (the last check and the spawn are atomic). `livepaper ai create|modify`: the first Ctrl-C/SIGTERM
  cancels (exit 130 once the stream ends); a second one calls `terminateNow(grace: 0)` and exits 130;
  SIGHUP (terminal closed) does the same and exits 129. A signal the CLI was started with ignored
  (SIGHUP under `nohup`) stays ignored, and the previous dispositions are restored once the
  session ends (before the accept prompt).
* **Session records and recovery** (`AI/AISessionRecord.swift`, `AI/AISessionRecovery.swift`). A
  crash, a force quit or a restart of the app (or a killed `livepaper ai`) leaves the agent running in
  its own process group with nobody to read its output, check its scene or stop it. So each session
  has a record, `<Workspaces>/.sessions/<id>/session.json` (§4.1) — next to the workspace, not in it: a
  Codex sandbox and a custom command can write anywhere in their workspace, and the record says which
  process group a later LivePaper may stop and which picture it puts back; and the names it shows stay
  out of the agent's view. The runner (app or CLI) writes it as the session goes (`AISessionRecordStore`,
  read-modify-write under `.sessions/.lock`; decoded field by field, a damaged field gets its default,
  an unknown resolution counts as decided): `request` (create / modify + `sceneID`), `prompt` (as
  TASK.md has it: attached paths already `references/ref-NN…`, earlier feedback included — what
  history records), `feedback` (the chain, oldest first), `references` (role, the name the app shows —
  the file's base name, never a path —, workspace path `references/ref-01.jpg`, format, size, the
  summary) and `animate` (asset path, SHA-256, size, transparent/flattened), `harness` (kind, name,
  executable, version, a custom template), `model`, `timeout`, `clonedFrom`, `sceneBefore` (SHA-256 of
  scene.js as LivePaper left it: the template or the scene being changed), `startedAt`, `runner` and
  `agent` (pid, process group, kernel start time from `proc_pidinfo(PROC_PIDTBSDINFO)` — what tells the
  process from a later one with the same pid), `finishedAt`, `outcome` (passed / failed / cancelled, the
  message, whether LivePaper's check passed and its first problems), `resolution` (accepted with the
  scene id / discarded: Discard, Try Again, a declined CLI prompt, or LivePaper for a session in which
  nothing happened) and `recoveredAt`. Written before the agent starts, with LivePaper's copies of the
  vision images and the picture to animate; the agent's facts once it is spawned; the outcome when the
  session ends (failed or cancelled: the copies go) — `terminateNow` records `cancelled` itself before
  it returns, as the process exits right after (quitting, a closed terminal), so a session stopped on
  purpose is never recovered, while a finished, undecided one keeps `passed` and is offered again;
  the resolution when the user decides (the copies go).
  At launch the app calls `AIServicing.recoverSessions` (off the main thread, after pruning, below), which
  decides each record (`AISessionRecovery.decide`) and claims the ones it takes over — runner := the app,
  `recoveredAt` — in the same locked step, so two LivePapers launched together never both take one:
  * resolved, failed or cancelled → left alone; its runner still runs (the CLI in its terminal, another
    copy of LivePaper) → left alone; its workspace is gone → left alone (pruning removes the record);
  * the agent still runs — the pid exists **and** its start time and group are the recorded ones →
    *watched*: "Still working (recovered)" with no transcript (its output went to the old pipe), the
    stills as usual (`scene/.check/` polled), the render relay again for a sandboxed agent, the time limit
    counted from `startedAt` (past it: stopped as at the timeout), and its exit noticed by a
    `DispatchSource.makeProcessSource(.exit)` on the pid — no polling; it fires at once for a process
    already gone. Then whatever is left in its group gets `leftoverGrace` (a group id isn't reused while
    anything is in it), and the rest is exactly a normal session's: links refused, the picture to animate
    put back from LivePaper's copy, LivePaper's check (with that picture as the reference), the candidate
    normalised (id from the name, the history entry). The exit status isn't known (only the parent gets
    it): the check alone judges;
  * the agent is gone (or its pid belongs to another process now) and scene.js differs from `sceneBefore`
    (or the record doesn't say) → the same check now, with "Recovered: <agent> finished while LivePaper
    wasn't running." — also for a session that passed but was never decided (finishing again is
    idempotent: the candidate keeps one history entry);
  * gone and unchanged → discarded quietly (resolution `discarded`; the workspace goes with the pruning).
  A recovered session's picture to animate is checked against LivePaper's copy (its SHA-256 must match);
  without it the session fails ("LivePaper no longer has its copy of the picture to animate…"). Its
  images for the app (thumbnails, Try Again) are rebuilt from the copies without decoding or opening any
  original (`AISessionRecovery.preparedReferences`: the copy as the vision image, the picture to animate's
  copy as its master). **Stopping** a recovered agent (Stop, Stop All, Discard, the time limit, quitting,
  uninstalling) goes through `AttachedAgent`: SIGTERM to its group only while the pid is still the
  recorded process, SIGKILL 3 s later; `terminateNow` the same synchronously. Nothing ever signals a
  process whose start time doesn't match the record. Uninstall also runs
  `AIServicing.stopOrphanedAgents` after stopping the app's own: agents whose runner is gone that no
  session watches (orphaned since this launch), matched the same way. **Pruning**
  (`WorkspaceBuilder.pruneWorkspaces`, once per run: at the app's recovery or the first session, and when
  the app drops expired sessions) treats a session as old as its workspace or its record's `startedAt`,
  whichever is older; a record goes with its workspace, a record without one goes too; an unreviewed
  recovered session goes after the same 7 days; a workspace whose agent still runs, or whose runner is
  still at work on it (no outcome yet), is never deleted; settled records lose their copies.
* **A session fails when:** the harness can't be found or the template is invalid; it is cancelled
  ("Cancelled."); it runs past the timeout (`AISettings.timeoutMinutes`, default 20, clamped
  1–240; the process group is killed); it exits non-zero (message = exit status/signal + last stderr
  lines or its final message); it exits 0 without changing `scene/scene.js`; the check can't run; or
  the check doesn't pass (first three problems quoted). Only a passing check yields `.finished`.
* Settings (`AISettings` in `ai-settings.json`, via `AIServicing.loadSettings/saveSettings`):
  preferred harness, per-harness model, extra arguments, custom template, timeout.

## 11. App UX (`Sources/LivePaperApp`)
* **Menu-bar extra:** Lock Now (shows the extra shortcut) · what the screen saver plays · Next
  Scene · AI jobs (open / stop all; running and waiting-for-review sessions, recovered ones marked
  "(recovered)", and Stop All stops their agents too) · Open LivePaper · Settings… · Quit.
  Lock Now posts `lockNow` and falls back to ScreenSaverEngine after 1 s (§7). While the password
  isn't required immediately, Lock Now is disabled with a one-line explanation and an "Open Lock
  Screen Settings…" item (the status is re-read when the user leaves System Settings).
* **Main window (NavigationSplitView):**
  * *Library* — grid of live thumbnails (hover = live preview), badges (video/web/AI, energy class).
    ⌘-click toggles a card's selection, ⇧-click adds the range from the last card clicked, a plain click
    opens the card (and ends the selection), Esc or Done ends it (`Logic/LibrarySelection.swift`; cards a
    search or filter hides leave it). While cards are selected a bar shows the count, "Add to Collection ▾",
    Select All and Done; a selected card gets an accent border and a checkmark in its badge row. Dragging
    a card carries every selected card when it is one of them (`SceneDragPayload`, the private type
    `com.nachmore.livepaper.scene-references`), else just it, with a count badge on the drag image.
  * *Collections* (§4.6; `Views/Collections/`, `Model/AppModel+Collections.swift`, `Logic/CollectionText.swift`)
    — a sidebar section: each collection by name with the number of its scenes in the library and a ▶ on
    the one the screen saver plays; context menu Open / Preview Full Screen / Use as Screen Saver / Export…
    / Rename… / Delete Collection…; "New Collection…" (also File › New Collection…, ⌥⌘N). Scene cards
    dropped on a collection are added (dropped back on their own collection: nothing), dropped on "New
    Collection…" they open the sheet for a collection with them; `.lpcollection` and `.lpscene` files
    dropped anywhere on the sidebar are imported. The new / rename sheet proposes "New Collection",
    "New Collection 2", … and says when a name is taken; deleting asks first ("Its 4 scenes stay in your
    library", and when it plays: "The screen saver keeps playing these scenes"). An empty collection
    created from the sidebar opens; one created with scenes stays put and offers Show. A collection's
    screen is the library grid limited to it, in its order: drag a card onto another to move it there (the
    dragged scenes — the selection — take its place; dropped on the empty space they go to the end;
    scenes from elsewhere are added there), the card menu adds Remove from “X” and Move to Collection ▸
    (applied to the selection when the card is selected), and the selection bar Move to ▾ / Remove. The
    header: the name and count, **Use as Screen Saver** (or "Plays in the screen saver" with Screen Saver
    Settings… and the line "The screen saver follows “X”: adding, removing or reordering its scenes
    updates it."), Export…; the toolbar Preview Full Screen (← → step through the collection in its order,
    `FullScreenPreviewSource.collection`; Space on a card starts at it) and More. Empty: a drop zone saying
    how to add scenes. Opening a scene pushes its detail onto the collection's own navigation stack
    (`AppModel.collectionPath`; the Scene menu acts on it); changing screens drops that and the selection.
    **Add to Collection ▸** in the card menu and in the scene detail view's actions lists every collection
    with a checkmark when it has the scene(s) ("Night Skies (2 of 3)" when it has some): choosing a
    checked one takes them out, otherwise adds the missing ones (`CollectionMembership`), then "New
    Collection…" / "New Collection with N Scenes…". The detail view's About lists the scene's collections.
    Banners say what changed ("Added 3 scenes to “Night Skies”", "Moved …", with Show), and deleting a
    scene adds "It was also removed from “Night Skies”."; importing says what came in and what couldn't
    (`CollectionText.importBanner`), with "Add N Scenes" / "Import as a Copy" for a collection the library
    already has.
  * *Scene detail* — full live preview (16:10 and 32:9), Use as Screen Saver / Add to Playlist /
    Add to Collection ▸, Clone, Modify with AI…, Export, Delete, check report, provenance and the
    collections it is in.
  * *Create* — **Video** (drop a file; optional "optimise for battery" HEVC transcode) and
    **Describe it** (prompt, agent + model picker, reference images) → live session view.
  * *AI Sessions* (sidebar, newest first; Stop / Close Session in the context menu). **Recovered
    sessions** (§10 "Session records and recovery"; `AppModel.recoverSessions` in `start()`, after the
    library loads) join the list with a "Recovered" badge (also in the session header) and one banner
    ("Recovered an AI session" / "Recovered 3 AI sessions", Show). One whose agent still runs reads "Still
    working (recovered)", shows the agent's renders but no transcript (the decision panel says why), and
    counts as a running AI job (quitting waits for it like for any agent; `hasAgentsToStop`); its time
    limit is the one it started with, from when it started. One whose agent had finished is checked at
    once. Either ends in the normal review: Preview Full Screen, Add to Library / Replace, Try Again with
    Feedback (same harness, model and references — rebuilt from LivePaper's copies — and the feedback
    chain grows: `AISessionModel.feedback`), Discard. Accept, Discard and Try Again write the record's
    resolution, so a session is never offered twice. Sessions (recovered or not) that aren't running and
    started more than the workspace retention (7 days) ago leave the list (`expireOldSessions`, at
    recovery and on each refresh from disk — the app becoming active) and their workspaces are pruned.
  * *Reference images* (`Views/Create/ReferenceTrayView.swift` over `Logic/ReferenceTray.swift`;
    the Describe-it card, between the prompt and the ideas, and — with smaller tiles — the Modify
    with AI sheet). Ways in: ⌘V in the prompt box (`Views/Common/PromptTextView.swift`, an
    NSTextView whose paste hands images to the tray and pastes text as usual; it enables Paste for an
    image-only pasteboard such as a screenshot), ⌘V while the tray or another control of the card has
    focus (`onPasteCommand`), drops anywhere on the card or sheet (Finder files and folders, Photos,
    a browser's image data; the prompt box takes image drops itself and leaves text drops alone), and
    "Add Images…" (an open panel for images and folders, several at once). Images, folders and
    pasted/dropped image data are prepared when added — off the main thread, one at a time — and the
    session's workspace is built off the main thread too (Generate / Start / Try Again wait
    meanwhile, `AppModel.isStartingSession`); at most 10 (failed ones don't count), duplicates by
    real path skipped, a note for whatever was left out (also for a folder with no images in it, and
    for the documents of a pasted or dropped Finder selection, which become one note, not failed tiles). Each tile (88 pt, 72 in the sheet; the
    thumbnail is the prepared copy decoded small off the main thread through `ThumbnailCache`) has a
    remove button, a role menu ("Reference — inspiration for style, colours and composition" /
    "Animate this image — the scene shows this exact picture, brought to life"; choosing it for one
    demotes the other, once that one is ready — an image that fails to prepare leaves the current
    choice alone; the picture to animate gets an accent border and a film badge), the same in
    its context menu, Delete when focused, and a VoiceOver label ("Reference image 2 of 4,
    sunset.heic, animate") with Remove / Animate actions (Animate only on ready tiles). Images that can't be added stay as marked
    tiles with the reason listed under the tray (and, on the Create card, in a banner); "Preparing 2
    images…" replaces the footer line and Generate / Start wait meanwhile. With images attached the
    prompt may be left empty (`PromptComposer.effectivePrompt` asks for the default request — in the
    Modify sheet one worded as a change to the scene, which the agent keeps). Paths
    typed into the prompt are offered, about 0.4 s after typing pauses, as "Attach" chips ("The agent
    can't open “refs” on your Desktop. Attach copies of its images?" — Attach Folder, or Attach /
    Animate It for an image; × hides it; once clicked a path isn't offered again); never attached
    silently, and paths in Desktop/Documents/Downloads/iCloud Drive/cloud storage
    (`~/Library/CloudStorage`)/volumes, in any letter case, aren't looked at until clicked, so typing
    never raises a privacy prompt. A click LivePaper isn't allowed to follow (access to that folder
    declined) gets a note saying what works instead (drag it in, Add Images…, or Files and Folders in
    System Settings), not "wasn't found". Unquoted paths with plain spaces are read whole when the words
    say where they end (screenshot and other image names, a folder name ending in "/"); otherwise the
    chip names the shorter path, and the lookup — while typing for unprotected paths, on the click for
    protected ones — tries the longer readings word by word, and the shorter one when a longer reading
    isn't there (`PromptPaths.resolveReadings`: "~/Desktop/Summer Trip for the palette" attaches the
    folder "Summer Trip"). In the prompt box Tab moves to the next control and quotes and dashes
    stay as typed (paths and code survive). `ReferencePasteRules` decides whether a paste is images
    (a screenshot, Finder copies of images or folders, Safari's Copy Image) or text and what it
    holds; `ReferenceDropReader` turns drops into files, image data or — for web URLs — a note
    (nothing is downloaded). The session view shows the session's references (header "· 3
    references"; a References box of thumbnails with the "Animate" badge, from the copies held in
    memory, as the workspace's are pruned after a day), and a session keeps its prepared references,
    so Try Again / Try Again with Feedback / Start Again reuse them (`AppModel.retry`) — of the
    full-size masters only the picture to animate's, and not even that once the session is accepted
    (`AISessionModel.slimmed`; this menu-bar app runs for days). A check
    report of an animate session adds "Looks like the picture: 0.92" (§9), and the scene's history
    "· 3 reference images (1 animated)".
  * *Screen Saver* — the playlist draft (scenes, order, cycle, clock, multiple displays, profile) →
    Save & Publish; a publish that left scenes out lists them with the reason (and a banner says so).
    **Play** (`PlaylistSource`, `PlaylistDraft.setSource`): All scenes (new ones join) / Scenes you
    choose (ordered, removable, "Add Scene") / a collection (§4.6: "The screen saver follows “X”: …" with
    Edit Collection and its scenes, read-only, in order; "“X” is empty, so the screen saver plays every
    scene"; a deleted one says so). Choosing scenes starts from what plays now (a copy of a collection's
    scenes, which no longer follows it). The summary — publish bar, menu bar, sidebar footer — starts with
    the collection's name ("“Night Skies” · Shuffle · 4 scenes · every 5 minutes"); the menu bar's Preview
    Full Screen plays what the saver plays.
    **Multiple displays** (`Views/Playlist/DisplaysSection.swift` over `Logic/PlaylistDraft.swift`;
    always shown, between Playback and Performance): the display mode (*Same on every display* /
    *Different on each display* / *Choose per display* / *Span across displays*, §4.3, §6) with a
    one-line explanation; a small picture of the arrangement (System Settings › Displays, scaled,
    numbered, the main display tinted, one gradient across all of them while spanning); the connected
    displays in the saver's order — number, `NSScreen.localizedName`, a "Main" tag (the built-in
    display, else the menu-bar one), size, context menu "Copy Display ID"; with one display, "Only
    one display is connected. These settings take effect when you connect another." *Choose* gives
    each connected display a picker ("Playlist" + every library scene; a deleted scene shows "Scene
    deleted — plays the playlist") and lists the choices of displays that aren't connected ("<name>
    (not connected)" — scene — Forget), named from `displayNames` (recorded when a scene is
    chosen, pruned to assigned displays; "Display 37D8832A" for one assigned elsewhere, e.g. by the
    CLI). Choices stay in the settings in every mode but are published only in *Choose*, and only
    for scenes that still exist (`PlaylistDraft.effectiveAssignments`, as PublishService does).
    *Different* says when the playlist has fewer scenes than there are displays (some then share
    one). *Span* says how many of the playlist's scenes can span (`SceneManifest.spans`: "3 of 5 scenes
    can span; the others show on every display.", naming up to four that can't). "On battery, other
    displays show": the scene / a still picture / nothing (black), with the footnote that the main
    display always shows the scene. The connected displays come from `AppEnvironment.connectedDisplays`
    (live: `Entry/DisplayProbe.swift`, `NSScreen.screens` keyed and framed exactly as the saver does
    — `Logic/DisplayIdentity.swift`: the UUID of `CGDisplayCreateUUIDFromDisplayID` uppercased, else
    "DISPLAY-<id>"; `LPDisplay.cocoa` with the menu-bar screen's height — so choices name the displays
    the saver sees) and are re-read on `NSApplication.didChangeScreenParameters`
    (`observeDisplays`) into `AppModel.displays`. The summary in the publish bar, the menu bar and
    Settings adds the mode when it changes what plays (" · different on each display", " · chosen
    per display", " · spanning all displays"; not with one display for Different and Span). A scene
    chosen for a display counts as one the saver has (`AppModel.isShownBySaver`): replacing or
    AI-modifying it republishes, and deleting it republishes without it (the choice stays, shown as
    deleted). The full-screen preview stays single-screen.
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
  `thumbnail.jpg`, `history.jsonl`, `.check/report.json`, `scene.js` and `assets/` (what the live
  previews compile), `playlist-settings.json` and `collections.json` count (a collection on screen that
  was deleted elsewhere goes back to the library);
  a burst becomes one refresh about 0.5 s after the last change (FSEvents latency 0.2 s + a 0.3 s
  debounce, at most 2 s). Becoming active and opening the main window refresh too, as a safety
  net. Refreshes are quiet: no loading state, unchanged data isn't reassigned (selection, scroll
  position and an edited playlist draft stay put), and nothing runs while nothing changes. Compiled
  previews are keyed by a stamp of what they are compiled from (scene.json, scene.js, assets/), so
  an edit that leaves `updated` alone (an editor, `livepaper check`) recompiles them too.
* **Saver update at launch:** the saver's code lives in `~/Library/Screen Savers`, not in the app,
  so after an app update the installed copy is the old build. At launch the app replaces it with its
  bundled build and republishes (`InstallServicing.updateSaver`) — only when the installed build is
  older (CFBundleVersion, the commit count: an older LivePaper launched next to a newer one never
  downgrades it; an explicit install in setup replaces any build), only while one is installed,
  never after an uninstall (the marker stays) and never while the Mac is locked. The lock, the
  versions and the marker are checked again under `publish.lock` right before the swap, and
  uninstall removes the bundle under the same lock. It runs alongside the rest of the launch;
  uninstall and setup wait for it. When the Mac is locked at launch (or locks before the swap) the
  app logs it and waits for the next unlock: it observes `com.apple.screenIsUnlocked` (distributed,
  object = the uid string, `.deliverImmediately`; `SessionUnlockObserver`) only while an update is
  pending, and on the unlock stops observing, re-reads the status and tries once more (a Mac locked
  again by then waits for the following unlock). Uninstall ends the wait; uninstall and setup wait for
  what an unlock started, and no saver update starts while either runs.
* **Helper repair at launch:** see §7 — the app registers the helper's login item again by itself
  (once per launch, only in the copy the helper belongs to) when launchd can't run this build's helper.
* **Selected on every display** (`InstallStatus.saverSelection`, docs/RESEARCH.md §5.8): selected
  means every display record of the wallpaper store resolves to LivePaper; "partly" (some do) shows
  as "Not on N of M connected displays" (`WallpaperSystem.connectedDisplayIDs`: CoreGraphics display
  UUIDs, the store's display keys; without them, of the store's display records) in Settings ›
  Screen Saver, the setup page and the sidebar footer ("Not on every display"), and before Lock Now,
  each with **Use LivePaper on Every Display** (the same `makeLivePaperScreenSaver` as setup; the
  guided step if macOS doesn't let LivePaper). A store LivePaper can't read that names LivePaper is
  `.unknown`: an optional setup row and "Open Screen Saver Settings", no claim either way.
* **Quiet re-apply** (`InstallServicing.reapplySelectionIfNeeded`, docs/RESEARCH.md §5.6): when the
  status says LivePaper owns the selection, is still chosen in some Idle slot, and a display record
  shows macOS's default — or inherits LivePaper from `SystemDefault` / a Space's `Default`, which the
  agent derives from the displays — only because its own Idle slot holds the placeholder
  (`InstallStatus.selectionReapplyNeeded`; a display connected after something reset `SystemDefault`),
  the app gives those placeholders LivePaper — never an explicit choice, so never a screen saver the
  user picked; originals already recorded stay. The uninstall marker, the manifest and the saver are
  checked again under `wallpaper-store.lock`, so an uninstall in another process is never
  re-selected over. At launch (after the saver update) and
  on `NSApplication.didChangeScreenParametersNotification`, once a burst of changes has been quiet
  for 3 s (`AppEnvironment.screenChangeSettleDelay`): at most once per burst. Not while the Mac is
  locked (it observes the next unlock, then reads the status again) and not while other install work
  runs (it runs once that ends); setup and uninstall wait for a running one, and uninstall ends the
  unlock wait. Quiet: only a change that was written but not confirmed shows a banner.
* *Settings* — Screen Saver (status — every display, not on N of M displays, not selected — and setup),
  Lock (**one** toggle "Use ⌃⌘Q and the lock key for LivePaper lock" + the optional extra shortcut
  recorder + helper status with Start Helper / Repair Helper / Open Login Items, or Use This Copy's
  Helper while another copy's runs; "Screens turning off": the toggle "Show your scene when the
  screens turn off first" (state.json, off by default, §7) with its one-line trade-off — moving the
  mouse in the last few seconds before the screens turn off then asks for the password — and a status
  line from `InstallStatus.screenTimers` + `passwordImmediately` through `LPPreSleepStatus`, the
  helper's own facts: "Applies on battery: screens off after 5 min, screen saver after 15 min" / "Not
  needed: the screen saver starts before the screens turn off" / "Off: your password isn't required
  immediately …"; the pane re-reads the install status when it appears), Performance (profile), AI
  (default agent, per-agent model, time limit, custom command), About (+ Uninstall).
* **Onboarding** (first launch; re-runnable, every step idempotent and showing live status), 4
  steps: Welcome → Screen saver (install, select — with backup, or a guided one-click step in
  System Settings) → Locking (lock keys toggle, "require password immediately", helper login item,
  including "waiting for approval in Login Items" and "can't start" with Repair Helper) → First scene
  (pick what plays).
* **Uninstall** (Settings › About): shows exactly what will happen, then runs
  `InstallServicing.performUninstall` and shows the step log (done / nothing to do / failed with the
  reason). Steps: mark LivePaper as uninstalled (`LivePaper.uninstalled`, §4.1), unregister and stop
  the helper, switch every screen-saver slot that is still LivePaper's back (recorded original, else
  the placeholder, else for SystemDefault the pre-LivePaper choice or macOS's Message saver; display
  records that would inherit an explicit choice put back into SystemDefault or a Space's Default get
  it themselves; confirmed by what every display shows — docs/RESEARCH.md §5.7), restore the lock
  keys, restore other changed preferences, remove the saver (only once the store, re-read, no longer
  points at it), delete LivePaper's data (optionally the library; backups/ stay if any step failed).
  If the screen saver can't be switched back automatically, or the restore isn't confirmed, the step
  fails, names the saver from before LivePaper, and says to pick it (or another) in System Settings
  and run uninstall again. Failures can be retried (finished steps are skipped); on success the app moves itself to
  the Trash and quits.
* **Document type:** `.lpscene` (`com.nachmore.livepaper.scene`, a package conforming to
  `com.apple.package`). Opening one (double-click in Finder, Import Scene… in the File menu and in
  the Library toolbar) goes through `LibraryServicing.openPackage(at:)`: `existingScene(matching:)`
  and, when that finds nothing, the import, as one step under the library's lock (so the same new
  package opened twice at once — two copies selected together, a second double-click while the
  first copy is still running — is imported once). A package that is a library or built-in scene
  (the same file), or has the same contents as one (`ScenePackageComparison`: the scene's files
  byte for byte plus kind, runtime, clock and video settings; scene.json metadata, thumbnail,
  history and `.check/` don't count), just opens that scene. Another version of a user scene —
  its id (or `id-2`, … from an earlier import) and its `created`, which export, import, AI modify
  and Replace keep, but other contents — opens that scene with a banner offering "Replace with
  This Version" (`replaceContents`, previous version kept in history) or "Import as a Copy". A
  shared id alone is no evidence (ids are name slugs: two people's "Aurora Lake copy", "Untitled
  Scene"), so such a package is imported as a copy, as is anything else. The CLI's
  `livepaper import` always imports.
  `.lpcollection` (`com.nachmore.livepaper.collection`, a zip conforming to `public.data`; §4.6):
  double-click in Finder, File › Import Collection… (⇧⌘O, several at once) and drops on the sidebar go
  through `AppModel.importCollection` (`CollectionServicing.importCollection`, `.automatic`). Info.plist also
  declares the private drag type `com.nachmore.livepaper.scene-references` (never written to disk).
* **Replacing a scene in the playlist** ("Replace with This Version", accepting an AI modify)
  publishes the playlist again, quietly, when the saver is installed: the saver plays the copies
  compiled at publish time, not the library. (The CLI leaves that to `livepaper publish`.)
* **Banners** stack at most 4; when a new one doesn't fit, the oldest that would go away on its own
  (info, success) makes room first, then the oldest without actions, so a warning waiting for a
  decision survives a burst of others (e.g. opening many packages at once).
* **Developer modes:** `LIVEPAPER_MOCK=1` runs on sample data in a temp directory with mock
  services (nothing on the system changes; Lock Now only shows a notice). Debug builds:
  `.build/debug/LivePaperApp --snapshot <dir> [--only name,…]` renders every key screen with mock
  data to PNGs and exits (`.prohibited` activation policy, off-screen windows, no live previews);
  `create-references-light`, `modify-references-dark` and `session-references-light` show the
  reference tray, the sheet's compact tray and a session's references with generated pictures;
  `session-recovered-dark` a recovered session whose agent still runs (`MockAIService.recoveredRunningSession`);
  `playlist-displays-choose-light`, `playlist-displays-span-dark` and `playlist-displays-single-light`
  the Multiple displays section with mock displays (`MockSampleData.displays`: a built-in 1512×982
  display with the menu bar and a 2560×1440 one to its right, made-up ids; mock mode uses them too).
  Mock mode and the snapshots also have sample collections (`MockSampleData.collections()`: Night Skies,
  Calm Water and an empty Warm Evenings, fixed ids) through the real CollectionService over the mock
  library; `collections-select-light` (three cards chosen, the selection bar, the sidebar section),
  `collection-dark` (a collection the screen saver follows), `collection-empty-light`,
  `sheet-new-collection-light`, `sheet-delete-collection-dark` and `playlist-collection-light` (Play: a
  collection) show them.

## 12. Performance & battery policy
* Budgets enforced by `livepaper check` (§9), shown in the UI as energy badges.
* Automatic profile: 60 fps full-res on AC; 30 fps @ 75 % on battery / Low Power Mode.
* Pause when displays sleep; exit the saver host on willstop; video scenes use hardware decode.
* The helper's "before screens off" (off by default) arms one one-shot timer per display-sleep
  period while on, and nothing while off (§7).
* Governor steps render scale down (to 0.6) if frame time stays over budget for 2 s (off while a
  scene spans displays: every display must draw the same).
* Multiple displays on battery or in Low Power Mode: the displays other than the main one show the
  scene, a still (nothing runs) or nothing, per the playlist's `onBattery` (§6); videos shown on
  several displays decode once.

## 13. Milestones
1. Core + runtime + RenderService + CLI `check` (AI-ready framework).
2. Saver (web + video + clock hand-off) and publish pipeline.
3. Helper (shortcut + Lock Now + open-app relay).
4. App: library, create (video, AI), clone, modify, settings, onboarding, uninstall.
5. Built-in example scenes generated through LivePaper's own AI pipeline.
