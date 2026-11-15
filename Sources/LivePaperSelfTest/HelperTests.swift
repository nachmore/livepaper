// Self tests owned by WS-helper.
//
// The helper is an executable target, so its Foundation-only parts (Sources/LivePaperHelper/Logic/)
// are compiled into this target through the symlinks in Sources/LivePaperSelfTest/HelperLogic/.
// Nothing here registers a hotkey, connects to the window server, launches anything or touches
// the real state.json: files live in temp directories and system facts are passed in.
import Darwin
import Foundation
import LivePaperCore

private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

private func json(_ text: String) -> Data { Data(text.utf8) }

/// A fake bundle at `root/<name>` with an Info.plist, plus an executable at `relativeExecutable`.
@discardableResult
private func makeBundle(_ root: URL, name: String, bundleID: String?, version: String? = nil,
                        executable relativeExecutable: String? = nil) throws -> URL {
    let bundle = root.appendingPathComponent(name)
    let contents = bundle.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var info: [String: Any] = [:]
    if let bundleID { info["CFBundleIdentifier"] = bundleID }
    if let version { info["CFBundleShortVersionString"] = version }
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    if let relativeExecutable {
        let exe = bundle.appendingPathComponent(relativeExecutable)
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: exe)
    }
    return bundle
}

private func reportInputs(config: HelperLockConfig = .defaults, stateExists: Bool = true,
                          app: HelperAppLocation = HelperAppLocation(url: URL(fileURLWithPath: "/Applications/LivePaper.app"),
                                                                     source: .enclosingBundle),
                          password: HelperPasswordPolicy = HelperPasswordPolicy(requirement: .immediate, source: .sysadminctl),
                          engineExists: Bool = true, carbonOK: Bool = true, agentPID: Int32? = 4242) -> HelperReport.Inputs {
    HelperReport.Inputs(executable: URL(fileURLWithPath: "/Applications/LivePaper.app/Contents/Helpers/LivePaperHelper"),
                        stateFile: URL(fileURLWithPath: "/tmp/lp/state.json"), stateExists: stateExists, config: config,
                        app: app, appVersion: "0.1.0", engineExists: engineExists, screenSaverRunning: false,
                        password: password, systemLockTakeover: true, carbonConstantsMatch: carbonOK, agentPID: agentPID)
}

extension SelfTests {
    static var helper: [TestCase] { helperHotkeys + helperState + helperPassword + helperAppLocation + helperPolicy + helperProcesses + helperReport }

    // MARK: - Hotkey → Carbon

    static var helperHotkeys: [TestCase] { [
        TestCase(name: "helper.hotkey.carbon-modifier-bits") {
            // <HIToolbox/Events.h>: cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000.
            try expectEqual(HelperHotkeyMapping.carbonMask(.command), 0x0100)
            try expectEqual(HelperHotkeyMapping.carbonMask(.shift), 0x0200)
            try expectEqual(HelperHotkeyMapping.carbonMask(.option), 0x0800)
            try expectEqual(HelperHotkeyMapping.carbonMask(.control), 0x1000)
            try expectEqual(HelperHotkeyMapping.carbonModifiers([]), 0)
            try expectEqual(HelperHotkeyMapping.carbonModifiers(LPHotkey.Modifier.allCases), 0x1B00)
        },
        TestCase(name: "helper.hotkey.carbon-mapping") {
            try expectEqual(try HelperHotkeyMapping.carbon(for: .controlCommandL).get(), HelperCarbonHotkey(keyCode: 37, modifiers: 0x1100))
            // Order and duplicates don't matter.
            let shuffled = LPHotkey(keyCode: 37, modifiers: [.command, .control, .command])
            try expectEqual(try HelperHotkeyMapping.carbon(for: shuffled).get(), HelperCarbonHotkey(keyCode: 37, modifiers: 0x1100))
            let optionShiftSpace = LPHotkey(keyCode: 49, modifiers: [.option, .shift])
            try expectEqual(try HelperHotkeyMapping.carbon(for: optionShiftSpace).get(), HelperCarbonHotkey(keyCode: 49, modifiers: 0x0A00))
            // F13 (kVK_F13 = 105) may be used bare.
            try expectEqual(try HelperHotkeyMapping.carbon(for: LPHotkey(keyCode: 105, modifiers: [])).get(),
                            HelperCarbonHotkey(keyCode: 105, modifiers: 0))
        },
        TestCase(name: "helper.hotkey.refuses-unsafe-combinations") {
            try expectEqual(HelperHotkeyMapping.problem(with: LPHotkey(keyCode: 37, modifiers: [])), .needsModifier("L"))
            try expectEqual(HelperHotkeyMapping.problem(with: LPHotkey(keyCode: 37, modifiers: [.shift])), .needsModifier("⇧L"))
            try expectEqual(HelperHotkeyMapping.problem(with: LPHotkey(keyCode: 200, modifiers: [.command])), .invalidKeyCode(200))
            try expectEqual(HelperHotkeyMapping.problem(with: LPHotkey(keyCode: 55, modifiers: [.control])), .modifierKey(55))
            try expectEqual(HelperHotkeyMapping.problem(with: .controlCommandQ), .systemLockShortcut)
            // ⌃⌥⌘Q is not the system shortcut.
            try expect(HelperHotkeyMapping.problem(with: LPHotkey(keyCode: 12, modifiers: [.control, .option, .command])) == nil)
            try expect(HelperHotkeyMapping.problem(with: LPHotkey(keyCode: 105, modifiers: [.shift])) == nil, "⇧F13 is fine")
            guard case .failure(.systemLockShortcut) = HelperHotkeyMapping.carbon(for: .controlCommandQ) else {
                throw TestFailure(description: "⌃⌘Q must not map to a Carbon hotkey")
            }
            try expect(!HelperHotkeyProblem.systemLockShortcut.description.isEmpty)
        },
        TestCase(name: "helper.hotkey.signature") {
            try expectEqual(HelperHotkeyMapping.signature, 0x4C50_484B)          // 'LPHK'
            try expectEqual(HelperHotkeyMapping.fourCharCode("abcd"), 0x6162_6364)
            try expectEqual(HelperHotkeyMapping.fourCharCode("abcdef"), 0x6162_6364)
            try expectEqual(HelperHotkeyMapping.fourCharCode("é"), 0x3F)
        },
    ] }

