# What LivePaper relies on in macOS 26

These are the findings about macOS 26 (Tahoe) that LivePaper is built on. Almost none of this
is documented by Apple. Everything was checked on macOS 26.7 (25G342) in November 2026, using
read-only methods:

* **Static analysis** of the system binaries: disassembly of loginwindow, WallpaperAgent and the
  Wallpaper, ScreenSaver and ServiceManagement frameworks, plus their Swift reflection metadata
  (type and field names).
* **The unified log** (`log show`) of the processes involved, over several days of normal use.
* **Controlled live tests** on one Mac: a real lock and unlock, and selecting a saver in System
  Settings while the log and the store file were watched.
* A **second, independent pass** whose job was to refute each claim. Where it corrected
  something, the corrected version is what appears here.

Each claim is labelled:

* **Verified**: seen in a live test, or in code and confirmed in the log.
* **Inferred**: follows from the code but wasn't observed.
* **Unknown**: not established.

Apple can change any of this in an update. That is why LivePaper checks before it relies on
something, and falls back to a guided manual step.

---------------------------------------------------------------------------------------------------

## 1. The lock screen is the screen saver

* macOS 26 has no wallpaper just for the lock screen. **Verified:** when the Mac locks,
  loginwindow puts up its shield window and asks **once** whether a screen saver is running
  (`-[LWDefaultScreenLockUI _load]`).
  * If a saver is running, the clock and password field are drawn over the live saver.
  * If not, you get the desktop picture.
  * A saver that starts *after* the lock runs unseen behind the shield.
* By default, ⌃⌘Q and Apple menu › Lock Screen lock straight away (a "direct lock") and never start
  a saver.
* So the dependable way to show a scene is to start the screen saver, and let the saver lock the
  Mac. This needs "Require password after screen saver begins: Immediately".
* Idle time and the password delay may be set by a configuration profile. LivePaper only reads them.

## 2. Lock keys: `immediateLockLaunchesScreenSaver`

* `defaults write com.apple.loginwindow immediateLockLaunchesScreenSaver -bool true` is a plain
  user preference: any host, no administrator rights, and off by default. With it on, ⌃⌘Q,
  Apple menu › Lock Screen and the Touch ID / lock key start the screen saver first, and then lock.
  * **Verified** in disassembly: loginwindow reads the key fresh on every lock request.
  * **Verified** live: a real ⌃⌘Q started the saver and locked, and unlocking still needed the
    password or Touch ID.
  * **Verified** live: no logout is needed. The running loginwindow picked the new value up at the
    next lock.
* **Not covered**, so they still show the desktop picture: locks caused by display sleep or system
  sleep, closing the lid, and the lock at login.
* **Side effects when on (Verified in code):**
  * The password field stays hidden until a key press or mouse move.
  * Touch ID locks lose their one-time short timeout for the lock UI.
* **Residual risk (Inferred):** if loginwindow already believes a saver is running, the switch does
  nothing. LivePaper can't detect that state.
* LivePaper offers this as an explicit opt-in. It records the previous value and restores it on
  uninstall. It never re-applies the setting against a configuration profile.

## 3. Prewarm

* **Verified** in the log: after every unlock, WallpaperAgent starts a hidden saver instance that
  is never shown, ready for the next lock. It does this only for the screen saver that is
  actually selected.
* With WebKit's occlusion detection turned off (see §4), such an instance would animate forever
  at roughly half a CPU core. So LivePaper's saver renders nothing until a saver is actually up:
  * the session is locked (`CGSSessionScreenIsLocked` in `CGSessionCopyCurrentDictionary()`, or the
    `com.apple.screenIsLocked` notification), or
  * loginwindow posted `com.apple.screensaver.didstart`, or ScreenSaverEngine is running;
  * it pauses again on `com.apple.screenIsUnlocked`, `didstop` and display sleep, and frees its
    scene a few seconds after the unlock.
* **Verified** in disassembly: `-[ScreenSaverDaemon _screenSaverStart:]` in loginwindow posts
  `com.apple.screensaver.didlaunch` (object = a UUID, options 3) and then
  `com.apple.screensaver.didstart` (object `"runFromPref"` or `""`, userInfo `{runFromPref: Bool}`,
  options 1 = deliver immediately) on the distributed notification center, for every saver start.
  `_screenSaverStop` posts `willstop` / `didstop`. ScreenSaverEngine quits on `didstop`.
