# LivePaper.saver

The screen saver that LivePaper installs into `~/Library/Screen Savers`. On macOS 26 the screen
saver is also the live lock screen, so this bundle is what users see when their Mac locks.
See `docs/ARCHITECTURE.md` §1 and §6 for the contract; this file explains how the saver meets it
and how to build and test it.

## Files

| File | What it does |
|---|---|
| `LivePaperSaverView.swift` | Principal class (`@objc(LivePaperSaverView)`). Lifecycle, run gate, scene selection, displays (in-process join, display plan, live/still/off), crossfades, recovery, system events. |
| `SaverLogic.swift` | All pure, Foundation-only decisions: playlist validation (and display-only scenes), sessions/epochs (and per-display history), deck order (with a spread for several displays), schedule, the display plan of every mode and span geometry, back-off, run gate and its policy, lock-UI state, clock geometry/format, web bridge JSON, Options summary. Unit tested. |
| `SceneHost.swift` | The interface between the view and one scene on screen (`SceneHost`, `SceneContext`). |
| `WebSceneHost.swift` | Web scenes: `PassiveWebView` (WKWebView), injected `LIVEPAPER_CONFIG`, `livepaper` message handler, host calls. |
| `VideoSceneHost.swift` | Video scenes: `AVPlayerLayer` + `AVPlayerLooper`, muted, with the native clock; one shared player per file for every display (`SharedVideoPlayers`), spanning by layer geometry, a still frame on battery. |
| `ClockOverlay.swift` | Native lock-screen-style clock (`CATextLayer`s), once-a-minute ticks aligned to the minute. |
| `FallbackSceneHost.swift` | Built-in scene when nothing is published or every scene failed. |
| `OptionsSheet.swift` | The "Options…" sheet: read-only summary and "Open LivePaper…". |
| `SaverSupport.swift` | os_log (incl. the `lifecycle` category), power source, notification relay (incl. screen changes), session-lock, display-sleep and ScreenSaverEngine/frontmost-app queries, displays (`SaverDisplays`: keys, arrangement), dev-host overrides, ScreenSaverDefaults store. |
| `Info.plist`, `Resources/thumbnail*.png` | Bundle metadata; System Settings thumbnail (drawn by `scripts/dev/render-saver-thumbnail.swift`). |

The saver also compiles `Sources/LivePaperCore/Playlist/PlaylistModel.swift` (the playlist
contract), `Sources/LivePaperCore/Playlist/DisplayLayout.swift` (display keys, arrangement, virtual
canvas) and `Sources/LivePaperCore/Render/SceneNavigationGate.swift`; it has no other dependency on
LivePaperCore.

## Behaviour

**Lifecycle and the run gate.** After every unlock WallpaperAgent spawns a hidden,
never-presented saver instance so the next start is fast. Web scenes must run with WebKit's
occlusion detection disabled (the host window is always reported as occluded, so WebKit would
otherwise never draw), which means that hidden copy would animate for as long as the user works —
about 45 % of a CPU core in the prototype. So a real (non-preview) instance renders only while
**all** of these hold (the pure `SaverRunGate` in `SaverLogic.swift`; video scenes obey it too):

1. `startAnimation` has been called, `stopAnimation` hasn't, and willstop hasn't arrived;
2. something says a saver is actually up — any of the signals switched on in `SaverGatePolicy`:
   the session is locked (`CGSSessionScreenIsLocked` at `startAnimation`, then
   `com.apple.screenIsLocked`/`…IsUnlocked`), loginwindow posted `com.apple.screensaver.didstart`
   (cleared by `didstop`, `willstop` and unlock; remembered per process so a view created after it
   still knows), or ScreenSaverEngine is running;
3. the displays are awake (`NSWorkspace.screensDidSleep/Wake`, `CGDisplayIsAsleep` at start).

