// HelperSystem — the read-only system facts the helper needs, gathered without connecting to the
// window server (CFPreferences, plain files, libproc, Launch Services lookups and one sysadminctl
// call), so --print-config and --self-check can use all of it.
import CoreServices
import Foundation
import LivePaperCore
import os

enum HelperLog {
    /// os_log: subsystem com.nachmore.livepaper, category helper.
    /// `log stream --predicate 'subsystem == "com.nachmore.livepaper" && category == "helper"'`
    static let main = Logger(subsystem: LPPaths.bundleID, category: "helper")
}

enum HelperSystem {
    /// This executable, symlinks resolved.
    static var executableURL: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    }

    /// Launch Services' preferred app for a bundle identifier (a database query; no window server).
    static func lookupApplication(bundleIdentifier: String) -> URL? {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleIdentifier as CFString, nil)?.takeRetainedValue()
                as? [URL] else { return nil }
        return urls.first
    }

    static var appLocator: HelperAppLocator { .live(lookup: lookupApplication) }

    /// `com.apple.loginwindow immediateLockLaunchesScreenSaver` (the app's system lock takeover);
    /// nil when not set.
    static var systemLockTakeover: Bool? {
        CFPreferencesCopyAppValue("immediateLockLaunchesScreenSaver" as CFString, "com.apple.loginwindow" as CFString) as? Bool
    }

    /// Resolves the password requirement (see HelperPasswordPolicy). Blocking: runs
    /// `sysadminctl -screenLock status` (read-only, ~20 ms) — call off the main thread in the agent.
    static func passwordPolicy(runner: CommandRunning = SystemCommandRunner()) -> HelperPasswordPolicy {
        let managed = HelperPasswordPolicy.managedSettings(files: HelperPasswordPolicy.managedPreferenceFiles())
        var user: [String: Any] = [:]
        for key in [HelperPasswordPolicy.askForPasswordKey, HelperPasswordPolicy.askForPasswordDelayKey] {
            if let value = CFPreferencesCopyAppValue(key as CFString, HelperPasswordPolicy.domain as CFString) { user[key] = value }
        }
        let tool = "/usr/sbin/sysadminctl"
        var output: String?
        if FileManager.default.isExecutableFile(atPath: tool),
           let result = try? runner.run(tool, ["-screenLock", "status"], timeout: 5), !result.timedOut {
            output = result.combinedOutput
        }
        return HelperPasswordPolicy.resolve(managed: managed, sysadminctlOutput: output, user: user)
    }

    /// Everything --print-config reports, read from the live system.
    static func reportInputs(previous: HelperLockConfig? = nil) -> HelperReport.Inputs {
        let executable = executableURL
        let stateFile = LPPaths.stateFile
        let app = appLocator.locate(executable: executable)
        return HelperReport.Inputs(
            executable: executable,
            stateFile: stateFile,
            stateExists: FileManager.default.fileExists(atPath: stateFile.path),
            config: HelperStateReader.load(from: stateFile, previous: previous),
            app: app,
            appVersion: app.url.flatMap(HelperAppLocator.infoPlistVersion),
            engineExists: FileManager.default.fileExists(atPath: HelperProcesses.screenSaverEngineApp.path),
            screenSaverRunning: HelperProcesses.isScreenSaverEngineRunning,
            password: passwordPolicy(),
            systemLockTakeover: systemLockTakeover,
            carbonConstantsMatch: CarbonHotkeyCenter.carbonConstantsMatch,
            agentPID: HelperProcesses.runningAgentPID())
    }
}
