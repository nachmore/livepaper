// Self tests for "Show your scene when the screens turn off first" (LPPreSleepPolicy and friends in
// LivePaperCore/Power, the helper's state.json and --print-config parts, the app's status line).
// Recorded values come from a MacBook on macOS 26.7 (docs/RESEARCH.md §7). Nothing here reads the
// live power settings, starts a timer in the helper or touches the real state.json.
import Foundation
import LivePaperCore

private let pmsetLaptop = """
Battery Power:
 Sleep On Power Button 1
 lowpowermode         0
 standby              1
 hibernatefile        /var/vm/sleepimage
 displaysleep         5
 sleep                1
 lessbright           1
AC Power:
 Sleep On Power Button 1
 lowpowermode         0
 displaysleep         20
 womp                 1
 sleep                1
"""

/// Screen timers for the owner's Mac: screens off after 5 min on battery, 20 on the adapter; the
/// screen saver after 15 min, forced by a configuration profile.
private func ownerTimers(on source: LPPowerSource? = .battery, idle: LPScreenSaverIdle? = LPScreenSaverIdle(seconds: 900, source: .managed))
    -> LPScreenTimers {
    LPScreenTimers(displaySleep: [.battery: 300, .ac: 1200], currentSource: source, screenSaverIdle: idle)
}

private func situation(enabled: Bool = true, password: Bool? = true, timers: LPScreenTimers = ownerTimers(),
                       locked: Bool = false, saver: Bool = false, assertions: LPPowerAssertions = LPPowerAssertions()) -> LPPreSleepSituation {
    LPPreSleepSituation(enabled: enabled, passwordImmediately: password, timers: timers, sessionLocked: locked,
                        screenSaverRunning: saver, assertions: assertions)
}

private func reportInputs(config: HelperLockConfig, timers: LPScreenTimers, assertions: LPPowerAssertions? = LPPowerAssertions(),
                          password: HelperPasswordPolicy = HelperPasswordPolicy(requirement: .immediate, source: .managedProfile))
    -> HelperReport.Inputs {
    HelperReport.Inputs(executable: URL(fileURLWithPath: "/Applications/LivePaper.app/Contents/Helpers/LivePaperHelper"),
                        stateFile: URL(fileURLWithPath: "/tmp/lp/state.json"), stateExists: true, config: config,
                        app: HelperAppLocation(url: URL(fileURLWithPath: "/Applications/LivePaper.app"), source: .enclosingBundle),
                        appVersion: "0.1.0", engineExists: true, screenSaverRunning: false, password: password,
                        systemLockTakeover: true, carbonConstantsMatch: true, agentPID: 4242, screenTimers: timers,
                        assertions: assertions)
}

extension SelfTests {
    static var preSleep: [TestCase] {
        preSleepTimers + preSleepAssertions + preSleepDecision + preSleepSchedule + preSleepStatus + preSleepState
            + preSleepHelper + preSleepApp
    }

    // MARK: - Reading the timers

