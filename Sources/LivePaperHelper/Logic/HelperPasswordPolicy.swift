// HelperPasswordPolicy — "Require password after screen saver begins", as far as the helper can
// tell without private API.
//
// LivePaper's lock is "start the screen saver; the saver locks", which only locks when the password
// is required immediately (askForPasswordDelay = 0). The helper never tries to lock any other way
// (no private lock calls): it reads this policy right before every lock, and when the password isn't
// required immediately (or can't be read) it starts nothing and tells the user why
// (HelperLockPolicy.decide → LPLockRefusal).
//
// Sources, strongest first:
//  1. A configuration profile (/Library/Managed Preferences[/<user>]/com.apple.screensaver.plist):
//     `askForPassword = false` or an `askForPasswordDelay` there is enforced.
//  2. `sysadminctl -screenLock status`: since macOS 10.13 the setting lives in the keybag, not in
//     com.apple.screensaver, and this is the supported way to read it ("screenLock delay is
//     immediate" / "screenLock delay is %d seconds" / "screenLock is off").
//  3. The user's com.apple.screensaver `askForPassword` / `askForPasswordDelay` (legacy; usually
//     absent on current macOS, sometimes stale).
//
// Pure logic (Foundation only), also compiled into LivePaperSelfTest.
import Foundation

struct HelperPasswordPolicy: Equatable, Sendable, Codable {
    enum Requirement: String, Codable, Sendable {
        /// Password required as soon as the saver starts: LivePaper's lock locks.
        case immediate
        /// Required only after `delaySeconds`.
        case delayed
        /// Not required at all.
        case off
        /// No source said anything.
        case unknown
    }

    enum Source: String, Codable, Sendable {
        case managedProfile, sysadminctl, userPreferences, none
    }

    var requirement: Requirement
    /// Only for `.delayed`.
    var delaySeconds: Int?
    var source: Source

    init(requirement: Requirement, delaySeconds: Int? = nil, source: Source) {
        self.requirement = requirement; self.delaySeconds = delaySeconds; self.source = source
    }

    /// Whether starting the screen saver locks right away (nil: unknown), as LPPreSleepPolicy takes it.
    var immediately: Bool? {
        switch requirement {
        case .immediate: return true
        case .delayed, .off: return false
        case .unknown: return nil
        }
    }

    /// What to tell the user when the LivePaper lock won't lock; nil when it will (or when nothing
    /// is known — the lock then refuses too, see HelperLockPolicy).
    var warning: String? {
        switch requirement {
        case .immediate, .unknown:
            return nil
        case .delayed:
            let delay = delaySeconds.map { "after \($0) s" } ?? "after a delay"
            return "\"Require password after screen saver begins\" is set to \(delay), not Immediately: the LivePaper lock "
                + "shortcut and Lock Now refuse to run, because starting the screen saver wouldn't lock the Mac. "
                + "Change it in System Settings › Lock Screen."
        case .off:
            return "\"Require password after screen saver begins\" is off: the LivePaper lock shortcut and Lock Now refuse "
                + "to run, because starting the screen saver wouldn't lock the Mac. Turn it on (Immediately) in System Settings › Lock Screen."
        }
    }

    static let domain = "com.apple.screensaver"
    static let askForPasswordKey = "askForPassword"
    static let askForPasswordDelayKey = "askForPasswordDelay"

    /// Combines the sources (see the file header for the order).
    /// - Parameters:
    ///   - managed: merged configuration-profile settings for com.apple.screensaver.
    ///   - sysadminctlOutput: combined stdout+stderr of `sysadminctl -screenLock status` (nil = not run).
    ///   - user: the user's com.apple.screensaver values for the two keys.
    static func resolve(managed: [String: Any], sysadminctlOutput: String?, user: [String: Any]) -> HelperPasswordPolicy {
        if let policy = fromPreferences(managed, source: .managedProfile, requireDelay: true) { return policy }
        if let output = sysadminctlOutput, let policy = parseSysadminctl(output) { return policy }
        if let policy = fromPreferences(user, source: .userPreferences, requireDelay: false) { return policy }
        return HelperPasswordPolicy(requirement: .unknown, source: .none)
    }

    /// Parses `sysadminctl -screenLock status` (it logs to stderr, prefixed with a timestamp).
    static func parseSysadminctl(_ output: String) -> HelperPasswordPolicy? {
        let text = output.lowercased()
        if text.contains("screenlock is off") { return HelperPasswordPolicy(requirement: .off, source: .sysadminctl) }
        if text.contains("screenlock delay is immediate") { return HelperPasswordPolicy(requirement: .immediate, source: .sysadminctl) }
        guard let range = text.range(of: "screenlock delay is ") else { return nil }
        let digits = text[range.upperBound...].prefix(while: \.isNumber)
        guard let seconds = Int(digits) else { return nil }
        return seconds <= 0 ? HelperPasswordPolicy(requirement: .immediate, source: .sysadminctl)
                            : HelperPasswordPolicy(requirement: .delayed, delaySeconds: seconds, source: .sysadminctl)
    }

    /// Interprets askForPassword / askForPasswordDelay from one preferences dictionary.
    /// - Parameter requireDelay: profiles that only force `askForPassword = true` say nothing about the
    ///   delay, so that alone is not an answer (the next source decides).
    static func fromPreferences(_ prefs: [String: Any], source: Source, requireDelay: Bool) -> HelperPasswordPolicy? {
        let ask = bool(prefs[askForPasswordKey])
        if ask == false { return HelperPasswordPolicy(requirement: .off, source: source) }
        guard let delay = number(prefs[askForPasswordDelayKey]) else {
            if ask == true && !requireDelay {
                // Legacy behaviour: askForPassword without a delay key meant "immediately".
                return HelperPasswordPolicy(requirement: .immediate, source: source)
            }
            return nil
        }
        if delay <= 0 { return HelperPasswordPolicy(requirement: .immediate, source: source) }
        // Clamped so a nonsense value can't overflow Int.
        return HelperPasswordPolicy(requirement: .delayed, delaySeconds: Int(min(delay, 1e9).rounded(.up)), source: source)
    }

    /// Configuration-profile copies of com.apple.screensaver: computer-wide, then per user.
    static func managedPreferenceFiles(root: URL = URL(fileURLWithPath: "/Library/Managed Preferences"),
                                       user: String = NSUserName()) -> [URL] {
        [root.appendingPathComponent("\(domain).plist"),
         root.appendingPathComponent(user, isDirectory: true).appendingPathComponent("\(domain).plist")]
    }

    /// Merges profile plists; later files (per user) override earlier ones. Unreadable files are skipped.
    static func managedSettings(files: [URL]) -> [String: Any] {
        var merged: [String: Any] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { continue }
            merged.merge(dict) { _, new in new }
        }
        return merged
    }

    // Preference values come back as NSNumber (Int/Real/Bool) or, from hand-edited plists, String.
    static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            switch text.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        }
        return nil
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        if let text = value as? String, let double = Double(text.trimmingCharacters(in: .whitespaces)), double.isFinite { return double }
        return nil
    }
}