* **Inferred:** WallpaperAgent calls `startAnimation` on the hidden instance (from the prototype's
  CPU use; never logged), and a presented run adds a second view to the prewarmed process (two
  ViewBridge "did terminate" lines per exit).
* **Unknown:** whether `didstart` (which carries a userInfo) reaches the sandboxed host, and when
  relative to `startAnimation` and `screenIsLocked`. The saver logs its whole lifecycle (category
  `lifecycle`) so real lock cycles can settle this; see Saver/README.md, "The run gate".
* Replacing the `.saver` bundle on disk ends the prewarmed host. WallpaperAgent then builds a new
  one (Verified).

## 4. Occlusion, stopping, notifications

* Third-party `.saver` bundles run inside `legacyScreenSaver`, a sandboxed host that WallpaperAgent
  manages.
  * AppKit reports the host window as occluded, so a `WKWebView` never draws. Setting
    `_setWindowOcclusionDetectionEnabled:` to `false` on the web view fixes this (Verified).
  * `stopAnimation` is not called reliably. The saver listens for `com.apple.screensaver.willstop`
    and exits its process, but only when it isn't a preview instance.
* The lock UI appearing over the saver (when you touch a key or the mouse) is bracketed by the
  distributed notifications `com.apple.screenLockUIIsShown` and `com.apple.screenLockUIIsHidden`
  (Verified). Scenes hide their own clock in between, so two clocks never show.
* AppKit holds back distributed notifications for inactive apps. A saver host, a helper agent and
  a menu-bar app are almost never active. So every LivePaper observer uses
  `.deliverImmediately`, and every poster passes `deliverImmediately: true`.
* A sandboxed process may post a distributed notification only with `userInfo == nil`. Any data
  goes in the `object` string.

## 5. Selecting the screen saver: the wallpaper store

### 5.1 The file
* `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` is a binary property list.
  WallpaperAgent writes it with Swift's `PropertyListEncoder`.
* Its format is gated by `defaults read com.apple.wallpaper StoreIndexMigrationVersion` = **10**.
  If the version differs, the agent migrates the content.
* Reading the file needs no permission, and reading it showed no privacy prompt.
* The legacy `com.apple.screensaver` `moduleDict` is no longer used on macOS 26: nothing reads or
  mirrors it.

### 5.2 The model (Swift field metadata of WallpaperAgent; Verified)
```
StoreIndex   { AllSpacesAndDisplays: Record?, SystemDefault: Record,
               Spaces: { <space uuid | ""> : { Default: Record, Displays: { <display uuid>: Record } } },
               Displays: { <display uuid>: Record } }
Record       = individual(Desktop, Idle) | desktop | idle | linked     (tagged by the key "Type")
Slot         { LastSet: Date, LastUse: Date, Content }
Content      { Choices: [Choice], Shuffle: Shuffle?, EncodedOptionValues: Data? }
Choice       { Provider: String, Files: [File], Configuration: Data }
```
* `nil` is stored as the string `"$null"`, which is how `PropertyListEncoder` writes it.
* The screen saver is the **Idle** slot. Every record seen so far is `individual`, and
  `AllSpacesAndDisplays` has always been `"$null"`.
* A Codable mirror of this model (`WallpaperStoreSchema`) decodes a real store and **re-encodes it
  to identical bytes**. That is strong evidence the mirror is complete for the shapes seen so far.
* A placeholder slot ("use the next record up") has `Provider = "default"`, an empty
  `Configuration` and `EncodedOptionValues = {values = {}}`.
* The order records fall back in is **Inferred** from the resolver's enum names: Space and display,
  then Space, then display, then `SystemDefault`.

### 5.3 The payload for a legacy `.saver` (Verified, byte for byte)
* `Provider = "com.apple.wallpaper.choice.screen-saver"` and `Files = []`.
* `Configuration` is a binary plist of
  `{module = {relative = "file:///Users/<name>/Library/Screen%20Savers/LivePaper.saver"}}`, which is
  Swift's Codable form of `URL`.
  * The path is percent-encoded and has **no trailing slash** and no base. That is what System
    Settings writes.
  * Building the URL from the existing bundle directory would add a slash.
  * For an 8-letter user name this is 132 bytes, identical to what System Settings writes for a
    saver at the same path.