    static var preSleepTimers: [TestCase] { [
        TestCase(name: "core.presleep.pmset-custom") {
            try expectEqual(LPScreenTimers.parsePmsetCustom(pmsetLaptop), [.battery: 300, .ac: 1200])
            // A desktop Mac (only AC Power), `pmset -g`'s annotations, "never" and junk.
            let desktop = "AC Power:\n displaysleep         10 (display sleep prevented by CallApp)\n sleep 0\n"
            try expectEqual(LPScreenTimers.parsePmsetCustom(desktop), [.ac: 600])
            try expectEqual(LPScreenTimers.parsePmsetCustom("UPS Power:\n displaysleep 0\n"), [.ups: 0])
            try expectEqual(LPScreenTimers.parsePmsetCustom("Battery Power:\n displaysleep soon\nAC Power:\n displaysleep -3\n"), [:])
            try expectEqual(LPScreenTimers.parsePmsetCustom("Mystery Power:\n displaysleep 5\n"), [:])
            try expectEqual(LPScreenTimers.parsePmsetCustom(""), [:])
            // The section names are IOKit's power-source types too.
            try expectEqual(LPPowerSource(pmsetName: "Battery Power"), .battery)
            try expectEqual(LPPowerSource(pmsetName: "AC Power"), .ac)
            try expectEqual(LPPowerSource(pmsetName: "UPS Power"), .ups)
            try expectEqual(LPPowerSource(pmsetName: "Solar"), nil)
        },
        TestCase(name: "core.presleep.power-management-plist") {
            // /Library/Preferences/com.apple.PowerManagement.plist, as on the owner's Mac.
            let plist: [String: Any] = [
                "AC Power": ["Display Sleep Timer": 20, "System Sleep Timer": 1],
                "Battery Power": ["Display Sleep Timer": 5, "ReduceBrightness": 1],
                "SystemPowerSettings": ["DestroyFVKeyOnStandby": 0],
            ]
            try expectEqual(LPScreenTimers.parsePowerManagementPreferences(plist), [.battery: 300, .ac: 1200])
            try expectEqual(LPScreenTimers.parsePowerManagementPreferences(["AC Power": ["Display Sleep Timer": "x"]]), [:])
        },
        TestCase(name: "core.presleep.idle-time") {
            let defaults: [String: Any] = ["idleTime": 1200, "moduleName": "Ventura"]
            // A profile wins (forced value, else the managed plist), even over the user's value.
            try expectEqual(LPScreenSaverIdle.resolve(forced: 900, managed: [:], userCurrentHost: 300, userAnyHost: nil, engineDefaults: defaults),
                            LPScreenSaverIdle(seconds: 900, source: .managed))
            try expectEqual(LPScreenSaverIdle.resolve(forced: nil, managed: ["idleTime": 600, "askForPassword": true], userCurrentHost: 300,
                                                      userAnyHost: nil, engineDefaults: defaults),
                            LPScreenSaverIdle(seconds: 600, source: .managed))
            // The user's: this host's first, then any host's.
            try expectEqual(LPScreenSaverIdle.resolve(forced: nil, managed: [:], userCurrentHost: 300, userAnyHost: 60, engineDefaults: defaults),
                            LPScreenSaverIdle(seconds: 300, source: .user))
            try expectEqual(LPScreenSaverIdle.resolve(forced: nil, managed: [:], userCurrentHost: nil, userAnyHost: "120", engineDefaults: defaults),
                            LPScreenSaverIdle(seconds: 120, source: .user))
            // 0 = never is a value, not "unset".
            try expectEqual(LPScreenSaverIdle.resolve(forced: nil, managed: [:], userCurrentHost: 0, userAnyHost: 300, engineDefaults: defaults),
                            LPScreenSaverIdle(seconds: 0, source: .user))
            // Nothing set: EngineDefaults.plist, else loginwindow's 1200 s.
            try expectEqual(LPScreenSaverIdle.resolve(forced: nil, managed: [:], userCurrentHost: nil, userAnyHost: nil,
                                                      engineDefaults: ["idleTime": 600]),
                            LPScreenSaverIdle(seconds: 600, source: .systemDefault))
            try expectEqual(LPScreenSaverIdle.resolve(forced: nil, managed: [:], userCurrentHost: nil, userAnyHost: nil, engineDefaults: nil),
                            LPScreenSaverIdle(seconds: 1200, source: .systemDefault))
            // Nonsense is skipped: a Bool, a negative number, text.
            try expectEqual(LPScreenSaverIdle.resolve(forced: true, managed: ["idleTime": -5], userCurrentHost: "soon", userAnyHost: 240,
                                                      engineDefaults: defaults),
                            LPScreenSaverIdle(seconds: 240, source: .user))
        },
        TestCase(name: "core.presleep.probe-reads-through-its-stand-ins") {
            let dir = try tempDir("presleep-probe")
            defer { try? FileManager.default.removeItem(at: dir) }
            let managed = dir.appendingPathComponent("com.apple.screensaver.plist")
            try PropertyListSerialization.data(fromPropertyList: ["idleTime": 900, "askForPassword": true, "askForPasswordDelay": 0],
                                               format: .xml, options: 0).write(to: managed)
            let runner = RecordingCommandRunner { exe, args in
                exe == "/usr/bin/pmset" && args == ["-g", "custom"] ? CommandResult(status: 0, stdout: pmsetLaptop) : nil
            }
            let probe = LPPowerProbe(runner: runner, preferences: NoPreferences(), managedPreferences: [managed],
                                     powerManagementPreferences: dir.appendingPathComponent("none.plist"),
                                     engineDefaults: dir.appendingPathComponent("none.plist"), currentSource: { .battery })
            try expectEqual(probe.screenTimers(), ownerTimers())
            try expectEqual(runner.commands, [["/usr/bin/pmset", "-g", "custom"]])
            // pmset gives nothing: the power-management plist (only what differs from macOS's defaults).
            let plist = dir.appendingPathComponent("com.apple.PowerManagement.plist")
            try PropertyListSerialization.data(fromPropertyList: ["Battery Power": ["Display Sleep Timer": 2]], format: .xml, options: 0)
                .write(to: plist)
            let silent = LPPowerProbe(runner: RecordingCommandRunner(), preferences: NoPreferences(), managedPreferences: [],
                                      powerManagementPreferences: plist, engineDefaults: dir.appendingPathComponent("none.plist"),
                                      currentSource: { nil })
            try expectEqual(silent.screenTimers(), LPScreenTimers(displaySleep: [.battery: 120], currentSource: nil,
                                                                  screenSaverIdle: LPScreenSaverIdle(seconds: 1200, source: .systemDefault)))
        },
        TestCase(name: "core.presleep.install-status-carries-timers") {
            // InstallService reports the timers it is given, and with only recorded commands (tests,
            // `LIVEPAPER_NO_SYSTEM_COMMANDS`) it reads nothing from the live system.
            try withScratchPaths("presleep-install") { root in
                let paths = InstallPaths.current()
                let recorded = InstallService(paths: paths, publisher: nil, runner: RecordingCommandRunner(), loginItem: NoLoginItem(),
                                              preferences: NoPreferences())
                try expectEqual(recorded.status().screenTimers, LPScreenTimers())
                let given = InstallService(paths: paths, publisher: nil, runner: RecordingCommandRunner(), loginItem: NoLoginItem(),
                                           preferences: NoPreferences(), screenTimers: { ownerTimers() })
                try expectEqual(given.status().screenTimers, ownerTimers())
                _ = root
            }
        },
    ] }

