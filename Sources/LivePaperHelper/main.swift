// LivePaperHelper — LivePaper's login agent (docs/ARCHITECTURE.md §1, §7).
//
// A plain executable inside the app bundle (LivePaper.app/Contents/Helpers/LivePaperHelper), started
// at login by launchd as the LaunchAgent `com.nachmore.livepaper.helper` (registered by Core's
// InstallService through SMAppService, or a ~/Library/LaunchAgents plist as a fallback). It runs as
// an accessory (LSUIElement-style) NSApplication: no Dock icon, no menu bar, no windows, and it never
// activates itself, so starting it can't take focus from the user.
//
// What it does — event-driven only (no timers, no polling), so it costs nothing while idle:
//  • LivePaper's optional lock shortcut (state.json `lock.hotkey`) through Carbon's
//    RegisterEventHotKey, which needs no TCC permission. Re-read on LPNotification.stateChanged;
//    suspended while the app's shortcut recorder is active (LPNotification.hotkeyRecording,
//    userInfo["active"]) so pressing the current shortcut to re-record it doesn't lock the Mac.
//  • The lock flow, on that shortcut or LPNotification.lockNow: unless a screen saver is already
//    running or the session is already locked, launch /System/Library/CoreServices/
//    ScreenSaverEngine.app. With "Require password after screen saver begins: Immediately" the saver
//    locks and loginwindow draws its lock UI over the running scene. When the password delay isn't
//    immediate the helper logs a warning; it never falls back to private lock APIs.
//  • LPNotification.openApp, posted by the sandboxed saver's "Open LivePaper…" button (sandboxed
//    code can't launch apps): opens the app that contains this helper.
// ⌃⌘Q, Apple menu › Lock Screen and the Touch ID / lock key are not handled here: the app sets
// `com.apple.loginwindow immediateLockLaunchesScreenSaver`, so loginwindow itself starts the saver
// before it locks.
//
// Why the helper must NOT start the screen saver in response to com.apple.screenIsLocked (what the
// early prototype did): when the session locks, loginwindow raises its shield window and asks
// exactly once (-[LWDefaultScreenLockUI _load]) whether a screen saver is running. If one is, the
// lock UI is drawn over the live saver; if not, over the desktop picture, for the rest of that lock.
// A saver started after the lock is discarded by loginwindow: it is never shown, it only runs
// invisibly behind the shield — and with WebKit's occlusion detection disabled (which LivePaper's
// saver needs to draw at all) it keeps animating there, burning CPU and battery for nothing. So the
// order is always "start the saver first; the saver locks", and the helper doesn't observe the lock
// notifications at all.
//
// Uninstall: when LPPaths.uninstallMarker exists the agent exits 0 at launch, before it creates
// anything (HelperLaunchPolicy). A clean exit isn't restarted by launchd's KeepAlive.
//
// Modes: no arguments runs the agent. `--print-config` (JSON, see HelperReport) and `--self-check`
// print the resolved configuration and exit without connecting to the window server, registering
// hotkeys or launching anything; `livepaper doctor` and tests use them.
//
// Logging: os_log, subsystem com.nachmore.livepaper, category helper. SIGTERM (launchctl bootout,
// logout) and SIGINT shut down cleanly with exit status 0, so launchd's KeepAlive
// {SuccessfulExit: false} doesn't restart the agent; SIGHUP re-reads state.json.
import Foundation
import LivePaperCore

/// Writes the report as JSON to stdout.
func printConfig() -> Int32 {
    do {
        let data = try HelperReport(HelperSystem.reportInputs()).json()
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return 0
    } catch {
        FileHandle.standardError.write(Data("LivePaperHelper: couldn't encode the report: \(error)\n".utf8))
        return 1
    }
}

/// Prints a short summary; exit status 1 when the report lists problems.
func selfCheck() -> Int32 {
    let report = HelperReport(HelperSystem.reportInputs())
    print(report.summary)
    return report.problems.isEmpty ? 0 : 1
}

switch HelperCommand.parse(Array(CommandLine.arguments.dropFirst())) {
case .agent:
    // Before anything else: after an uninstall the agent must not create files or register keys.
    if HelperLaunchPolicy.decide(uninstallMarker: LPPaths.uninstallMarker) == .exitUninstalled {
        HelperLog.main.notice("LivePaper was uninstalled (\(LPPaths.uninstallMarker.path, privacy: .public) exists); exiting")
        exit(0)
    }
    MainActor.assumeIsolated { HelperAgent.run() }
case .printConfig:
    exit(printConfig())
case .selfCheck:
    exit(selfCheck())
case .version:
    let app = HelperSystem.appLocator.locate(executable: HelperSystem.executableURL).url
    print("LivePaperHelper \(app.flatMap(HelperAppLocator.infoPlistVersion) ?? "(unbundled build)")")
    exit(0)
case .help:
    print(HelperCommand.usage)
    exit(0)
case .usageError(let message):
    FileHandle.standardError.write(Data("LivePaperHelper: \(message)\n\n\(HelperCommand.usage)\n".utf8))
    exit(64)   // EX_USAGE
}
