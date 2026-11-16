# LivePaper

LivePaper turns animations and videos into your Mac's screen saver — and, on macOS 26, that means
your **live lock screen**. Bring a video, or describe a scene and let an AI coding agent (Claude
Code, Codex or Kiro CLI) write it; LivePaper validates every scene for frame time, brightness and
battery use before it ever reaches your lock screen.

* A menu-bar app with a library of scenes, a playlist, and guided setup.
* Web scenes (one JavaScript file on a full-screen canvas) and video scenes (hardware-decoded).
* AI authoring from the app or the terminal, checked by LivePaper itself — never on the agent's word.
* Reference images: paste, drop or pick images or folders as a starting point — or have the agent
  animate one exact picture.
* Your usual lock keys (⌃⌘Q, Apple menu › Lock Screen, the Touch ID / lock key) can show the scene.
* One-step uninstall that puts everything back.

Requires macOS 14 or later; the lock-screen behaviour described below is macOS 26 (Tahoe).
Licensed under the [Apache License 2.0](LICENSE).

## How it works on macOS 26

macOS 26 has no separate "lock-screen wallpaper". What you see on the lock screen is the **screen
saver**, if it was already running when the Mac locked: the login window draws its clock and
password field over the live saver. If no saver is running at that moment, you get the plain
desktop picture. LivePaper builds on exactly that:

* **The saver.** LivePaper installs `LivePaper.saver` into `~/Library/Screen Savers` and, when you
  click *Make LivePaper my screen saver*, selects it for you: it edits only the screen-saver slots of
  macOS's wallpaper store (your desktop picture is never touched), restarts WallpaperAgent (about a
  second of blank desktop) and verifies the result. If that isn't possible (System Settings is open,
  the setting is managed by your organisation, …) it falls back to a one-click guided step in
  System Settings › Wallpaper › Screen Saver. The saver runs sandboxed and can only read
  its own bundle, so "publishing" compiles your playlist's scenes *into* the installed saver.
* **Idle timeout — unchanged.** macOS starts the screen saver after your usual idle time (System
  Settings › Lock Screen). LivePaper never changes it (on managed Macs it may be set by your
  organisation). With *Require password after screen saver begins: Immediately*, the scene *is*
  the lock screen.
* **Lock keys.** ⌃⌘Q, Apple menu › Lock Screen and the Touch ID / lock key normally lock straight to
  the wallpaper. With LivePaper's *Lock keys* switch on (Settings › Lock, also offered during
  setup) they start the screen saver first, so the lock screen shows your scene. This is the
  user-level preference `com.apple.loginwindow immediateLockLaunchesScreenSaver`: no
  Accessibility or other permissions, effective immediately, and it fails safe (if the saver
  can't run, the Mac still locks). LivePaper remembers the previous value and uninstall restores
  it. Closing the lid or letting the display sleep still locks to the wallpaper.
* **The helper.** A small login item (`LivePaperHelper`) provides an optional extra lock shortcut
  of your choice and the menu bar's *Lock now*. Both start the screen saver and let it lock, which
  only locks with *Require password after screen saver begins: Immediately*. Otherwise they refuse
  and say why rather than start a screen saver that merely looks locked (⌃⌘Q always locks).
* **No wasted energy.** After every unlock macOS quietly pre-starts a hidden copy of the screen
  saver. LivePaper's saver renders nothing until a screen saver is actually up (the session locks
  or macOS reports that the saver started), pauses when the displays sleep and when you unlock,
  frees its scene a few seconds later, and exits when the saver stops. System Settings previews
  run at 15 fps and pause while the Mac is locked or System Settings is in the background. One
  known exception: a direct lock (⌃⌘Q with the lock keys switch off, closing the lid) can make the
  hidden copy render behind the lock screen until you unlock (Saver/README.md, "Known limitations").

The contract between the components is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Install from source

You need Xcode 26 or later (or the Command Line Tools with Swift 6). Then:

```sh
git clone https://github.com/nachmore/livepaper.git
cd livepaper
scripts/build.sh          # → build/LivePaper.app (universal, ad-hoc signed)
scripts/dev-install.sh    # → /Applications (or ~/Applications), then: open it
```

`scripts/build.sh` builds a universal (Apple silicon + Intel) release bundle, signs every piece
ad-hoc from the inside out and verifies the result; `--debug` is a fast incremental build for this
Mac's architecture only. `scripts/dev-install.sh` copies the bundle into `/Applications` when it is
writable (else `~/Applications`, or wherever LivePaper is already installed), clears the
quarantine flag, verifies the signature and restarts the helper if it was running; it doesn't
open the app unless you pass `--launch`.
`--link-cli` also links the `livepaper` command into `~/.local/bin`.