* `EncodedOptionValues` is the 54-byte binary plist `{values = {}}`, the same as the agent writes
  itself. `Shuffle` is `"$null"`.

### 5.4 Which slots System Settings changes (Verified from a logged selection)
* It changes `SystemDefault.Idle`, plus every per-display, per-Space and per-Space-per-display Idle
  slot whose provider is **not** `default`. Placeholder slots keep inheriting.
* Desktop slots are never touched.
* A display that first appears later gets a record copied from `SystemDefault`, timestamps
  included (Inferred from the timestamps).

### 5.5 How WallpaperAgent uses the file (Verified)
1. **It reads the file only at launch.** It has no file watcher of any kind: no vnode source,
   FSEvents, kqueue, file presenter or notification for the store. It also has no "reload"
   work item.
2. **It writes the whole file from memory, very often.** It encodes its in-memory model and writes
   with `Data.write(options: .atomic)`, so every write is a rename to a new inode. It writes after
   almost every lock, unlock, display change or Dock assertion, mostly in bursts. Any edit made
   while the agent runs is overwritten at its next write.
3. **A file it can't decode costs the user their desktop choices.** The agent logs
   `Unable to read Index` and `Using default store index`, builds a default store and writes it
   back. So never put a file in place that its decoder might reject.
4. **Restarting it is cheap.**
   * It runs as the user and has no SIGTERM handler.
   * launchd relaunches it (`KeepAlive`) in about 0.15 s, and it then rewrites the file once.
   * Expect about a second of blank desktop while its extensions rebuild.
   * Never restart it while the screen is locked or a saver is showing: the agent draws the
     lock-screen saver (Inferred).
5. **No supported route exists.**
   * Its XPC service accepts any connection, but anything beyond display assertions needs the
     private `com.apple.private.wallpaper` entitlement. That includes the message System Settings
     sends to change the screen saver.
   * No App Intent sets the screen saver.
   * `ScreenSaverNameIntent` reads the legacy `moduleDict` and would report "No Screen Saver".
6. **MDM:** the agent honours a forced `moduleName` in `com.apple.screensaver` (Verified string).
   Check it with `CFPreferencesAppValueIsForced("moduleName", "com.apple.screensaver")`.

### 5.6 What LivePaper does (`Sources/LivePaperCore/Install/WallpaperStore/`)
LivePaper changes the store only on an explicit click, never at login or on a timer.

**It refuses, and points the user to the one-click guided step, when any of these is true:**
* The store isn't the one the agent reads.
* The session is locked or not on the console.
* System Settings, its Wallpaper extension, or ScreenSaverEngine is running.
* A profile forces the saver module or forbids wallpaper changes.
* The format version isn't 10.
* The file is missing or doesn't decode with the mirror.
* Any record is `linked`.
* The saver isn't installed.

**Otherwise it runs this sequence:**
1. Hold a lock file, so no other LivePaper process edits the store at the same time, and run the
   checks above again once it has it.
2. Wait until the file has been unchanged for about 1 s.
3. Read the store and decode it with the mirror.
4. Replace only `SystemDefault.Idle` and the explicit (non-placeholder) Idle slots.
5. Check the result before writing:
   * it still decodes;
   * only the planned Idle slots differ;
   * every Desktop slot is byte-identical.
6. Check again that the session is unlocked and System Settings isn't open: the waits above take
   seconds, and locking the Mac to look at the new screen saver right after clicking is natural.
   Every agent restart below is preceded by the same check.
7. Back up before writing anything:
   * the exact bytes about to be replaced (every time, select and restore alike);
   * the raw file, the first time only;
   * a manifest that records, for each Idle slot it replaces, the user's original choice.