    // MARK: - Assertions

    static var preSleepAssertions: [TestCase] { [
        TestCase(name: "core.presleep.assertions") {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            func at(_ offset: TimeInterval) -> Date { now.addingTimeInterval(offset) }
            // Shapes recorded from IOPMCopyAssertionsByProcess (macOS 26.7).
            let call: [String: Any] = ["AssertType": "NoDisplaySleepAssertion", "AssertionTrueType": "NoDisplaySleepAssertion",
                                       "AssertLevel": 255, "AssertName": "Call in progress", "Process Name": "CallApp",
                                       "AssertStartWhen": at(-3000)]
            let proxy: [String: Any] = ["AssertType": "InternalPreventDisplaySleep", "AssertLevel": 255,
                                        "AssertName": "com.apple.powermanagement.delayDisplayOff", "Process Name": "powerd",
                                        "AssertStartWhen": at(-100), "AssertTimeoutUpdateTime": at(-100), "AssertTimeoutTimeLeft": 300,
                                        "TimeoutSeconds": 300, "TimeoutAction": "TimeoutActionTurnOff"]
            let hid: [String: Any] = ["AssertType": "UserIsActive", "AssertLevel": 255, "Process Name": "WindowServer",
                                      "AssertName": "com.apple.iohideventsystem.queue.tickle", "AssertStartWhen": at(-900),
                                      "AssertTimeoutUpdateTime": at(-290), "AssertTimeoutTimeLeft": 300, "TimeoutSeconds": 300,
                                      "TimeoutAction": "TimeoutActionRelease"]
            let declared: [String: Any] = ["AssertType": "UserIsActive", "AssertLevel": 255, "Process Name": "rcd",
                                           "AssertName": "com.apple.rcdevent", "AssertTimeoutUpdateTime": at(-200),
                                           "AssertTimeoutTimeLeft": 300, "TimeoutSeconds": 300, "TimeoutAction": "TimeoutActionRelease"]
            let expired: [String: Any] = ["AssertType": "UserIsActive", "AssertLevel": 255, "AssertTimeoutUpdateTime": at(-400),
                                          "AssertTimeoutTimeLeft": 300, "TimeoutSeconds": 300]
            let off: [String: Any] = ["AssertType": "PreventUserIdleDisplaySleep", "AssertLevel": 0, "AssertName": "video"]
            let logOnly: [String: Any] = ["AssertType": "PreventUserIdleDisplaySleep", "AssertLevel": 255, "AssertName": "slides",
                                          "AssertPID": 42, "AssertStartWhen": at(-10), "TimeoutSeconds": 60, "TimeoutAction": "TimeoutActionLog"]
            let unrelated: [String: Any] = ["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255, "AssertName": "com.apple.BTStack"]

            let parsed = LPPowerAssertions.parse([call, proxy, hid, declared, expired, off, logOnly, unrelated], now: now)
            try expectEqual(parsed.preventingDisplaySleep, ["CallApp: Call in progress", "pid 42: slides"])
            try expectEqual(parsed.preventionEnds, at(200))
            // The latest UserIsActive counts (rcd's declared activity, after the last HID input).
            try expectEqual(parsed.userActivityEnds, at(100))
            // Nothing held: nothing known.
            try expectEqual(LPPowerAssertions.parse([unrelated, expired], now: now), LPPowerAssertions())
            // The summary (IOPMCopyAssertionsStatus) when the per-process list can't be read.
            let summary: [String: Any] = ["PreventUserIdleDisplaySleep": 1, "InternalPreventDisplaySleep": 0, "UserIsActive": 1]
            try expectEqual(LPPowerAssertions.fromSummary(summary), LPPowerAssertions(preventingDisplaySleep: ["PreventUserIdleDisplaySleep"]))
            try expectEqual(LPPowerAssertions.fromSummary(["PreventUserIdleDisplaySleep": 0]), LPPowerAssertions())
        },
    ] }

    // MARK: - The decision

    static var preSleepDecision: [TestCase] { [
        TestCase(name: "core.presleep.decide-applies") {
            try expectEqual(LPPreSleepPolicy.decide(situation()), .watch(displaySleep: 300, screenSaverIdle: 900))
            // The user's idle time counts like a managed one, and 0 (never) is longer than any display sleep.
            try expectEqual(LPPreSleepPolicy.decide(situation(timers: ownerTimers(idle: LPScreenSaverIdle(seconds: 600, source: .user)))),
                            .watch(displaySleep: 300, screenSaverIdle: 600))
            try expectEqual(LPPreSleepPolicy.decide(situation(timers: ownerTimers(on: .ac, idle: LPScreenSaverIdle(seconds: 0, source: .user)))),
                            .watch(displaySleep: 1200, screenSaverIdle: 0))
            // A UPS has its own settings.
            let ups = LPScreenTimers(displaySleep: [.ups: 120], currentSource: .ups, screenSaverIdle: LPScreenSaverIdle(seconds: 900, source: .user))
            try expectEqual(LPPreSleepPolicy.decide(situation(timers: ups)), .watch(displaySleep: 120, screenSaverIdle: 900))
        },
        TestCase(name: "core.presleep.decide-not-needed") {
            // On the adapter the screen saver (15 min) starts before the screens turn off (20 min).
            try expectEqual(LPPreSleepPolicy.decide(situation(timers: ownerTimers(on: .ac))),
                            .inactive(.screenSaverStartsFirst(.ac, displaySleep: 1200, screenSaverIdle: 900)))
            // Equal is not shorter.
            let equal = LPScreenTimers(displaySleep: [.battery: 900], currentSource: .battery, screenSaverIdle: LPScreenSaverIdle(seconds: 900, source: .user))
            try expectEqual(LPPreSleepPolicy.decide(situation(timers: equal)),
                            .inactive(.screenSaverStartsFirst(.battery, displaySleep: 900, screenSaverIdle: 900)))
            // Screens that never turn off by themselves.
            let never = LPScreenTimers(displaySleep: [.battery: 0], currentSource: .battery, screenSaverIdle: LPScreenSaverIdle(seconds: 900, source: .user))
            try expectEqual(LPPreSleepPolicy.decide(situation(timers: never)), .inactive(.displaysNeverSleep(.battery)))
            // Unknown power source / unknown timer for it.
            try expectEqual(LPPreSleepPolicy.decide(situation(timers: ownerTimers(on: nil))), .inactive(.powerSourceUnknown))
            try expectEqual(LPPreSleepPolicy.decide(situation(timers: ownerTimers(on: .ups))), .inactive(.displaySleepUnknown(.ups)))
            // No idle time read: loginwindow's default (1200 s) still says the battery's 5 min come first.
            try expectEqual(LPPreSleepPolicy.decide(situation(timers: ownerTimers(idle: nil))), .watch(displaySleep: 300, screenSaverIdle: 1200))
        },
        TestCase(name: "core.presleep.decide-conditions") {
            try expectEqual(LPPreSleepPolicy.decide(situation(enabled: false)), .inactive(.optionOff))
            try expectEqual(LPPreSleepPolicy.decide(situation(locked: true)), .inactive(.sessionLocked))
            try expectEqual(LPPreSleepPolicy.decide(situation(saver: true)), .inactive(.screenSaverRunning))
            // Without "require password immediately" starting early changes nothing security-wise; it
            // would only show the saver sooner than expected.
            try expectEqual(LPPreSleepPolicy.decide(situation(password: false)), .inactive(.passwordNotImmediate))
            try expectEqual(LPPreSleepPolicy.decide(situation(password: nil)), .inactive(.passwordUnknown))
            // The option comes first: nothing else is even looked at while it is off.
            try expectEqual(LPPreSleepPolicy.decide(situation(enabled: false, password: false, locked: true)), .inactive(.optionOff))
            // A call keeps the screens on: look again later.
            let call = LPPowerAssertions(preventingDisplaySleep: ["CallApp: Call in progress"])
            try expectEqual(LPPreSleepPolicy.decide(situation(assertions: call)),
                            .blocked(.displaySleepPrevented(["CallApp: Call in progress"])))
            // …but not where the option has nothing to do anyway.
            try expectEqual(LPPreSleepPolicy.decide(situation(timers: ownerTimers(on: .ac), assertions: call)),
                            .inactive(.screenSaverStartsFirst(.ac, displaySleep: 1200, screenSaverIdle: 900)))
            // A timed preventer (powerd's "delay display off") doesn't block; the schedule waits for it.
            try expectEqual(LPPreSleepPolicy.decide(situation(assertions: LPPowerAssertions(preventionEnds: Date()))),
                            .watch(displaySleep: 300, screenSaverIdle: 900))
            try expect(LPPreSleepReason.displaySleepPrevented(["MeetingApp: Meeting in progress"]).description.contains("MeetingApp"))
        },
        TestCase(name: "core.presleep.applies-per-source") {
            try expectEqual(LPPreSleepPolicy.applies(on: .battery, timers: ownerTimers()), true)
            try expectEqual(LPPreSleepPolicy.applies(on: .ac, timers: ownerTimers()), false)
            try expectEqual(LPPreSleepPolicy.applies(on: .ups, timers: ownerTimers()), nil)
            try expectEqual(LPPreSleepPolicy.applies(on: .ac, timers: ownerTimers(idle: LPScreenSaverIdle(seconds: 0, source: .user))), true)
            try expectEqual(LPPreSleepStatus.applicableSources(ownerTimers()), [.battery])
        },
    ] }

    // MARK: - The schedule

    static var preSleepSchedule: [TestCase] { [
        TestCase(name: "core.presleep.schedule-next-fire") {
            let lead = LPPreSleepSchedule.lead
            try expectEqual(lead, 8)
            try expectEqual(LPPreSleepSchedule.threshold(displaySleep: 300), 292)
            // Fresh activity: the full threshold. Some idle time so far: the rest of it.
            try expectEqual(LPPreSleepSchedule.next(displaySleep: 300, idle: 0), .check(after: 292))
            try expectEqual(LPPreSleepSchedule.next(displaySleep: 300, idle: 100), .check(after: 192))
            // The timer fired but there was activity meanwhile (idle reset to 12 s): armed again.
            try expectEqual(LPPreSleepSchedule.next(displaySleep: 300, idle: 12), .check(after: 280))
            // At the threshold, a little early (timer leeway) or a little late: start.
            try expectEqual(LPPreSleepSchedule.next(displaySleep: 300, idle: 292), .start(dimsIn: 8))
            try expectEqual(LPPreSleepSchedule.next(displaySleep: 300, idle: 291.5), .start(dimsIn: 8.5))
            try expectEqual(LPPreSleepSchedule.next(displaySleep: 300, idle: 296), .start(dimsIn: 4))
            try expectEqual(LPPreSleepSchedule.next(displaySleep: 300, idle: 302), .start(dimsIn: -2))
            // Long past (the Mac woke idle, the timer was held back): don't start; the earliest next
            // crossing is a full threshold after the next activity.
            try expectEqual(LPPreSleepSchedule.next(displaySleep: 300, idle: 330), .missed(checkAfter: 292))
            try expectEqual(LPPreSleepSchedule.next(displaySleep: 300, idle: 5000), .missed(checkAfter: 292))
            // Just over a second early: another (short) timer rather than starting 9+ s ahead.
            try expectEqual(LPPreSleepSchedule.next(displaySleep: 300, idle: 290), .check(after: 2))
            // A negative idle time from a clock hiccup counts as fresh activity.
            try expectEqual(LPPreSleepSchedule.next(displaySleep: 300, idle: -3), .check(after: 292))
        },
        TestCase(name: "core.presleep.schedule-assertion-ends") {
            // An app declared user activity after the last HID input (rcd, Bluetooth HID, capture
            // apps): the screens dim when that times out, not when the HID idle time says.
            try expectEqual(LPPreSleepSchedule.next(displaySleep: 300, idle: 292, userActivityEndsIn: 120), .check(after: 112))
            // A UserIsActive that ends earlier than the HID idle time predicts changes nothing.
            try expectEqual(LPPreSleepSchedule.next(displaySleep: 300, idle: 100, userActivityEndsIn: 50), .check(after: 192))
            // powerd's "delay display off" after a call: the screens stay on until it ends.
            try expectEqual(LPPreSleepSchedule.next(displaySleep: 300, idle: 2000, preventionEndsIn: 150), .check(after: 142))
            try expectEqual(LPPreSleepSchedule.next(displaySleep: 300, idle: 2000, preventionEndsIn: 7), .start(dimsIn: 7))
            // Both: the later one.
            try expectEqual(LPPreSleepSchedule.next(displaySleep: 300, idle: 0, userActivityEndsIn: 310, preventionEndsIn: 400), .check(after: 392))
            // While the screens are kept on: one full threshold.
            try expectEqual(LPPreSleepSchedule.recheck(displaySleep: 300), 292)
            try expectEqual(LPPreSleepSchedule.recheck(displaySleep: 1200), 1192)
        },
    ] }

    // MARK: - Status text

    static var preSleepStatus: [TestCase] { [
        TestCase(name: "core.presleep.status-text") {
            func text(_ timers: LPScreenTimers) -> String { text(true, timers) }
            func text(_ password: Bool?, _ timers: LPScreenTimers) -> String {
                LPPreSleepStatus.text(passwordImmediately: password, timers: timers)
            }
            try expectEqual(text(ownerTimers()), "Applies on battery: screens off after 5 min, screen saver after 15 min")
            // The same whichever source is in use: the line describes the settings.
            try expectEqual(text(ownerTimers(on: .ac)), "Applies on battery: screens off after 5 min, screen saver after 15 min")
            let both = LPScreenTimers(displaySleep: [.battery: 120, .ac: 600], currentSource: .ac,
                                      screenSaverIdle: LPScreenSaverIdle(seconds: 1200, source: .systemDefault))
            try expectEqual(text(both), "Applies on battery and on power adapter: screens off after 2 and 10 min, screen saver after 20 min")
            try expectEqual(text(ownerTimers(idle: LPScreenSaverIdle(seconds: 0, source: .user))),
                            "Applies on battery and on power adapter: screens off after 5 and 20 min, the screen saver never starts by itself")
            let first = LPScreenTimers(displaySleep: [.battery: 600, .ac: 1200], currentSource: .battery,
                                       screenSaverIdle: LPScreenSaverIdle(seconds: 300, source: .user))
            try expectEqual(text(first), "Not needed: the screen saver starts before the screens turn off")
            let never = LPScreenTimers(displaySleep: [.ac: 0], currentSource: .ac, screenSaverIdle: LPScreenSaverIdle(seconds: 300, source: .user))
            try expectEqual(text(never), "Not needed: your screens don\u{2019}t turn off by themselves")
            try expectEqual(text(false, ownerTimers()), "Off: your password isn\u{2019}t required immediately after the screen saver starts")
            try expectEqual(text(nil, ownerTimers()), "Off: LivePaper can\u{2019}t tell whether your password is required immediately")
            try expectEqual(text(LPScreenTimers()), "LivePaper can\u{2019}t tell when your screens turn off")
            let odd = LPScreenTimers(displaySleep: [.battery: 90], currentSource: .battery, screenSaverIdle: LPScreenSaverIdle(seconds: 45, source: .user))
            try expectEqual(text(odd), "Not needed: the screen saver starts before the screens turn off")
            let seconds = LPScreenTimers(displaySleep: [.battery: 90], currentSource: .battery,
                                         screenSaverIdle: LPScreenSaverIdle(seconds: 150, source: .user))
            try expectEqual(text(seconds), "Applies on battery: screens off after 1 min 30 s, screen saver after 2 min 30 s")
            try expectEqual(LPPreSleepStatus.duration(45), "45 s")
        },
    ] }

    // MARK: - state.json

    static var preSleepState: [TestCase] { [
        TestCase(name: "core.presleep.state-json") {
            try expectEqual(LPSharedState().lock.showSceneBeforeDisplaySleep, false)
            // Files from before the option decode as off.
            let old = Data(#"{"schema": 1, "lock": {"hotkey": {"keyCode": 37, "modifiers": ["control", "command"]}, "lockKeysShowScene": true}}"#.utf8)
            let decoded = try SceneManifest.decoder().decode(LPSharedState.self, from: old)
            try expectEqual(decoded.lock.showSceneBeforeDisplaySleep, false)
            try expectEqual(decoded.lock.lockKeysShowScene, true)
            let older = Data(#"{"schema": 1, "lock": {"takeOverSystemLock": true}}"#.utf8)
            try expectEqual(try SceneManifest.decoder().decode(LPSharedState.self, from: older).lock.showSceneBeforeDisplaySleep, false)
            // Anything but a Bool is off and doesn't break the rest of the file.
            for value in ["null", "\"yes\"", "1", "{}"] {
                let odd = Data(#"{"schema": 1, "lock": {"lockKeysShowScene": true, "showSceneBeforeDisplaySleep": \#(value)}}"#.utf8)
                let state = try SceneManifest.decoder().decode(LPSharedState.self, from: odd)
                try expectEqual(state.lock.showSceneBeforeDisplaySleep, false)
                try expectEqual(state.lock.lockKeysShowScene, true)
            }
            // Round trip, and the key is always written.
            var on = LPSharedState()
            on.lock.showSceneBeforeDisplaySleep = true
            let data = try SceneManifest.encoder().encode(on)
            try expect(String(decoding: data, as: UTF8.self).contains("\"showSceneBeforeDisplaySleep\" : true"), String(decoding: data, as: UTF8.self))
            try expectEqual(try SceneManifest.decoder().decode(LPSharedState.self, from: data), on)
            let offData = try SceneManifest.encoder().encode(LPSharedState())
            try expect(String(decoding: offData, as: UTF8.self).contains("\"showSceneBeforeDisplaySleep\" : false"))
        },
        TestCase(name: "helper.state.before-display-sleep") {
            var state = LPSharedState()
            state.lock.showSceneBeforeDisplaySleep = true
            let data = try SceneManifest.encoder().encode(state)
            try expectEqual(HelperStateReader.config(fromStateData: data, previous: nil),
                            HelperLockConfig(hotkey: .controlCommandL, showSceneBeforeDisplaySleep: true, source: .stateFile))
            try expectEqual(HelperLockConfig.defaults.showSceneBeforeDisplaySleep, false)
            try expectEqual(HelperStateReader.config(fromStateData: nil, previous: nil).showSceneBeforeDisplaySleep, false)
            // Fallback (LPSharedState doesn't decode): only a JSON true turns it on.
            func fallback(_ value: String) -> HelperLockConfig {
                HelperStateReader.config(fromStateData: Data(#"{"schema": 9, "lock": {"showSceneBeforeDisplaySleep": \#(value)}, "installedAt": 5}"#.utf8),
                                         previous: nil)
            }
            try expectEqual(fallback("true").showSceneBeforeDisplaySleep, true)
            try expectEqual(fallback("true").source, .fallback)
            for off in ["false", "1", "\"true\"", "null", "[]"] { try expectEqual(fallback(off).showSceneBeforeDisplaySleep, false) }
            let absent = HelperStateReader.config(fromStateData: Data(#"{"lock": {}}"#.utf8), previous: nil)
            try expectEqual(absent.showSceneBeforeDisplaySleep, false)
            // An unreadable file keeps what was in effect.
            let previous = HelperLockConfig(hotkey: nil, showSceneBeforeDisplaySleep: true, source: .stateFile)
            let kept = HelperStateReader.config(fromStateData: Data("{nope".utf8), previous: previous)
            try expectEqual(kept.showSceneBeforeDisplaySleep, true)
            try expectEqual(kept.source, .previous)
        },
    ] }

    // MARK: - Helper: trigger and --print-config

    static var preSleepHelper: [TestCase] { [
        TestCase(name: "helper.presleep.trigger") {
            // The display-sleep start is LivePaper's own idea: a refusal is never shown to the user.
            try expect(!HelperLockTrigger.beforeDisplaySleep.reportsRefusal)
            try expect(HelperLockTrigger.hotkey.reportsRefusal && HelperLockTrigger.lockNowNotification.reportsRefusal)
            // It goes through the same lock decision as Lock Now.
            let lockSituation = HelperLockSituation(engineExists: true, screenSaverRunning: false, sessionLocked: false,
                                                    launchInFlight: false, password: .immediate)
            try expectEqual(HelperLockPolicy.decide(lockSituation), .startScreenSaver)
            try expectEqual(HelperPasswordPolicy(requirement: .immediate, source: .sysadminctl).immediately, true)
            try expectEqual(HelperPasswordPolicy(requirement: .delayed, delaySeconds: 5, source: .sysadminctl).immediately, false)
            try expectEqual(HelperPasswordPolicy(requirement: .off, source: .sysadminctl).immediately, false)
            try expectEqual(HelperPasswordPolicy(requirement: .unknown, source: .none).immediately, nil)
        },
        TestCase(name: "helper.presleep.report") {
            let on = HelperLockConfig(hotkey: nil, showSceneBeforeDisplaySleep: true, source: .stateFile)
            let report = HelperReport(reportInputs(config: on, timers: ownerTimers()))
            try expectEqual(report.preSleep, HelperReport.PreSleep(
                enabled: true, appliesOn: [.battery], status: "Applies on battery: screens off after 5 min, screen saver after 15 min",
                now: "watching: screens off after 300 s, screen saver after 900 s; starts the screen saver 8 s before the screens dim",
                powerSource: .battery, displaySleepSeconds: [.battery: 300, .ac: 1200], screenSaverIdleSeconds: 900,
                screenSaverIdleSource: .managed, leadSeconds: 8, preventedBy: []))
            try expect(report.summary.contains("before screens off: on — Applies on battery"), report.summary)
            try expect(report.problems.isEmpty && report.warnings.isEmpty, "\(report.problems) \(report.warnings)")
            // JSON: per-source seconds as an object, and it round-trips.
            let data = try report.json()
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let preSleep = object?["preSleep"] as? [String: Any]
            try expectEqual(preSleep?["displaySleepSeconds"] as? [String: Int], ["battery": 300, "ac": 1200])
            try expectEqual(preSleep?["appliesOn"] as? [String], ["battery"])
            try expectEqual(try JSONDecoder().decode(HelperReport.self, from: data), report)

            let off = HelperReport(reportInputs(config: HelperLockConfig(hotkey: nil, source: .stateFile), timers: ownerTimers(on: .ac)))
            try expectEqual(off.preSleep.enabled, false)
            try expectEqual(off.preSleep.now, "inactive: the option is off")
            try expect(off.summary.contains("before screens off: off — Applies on battery"), off.summary)
            let adapter = HelperReport(reportInputs(config: on, timers: ownerTimers(on: .ac)))
            try expect(adapter.preSleep.now.hasPrefix("inactive: the screen saver starts first on power adapter"), adapter.preSleep.now)
            let call = HelperReport(reportInputs(config: on, timers: ownerTimers(),
                                                 assertions: LPPowerAssertions(preventingDisplaySleep: ["MeetingApp: Meeting in progress"])))
            try expectEqual(call.preSleep.preventedBy, ["MeetingApp: Meeting in progress"])
            try expect(call.preSleep.now.hasPrefix("blocked: the screens are kept on by MeetingApp"), call.preSleep.now)
            let delayed = HelperReport(reportInputs(config: on, timers: ownerTimers(),
                                                    password: HelperPasswordPolicy(requirement: .delayed, delaySeconds: 5, source: .sysadminctl)))
            try expectEqual(delayed.preSleep.status, "Off: your password isn\u{2019}t required immediately after the screen saver starts")
            try expectEqual(delayed.preSleep.now, "inactive: the password isn't required immediately after the screen saver starts")
        },
    ] }

    // MARK: - App

    static var preSleepApp: [TestCase] { [
        TestCase(name: "app.settings.before-screens-off") {
            let status = InstallStatus(passwordImmediately: true, screenTimers: ownerTimers(on: .ac))
            try withInstallModel("presleep-app", status: status, locked: false) { model, install, _ in
                try awaitMain { await model.refreshInstallStatus() }
                try expectEqual(model.preSleepStatus, "Applies on battery: screens off after 5 min, screen saver after 15 min")
                try expectEqual(model.showSceneBeforeDisplaySleep, false)
                model.setShowSceneBeforeDisplaySleep(true)
                try expectEqual(model.showSceneBeforeDisplaySleep, true)
                try expectEqual(model.sharedState.lock.showSceneBeforeDisplaySleep, true)
                model.setShowSceneBeforeDisplaySleep(false)
                try expectEqual(model.sharedState.lock.showSceneBeforeDisplaySleep, false)
                _ = install
            }
            // The line follows the password setting and the timers as the status is read again.
            let delayed = InstallStatus(passwordImmediately: false, screenTimers: ownerTimers())
            try withInstallModel("presleep-app-password", status: delayed, locked: false) { model, _, _ in
                try awaitMain { await model.refreshInstallStatus() }
                try expectEqual(model.preSleepStatus, "Off: your password isn\u{2019}t required immediately after the screen saver starts")
            }
            let notNeeded = InstallStatus(passwordImmediately: true, screenTimers: LPScreenTimers(
                displaySleep: [.ac: 1800], currentSource: .ac, screenSaverIdle: LPScreenSaverIdle(seconds: 600, source: .user)))
            try withInstallModel("presleep-app-not-needed", status: notNeeded, locked: false) { model, _, _ in
                try awaitMain { await model.refreshInstallStatus() }
                try expectEqual(model.preSleepStatus, "Not needed: the screen saver starts before the screens turn off")
            }
        },
        TestCase(name: "app.settings.before-screens-off-saved") {
            try withModel("presleep-app-saved") { model, fx in
                let before = fx.saved.count
                model.setShowSceneBeforeDisplaySleep(true)
                try expectEqual(fx.saved.count, before + 1)
                try expectEqual(fx.saved.last?.lock.showSceneBeforeDisplaySleep, true)
                // Unchanged: nothing written.
                model.setShowSceneBeforeDisplaySleep(true)
                try expectEqual(fx.saved.count, before + 1)
                // The hotkey and lock-keys mirror stay as they were.
                try expectEqual(fx.saved.last?.lock.hotkey, LPSharedState().lock.hotkey)
            }
        },
    ] }
}

/// Preferences with nothing set (InstallService and LPPowerProbe only read here).
private struct NoPreferences: PreferencesAccessing {
    func value(domain: String, key: String, currentHost: Bool) -> Any? { nil }
    func set(_ value: Any?, domain: String, key: String, currentHost: Bool) -> Bool { false }
}