On first launch LivePaper walks you through setup: it installs the screen saver, selects it (or
guides you if it can't), offers the lock-keys switch, starts the helper (System Settings may ask you to allow it under
General › Login Items) and checks that a password is required immediately. Every step can be
re-run from Settings and only changes what still needs it.

## Using it

* **From a video.** *Create › Video*: drop a `.mov`, `.mp4` or `.m4v`. *Optimise for battery*
  converts it to HEVC at display resolution, which then plays for a fraction of the energy.
  From the terminal: `livepaper import clip.mov [--battery]`.
* **With AI.** *Create › Describe it*: write what you want to see, pick an agent, and watch the
  session — the agent's messages, tool calls and the stills it renders while it iterates. When the
  agent finishes, LivePaper runs its own check; a passing scene can be added to the library (or,
  for *Modify with AI…*, replace the scene — the previous version is kept in its history).
  To give the agent **reference images**, paste them (⌘V, e.g. a screenshot), drop images or
  folders onto the card, or click *Add Images…* (up to 10). Each is a reference — inspiration for
  style, colours and composition — or, for one of them, *Animate this image*: the scene then shows
  that exact picture, cover-filling any screen, and brings it to life (water shimmer, drifting mist,
  a slow camera), and LivePaper's check makes sure it still looks like the picture. The agent works
  from copies LivePaper makes in its workspace (resized, metadata such as location removed); a
  path typed into the prompt gets an *Attach* suggestion, because the agent can't open files
  elsewhere on your Mac. LivePaper itself uploads nothing (the agent shows the images it looks at to
  its model, like the rest of the session), and *Try Again* keeps them.
* **By hand.** `livepaper new "Aurora Lake"` scaffolds a web scene from the template; edit its
  `scene.js` (see [Runtime/SCENE_API.md](Runtime/SCENE_API.md)) and run `livepaper check` on it.
* **The playlist.** Choose which scenes the screen saver shows, shuffle / in sequence / one scene,
  how often it changes, whether to show the clock, and the performance profile. Changes are
  published into the saver and take effect the next time it starts.

## The `livepaper` command

The CLI ships inside the app at `LivePaper.app/Contents/Helpers/livepaper` (link it onto your
PATH with `scripts/dev-install.sh --link-cli`). It is a plain command-line process — it never
links AppKit or WebKit — so AI agents can run it without disturbing you; rendering goes to
LivePaper's render server (the running app, or one headless `LivePaperRenderd` started on demand
that exits after 15 idle minutes). Inside an AI session it runs only the scene commands (`check`,
`still`, `bench`, `live`, `thumbnail`, `compile`) on the session's own workspace, and each agent
is limited to editing the scene and running those commands (details in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §10). `livepaper help <command>` lists every option.

| Command | What it does |
|---|---|
| `check <dir.lpscene> [--quick] [--power] [--json]` | compile and validate a scene: stills at several sizes and times, JavaScript errors, frame time, brightness, motion (alive everywhere, not busy, no flicker) (and energy with `--power`); exit 0 only if it passes |
| `still`, `bench`, `live`, `compile` | one frame to a PNG · frame time at one moment · fps/CPU/energy while running live · the self-contained HTML |
| `new <name> [--from <id>]` | scaffold a web scene in the library, or clone one |
| `list [--json]` | the library (yours first, then built-in), with frame times and playlist membership |
| `import <video \| .lpscene \| .zip> [--name N] [--battery]` | add a video or a scene package |
| `publish [--scenes a,b\|all] [--mode M] [--cycle MIN] [--performance P] [--clock\|--no-clock]` | update the playlist settings (optional) and publish into the installed saver |
| `ai create "<prompt>"` / `ai modify <id> "<prompt>"` | run an AI session in the terminal; `--harness claude\|codex\|kiro\|custom`, `--command "<template>"`, `--model`, `--timeout`, `--yes` to accept without asking, `--json` for one JSON event per line |
| `ai create [...] --ref <image\|folder>… [--animate <image>]` | the same with reference images (up to 10; `--ref` is repeatable and folders expand) and at most one picture to animate exactly; the prompt may be left out when images are given (also for `ai modify`) |
| `ai harnesses` | the AI command-line tools LivePaper found |
| `doctor [--no-ai] [--json]` | saver, helper, lock settings, render server, library and AI tools; exits 1 when something needs fixing |
| `uninstall [--yes] [--keep-scenes] [--dry-run]` | undo everything LivePaper changed (see below) |
| `server status\|start\|stop` | the render server |

Exit codes: 0 success · 1 the scene (or request) has problems · 2 usage error · 3 LivePaper itself
couldn't do the work (e.g. the saver isn't installed).