8. Put it in place with a single atomic rename (only if the file hasn't changed since it was read),
   then **immediately** run `killall WallpaperAgent`.
9. Wait for the restarted agent's own rewrite, re-read the store and confirm the result. A planned
   slot counts as kept when it makes the planned choice; the agent may spell option values and
   timestamps its own way (System Settings itself copies the Desktop's option values into saver
   slots):
   * If an Idle choice was lost (the old agent wrote between the rename and the kill), plan again
     and retry, at most twice, 2 s apart. If the new plan is empty, the agent's own store already
     is right: confirmed without another restart.
   * If the Desktop slots changed or the store is unreadable, roll back: put the original bytes
     back through the same protected steps (wait until unlocked, rename, restart, confirm, retry at
     most twice). Only a confirmed rollback is reported as "put the previous settings back";
     otherwise LivePaper says it couldn't confirm it and names the saved copy from step 7.

Optional hardening, not used: freezing the agent with SIGSTOP while swapping the file would close
the race completely. But if LivePaper crashed mid-step, the process that draws the desktop and the
lock screen would stay frozen.

### 5.7 Undoing it (uninstall)
* Restore runs **before** the `.saver` is deleted. The store must never point at a missing module;
  what the agent does then is Unknown. So the saver is removed only after the store has been
  re-read and no Idle slot names it (a copy of LivePaper.saver at another location that exists
  doesn't count).
* Every Idle slot that **still** names LivePaper.saver is changed, whether or not LivePaper made
  the selection itself (it may have been picked by hand in System Settings):
  * If the manifest has an original for that slot, the original goes back exactly. LivePaper.saver
    at another location that still exists (say /Library/Screen Savers) is recorded as an original
    too, so that location comes back.
  * A slot with no recorded original gets the placeholder. An example is a display added since
    install, which was copied from `SystemDefault`.
  * A recorded original whose module was deleted since also gets the placeholder. The exception
    is `SystemDefault`, which has nothing to fall back to: its original goes back as it was.
  * `SystemDefault` (or an explicit `AllSpacesAndDisplays`) without a recorded original gets the
    choice the raw pre-LivePaper copy has there, unless that names LivePaper too; otherwise macOS's
    own Message saver (`/System/Library/Screen Savers/FloatingMessage.saver`, the same legacy
    `.saver` payload as §5.3), and uninstall says so.
* Slots the user changed since are left alone.
* The whole old file is **never** put back: that would undo later Desktop changes and drop
  displays and Spaces added since.
* If the restore can't run — for a reason that may pass, such as System Settings being open, or
  one that won't, such as a new store format — the step fails and says what to do, and the saver
  and every backup are kept. Once the user has picked another saver in System Settings, running
  uninstall again finishes.

### 5.8 Detection
* Reading the store, as in §5.2, is the only reliable signal. "Selected" means that an Idle slot's
  screen-saver choice names `LivePaper.saver`.
* LivePaper reports two levels:
  * **any:** the status shown in the app;
  * **everywhere:** `SystemDefault` and every explicit slot point at LivePaper.
* Signals rejected, because they are unreliable or need private entitlements:
  * the legacy `moduleDict`;
  * the `ScreenSaverNameIntent` App Intent;
  * WallpaperAgent's XPC read calls;
  * the screen-saver start and stop notifications, which don't name the module;
  * scraping the log.

### 5.9 Still open
* A freshly launched agent loading a hand-written `.saver` choice from disk has not been observed
  on the test Mac. Independent open-source tooling reports that it works on macOS 26. LivePaper's
  confirm step exists for exactly this reason.
* What "Show on all Spaces" writes to `AllSpacesAndDisplays`.
* What the agent does with an Idle choice whose module is missing.

## 6. Login items for an ad-hoc-signed helper

These points come from static analysis of ServiceManagement, smd and the background-task manager:

* **`SMAppService.agent(plistName:)` accepts ad-hoc-signed code.**
  * There is no Team ID check.
  * The code must have an embedded signature, and the launchd plist must be a sealed resource of the
    bundle, at `Contents/Library/LaunchAgents/<name>.plist`.
  * `BundleProgram` must resolve inside the bundle.
  * `register()` must be called by the app's **main executable**.
  * The app can live anywhere.
* **New agents start out enabled and allowed.** No approval is needed; daemons are different.
* **A login-item record is keyed by `<type>.<Label>`.** A legacy `~/Library/LaunchAgents` plist with
  the same label shares that record, so LivePaper's fallback uses a different label.
* **For ad-hoc code, the stored launch constraint is a set of cdhashes.**
  * After a rebuild changes the helper binary, launchd's repair path re-registers the item (Inferred).
  * Expect one failed launch and a new "Login Item Added" notification.
  * Keeping the helper byte-identical across app updates avoids that.
* Switching the item off in System Settings needs administrator rights. `sfltool resetbtm` would
  reset every app's login items, so LivePaper never uses it.