Nothing is loaded before that — not on `startAnimation` alone, not from `viewDidMoveToWindow`, not
while the displays sleep (a lid-close lock loads on wake). It pauses on unlock, didstop,
`stopAnimation` and display sleep, and 5 s after its gate closed for good (unlock, didstop,
`stopAnimation`; not display sleep) it frees its web view or player — and with it the WebContent
process — so nothing stays resident and the next run reads the playlist again. The 5 s keep the
last frame up during loginwindow's fade-out. Previews (`isPreview || width < 500`, because
`isPreview` is unreliable in the macOS 26 host) render once started, but pause while the session
is locked, while the displays sleep, while System Settings isn't the frontmost app, and while
their window is ordered out, miniaturised or occluded (each window signal is trusted only after it
has once said "visible"). Previews' web scenes are capped at 15 fps.

**The run gate: what is verified and what is assumed.** Every lifecycle step is logged, one line
each, at notice level (persisted) in category `lifecycle`, with a per-process view id (`v1`, `v2`,
…), the gate's inputs and decision, the time since init and since `startAnimation`, the number of
other views of the same process that are running, and the window's state:

```sh
/usr/bin/log show --last 2h --style compact \
  --predicate 'subsystem == "com.nachmore.livepaper.saver" && category == "lifecycle"'
```