Example: an AI-made scene straight into the screen saver.

```sh
livepaper ai create "Paper lanterns drifting upward through a warm summer night" --yes
livepaper publish
```

## Performance and battery

* Every scene must pass `livepaper check`: at most 4 ms per frame at 1512×982@2x (6 ms on a
  5120×1440 ultra-wide), no JavaScript errors, not too bright overall, calm behind the clock, and
  gently alive across the whole frame without being busy or flickering.
  `--power` also measures energy in the battery profile.
* The *Automatic* profile runs 60 fps at full resolution on power and 30 fps at 75 % on battery or
  in Low Power Mode; *Best*, *Balanced* and *Battery* fix it. Scenes step their render scale down
  on their own if frames take too long.
* Video scenes play through AVFoundation with hardware decoding — the most frugal option; the
  battery-optimised import makes them cheaper still.
* Nothing renders while the displays sleep, and the hidden pre-started saver renders nothing
  until a saver is up (see the exception under "No wasted energy").
* Video-call apps that keep the display awake also keep any screen saver from starting; that is
  expected macOS behaviour.

## Uninstall

In the app: *Settings › About › Uninstall LivePaper…*, which shows exactly what will happen.
From the terminal, either of:

```sh
scripts/uninstall-dev.sh [--delete-scenes [--yes]] [--dry-run]   # everything below, then deletes the app
livepaper uninstall [--keep-scenes] [--dry-run] [--yes]
```

Uninstalling stops the helper and removes its login item / LaunchAgent, switches the screen saver
back — to your previous choice, or, if LivePaper never recorded one (say you picked LivePaper in
System Settings yourself), to macOS's Message saver — and restores the lock-keys setting (and any
other preference LivePaper changed), removes `LivePaper.saver`, and deletes
`~/Library/Application Support/LivePaper` — or, with `--keep-scenes`, everything there except your
scene library and preferences. `scripts/uninstall-dev.sh` keeps the scenes unless you pass
`--delete-scenes` (it asks first, unless `--yes`). LivePaper.saver is only removed once no screen
saver choice points at it any more: if the screen saver can't be switched back automatically (for
example after a macOS update changed the settings format), uninstall says so, keeps the saver and
its backups, and asks you to choose another screen saver in System Settings › Wallpaper › Screen
Saver and run it again. Each step can be re-run safely. One difference from the in-app uninstall:
only the app can unregister its entry in System Settings › General › Login Items, so after a
terminal uninstall that entry may stay listed until you delete the app or remove it there — it
can't start the helper any more (uninstall leaves a `LivePaper.uninstalled` marker next to the
data folder; setting LivePaper up again removes it).

## Development

```
Sources/LivePaperCore/        models, library, publishing, AI sessions, install (Foundation only)
Sources/LivePaperRenderKit/   off-screen WebKit renderer + render socket server
Sources/LivePaperApp/         the SwiftUI app            Sources/LivePaperHelper/   login-item helper
Sources/LivePaperCLI/         `livepaper`                Sources/LivePaperRenderd/  headless render daemon
Saver/                        LivePaper.saver (built by scripts/build-saver.sh)
Runtime/                      runtime.js, scene API docs, agent guide, scene template
App/                          Info.plist, helper LaunchAgent plist, procedural app icon
scripts/                      build.sh, build-saver.sh, dev-install.sh, uninstall-dev.sh, dev/
```

* `swift build` builds every Swift target; `scripts/build.sh --debug` assembles a development
  bundle in a few seconds. The version lives in the `VERSION` file; the build number is the commit
  count.
* **Tests:** `swift build && swift run LivePaperSelfTest [filter]` (a small custom runner; no
  XCTest). Tests run against temporary directories through the `LIVEPAPER_HOME`,
  `LIVEPAPER_SAVERS_DIR`, `LIVEPAPER_LAUNCH_AGENTS_DIR` and `LIVEPAPER_WALLPAPER_STORE` overrides
  and must never touch your real screen saver, preferences or login items. The `cli.*` tests run
  the built `livepaper` binary, so build first.
* **Contributor rule — never steal focus.** Anything that registers a process with the window
  server (a GUI app, a WebKit view, a browser) can take keyboard focus from whoever is using the
  Mac. LivePaper's tooling therefore renders through one long-lived render server, the CLI never
  links AppKit/WebKit (`scripts/build.sh` enforces this), and tests use `LIVEPAPER_NO_SPAWN=1`
  unless they explicitly exercise the render server. Don't add tests or scripts that launch apps,
  browsers, System Settings or ScreenSaverEngine.
* Scenes in this repository must be original work: the repository is public.

## Licence

Copyright © 2026 Oren Nachman. Licensed under the [Apache License, Version 2.0](LICENSE).
