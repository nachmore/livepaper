// PowerProbe — reads the live screen timers and power assertions, read-only: `pmset -g custom`,
// CFPreferences and plain files for the screen saver's idle time, and IOKit's power-source and
// assertion queries (no window server). Used by InstallService.status (the app's Settings › Lock,
// `livepaper doctor`) and by the helper (docs/RESEARCH.md §7).
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

public struct LPPowerProbe: Sendable {
    public var runner: CommandRunning
    public var preferences: PreferencesAccessing
    /// Configuration-profile copies of com.apple.screensaver (computer-wide, then per user).
    public var managedPreferences: [URL]
    /// Read only when pmset gives nothing.
    public var powerManagementPreferences: URL
    public var engineDefaults: URL
    public var currentSource: @Sendable () -> LPPowerSource?

    public static let powerManagementPreferencesFile = URL(fileURLWithPath: "/Library/Preferences/com.apple.PowerManagement.plist")

    /// /Library/Managed Preferences[/<user>]/com.apple.screensaver.plist.
    public static func managedScreenSaverPreferences() -> [URL] { SystemProbes.managedScreenSaverPreferences() }

    public init(runner: CommandRunning = SystemCommandRunner(), preferences: PreferencesAccessing = SystemPreferences(),
                managedPreferences: [URL] = LPPowerProbe.managedScreenSaverPreferences(),
                powerManagementPreferences: URL = LPPowerProbe.powerManagementPreferencesFile,
                engineDefaults: URL = LPScreenSaverIdle.engineDefaultsFile,
                currentSource: @escaping @Sendable () -> LPPowerSource? = { LPPowerProbe.providingPowerSource() }) {
        self.runner = runner; self.preferences = preferences; self.managedPreferences = managedPreferences
        self.powerManagementPreferences = powerManagementPreferences; self.engineDefaults = engineDefaults
        self.currentSource = currentSource
    }

    /// Blocking: runs `pmset -g custom` (read-only, about 20 ms).
    public func screenTimers() -> LPScreenTimers {
        var displaySleep: [LPPowerSource: Int] = [:]
        if let result = try? runner.run("/usr/bin/pmset", ["-g", "custom"], timeout: 5), result.succeeded {
            displaySleep = LPScreenTimers.parsePmsetCustom(result.stdout)
        }
        if displaySleep.isEmpty, let plist = Self.plist(at: powerManagementPreferences) {
            displaySleep = LPScreenTimers.parsePowerManagementPreferences(plist)
        }
        return LPScreenTimers(displaySleep: displaySleep, currentSource: currentSource(), screenSaverIdle: screenSaverIdle())
    }

    /// loginwindow's idle time (LPScreenSaverIdle.resolve).
    public func screenSaverIdle() -> LPScreenSaverIdle {
        let domain = LPScreenSaverIdle.domain, key = LPScreenSaverIdle.key
        return LPScreenSaverIdle.resolve(forced: preferences.forcedValue(domain: domain, key: key),
                                         managed: SystemProbes.managedSettings(managedPreferences),
                                         userCurrentHost: preferences.value(domain: domain, key: key, currentHost: true),
                                         userAnyHost: preferences.value(domain: domain, key: key, currentHost: false),
                                         engineDefaults: Self.plist(at: engineDefaults))
    }

    /// The power source in use (IOPSGetProvidingPowerSourceType; nil when it says something else).
    public static func providingPowerSource() -> LPPowerSource? {
        guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() else { return nil }
        return LPPowerSource(pmsetName: type as String)
    }

    /// powerd's assertions: IOPMCopyAssertionsByProcess (each assertion, with its timeout), else the
    /// summary IOPMCopyAssertionsStatus; nil when neither can be read. An IPC to powerd, no subprocess.
    public static func assertions(now: Date = Date()) -> LPPowerAssertions? {
        var byProcess: Unmanaged<CFDictionary>?
        if IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess {
            let dictionary = byProcess?.takeRetainedValue() as? [AnyHashable: Any] ?? [:]
            let all = dictionary.values.flatMap { ($0 as? [[String: Any]]) ?? [] }
            return LPPowerAssertions.parse(all, now: now)
        }
        var summary: Unmanaged<CFDictionary>?
        if IOPMCopyAssertionsStatus(&summary) == kIOReturnSuccess, let dictionary = summary?.takeRetainedValue() as? [String: Any] {
            return LPPowerAssertions.fromSummary(dictionary)
        }
        return nil
    }

    static func plist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