| Signal | Status (macOS 26.7) |
|---|---|
| A hidden prewarm instance after every unlock | **Verified** (log: a replacement `legacyScreenSaver` ~0.2 s after each `_screenSaverStop`). |
| The prewarm gets `startAnimation` | **Inferred** from the prototype's CPU use, never logged. |
| During a presented run the prewarm view and the presented view live in the same process | **Inferred** (two ViewBridge "did terminate" lines per exit). Both then receive the same notifications; `othersRunning` shows whether both render. |
| `com.apple.screenIsLocked` / `…IsUnlocked` are posted on every lock, direct locks included | **Verified** (loginwindow log). Their delivery into the sandboxed host is assumed, as for `screenLockUIIsShown`. |
| `CGSSessionScreenIsLocked` is present only while locked | **Verified** (`CGSessionCopyCurrentDictionary`). |
| `com.apple.screensaver.didstart` is posted for every saver start (idle, hot corner, ScreenSaverEngine, lock keys) | **Verified in disassembly**: `-[ScreenSaverDaemon _screenSaverStart:]` posts `didlaunch` (object = a UUID, options 3) and `didstart` (object `"runFromPref"` or `""`, userInfo `{runFromPref}`, options 1 = deliver immediately) on the distributed center. **Unverified:** that it reaches the sandboxed host (it carries a userInfo), when it arrives relative to `startAnimation` and `screenIsLocked`, and whether a hidden prewarm view gets it too. |
| `willstop` precedes the host's exit; `didstop` ends a run | `willstop` **Verified** (clean `exit(0)` 0.5 s later, 15/15). `didstop` **Verified in disassembly** (ScreenSaverEngine quits on it); its delivery to the saver is assumed. |
| ScreenSaverEngine runs exactly while a saver it started is up | **Verified in disassembly**: on macOS 26 it only calls `SACScreenSaverStartNow` and idles until `didstop`. Querying it from the sandbox (`NSRunningApplication`) is assumed to work; it is re-read on every lifecycle event because the launch notification may not be posted for this background app. |
| System Settings' preview host: frontmost-app and window visibility signals inside the sandbox | **Unknown.** An unknown frontmost app counts as "in front"; window signals that never say "visible" are ignored. |
| All displays' views run in one host process | **Verified** (lifecycle log of a real lock with two displays: two views, one pid, `new` then `joined` session 100 ms apart). |
| `NSScreen.screens`, `window.screen`, `CGDisplayCreateUUIDFromDisplayID`, `CGDisplayIsBuiltin` in the sandbox | **Assumed** (the `load` line logs the arrangement and this view's display; an unknown display plays as if alone). |
| `NSApplication.didChangeScreenParametersNotification` in the host | **Unknown** (the arrangement is also re-read at every start and when the window changes screen; `event=screensChanged` shows it arriving). |
| A view is created for a display connected mid-run | **Unknown** (if so, it joins the running views' session in-process). |
| macOS's lock-UI clock on displays other than the main one | **Unknown** (every display hands its clock off as before). |
| One `AVPlayer` behind several `AVPlayerLayer`s | AVFoundation-documented; **assumed** in this host (`sharedLayers` in the video host's diagnostics). |

Questions the logs answer: does the prewarm view get `startAnimation` (an `event=startAnimation`
long before any lock)? Does `event=saverDidStart` arrive at real starts, and before or after the
presented view's `startAnimation`? At a direct lock (⌃⌘Q with the lock keys off, lid close), is
there `run (locked)` without a `saverDidStart` (the remaining waste, below)? Is `othersRunning`
ever above 0 during a run?

**Adjusting the gate.** `SaverGatePolicy.standard` in `SaverLogic.swift` is the one place:
`sessionLockOpens`, `didStartOpens`, `engineOpens` (and `previewFPS`). The self tests
`saver.gate.*` say what each switch does. Once the logs show `didstart` arriving for idle,
hot-corner, lock-key and LivePaper starts, turning `sessionLockOpens` off stops a prewarmed
instance from rendering behind direct locks; until then it stays on, because a lock that never
hears `didstart` would otherwise stay black.

**Stopping.** `stopAnimation` is often never called on macOS 26 and views aren't released between
runs, so non-preview instances `exit(0)` the host 0.5 s after `com.apple.screensaver.willstop`
(keeping the scene up during loginwindow's fade). Previews ignore it — the System Settings preview
lives in a host that must keep running.

**Playlist.** `Contents/Resources/Playlist/playlist.json` is read once per run (previews also
reload on `com.nachmore.livepaper.published`). Entries are kept only if their file is a plain name
inside `Playlist/` with a matching extension (`html`/`htm`, `mov`/`mp4`/`m4v`) and exists; problems
are logged. A missing, unreadable or empty playlist shows the fallback: a dark gradient, the
native clock and "Open LivePaper to choose a scene".

**Displays.** Every display's view runs in the same host process. Each view finds its display
(`window.screen` → `NSScreenNumber` → `CGDisplayCreateUUIDFromDisplayID`, uppercase — the wallpaper
store's form; "DISPLAY-<id>" without a UUID), the arrangement (`NSScreen.screens`, turned into
top-left global points), its index in a stable order (left edge, then top edge, then key) and the
main display (the built-in one if it is on, else the menu-bar screen) — at every start, on screen
changes and when its window moves to another screen — and logs them on the `load` line
(`display 2/3 main=0 mode=different liveness=still lead=0 key=37D8832A`). The playlist's `displays`
setting (`SaverDisplayPlan`) then decides what it shows: *same* (as before); *different* (display k
plays k steps ahead in the deck); *choose* (its assigned scene, from the deck or `displayScenes`,
without cycling; the playlist when it has none or the scene keeps failing); *span* (a step whose scene
supports it is drawn across all displays: each shows its viewport of the union of all frames; the
others play as *same*). Different and span need two displays. Previews, and a display the view can't
find in the arrangement, play as *same*. On battery or in Low Power Mode every display but the main
one follows `onBattery`: the scene, a **still** (web: the page loaded paused with its clock hidden —
one frame, no frame loop; video: one decoded frame, no player; fallback: no clock or hint; still
displays still cycle with the playlist, one page load per cycle) or **off** (no scene, no timers:
black; with span the main display then shows the whole scene). Power and screen changes are followed
live (`event=displays reason=power|screens|window`): another scene or slice crossfades in, live ⇄
still switches in place.

**Spanning.** All displays share the seed and the time origin (the step's start, wall clock), so
web slices line up frame for frame (`timeOrigin` in `LIVEPAPER_CONFIG`; the runtime offsets the
page's drawing, SCENE_API.md §16); the runtime's governor is off. There is one clock, on the main
display, placed by the scene's clock position inside that display: web pages get the main
display's viewport as the clock box (`lp.clockRect` is the same on every display), video and
fallback scenes create a native clock only there. A spanning video is one shared player whose layer
is framed as the whole canvas, offset by −viewport, and clipped by the host view.

**Shared video.** Displays showing the same video (same file and publish) lease one `AVQueuePlayer`
+ `AVPlayerLooper` (`SharedVideoPlayers`), each with its own `AVPlayerLayer` and readiness: it plays
while any lease runs (each display still pauses with its own gate) and is released with the last
lease; a looper failure fails every leaseholder, and their retries create a fresh player.

**Scene selection.** `shuffle`, `sequence` or `single`. Every display decides independently but
identically: a display joins the session recorded by another display if that session is still
running (no willstop yet) and started less than 45 s earlier. Otherwise it starts a new session in
the current 30 s epoch, or one past the previous session's epoch when that is the same or later (a
quick unlock → lock), so the shuffle always changes; such a session starts at the actual time, not
at an epoch boundary. A stored epoch more than a day ahead of the clock is ignored. The epoch seeds
the shuffle (SplitMix64, identical on every architecture) and the web scenes' `seed`. The record
keeps the recently shown scenes (up to 12, newest first): a new shuffle session never starts with
the scene shown last or with any of the newest ⌊n/2⌋ of an n-scene deck, so repeated locks walk
through the deck, and sequence continues after the scene shown last. Each shuffled pass is
reshuffled without repeating across the pass boundary. What a session's first scene avoids is
frozen in the record when the session starts (`startRecent`), so a display that joins builds the
same deck. By then the history already holds the scene the first display is showing. A view that
starts while another view of the same process runs joins that view's session in-process, however
old it is (a display connected mid-run must share the time origin); the store-based join above is
the fallback. With *different*, display k plays step s + k of a deck whose `spread` is the number of
displays: any d consecutive steps are distinct (across reshuffles too, so the displays differ
whenever the deck has at least d scenes; with fewer, display k matches display k + n), the start
avoids the newest min(⌊n/2⌋, n − d) recent scenes in all d positions, and no display starts with the
scene it showed last (`shownOn`, display key → scene, frozen at the session start as `startShownOn`);
with n ≥ 2d nothing that was on screen at the end of the last session comes back first. Only the last
display in order that shows anything writes `lastShown`, so *sequence* continues after it. With
`spread` 1 the deck is exactly the single-display one (`saver.deck.spread1MatchesLegacy`). Scene changes
happen every `cycleMinutes` at wall-clock steps from the session start, so displays switch together
and a view that slept catches up. Changes crossfade (2 s; first reveal 0.6 s). Bookkeeping is a
single blob in ScreenSaverDefaults (see the pitfalls in `SaverSupport.swift`); previews never write
it. Each display adds the scenes it shows to the stored record when that record is its session or
a newer one (any later epoch, however long after its own session began — a display docked days into
a lock that never ended — unless it is a day or more ahead of the clock), and willstop marks the
stored record ended, so displays writing in any order keep each other's history.

**Web scenes.** `loadHTMLString(_:baseURL: nil)` (scenes are self-contained; the sandboxed
WebContent process couldn't read the bundle anyway), non-persistent data store, no navigation away
from `about:`/`data:`/`blob:`. `window.LIVEPAPER_CONFIG = {clock, clockPosition, fps, scale, seed,
power, lowPower}` is injected at document start using the runtime's keys (plus `lockUI`; the span
keys and `timeOrigin` on a spanning step; `paused` for a page created paused — a still display, or
while the gate is closed). The page reports
`{type:'ready'}` (or `ready` with `failed:true` when the scene never registered — treated as a
failure), `{type:'error'}` (logged with os_log, category `scene`) and `{type:'stats'}`. The saver
calls `LivePaper.host.pause()/resume()/lockUI(bool)/power({...})`; every call is guarded so it is a
no-op before the runtime exists, and pause/lock-UI/power state that changed while loading is
re-applied on `ready`. If no `ready` arrives the page is revealed after 8 s anyway.

**Video scenes.** `AVQueuePlayer` + `AVPlayerLooper`, muted, `preventsDisplaySleepDuringVideoPlayback
= false` (a saver must let the display sleep on schedule), `fill`/`fit` via the layer's gravity.
AVFoundation decodes in hardware and drives presentation itself; the only timer is the clock's
once-a-minute tick. Revealed on `isReadyForDisplay`; a video without a frame after 10 s fails.

**Clock hand-off.** When the user touches the keyboard or mouse, loginwindow draws its lock UI —
with Apple's own clock — over the running saver, bracketed by the distributed notifications
`LPNotification.lockUIShown` / `lockUIHidden` (`lockUIShowing` is accepted as an alias). Web
scenes get `LivePaper.host.lockUI(true|false)` (the runtime fades its clock over 300 ms); video
scenes and the fallback fade their native clock (and the fallback hint) over 300 ms. Unlocking
also clears the state in case `…IsHidden` was missed, and a scene created while the lock UI is up
starts with its clock hidden. All distributed observers use `.deliverImmediately`: AppKit suspends
distributed-notification delivery for inactive apps, and a saver host never becomes active.

**Native clock.** Same geometry as the runtime clock (`SaverClockLayout` mirrors runtime.js
`clockSizes`/`rectFor`: time = clamp(min(w·0.11, h·0.15), 40, 210), date = max(13, time·0.2), top
centre at 7 % or bottom corners), SF semibold date above SF bold time, white at 90 %, soft dark
shadow. Hours and minutes follow the user's locale and 12/24-hour setting, without AM/PM, like the
macOS lock screen.

**Power.** `automatic` resolves to battery saver (30 fps, 75 %) on battery power (IOPS) or in Low
Power Mode, else 60 fps at full resolution; `best`/`balanced`/`battery` are fixed; previews run at
15 fps. Power-source and Low Power Mode changes are event-driven (`notify_register_dispatch` on
`kIOPSNotifyPowerSource`, `NSProcessInfoPowerStateDidChange`) and forwarded to web scenes with
`LivePaper.host.power(...)`. Everything pauses on `NSWorkspace.screensDidSleep` and resumes on
wake. While paused or waiting for the gate there are no timers and no frames (the only one-shot
timer is the release 5 s after the gate closes).

**Failure recovery.** WebContent crashes, failed loads, scenes that never start and undecodable
videos retry with back-off (1 s, 2 s, 4 s within a 2-minute window), skipping to the next scene from
the second failure; the fourth failure shows the fallback instead of crash-looping all night (the
next cycle tries again).

**Options sheet.** A small programmatic sheet: playlist summary (scenes, mode, cycle, clock,
performance, publish generation) plus "Open LivePaper…" and "Done". Settings live in the app; the
sandboxed saver can't launch apps, so the button posts `LPNotification.openApp` (no userInfo —
sandboxed processes may not attach any) for the helper to act on. `isReleasedWhenClosed = false`
because the host keeps and re-presents the window.

## Build

```sh
scripts/build-saver.sh            # → build/LivePaper.saver (arm64 + x86_64, -O, ad-hoc signed)
scripts/build-saver.sh --debug    # -Onone -g
```

SwiftPM can't produce an `MH_BUNDLE`, so the script calls `swiftc -parse-as-library -emit-executable
-Xlinker -bundle` per architecture, `lipo`s the slices, copies `Info.plist` and the thumbnails,
creates an empty `Contents/Resources/Playlist/`, then signs ad-hoc and verifies. It works with the
Command Line Tools alone (it falls back to them if Xcode's license hasn't been accepted).
`LIVEPAPER_VERSION` / `LIVEPAPER_BUILD` override the bundle versions; `LIVEPAPER_ARCHS` the slices.

## Publishing into a signed bundle

The app publishes content by swapping files into `Contents/Resources/Playlist/` of the installed,
already-signed saver. Verified on macOS 26 with the Command Line Tools:

* An empty directory isn't part of the resource seal (`codesign -dvv` lists only the thumbnails).
  As soon as files are added, `codesign --verify --strict` fails with "a sealed resource is missing
  or invalid" (`file added: …/Playlist/playlist.json`, …).
* **The bundle still loads and plays the new content.** `scripts/dev/saverhost-lp.swift` loads the
  bundle through NSBundle exactly like the real host, rewrites `playlist.json` inside the signed
  bundle mid-run, and a fresh view plays the new publish (check "publish: playlist rewritten
  after signing is played", generation 2). The code signature that matters at load time covers
  the executable's pages, which publishing never touches; the resource seal is only evaluated by
  `codesign --verify` and Gatekeeper assessments.
* The real host, `legacyScreenSaver.appex`, is entitled with
  `com.apple.security.cs.disable-library-validation` (`codesign -d --entitlements -` on
  `/System/Library/Frameworks/ScreenSaver.framework/PlugIns/legacyScreenSaver.appex`), which is
  why it loads ad-hoc and third-party signed savers at all. It wasn't exercised directly here (dev
  rules forbid starting ScreenSaverEngine); the first real lock after install is the remaining
  confirmation.
* Caveats for the publish pipeline: never distribute a bundle whose resources changed after
  signing (a quarantined copy would fail Gatekeeper). The installed copy is written locally by the
  app, so it carries no quarantine attribute. If a clean `codesign --verify` matters (for example
  to a `doctor` check), re-signing the installed copy ad-hoc after publishing
  (`codesign --force --sign - --timestamp=none`) is cheap — but it replaces a Developer ID
  signature, so prefer simply not verifying the seal of the installed copy.
* For the record: the host's sandbox also has a read-only exception for `/`
  (`com.apple.security.temporary-exception.files.absolute-path.read-only`). LivePaper doesn't rely
  on it (the saver reads only its own bundle, per the architecture), but it's a fallback should
  publishing into the bundle ever stop working.

## Testing

Two layers, neither of which may launch GUI processes in a loop (see the focus rule in
`docs/ARCHITECTURE.md` §2).

**Unit tests (no GUI).** `SaverLogic.swift` is compiled into the `LivePaperSelfTest` target through
the symlink `Sources/LivePaperSelfTest/SaverLogic.swift` (there the playlist types come from
LivePaperCore — hence the `#if canImport(LivePaperCore)` at the top of the file). Tests live in
`Sources/LivePaperSelfTest/SaverTests.swift`:

```sh
swift run LivePaperSelfTest saver
```

They cover playlist validation (and display-only scenes), the deck (determinism, no repeats over
many seeds, sequence and single; the spread for several displays against a frozen copy of the
single-display deck, displays differing for 1–4 displays and 1–8 scenes, no display repeating
itself over 30 re-locks), sessions (displays that join build the same deck after the first display
recorded its scene, epoch boundaries, ended sessions, quick re-locks, displays keeping each other's
history, damaged records, per-display history and the lead), the display plan of every mode ×
display count × power × battery setting (assignments, span per scene, previews and unknown displays),
span geometry (video layer frames, the clock), the schedule, back-off, events and
lock-UI state, the run gate (prewarm, explicit starts, display sleep, release, previews, the
policy switches), clock geometry (against the runtime's numbers) and locale
formatting, the web bridge JSON, performance resolution, the Options summary and the bundle
contract (Info.plist, principal class name, thumbnails). They use temp directories only. (The
runtime's span logic is tested in `runtime.span.jsLogic`, its pixels in `runtime.e2e.spanCrops`.)

**End-to-end dev host (one GUI launch).** `scripts/dev/saverhost-lp.swift` loads the built bundle
the way the host does and drives one scripted scenario through off-screen windows in a
`.prohibited` (never-activating) process: the prewarm gate, web scene load on lock, injected
config, clock hand-off both ways, state queued before the page is ready, display sleep/wake,
unlock and the release after it, a start by `didstart` while unlocked, a lock while the displays
sleep, the Options sheet, a second display agreeing on the scene (sequence and shuffle), a publish
into the signed bundle, video playback and its native clock
hand-off, a preview (runs while "System Settings" is in front; pauses while locked, in the
background or ordered out), the fallback, and finally willstop (ignored by the preview, `exit(0)`
from a real instance). System events reach the view through its `livepaperHandleNotificationNamed:`
hook — nothing is broadcast — and `LIVEPAPER_SAVER_STATE_FILE` keeps bookkeeping out of the user's
real ScreenSaverDefaults. The host sets `LIVEPAPER_SAVER_SIMULATED_SYSTEM` for itself, so the
saver's polled facts (session lock, display sleep, ScreenSaverEngine, frontmost app) read
"unlocked, awake, no engine, another app in front" and the real Mac's notifications are not
observed, whatever state the Mac is in (locked, display asleep, someone switching apps); the real
host never sets it. Its lifecycle lines appear in the log under the process name `saverhost-lp`. It writes `report.json` and half-size PNGs (video snapshots composite the
frame at the player's current time under the saver's own layers, since an `AVPlayerLayer` can't be
read back without screen recording).

```sh
scripts/build-saver.sh
scripts/dev/make-test-playlist.sh          # test web scene + 4 s H.264 clip (generated without the window server)
xcrun swiftc -O -o build/dev/saverhost-lp scripts/dev/saverhost-lp.swift
mkdir -p build/dev/run
LIVEPAPER_SAVER_STATE_FILE="$PWD/build/dev/run/state.json" build/dev/saverhost-lp build/LivePaper.saver build/dev/run
# exit status 0 = every check passed and the saver quit the host on willstop
/usr/bin/log show --last 2m --info --predicate 'subsystem == "com.nachmore.livepaper.saver"'
```

Never install a development build into `~/Library/Screen Savers` to test it, and never start
ScreenSaverEngine from tooling.

## Known limitations

* With `sessionLockOpens` on (the default, see "Adjusting the gate"), a prewarmed instance that has
  had `startAnimation` renders behind a direct lock — ⌃⌘Q, Apple menu › Lock Screen or the lock key
  with the lock keys switch off, lid close, display sleep — while the displays are on, until the
  unlock (then it releases its scene 5 s later). Nothing loads while the displays sleep.
  LivePaper's own lock and the lock keys switch start the saver first, which avoids this.
* If `didstart` doesn't reach the sandboxed host and ScreenSaverEngine isn't running (an idle start
  with "Require password after screen saver begins" set to a delay or Never, or a hot corner), the
  saver shows black until the session locks, as before. The lifecycle log shows which it is.
* If a hidden prewarm view and the presented view share a process during a run, both receive the
  lock and `didstart` and both render (`othersRunning=1` in the log); unverified.
* Whether System Settings' preview host reports its window's visibility and the frontmost app to
  the sandboxed saver is unverified; previews then fall back to "visible".
* A display in another host process that starts more than 45 s after another begins a new session
  and may pick a different scene (it still avoids the recent scenes). In the same process it joins.
* Connecting or disconnecting a display while the saver runs changes the arrangement: in *different*
  and *span* the other displays may switch scene or slice (with a crossfade). Bezels aren't
  compensated (System Settings' arrangement is the truth), and spanning web slices on displays with
  different refresh rates can be up to a frame apart.
* Recovery moves only the failing display on: in *different* two displays may briefly show the same
  scene.
* A session counts as ended only once willstop arrives. If a run ends without one (for example a
  prewarmed instance behind a direct lock, which just releases its scene after the unlock), a
  re-lock within 45 s of that session's start joins it and shows its first scene again.