    // MARK: - state.json

    static var helperState: [TestCase] { [
        TestCase(name: "helper.state.decodes-shared-state") {
            var state = LPSharedState(lock: LPLockSettings(hotkey: LPHotkey(keyCode: 40, modifiers: [.control, .option])))
            state.installedAt = Date(timeIntervalSince1970: 1_800_000_000)
            let data = try SceneManifest.encoder().encode(state)
            let config = HelperStateReader.config(fromStateData: data, previous: nil)
            try expectEqual(config, HelperLockConfig(hotkey: LPHotkey(keyCode: 40, modifiers: [.control, .option]), source: .stateFile))
        },
        TestCase(name: "helper.state.disabled-hotkey-is-omitted-key") {
            // The app turns the shortcut off by saving hotkey = nil, which the synthesized encoder omits.
            let data = try SceneManifest.encoder().encode(LPSharedState(lock: LPLockSettings(hotkey: nil)))
            try expect(!(String(decoding: data, as: UTF8.self).contains("hotkey")), "nil hotkey is omitted")
            let config = HelperStateReader.config(fromStateData: data, previous: nil)
            try expectEqual(config.hotkey, nil)
            try expectEqual(config.source, .stateFile)
        },
        TestCase(name: "helper.state.missing-file-uses-defaults") {
            let dir = try tempDir("helper-state-missing")
            defer { remove(dir) }
            let config = HelperStateReader.load(from: dir.appendingPathComponent("state.json"), previous: nil)
            try expectEqual(config, HelperLockConfig.defaults)
            try expectEqual(config.hotkey, LPSharedState().lock.hotkey)
            try expect(config.problems.isEmpty)
        },
        TestCase(name: "helper.state.fallback-when-fields-renamed") {
            // A future app renamed the takeover flags: LPSharedState no longer decodes, the hotkey still does.
            let data = json(#"{"schema": 2, "lock": {"hotkey": {"keyCode": 37, "modifiers": ["control", "command", "control"]},"#
                + #" "takeOverLockGestures": true}, "installedAt": "not a date"}"#)
            let config = HelperStateReader.config(fromStateData: data, previous: nil)
            try expectEqual(config.source, .fallback)
            try expectEqual(config.hotkey, LPHotkey(keyCode: 37, modifiers: [.control, .command]))
            try expectEqual(config.problems.count, 1)
            try expect(config.problems[0].contains("LPSharedState"), config.problems[0])
        },
        TestCase(name: "helper.state.fallback-disabled-and-malformed") {
            let off = HelperStateReader.config(fromStateData: json(#"{"lock": {"hotkey": null}}"#), previous: nil)
            try expectEqual(off.hotkey, nil)
            try expectEqual(off.source, .fallback)
            let absent = HelperStateReader.config(fromStateData: json(#"{"lock": {}}"#), previous: nil)
            try expectEqual(absent.hotkey, nil)
            // Malformed hotkeys turn the shortcut off (never guess a global key).
            for bad in [#"{"lock": {"hotkey": {"keyCode": 37, "modifiers": ["hyper"]}}}"#,
                        #"{"lock": {"hotkey": {"keyCode": -1, "modifiers": []}}}"#,
                        #"{"lock": {"hotkey": {"keyCode": 3.5, "modifiers": []}}}"#,
                        #"{"lock": {"hotkey": {"keyCode": true, "modifiers": []}}}"#,
                        #"{"lock": {"hotkey": "⌃⌘L"}}"#] {
                let config = HelperStateReader.config(fromStateData: json(bad), previous: .defaults)
                try expectEqual(config.hotkey, nil)
                try expectEqual(config.source, .fallback)
                try expectEqual(config.problems.count, 2)
            }
        },
        TestCase(name: "helper.state.corrupt-keeps-previous") {
            let previous = HelperLockConfig(hotkey: LPHotkey(keyCode: 3, modifiers: [.option, .command]), source: .stateFile)
            for bad in ["{not json", "[1, 2]", #"{"schema": 1}"#] {
                let kept = HelperStateReader.config(fromStateData: json(bad), previous: previous)
                try expectEqual(kept.hotkey, previous.hotkey)
                try expectEqual(kept.source, .previous)
                try expectEqual(kept.problems.count, 1)
                let fresh = HelperStateReader.config(fromStateData: json(bad), previous: nil)
                try expectEqual(fresh.hotkey, HelperLockConfig.defaults.hotkey)
                try expectEqual(fresh.source, .defaults)
                try expect(fresh.problems.first?.contains("defaults") == true, "\(fresh.problems)")
            }
        },
        TestCase(name: "helper.state.load-from-file") {
            let dir = try tempDir("helper-state-file")
            defer { remove(dir) }
            let url = dir.appendingPathComponent("state.json")
            try SceneManifest.encoder().encode(LPSharedState(lock: LPLockSettings(hotkey: .controlCommandL))).write(to: url)
            try expectEqual(HelperStateReader.load(from: url, previous: nil).hotkey, .controlCommandL)
            // A directory where the file should be is unreadable: keep what was in effect.
            let blocked = dir.appendingPathComponent("blocked.json")
            try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
            let previous = HelperLockConfig(hotkey: nil, source: .stateFile)
            let kept = HelperStateReader.load(from: blocked, previous: previous)
            try expectEqual(kept.source, .previous)
            try expectEqual(kept.hotkey, nil)
        },
        TestCase(name: "helper.state.recording-signal") {
            try expectEqual(HelperRecordingSignal.isActive(userInfo: ["active": true]), true)
            try expectEqual(HelperRecordingSignal.isActive(userInfo: ["active": NSNumber(value: false)]), false)
            try expectEqual(HelperRecordingSignal.isActive(userInfo: ["active": NSNumber(value: 1)]), true)
            try expectEqual(HelperRecordingSignal.isActive(userInfo: ["active": "false"]), false)
            try expectEqual(HelperRecordingSignal.isActive(userInfo: ["active": "maybe"]), nil)
            try expectEqual(HelperRecordingSignal.isActive(userInfo: ["other": true]), nil)
            try expectEqual(HelperRecordingSignal.isActive(userInfo: nil), nil)
        },
    ] }

    // MARK: - Password requirement

    static var helperPassword: [TestCase] { [
        TestCase(name: "helper.password.sysadminctl") {
            let stamp = "2026-11-14 19:42:32.879 sysadminctl[67963:4496546] "
            try expectEqual(HelperPasswordPolicy.parseSysadminctl(stamp + "screenLock delay is immediate\n"),
                            HelperPasswordPolicy(requirement: .immediate, source: .sysadminctl))
            try expectEqual(HelperPasswordPolicy.parseSysadminctl(stamp + "screenLock delay is 300 seconds\n"),
                            HelperPasswordPolicy(requirement: .delayed, delaySeconds: 300, source: .sysadminctl))
            try expectEqual(HelperPasswordPolicy.parseSysadminctl(stamp + "screenLock delay is 0 seconds"),
                            HelperPasswordPolicy(requirement: .immediate, source: .sysadminctl))
            try expectEqual(HelperPasswordPolicy.parseSysadminctl(stamp + "screenLock is off\n"),
                            HelperPasswordPolicy(requirement: .off, source: .sysadminctl))
            try expectEqual(HelperPasswordPolicy.parseSysadminctl(stamp + "Unknown state for screenLock (x)"), nil)
            try expectEqual(HelperPasswordPolicy.parseSysadminctl(""), nil)
        },
        TestCase(name: "helper.password.source-order") {
            let immediate = "screenLock delay is immediate"
            // A profile that forces a delay wins over everything.
            let forced = HelperPasswordPolicy.resolve(managed: ["askForPassword": true, "askForPasswordDelay": 5],
                                                      sysadminctlOutput: immediate, user: [:])
            try expectEqual(forced, HelperPasswordPolicy(requirement: .delayed, delaySeconds: 5, source: .managedProfile))
            let forcedOff = HelperPasswordPolicy.resolve(managed: ["askForPassword": false], sysadminctlOutput: immediate, user: [:])
            try expectEqual(forcedOff, HelperPasswordPolicy(requirement: .off, source: .managedProfile))
            // A profile that only forces askForPassword says nothing about the delay.
            let askOnly = HelperPasswordPolicy.resolve(managed: ["askForPassword": true, "idleTime": 900],
                                                       sysadminctlOutput: "screenLock delay is 60 seconds", user: [:])
            try expectEqual(askOnly, HelperPasswordPolicy(requirement: .delayed, delaySeconds: 60, source: .sysadminctl))
            // sysadminctl beats the (legacy, often stale) user preferences.
            let stale = HelperPasswordPolicy.resolve(managed: [:], sysadminctlOutput: immediate, user: ["askForPasswordDelay": 300])
            try expectEqual(stale.requirement, .immediate)
            // Without sysadminctl output the user preferences decide.
            let user = HelperPasswordPolicy.resolve(managed: [:], sysadminctlOutput: nil, user: ["askForPassword": 1, "askForPasswordDelay": 5.0])
            try expectEqual(user, HelperPasswordPolicy(requirement: .delayed, delaySeconds: 5, source: .userPreferences))
            let legacy = HelperPasswordPolicy.resolve(managed: [:], sysadminctlOutput: "garbage", user: ["askForPassword": "1"])
            try expectEqual(legacy, HelperPasswordPolicy(requirement: .immediate, source: .userPreferences))
            let none = HelperPasswordPolicy.resolve(managed: [:], sysadminctlOutput: nil, user: [:])
            try expectEqual(none, HelperPasswordPolicy(requirement: .unknown, source: .none))
        },
        TestCase(name: "helper.password.value-parsing") {
            try expectEqual(HelperPasswordPolicy.number(NSNumber(value: 0.4)), 0.4)
            try expectEqual(HelperPasswordPolicy.number(" 30 "), 30)
            try expectEqual(HelperPasswordPolicy.number(NSNumber(value: true)), nil)
            try expectEqual(HelperPasswordPolicy.number("soon"), nil)
            try expectEqual(HelperPasswordPolicy.bool("YES"), true)
            try expectEqual(HelperPasswordPolicy.bool(NSNumber(value: 0)), false)
            // Fractional delays round up; absurd ones don't overflow.
            try expectEqual(HelperPasswordPolicy.fromPreferences(["askForPasswordDelay": 0.4], source: .userPreferences, requireDelay: false)?.delaySeconds, 1)
            try expectEqual(HelperPasswordPolicy.fromPreferences(["askForPasswordDelay": 1e300], source: .userPreferences, requireDelay: false)?.delaySeconds, 1_000_000_000)
            try expectEqual(HelperPasswordPolicy.fromPreferences(["askForPasswordDelay": -3], source: .userPreferences, requireDelay: false)?.requirement, .immediate)
        },
        TestCase(name: "helper.password.warnings") {
            try expect(HelperPasswordPolicy(requirement: .immediate, source: .sysadminctl).warning == nil)
            try expect(HelperPasswordPolicy(requirement: .unknown, source: .none).warning == nil)
            let delayed = HelperPasswordPolicy(requirement: .delayed, delaySeconds: 300, source: .sysadminctl).warning ?? ""
            try expect(delayed.contains("300 s") && delayed.contains("Immediately"), delayed)
            try expect(HelperPasswordPolicy(requirement: .off, source: .sysadminctl).warning?.contains("off") == true)
        },
        TestCase(name: "helper.password.managed-files") {
            let root = try tempDir("helper-managed")
            defer { remove(root) }
            let files = HelperPasswordPolicy.managedPreferenceFiles(root: root, user: "someone")
            try expectEqual(files.map { $0.path.replacingOccurrences(of: root.path, with: "") },
                            ["/com.apple.screensaver.plist", "/someone/com.apple.screensaver.plist"])
            try FileManager.default.createDirectory(at: files[1].deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["askForPassword": true, "askForPasswordDelay": 0, "idleTime": 900],
                                               format: .xml, options: 0).write(to: files[0])
            try PropertyListSerialization.data(fromPropertyList: ["askForPasswordDelay": 60], format: .binary, options: 0).write(to: files[1])
            let merged = HelperPasswordPolicy.managedSettings(files: files + [root.appendingPathComponent("missing.plist")])
            try expectEqual(merged["askForPasswordDelay"] as? Int, 60)   // per user overrides computer-wide
            try expectEqual(merged["idleTime"] as? Int, 900)
            try expectEqual(HelperPasswordPolicy.resolve(managed: merged, sysadminctlOutput: nil, user: [:]),
                            HelperPasswordPolicy(requirement: .delayed, delaySeconds: 60, source: .managedProfile))
        },
    ] }

    // MARK: - Finding the app

    static var helperAppLocation: [TestCase] { [
        TestCase(name: "helper.app.enclosing-path-math") {
            func app(_ path: String) -> String? { HelperAppLocator.enclosingApp(ofExecutable: URL(fileURLWithPath: path))?.path }
            try expectEqual(app("/Applications/LivePaper.app/Contents/Helpers/LivePaperHelper"), "/Applications/LivePaper.app")
            try expectEqual(app("/Users/x/Applications/LivePaper.app/Contents/MacOS/LivePaper"), "/Users/x/Applications/LivePaper.app")
            try expectEqual(app("/repo/.build/debug/LivePaperHelper"), nil)
            try expectEqual(app("/Applications/LivePaper.app/Contents/Resources/LivePaperHelper"), nil)
            try expectEqual(app("/Applications/LivePaper/Contents/Helpers/LivePaperHelper"), nil)
        },
        TestCase(name: "helper.app.prefers-enclosing-bundle") {
            let root = try tempDir("helper-app")
            defer { remove(root) }
            let app = try makeBundle(root, name: "LivePaper.app", bundleID: LPPaths.bundleID, version: "1.2.3",
                                     executable: "Contents/Helpers/LivePaperHelper")
            var lookups: [String] = []
            let locator = HelperAppLocator(bundleIdentifier: HelperAppLocator.infoPlistBundleIdentifier,
                                           lookup: { lookups.append($0); return URL(fileURLWithPath: "/elsewhere/LivePaper.app") })
            let found = locator.locate(executable: app.appendingPathComponent("Contents/Helpers/LivePaperHelper"))
            try expectEqual(found.source, .enclosingBundle)
            try expectEqual(found.url?.standardizedFileURL.path, app.standardizedFileURL.path)
            try expect(lookups.isEmpty, "no Launch Services lookup when the enclosing app is ours")
            try expectEqual(HelperAppLocator.infoPlistVersion(app), "1.2.3")
        },
        TestCase(name: "helper.app.resolves-symlinked-executable") {
            let root = try tempDir("helper-app-link")
            defer { remove(root) }
            let app = try makeBundle(root, name: "LivePaper.app", bundleID: LPPaths.bundleID, executable: "Contents/Helpers/LivePaperHelper")
            let link = root.appendingPathComponent("bin/LivePaperHelper")
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app.appendingPathComponent("Contents/Helpers/LivePaperHelper"))
            let locator = HelperAppLocator.live(lookup: { _ in nil })
            let found = locator.locate(executable: link)
            try expectEqual(found.source, .enclosingBundle)
            try expectEqual(found.url?.resolvingSymlinksInPath().path, app.resolvingSymlinksInPath().path)
        },
        TestCase(name: "helper.app.falls-back-to-bundle-id") {
            let root = try tempDir("helper-app-fallback")
            defer { remove(root) }
            // Embedded in some other app: don't open that one.
            let other = try makeBundle(root, name: "Other.app", bundleID: "com.example.other", executable: "Contents/Helpers/LivePaperHelper")
            let installed = URL(fileURLWithPath: "/Applications/LivePaper.app")
            var asked: [String] = []
            let locator = HelperAppLocator(bundleIdentifier: HelperAppLocator.infoPlistBundleIdentifier,
                                           lookup: { asked.append($0); return installed })
            let found = locator.locate(executable: other.appendingPathComponent("Contents/Helpers/LivePaperHelper"))
            try expectEqual(found, HelperAppLocation(url: installed, source: .bundleIdentifier))
            try expectEqual(asked, [LPPaths.bundleID])
            // Unbundled (swift run) with nothing registered.
            let none = HelperAppLocator(bundleIdentifier: HelperAppLocator.infoPlistBundleIdentifier, lookup: { _ in nil })
                .locate(executable: root.appendingPathComponent(".build/debug/LivePaperHelper"))
            try expectEqual(none, HelperAppLocation(url: nil, source: .notFound))
            // A bundle without Info.plist identifier isn't trusted either.
            let anonymous = try makeBundle(root, name: "LivePaper2.app", bundleID: nil, executable: "Contents/Helpers/LivePaperHelper")
            let viaLookup = locator.locate(executable: anonymous.appendingPathComponent("Contents/Helpers/LivePaperHelper"))
            try expectEqual(viaLookup.source, .bundleIdentifier)
        },
    ] }

    // MARK: - Decisions

    static var helperPolicy: [TestCase] { [
        TestCase(name: "helper.lock.decision") {
            let idle = HelperLockSituation(engineExists: true, screenSaverRunning: false, sessionLocked: false, launchInFlight: false)
            try expectEqual(HelperLockPolicy.decide(idle), .startScreenSaver)
            var s = idle; s.sessionLocked = true
            guard case .skip = HelperLockPolicy.decide(s) else { throw TestFailure(description: "locked session must be left alone") }
            s = idle; s.screenSaverRunning = true
            guard case .skip = HelperLockPolicy.decide(s) else { throw TestFailure(description: "running saver must be left alone") }
            s = idle; s.launchInFlight = true
            guard case .skip = HelperLockPolicy.decide(s) else { throw TestFailure(description: "a second press must not launch twice") }
            s = idle; s.engineExists = false
            guard case .fail = HelperLockPolicy.decide(s) else { throw TestFailure(description: "missing engine is an error") }
            // Already locked wins over a missing engine (nothing to do either way).
            s.sessionLocked = true
            guard case .skip = HelperLockPolicy.decide(s) else { throw TestFailure(description: "locked first") }
        },
        TestCase(name: "helper.hotkey.registration-plan") {
            let l = LPHotkey.controlCommandL
            let k = LPHotkey(keyCode: 40, modifiers: [.control, .command])
            let config = HelperLockConfig(hotkey: l, source: .stateFile)
            try expectEqual(HelperHotkeyPlan.desired(config: config, suspended: false), l)
            try expectEqual(HelperHotkeyPlan.desired(config: config, suspended: true), nil)
            try expectEqual(HelperHotkeyPlan.desired(config: HelperLockConfig(hotkey: .controlCommandQ, source: .stateFile), suspended: false), nil)
            try expectEqual(HelperHotkeyPlan.actions(registered: nil, desired: l), [.register(l)])
            try expectEqual(HelperHotkeyPlan.actions(registered: l, desired: l), [])
            try expectEqual(HelperHotkeyPlan.actions(registered: l, desired: LPHotkey(keyCode: 37, modifiers: [.command, .control])), [])
            try expectEqual(HelperHotkeyPlan.actions(registered: l, desired: k), [.unregister, .register(k)])
            try expectEqual(HelperHotkeyPlan.actions(registered: l, desired: nil), [.unregister])
            try expectEqual(HelperHotkeyPlan.actions(registered: nil, desired: nil), [])
        },
        TestCase(name: "helper.recording.suspend-resume-sequence") {
            // stateChanged arrives while recording (the app saves before it announces the end):
            // nothing may be registered until recording ends, then the new shortcut is.
            let old = LPHotkey.controlCommandL, new = LPHotkey(keyCode: 40, modifiers: [.control, .option])
            var registered: LPHotkey? = old
            func apply(_ config: HelperLockConfig, suspended: Bool) {
                for action in HelperHotkeyPlan.actions(registered: registered, desired: HelperHotkeyPlan.desired(config: config, suspended: suspended)) {
                    switch action {
                    case .unregister: registered = nil
                    case .register(let hotkey): registered = hotkey
                    }
                }
            }
            apply(HelperLockConfig(hotkey: old, source: .stateFile), suspended: true)
            try expectEqual(registered, nil)
            apply(HelperLockConfig(hotkey: new, source: .stateFile), suspended: true)
            try expectEqual(registered, nil)
            apply(HelperLockConfig(hotkey: new, source: .stateFile), suspended: false)
            try expectEqual(registered, new)
        },
        TestCase(name: "helper.request-gate") {
            var gate = HelperRequestGate(minimumInterval: 1)
            let t0 = Date(timeIntervalSince1970: 1000)
            try expect(gate.accept(at: t0))
            try expect(!gate.accept(at: t0.addingTimeInterval(0.4)))
            try expect(gate.accept(at: t0.addingTimeInterval(1.2)))
            // A clock that jumped backwards doesn't block requests forever.
            try expect(gate.accept(at: t0))
        },
        TestCase(name: "helper.command-line") {
            try expectEqual(HelperCommand.parse([]), .agent)
            try expectEqual(HelperCommand.parse(["-psn_0_12345"]), .agent)
            try expectEqual(HelperCommand.parse(["--print-config"]), .printConfig)
            try expectEqual(HelperCommand.parse(["--self-check"]), .selfCheck)
            try expectEqual(HelperCommand.parse(["--version"]), .version)
            try expectEqual(HelperCommand.parse(["-h"]), .help)
            guard case .usageError = HelperCommand.parse(["--lock"]) else { throw TestFailure(description: "unknown option") }
            guard case .usageError = HelperCommand.parse(["--print-config", "--self-check"]) else { throw TestFailure(description: "two options") }
        },
    ] }

    // MARK: - Processes and the instance file

    static var helperProcesses: [TestCase] { [
        TestCase(name: "helper.processes.scan") {
            let me = try expectNotNil(HelperProcesses.executablePath(of: getpid()))
            try expectEqual(URL(fileURLWithPath: me).resolvingSymlinksInPath().path,
                            (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path)
            try expect(HelperProcesses.isRunning(executable: me), "the scan finds this test process")
            try expect(!HelperProcesses.isRunning(executable: "/nonexistent/LivePaperHelper"))
            let engine = HelperProcesses.screenSaverEngineApp.deletingLastPathComponent().path + HelperProcesses.screenSaverEngineExecutableSuffix
            try expect(FileManager.default.isExecutableFile(atPath: engine), "the scan looks for \(engine)")
        },
        TestCase(name: "helper.processes.instance-file") {
            try expectEqual(HelperProcesses.parsePID("123\n"), 123)
            try expectEqual(HelperProcesses.parsePID(""), nil)
            try expectEqual(HelperProcesses.parsePID("-5"), nil)
            try expectEqual(HelperProcesses.parsePID("12ab"), nil)
            let dir = try tempDir("helper-pid")
            defer { remove(dir) }
            let file = dir.appendingPathComponent("helper.pid")
            try expectEqual(HelperProcesses.runningAgentPID(instanceFile: file), nil)          // no file
            // Our parent (the shell or `swift run`) is alive; it counts only under the expected name.
            let parent = getppid()
            let parentName = try expectNotNil(HelperProcesses.executablePath(of: parent)).split(separator: "/").last.map(String.init) ?? ""
            try Data("\(parent)\n".utf8).write(to: file)
            try expectEqual(HelperProcesses.runningAgentPID(instanceFile: file, executableName: parentName), parent)
            try expectEqual(HelperProcesses.runningAgentPID(instanceFile: file), nil)          // not a LivePaperHelper
            try Data("\(getpid())\n".utf8).write(to: file)
            try expectEqual(HelperProcesses.runningAgentPID(instanceFile: file, executableName: "LivePaperSelfTest"), nil)  // never itself
        },
        TestCase(name: "helper.single-instance") {
            let dir = try tempDir("helper-instance")
            defer { remove(dir) }
            let file = dir.appendingPathComponent("sub/helper.pid")
            guard case .acquired(let first) = HelperSingleInstance.acquire(at: file) else {
                throw TestFailure(description: "first acquire must succeed")
            }
            try expectEqual(HelperProcesses.parsePID(try String(contentsOf: file, encoding: .utf8)), getpid())
            // flock is per open file description, so a second open in this process conflicts too.
            guard case .heldByOther(let pid) = HelperSingleInstance.acquire(at: file) else {
                throw TestFailure(description: "second acquire must be refused")
            }
            try expectEqual(pid, getpid())
            first.release()
            try expectEqual(try String(contentsOf: file, encoding: .utf8), "")
            guard case .acquired(let again) = HelperSingleInstance.acquire(at: file) else {
                throw TestFailure(description: "acquire after release must succeed")
            }
            again.release()
            let blocked = dir.appendingPathComponent("file")
            try Data().write(to: blocked)
            guard case .unavailable = HelperSingleInstance.acquire(at: blocked.appendingPathComponent("helper.pid")) else {
                throw TestFailure(description: "an impossible location must be reported, not crash")
            }
        },
    ] }

    // MARK: - --print-config report

    static var helperReport: [TestCase] { [
        TestCase(name: "helper.report.healthy") {
            let report = HelperReport(reportInputs(config: HelperLockConfig(hotkey: .controlCommandL, source: .stateFile)))
            try expect(report.problems.isEmpty && report.warnings.isEmpty, "\(report.problems) \(report.warnings)")
            try expectEqual(report.hotkey, HelperReport.Hotkey(enabled: true, registrable: true, display: "⌃⌘L", keyCode: 37,
                                                               modifiers: ["control", "command"], carbonKeyCode: 37,
                                                               carbonModifiers: 0x1100, problem: nil))
            try expectEqual(report.helper.agentPID, 4242)
            try expect(report.helper.agentRunning)
            try expectEqual(report.helper.label, LPPaths.helperLabel)
            try expectEqual(report.app.source, .enclosingBundle)
            try expectEqual(report.notifications, [LPNotification.stateChanged, LPNotification.hotkeyRecording,
                                                   LPNotification.lockNow, LPNotification.openApp])
            try expect(report.summary.hasSuffix("ok"), report.summary)
        },
        TestCase(name: "helper.report.json-contract") {
            let report = HelperReport(reportInputs(config: HelperLockConfig(hotkey: nil, source: .stateFile)))
            let data = try report.json()
            let object = try expectNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            try expectEqual(Set(object.keys), ["schema", "helper", "state", "hotkey", "app", "screenSaver", "password",
                                               "systemLockTakeover", "notifications", "problems", "warnings"])
            try expectEqual(object["schema"] as? Int, 1)
            let hotkey = try expectNotNil(object["hotkey"] as? [String: Any])
            try expectEqual(hotkey["enabled"] as? Bool, false)
            let password = try expectNotNil(object["password"] as? [String: Any])
            try expectEqual(password["requirement"] as? String, "immediate")
            try expectEqual((object["state"] as? [String: Any])?["source"] as? String, "stateFile")
            try expect(!String(decoding: data, as: UTF8.self).contains("\\/"), "paths are not slash-escaped")
            try expectEqual(try JSONDecoder().decode(HelperReport.self, from: data), report)
        },
        TestCase(name: "helper.report.problems-and-warnings") {
            let report = HelperReport(reportInputs(
                config: HelperLockConfig(hotkey: LPHotkey(keyCode: 37, modifiers: []), source: .stateFile),
                app: HelperAppLocation(url: nil, source: .notFound),
                password: HelperPasswordPolicy(requirement: .delayed, delaySeconds: 60, source: .sysadminctl),
                engineExists: false, carbonOK: false, agentPID: nil))
            try expectEqual(report.problems.count, 3)                        // Carbon mirror, engine, unregistrable shortcut
            try expectEqual(report.warnings.count, 3)                        // app, password, agent
            try expectEqual(report.hotkey.registrable, false)
            try expect(report.hotkey.problem?.contains("capture normal typing") == true, report.hotkey.problem ?? "")
            try expect(report.summary.contains("3 problem(s)"), report.summary)
            // A state file that exists but can't be read is a problem; a fallback decode only a warning.
            let unreadable = HelperReport(reportInputs(config: HelperStateReader.config(fromStateData: Data("{".utf8), previous: nil)))
            try expectEqual(unreadable.problems.count, 1)
            let fallback = HelperReport(reportInputs(config: HelperStateReader.config(fromStateData: Data(#"{"lock": {}}"#.utf8), previous: nil)))
            try expect(fallback.problems.isEmpty && fallback.warnings.count == 1, "\(fallback.problems) \(fallback.warnings)")
            let fresh = HelperReport(reportInputs(config: .defaults, stateExists: false))
            try expect(fresh.problems.isEmpty, "\(fresh.problems)")
        },
    ] }
}

/// Unwraps or fails the test.
private func expectNotNil<T>(_ value: T?, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(description: "\(file):\(line) unexpected nil") }
    return value
}
