// SystemProbes — read-only checks of the system settings LivePaper depends on. Pure parsing lives
// here (tested with recorded outputs); InstallService runs the commands.
import Foundation

enum SystemProbes {
    /// Configuration-profile copies of com.apple.screensaver (computer-wide, then per user).
    static func managedScreenSaverPreferences(user: String = NSUserName()) -> [URL] {
        let root = URL(fileURLWithPath: "/Library/Managed Preferences")
        return [root.appendingPathComponent("com.apple.screensaver.plist"),
                root.appendingPathComponent(user).appendingPathComponent("com.apple.screensaver.plist")]
    }

    /// Keys an MDM profile uses to enforce idle time / the password requirement.
    static let managedKeys: Set<String> = ["idleTime", "askForPassword", "askForPasswordDelay", "loginWindowIdleTime", "moduleDict"]

    /// The managed screen-saver settings, later files (per user) overriding earlier ones.
    static func managedSettings(_ files: [URL]) -> [String: Any] {
        var merged: [String: Any] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            merged.merge(dict) { _, new in new }
        }
        return merged
    }

    static func isManaged(_ settings: [String: Any]) -> Bool {
        settings.keys.contains(where: managedKeys.contains)
    }

    static let screenSaverDomain = "com.apple.screensaver"
    /// The keys behind "Require password after screen saver begins".
    static let passwordKeys = ["askForPassword", "askForPasswordDelay"]

    /// What a configuration profile forces for the password keys: the profile plists, overridden by
    /// what CFPreferences reports as forced (`CFPreferencesAppValueIsForced`, the authority; the
    /// plists are what tests can set up). Other managed keys (idleTime, moduleDict, …) say nothing
    /// about the password and are left out.
    static func enforcedPasswordSettings(managed: [String: Any], forcedValue: (String) -> Any?) -> [String: Any] {
        var enforced = managed.filter { passwordKeys.contains($0.key) }
        for key in passwordKeys { if let value = forcedValue(key) { enforced[key] = value } }
        return enforced
    }

    /// The profile itself keeps the password from being required immediately: it forces
    /// `askForPassword = false` or a non-zero `askForPasswordDelay`. Only then can't the user fix it
    /// in System Settings; a profile forcing only idle time, the module or `askForPassword = true`
    /// leaves the delay to the user.
    static func passwordEnforcedNotImmediately(_ enforced: [String: Any]) -> Bool {
        if let ask = enforced["askForPassword"] as? NSNumber, !ask.boolValue { return true }
        if let delay = enforced["askForPasswordDelay"] as? NSNumber, CFGetTypeID(delay) != CFBooleanGetTypeID() {
            return delay.doubleValue > 0
        }
        return false
    }

    /// Parses `sysadminctl -screenLock status` (it logs to stderr), e.g.
    /// "2026-11-14 18:32:04.037 sysadminctl[8213:4276522] screenLock delay is immediate".
    /// nil when the output isn't recognised.
    static func screenLockImmediate(sysadminctlOutput output: String) -> Bool? {
        let text = output.lowercased()
        if text.contains("screenlock delay is immediate") { return true }
        if text.contains("screenlock delay is") || text.contains("screenlock is off") { return false }
        return nil
    }

    /// "Require password … Immediately": what sysadminctl reports, else what a profile enforces.
    static func passwordImmediately(sysadminctlOutput: String?, managed: [String: Any]) -> Bool {
        if let output = sysadminctlOutput, let parsed = screenLockImmediate(sysadminctlOutput: output) { return parsed }
        guard (managed["askForPassword"] as? NSNumber)?.boolValue == true else { return false }
        return (managed["askForPasswordDelay"] as? NSNumber)?.doubleValue == 0
    }

    /// Parses `launchctl print gui/<uid>/<label>`: loaded and currently running.
    static func helperRunning(launchctlPrint result: CommandResult) -> Bool {
        guard result.succeeded else { return false }
        return LaunchdJob.parse(result.stdout).isRunning
    }
}
