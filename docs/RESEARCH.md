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

### 4.1 Several displays

* **All displays' saver views run in one `legacyScreenSaver` process** (Verified, from the saver's
  lifecycle log during a real lock with two displays: two views, one pid, the first starting a new
  session and the second joining it about 100 ms later). So a process-wide object — one AVPlayer
  for every display showing a video, one session for every display — is shared by all displays.
* `NSScreen.screens`, `window.screen` (`NSScreenNumber`), `CGDisplayCreateUUIDFromDisplayID` and
  `CGDisplayIsBuiltin` inside the sandboxed host: **Inferred** to work (they are plain WindowServer
  and CoreGraphics queries; the saver logs the arrangement it sees at every start, and a display it
  can't identify plays as if it were the only one).
* `NSApplication.didChangeScreenParametersNotification` inside the host: **Unknown**. The saver also
  re-reads the arrangement at every start and when its window changes screen.
* Whether a view is created for a display connected while the saver runs: **Unknown**. If one is,
  it joins the running views' session in-process (so it shares their time origin and seed).
* Whether macOS draws its lock-UI clock on displays other than the main one: **Unknown**. Every
  display hands its clock off on `screenLockUIIsShown` as before.
* One `AVPlayer` behind several `AVPlayerLayer`s is documented AVFoundation behaviour; that it works
  in this host is **Inferred**.

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
  `Configuration` and `EncodedOptionValues = {values = {}}`. In `SystemDefault`, which has nothing
  above it, the placeholder means macOS's own default screen saver (an aerial).
* The order records fall back in is **Inferred** from the resolver's enum names: Space and display,
  then Space, then display, then `SystemDefault`. LivePaper resolves every record this way
  (`WallpaperStoreDocument.resolution`); an `AllSpacesAndDisplays` override, never seen set, is
  taken at its name and tried first.

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
5. **It doesn't keep a `SystemDefault` written into the file while the displays it shows hold the
   placeholder** (Verified on macOS 26.7, 2026-11-16, on a store with 6 display records, 4 Spaces and
   20 records):
   * The state found: `SystemDefault.Idle` was the placeholder, its `LastSet` older than LivePaper's
     selection (most likely put back by another screen saver's uninstaller from its own old copy).
     Two display records — displays not connected that day — chose LivePaper explicitly; the four
     displays in use had the placeholder in every record (per display and per Space), so they fell
     back to `SystemDefault`: the lock screen showed macOS's default aerial. LivePaper said
     "selected" because one slot named it.
   * Writing only `SystemDefault.Idle` = LivePaper and restarting the agent: within 1.5 s the
     agent had written `SystemDefault.Idle` back to the placeholder, with the old `LastSet`. Every
     retry ended the same way ("WallpaperAgent overwrote SystemDefault").
   * Writing LivePaper into the 11 placeholder Idle slots of display records (`Displays/*` and
     `Spaces/*/Displays/*`) and restarting the agent: the agent kept all of them, and then
     `SystemDefault.Idle` and the `Default` of the two Spaces in use held LivePaper too, with the
     `LastSet`/`LastUse` of a display slot in use. The `Default` of the two Spaces not in use kept
     the placeholder; every display record resolved to LivePaper.
   * The timestamps, compared in read-only copies of both stores: every placeholder had the same
     `LastSet` (the old `SystemDefault`'s; display records start as copies of it, §5.4). After the
     fill, `SystemDefault.Idle` was LivePaper with that display slot's `LastSet`, not a new one —
     nothing wrote `SystemDefault` but the agent, so it copied a whole display slot there. `LastUse`
     is bumped on every record along the resolution chain of a display shown (its Space record, the
     Space's `Default`, its display record, `SystemDefault`): it shows which displays and Spaces were
     in use, but not which record was read.
   * Inferred: the agent derives `SystemDefault` and the `Default` of each Space in use from the
     slots of the displays it shows, copying whole slots, placeholder included. So a selection made
     by editing the file must give the displays themselves the choice — and so must an uninstall
     that puts an explicit choice back into `SystemDefault` (§5.7). (System Settings, which tells
     the running agent over XPC, leaves display placeholders alone, §5.4; whether its choice then
     survives the agent's next launch hasn't been observed.)
6. **No supported route exists.**
   * Its XPC service accepts any connection, but anything beyond display assertions needs the
     private `com.apple.private.wallpaper` entitlement. That includes the message System Settings
     sends to change the screen saver.
   * No App Intent sets the screen saver.
   * `ScreenSaverNameIntent` reads the legacy `moduleDict` and would report "No Screen Saver".
7. **MDM:** the agent honours a forced `moduleName` in `com.apple.screensaver` (Verified string).
   Check it with `CFPreferencesAppValueIsForced("moduleName", "com.apple.screensaver")`.

### 5.6 What LivePaper does (`Sources/LivePaperCore/Install/WallpaperStore/`)
LivePaper changes the store on an explicit click ("Make LivePaper my screen saver", "Use LivePaper
on Every Display", `livepaper select`), and otherwise only for the quiet re-apply below — never on a
timer.

**It refuses, and points the user to the one-click guided step, when any of these is true:**
* The store isn't the one the agent reads.
* The session is locked or not on the console.
* System Settings, its Wallpaper extension, or ScreenSaverEngine is running.
* A profile forces the saver module or forbids wallpaper changes.
* The format version isn't 10.
* The file is missing or doesn't decode with the mirror.
* Any record is `linked`.
* The saver isn't installed.

**Nothing is written when every display record already shows the installed LivePaper.saver from a
display's own record** (its own Idle slot, or — a Space's record of it — the display's record):
every display record chose it, or the agent kept its placeholder in `SystemDefault` after LivePaper
filled the displays. LivePaper only records that it owns the selection. System Settings' own
selection doesn't count: its display placeholders inherit `SystemDefault` (or a Space's `Default`),
which the agent derives from the displays at its next launch (§5.5), so "Make LivePaper my screen
saver" and `livepaper select` fill them. A choice of LivePaper.saver at another location is
rewritten.

**Otherwise it runs this sequence:**
1. Hold a lock file, so no other LivePaper process edits the store at the same time, and run the
   checks above again once it has it.
2. Wait until the file has been unchanged for about 1 s.
3. Read the store and decode it with the mirror.
4. Replace `SystemDefault.Idle`, every explicit (non-placeholder) Idle slot — as System Settings
   does, another saver's too — and the placeholder Idle slot of every display record, per display
   and per Space per display (§5.5). The placeholders of Space `Default` records are left alone: a
   display record is tried before its Space's `Default`, every display record gets LivePaper, and
   after the 2026-11-16 fill the agent set the Defaults of the Spaces in use itself while the
   others kept the placeholder with every display still resolving to LivePaper.
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
   * a manifest that records, for each Idle slot it replaces, the user's original choice — a
     placeholder too, so uninstall puts exactly that placeholder back. A placeholder never replaces
     an original recorded earlier: one found later was left by a reset (another tool's uninstaller,
     the quiet re-apply's case), not chosen; a newer explicit choice does replace it.
8. Put it in place with a single atomic rename (only if the file hasn't changed since it was read),
   then **immediately** run `killall WallpaperAgent`.
9. Wait for the restarted agent's own rewrite, re-read the store and confirm the result. A planned
   slot counts as kept when it makes the planned choice; the agent may spell option values and
   timestamps its own way (System Settings itself copies the Desktop's option values into saver
   slots):
   * If the agent wrote its own choice into a planned `SystemDefault` or Space `Default` (§5.5) but
     kept the display slots, and every display record shows what the plan asked for, the change is
     confirmed as it is (select and restore alike): what every display shows is what was asked for.
     Retrying would only restart the agent to the same result. A selection notes what the agent
     wrote there in the manifest, so uninstall still treats that record as LivePaper's.
   * If an Idle choice was lost (the old agent wrote between the rename and the kill), plan again
     and retry, at most twice, 2 s apart. If the new plan is empty, it is confirmed without another
     restart only when every display shows what the last write asked for; otherwise the agent kept
     something else (a restored `SystemDefault` it put a placeholder into): an error, not "done".
   * If the Desktop slots changed or the store is unreadable, roll back: put the original bytes
     back through the same protected steps (wait until unlocked, rename, restart, confirm, retry at
     most twice). Only a confirmed rollback is reported as "put the previous settings back";
     otherwise LivePaper says it couldn't confirm it and names the saved copy from step 7.

**The quiet re-apply** (the app, at launch and after display changes): a display that appears later
gets a record copied from `SystemDefault` (§5.4). If that is the placeholder — the agent kept its own
there, or something reset it — the new display shows macOS's default. So while LivePaper owns the
selection (its manifest exists: it made the selection, or found itself selected and recorded that)
**and is still chosen in some Idle slot**, the app runs the same sequence with a narrower plan: only
the placeholder Idle slots of display records that show macOS's default through placeholders alone,
or inherit LivePaper from `SystemDefault` or a Space's `Default` (which the agent derives from the
displays, §5.5), plus `SystemDefault`'s placeholder with them; each original goes into the manifest
unless one is recorded already. A slot with an explicit choice, and any placeholder that inherits
one (a screen saver the user picked), is never touched; a store that names LivePaper nowhere (the
user switched away, or something reset every slot — the manifest outlives both) is left to the
user's button or `livepaper select`; with nothing to fill there is no plan and no agent restart. The
uninstall marker, the manifest and the saver are checked again while holding the store lock, right
before planning and right before writing, so an uninstall started meanwhile in another process is
never re-selected over. It runs at most once per burst of
`NSApplication.didChangeScreenParametersNotification` (3 s after the last), never while the Mac is
locked (it waits for the unlock) or other install work runs (it waits for that), never after an
uninstall.

Optional hardening, not used: freezing the agent with SIGSTOP while swapping the file would close
the race completely. But if LivePaper crashed mid-step, the process that draws the desktop and the
lock screen would stay frozen.

### 5.7 Undoing it (uninstall)
* Restore runs **before** the `.saver` is deleted. The store must never point at a missing module;
  what the agent does then is Unknown. So the saver is removed only after the store has been
  re-read and no Idle slot names it (a copy of LivePaper.saver at another location that exists
  doesn't count).
* Every Idle slot that is **still LivePaper's** is changed, whether or not LivePaper made the
  selection itself (it may have been picked by hand in System Settings): it names LivePaper.saver,
  or it is a `SystemDefault` / Space `Default` the agent wrote its own choice into when LivePaper
  selected (the manifest notes it) and still holds that choice. The manifest is read while holding
  the store lock.
  * If the manifest has an original for that slot, the original goes back exactly — the
    placeholder of a display record LivePaper filled included. LivePaper.saver
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
* **The displays get what they would inherit.** A display record that the restore leaves holding the
  placeholder, and that would then inherit an explicit choice from `SystemDefault` or a Space's
  `Default` the restore writes (say the saver the user had picked before LivePaper), gets that choice
  itself — a copy of the whole slot, as the agent copies `SystemDefault` into a new display's record.
  By §5.5 the agent would otherwise copy a display's placeholder into `SystemDefault` at once and the
  previous saver would be lost. So the restore is exact, byte for byte, when no display inherits an
  explicit choice (the 2026-11-16 store, a Mac whose saver was never chosen); otherwise every display
  shows exactly what it showed before, from its own record. A choice whose module is missing isn't
  copied.
* The restore is confirmed by what the displays show: every display record must show what the plan
  asked for. If it doesn't, the step fails, names the saver from before LivePaper (so the user can
  pick it in System Settings), and the saver, the manifest and every backup stay.
* Slots the user changed since are left alone.
* The whole old file is **never** put back: that would undo later Desktop changes and drop
  displays and Spaces added since.
* If the restore can't run — for a reason that may pass, such as System Settings being open, or
  one that won't, such as a new store format — or isn't confirmed, the step fails and says what to
  do, and the saver and every backup are kept. Once the user has picked another saver in System
  Settings (nothing names LivePaper any more), running uninstall again finishes.

### 5.8 Detection
* Reading the store, as in §5.2, is the only reliable signal. An Idle slot chooses LivePaper when its
  screen-saver choice names `LivePaper.saver`.
* **Selected** means every display record resolves to LivePaper (Space and display, then Space, then
  display, then `SystemDefault`; with no display record yet, `SystemDefault` decides). A slot that
  names LivePaper is not enough: on 2026-11-16 two did while every display in use showed the aerial.
* **The store's display keys are CoreGraphics display UUIDs** (Verified, 2026-11-16, read-only):
  `CGDisplayCreateUUIDFromDisplayID` of each display `CGGetOnlineDisplayList` listed on the test Mac
  was a key of its store's `Displays` (both connected displays, two of the four in use earlier that
  day). The records of displays not connected stay in the store.
* LivePaper reports (`InstallStatus.saverSelection`, `livepaper doctor`, the app):
  * **every display;**
  * **partly:** some display records resolve to LivePaper, not all — a problem whose fix is
    `livepaper select` or the app's "Use LivePaper on Every Display". It counts the displays some
    record of which (in some Space) shows something else, of the connected displays first ("2 of
    your 2 connected displays"; on 2026-11-16 the two records on LivePaper belonged to displays not
    connected), else of the display records in the store; a display is never counted twice;
  * **none;**
  * **unknown:** the store isn't in a format LivePaper knows but names LivePaper in a screen-saver
    slot (the structural scan) — a warning to check System Settings, never "every display".
  * Uninstall still looks for **any** slot naming LivePaper (that is what it has to undo), and
    "everywhere" (`SystemDefault` and the Space Defaults too) is what a selection writes.
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
* Whether a `SystemDefault` holding another explicit saver, written into the file while the displays
  in use hold the placeholder, survives a restart (§5.5 saw only LivePaper's written back). Uninstall
  doesn't depend on it: the displays that would inherit it get it themselves (§5.7).
* Whether System Settings' own selection, which leaves display placeholders inheriting
  `SystemDefault`, survives the agent's next launch. LivePaper fills those placeholders when it
  selects, and its quiet re-apply does while it owns the selection; a selection made only in
  System Settings (the guided step) isn't LivePaper's to change by itself.
* Which display's slot the agent copies into `SystemDefault` when several are in use (seen: the one
  showing the first Space), and whether the `Default` of a Space not in use is ever read.

## 6. Login items for an ad-hoc-signed helper

These points come from static analysis of ServiceManagement, smd and the background-task manager,
and (6.1) from the log of a login item that an update broke:

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
* **For ad-hoc code, the stored launch constraint is a set of cdhashes**, recorded when the item is
  registered (an ad-hoc helper's designated requirement is `cdhash H"…"`, so it changes with every
  build that changes the helper). An earlier version of this page expected launchd's repair path to
  re-register the item after such a rebuild, at the cost of one failed launch. That was wrong: the
  repair can fail for good (6.1). For code with a Team ID the requirement should name the team rather
  than a cdhash, so a rebuild with the same Team ID keeps starting (Inferred; not seen on the test Mac,
  which only ran ad-hoc builds).
* **Every new registration posts an advisory** (Verified from the log, 6.1): backgroundtaskmanagementd
  makes a new record (`disposition=[enabled, allowed, not notified]`) and about 10 s later posts
  "“LivePaper” can run in the background…", which usernoted shows. Registering again is therefore only
  worth it when launchd can't run the helper as it is.
* Switching the item off in System Settings needs administrator rights. `sfltool resetbtm` would
  reset every app's login items, so LivePaper never uses it.

### 6.1 An update that left the helper unable to start (Verified)

On the test Mac (26.7, ad-hoc-signed development builds, 2026-11-15) the helper's login item had been
registered by build 125. After a later update to build 186 changed the helper, it never ran again
until the app registered it anew; LivePaper's lock shortcut was dead for hours and the app showed
nothing. From the unified log and `launchctl print gui/$UID/com.nachmore.livepaper.helper`:

1. **The first start of the new helper was refused:** `xpcproxy exited due to OS_REASON_CODESIGNING
   | Launch Constraint Violation, … (Constraint not matched)`.
2. **launchd's repair then broke the job.** smd fetched the item by its background-item (BTM) UUID and
   had backgroundtaskmanagementd invalidate it. That made a *new* record, with a new UUID and
   `disposition=[enabled, allowed, not notified]` (plus `Bundle identifiers from launchd plist ignored
   because the executable doesn't have a Team ID`, and a "Login Item Added" advisory), but smd then
   logged `Unable to invalidate item`, and launchd's job kept the old record's UUID.
3. **From then on every start failed in xpcproxy**, before the helper ran: `Unable to resolve <old
   UUID> error: BTMErrorDomain Code=-95`, then `copy_bundle_path(<old UUID>, …), error 0x6f - Invalid
   or missing Program/ProgramArguments`, exit 78. Each try logs `Requesting repair LWCR update`, and
   nothing comes of it; launchd retries every 10 s (`Service only ran for 0 seconds. Pushing respawn
   out by 10 seconds`), well past 1000 runs.
4. **`launchctl print` shows it** (top-level keys): `job state = spawn failed`, `last exit code = 78:
   EX_CONFIG`, `properties = partial import | runatload | resolve program | needs LWCR update | has
   LWCR`, `state = spawn scheduled`. A healthy SMAppService job shows `state = running`, a `pid`, `job
   state = running` and no `needs LWCR update`.
5. **SMAppService still says enabled** all along (smd: `getEffectiveDisposition: disposition=[enabled,
   allowed, notified], have LWCR=true`, `Found status: 1`), so the app's checks saw nothing wrong, and
   `launchctl kickstart` only repeats the failure.
6. **`parent bundle version` is the registering build:** it stayed `125` while the app went to 186
   through several installs. One earlier that day (11:48) had the helper started normally by
   `launchctl kickstart -k` right after it, so an install that leaves the helper unchanged isn't
   affected (Inferred: that start passed the recorded constraint).
7. **A restart is what sets it off.** At 16:32:18, right after a `scripts/dev-install.sh` run, launchd
   stopped the running helper and refused the next spawn (`xpcproxy exited due to OS_REASON_CODESIGNING |
   Launch Constraint Violation`, `Requesting LWCR update on next spawn`); at 16:32:28
   backgroundtaskmanagementd invalidated the item for `/Applications/LivePaper.app`, and at 16:32:39 it
   posted "“LivePaper” can run in the background" for the new record. That install's helper was
   identical to the one it replaced but not to the one that ran, which an earlier install had left
   running (Inferred from the review of that script; the old check compared with the replaced file).
8. **What a running helper runs** (Verified on 26.7 with throwaway ad-hoc binaries): once its
   executable is replaced, `codesign -dvvv <pid>` and `SecCodeCopySigningInformation` describe the
   *new* file at its path (its CDHash), not the code that runs; `codesign --verify <pid>` and
   `SecCodeCheckValidity` fail with errSecCSStaticCodeChanged ("the code on disk does not match what is
   running"), and pass again for byte-identical code in a new file. `proc_pidpath` follows the file when
   it is moved (e.g. to the Trash with its app) and fails with ENOENT once it is deleted.
   `launchctl print` of a service the domain doesn't have exits 113 ("Could not find service").

What fixes it, and what LivePaper does (ARCHITECTURE §7):

* **Register the item again from the app.** SMAppService.h: "If an app updates either the plist or
  the executable for a LaunchAgent or LaunchDaemon, the SMAppService must be re-registered or it may
  not launch. It is recommended to also call unregister before re-registering if the executable has
  been changed." `register()` alone can't do it: for a registered service it returns
  `kSMErrorAlreadyRegistered`. The asynchronous `unregister(completionHandler:)` calls back once the
  job is gone ("After the completion handler has been invoked it is safe to re-register the
  service"). So LivePaper unregisters, waits for that, and registers: only from the app's main
  executable (the CLI and `scripts/dev-install.sh` can't), only for an item that is enabled, at most
  once per launch by itself. That this gives launchd a working job again is **Inferred** from the
  header and smd's register path. It wasn't run on the test Mac, whose login items were not to be
  changed. To confirm after the next update: `launchctl print` should show `state = running` and
  `parent bundle version` = the new build.
* **Approval should survive it** (Inferred): new agents start out enabled and allowed, as the
  repair's replacement record shows (Verified, 2. above). LivePaper re-registers only an enabled item,
  and says so if macOS asks for approval anyway.
* **When it does it — only on positive evidence that launchd can't run this build's helper**, decided
  by code, not by file times or build numbers (ARCHITECTURE §7): launchd can't start the job (the signs
  in 4.), doesn't have it (exit 113; a timeout or another error changes nothing), runs a helper whose
  code is no longer this copy's on disk (8.) when the recorded requirement doesn't cover this copy's
  helper (for ad-hoc code another cdhash), or has a stopped job whose recorded
  helper signature doesn't cover this one (LivePaper records it at every registration; without a
  record, a stopped job registered by an older build). A helper that runs this copy's current code is
  left alone; an outdated one that the recorded requirement covers (the registration's Team ID, or the
  same ad-hoc cdhash — Finder's Replace leaves the old helper running from the Trash) is restarted
  (`kickstart -k`); a stopped job launchd should accept is started. Whether launchd then starts the
  helper of the app at the original path or follows the old one into the Trash wasn't tested (that
  needs the login item on the test Mac); a restart after which the old copy's helper runs again is
  registered again. A start that launchd then refuses is registered again; launchctl text LivePaper
  can't read never leads to an unregister.
* **Only from the copy the login item belongs to:** registering moves the item to the registering app.
  The automatic repair runs only in the copy that registered it — or, without a record (or when that
  copy is gone or in the Trash), in a copy in /Applications or ~/Applications — never in a download,
  a translocated copy, a disk image or a build folder that was just opened. Whether SMAppService reports
  `.enabled` to a second copy at another path wasn't tested (that needs SMAppService calls on the test
  Mac); LivePaper doesn't rely on it.
* **An unfinished re-registration is remembered:** LivePaper writes its intent before the unregister
  and clears it once registering worked, so a register that fails in between is retried at the next
  launch and reported (`livepaper doctor`) rather than leaving the helper unregistered and forgotten.
* **Without the app:** switching LivePaper off and on in Login Items (administrator rights), or
  logging out and in, should make smd submit the job from the current record (Inferred, untested).
* **Keeping the helper byte-identical across app updates avoids all of this** (Inferred from 6.): the
  running helper then passes `SecCodeCheckValidity` against the new file, so LivePaper leaves it alone
  — no re-registration, no advisory.

## 7. When the screens turn off before the screen saver starts

The case behind "Show your scene when the screens turn off first" (ARCHITECTURE §7). On the test
Mac the configuration profile sets `idleTime` 900 s, `askForPassword` 1, `askForPasswordDelay` 0,
and the displays sleep after 5 min on battery and 20 min on AC. On battery the displays turn off
first; macOS locks then (the password is required immediately), no screen saver is running, and the
lock screen shows the desktop picture (§1: loginwindow only uses a saver that runs when the lock
begins; §2: display-sleep locks aren't covered by `immediateLockLaunchesScreenSaver`).

### 7.1 When macOS starts the screen saver (Verified in disassembly, loginwindow, 26.7)

* `-[ScreenSaverDaemon idleTimePreference]` calls `CFPreferencesAppSynchronize` and then
  `CFPreferencesGetAppIntegerValue("idleTime", "com.apple.screensaver")` (`loginWindowIdleTime` while
  the login window is up). That search list puts a configuration profile's forced value first, then
  the user's current-host value (where System Settings writes it), then the any-host one.
* Without a value it uses `_defaultUserIdleTimePreference`, which `-[ScreenSaverDaemon init]` reads
  from `/System/Library/Frameworks/ScreenSaver.framework/Resources/EngineDefaults.plist` (`idleTime`
  1200 on 26.7), falling back to a built-in 1200 s.
* 0 means the screen saver never starts by itself (the System Settings choice "Never").
* LivePaper resolves it the same way (`LPScreenSaverIdle.resolve`). On the test Mac
  `CFPreferencesAppValueIsForced("idleTime")` is true and the value is 900 (Verified, read-only).

### 7.2 When macOS turns the displays off (Verified in the power log)

* `pmset -g custom` prints one section per power source ("Battery Power:", "AC Power:", "UPS
  Power:"), each with `displaysleep` in minutes (0 = never). /Library/Preferences/com.apple.PowerManagement.plist
  holds the same as "Display Sleep Timer", but only the values changed from the defaults.
  `IOPSGetProvidingPowerSourceType` names the source in use with the same strings (public, IOPowerSources.h).
* Activity is tracked with `UserIsActive` assertions: WindowServer's HID tickle
  ("com.apple.iohideventsystem.queue.tickle …"), powerd's "com.apple.powermanagement.kernel.useractive
  …", and processes declaring user activity (rcd's "com.apple.rcdevent", bluetoothd's "Bluetooth LE
  HID Activity", loginwindow, a screen-capture app). Their timeout is the current source's display-sleep time ("Timeout
  will fire in 1200 secs" on AC) and activity re-arms it.
* **"Display is turned off" follows 10–11 s after the last `UserIsActive` assertion times out**, in
  all ten idle display-offs of the test Mac's `pmset -g log` (2026-11-13 to 11-16). The 10 s in
  between are the dim (Inferred: it wasn't watched on screen).
* WindowServer's tickle and powerd's kernel tickle can end minutes apart (7.5 min once); the displays
  went off after the later one. LivePaper's idle time is WindowServer's
  (`CGEventSourceSecondsSinceLastEventType(.hidSystemState, kCGAnyInputEventType)`), and it also takes
  the end of the last `UserIsActive` assertion into account (below), so a declared activity after the
  last key or mouse event doesn't make it start early.
* `IOPMCopyAssertionsByProcess` (public) returns each assertion as a dictionary with `AssertType` /
  `AssertionTrueType`, `AssertLevel`, `AssertName`, `Process Name`, `TimeoutSeconds`, `TimeoutAction`,
  `AssertTimeoutUpdateTime` and `AssertTimeoutTimeLeft` (Verified, read-only). The time left is the
  value at the last re-arm, not a live countdown (one re-armed three minutes earlier still said 300),
  so an assertion ends at update time + time left. These keys aren't documented; when they
  are missing LivePaper uses the HID idle time alone, and when the per-process list can't be read, the
  summary (`IOPMCopyAssertionsStatus`), where any display preventer counts as untimed.
* `ioreg`'s `HIDIdleTime` (IOHIDSystem) wasn't used: it follows the kernel's tickle, which ended 7.5
  minutes before WindowServer's in the example above.

### 7.3 What keeps the displays on (Verified in the power log)

* Call apps and video players hold `NoDisplaySleepAssertion` (for example "… Call in progress",
  Chrome's "Video Wake Lock", Firefox's "video-playing") or `PreventUserIdleDisplaySleep`. The summary (`IOPMCopyAssertionsStatus`, `pmset -g assertions`) counts
  `NoDisplaySleepAssertion` under `PreventUserIdleDisplaySleep`.
* **When such an assertion is released, powerd turns on `InternalPreventDisplaySleep`
  "com.apple.powermanagement.delayDisplayOff"** ("Proxy to delay display off") in the same second,
  with a 300 s timeout (every release in the log, 2026-11-09 to 11-16). So after a call the displays
  stay on for up to 5 more minutes. LivePaper treats untimed display preventers as "the displays
  won't turn off by themselves" (it does nothing) and timed ones by their end.
* The power log shows no assertion from ScreenSaverEngine or legacyScreenSaver (LivePaper's video
  scenes set `preventsDisplaySleepDuringVideoPlayback = false`, Saver/README.md), and the displays do
  sleep under a running saver (Verified 2026-11-16, Saver/README.md: the host stops the animation for
  display sleep; the saver resumes by itself on wake since commit 74f0a05). So a saver LivePaper
  starts early doesn't keep the displays on (Inferred for this exact path: not yet watched end to end).

### 7.4 What LivePaper does, and what is still open

* The helper starts the screen saver through its lock flow 8 s before the predicted dim (the latest
  of display sleep − HID idle, the last `UserIsActive` end, the last timed preventer's end): about 18 s
  before the displays turn off. With the password required immediately the saver locks as it starts,
  so the lock at display sleep finds the session already locked over the running saver. The cost: a
  mouse move in those seconds meets the password prompt instead of an unlocked Mac.
* Nothing runs while the option is off. While on, one one-shot timer, re-armed after activity (about
  once per display-sleep period while the Mac is in use), plus notify(3) observers:
  `com.apple.system.powersources.source` (kIOPSNotifyPowerSource, documented), and two names found as
  strings in powerd and not observed firing: `com.apple.system.powermanagement.prefschange` (energy
  settings changed) and `com.apple.system.powermanagement.assertions` (an assertion summary changed;
  only while the displays are kept on). If the first doesn't fire, a changed display-sleep setting is
  picked up at the next unlock, wake, power-source change or timer.
* **Unknown — to be checked live** (the log lines "before screens off (…)" carry the numbers):
  * the whole path once on battery: started at ~292 s idle, the displays dimming and turning off
    under the saver, the lock screen showing the scene after the wake;
  * whether a strict `DispatchSource` timer in the helper (an accessory app without windows, which
    App Nap may throttle) fires within its 0.5 s leeway — the log records the idle time at every
    evaluation;
  * whether `CGEventSourceSecondsSinceLastEventType` works in the LaunchAgent without Input Monitoring
    (Inferred: it reports only times; it was read from a terminal process here);
  * whether the dim really starts at the `UserIsActive` timeout (the 10 s gap is Inferred to be it).

## 8. An agent whose app went away (session recovery, ARCHITECTURE §10)

An AI agent runs in a process group of its own (`POSIX_SPAWN_SETPGROUP`), so it doesn't die with
LivePaper. What a later LivePaper can know about it (Verified 2026-11-16 on 26.7 with a small test
program and the self-tests' orphaned agents — a shell's `set -m` background job, which leads its own
group, left behind by its exiting shell):

* An orphaned agent is adopted by launchd (ppid 1) and keeps its process group (pgid = its pid).
* `proc_pidinfo(pid, PROC_PIDTBSDINFO)` answers for any of the user's processes, also ones this
  process didn't start: `pbi_start_tvsec`/`pbi_start_tvusec` (the start time, to the microsecond) and
  `pbi_pgid`. For another user's process (launchd, pid 1) it fails without privileges, and for a pid
  that doesn't exist it fails. A pid can be reused once its process is gone; pid + start time + group
  together identify the process.
* `DispatchSource.makeProcessSource(identifier:eventMask: .exit)` on a pid that isn't this process's
  child fires when it exits (within milliseconds), and fires at once — data `NOTE_EXIT` — for a pid that
  doesn't exist, so a watch set up just after the process exited isn't missed. The exit status isn't
  available (only the parent gets it).
* A process group's id is its creator's pid, and it isn't given to another group while any member is
  left; once the leader has exited, signalling the group reaches only its leftovers (Inferred from the
  POSIX rules; matches what the self-tests see).
