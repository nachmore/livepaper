// ScreenTimers — when macOS turns the displays off and when it starts the screen saver, and what
// keeps the displays on, as far as LivePaper can tell without changing anything
// (docs/RESEARCH.md §7). Pure parsing, tested with recorded values; PowerProbe.swift reads the
// live system.
import Foundation

/// A power source with its own energy settings (`pmset -g custom` has one section per source).
public enum LPPowerSource: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    case battery, ac, ups

    /// The section name in `pmset -g custom`, which is also the providing power source type IOKit
    /// reports (`IOPSGetProvidingPowerSourceType`: kIOPMBatteryPowerKey, kIOPMACPowerKey, kIOPMUPSPowerKey).
    public var pmsetName: String {
        switch self {
        case .battery: return "Battery Power"
        case .ac: return "AC Power"
        case .ups: return "UPS Power"
        }
    }

    public init?(pmsetName: String) {
        guard let source = Self.allCases.first(where: { $0.pmsetName == pmsetName }) else { return nil }
        self = source
    }

    /// "on battery", for status lines.
    public var phrase: String {
        switch self {
        case .battery: return "on battery"
        case .ac: return "on power adapter"
        case .ups: return "on UPS power"
        }
    }
}

/// When macOS starts the screen saver after the user stops using the Mac.
public struct LPScreenSaverIdle: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// A configuration profile forces it (the user can't change it).
        case managed
        /// The user's setting (System Settings › Lock Screen).
        case user
        /// Nothing set: macOS's default (ScreenSaver.framework's EngineDefaults.plist).
        case systemDefault
    }

    /// Seconds; 0 = never.
    public var seconds: Int
    public var source: Source

    public init(seconds: Int, source: Source) { self.seconds = seconds; self.source = source }

    public static let domain = "com.apple.screensaver"
    public static let key = "idleTime"
    /// Where loginwindow reads the default (Verified in its disassembly, macOS 26.7).
    public static let engineDefaultsFile =
        URL(fileURLWithPath: "/System/Library/Frameworks/ScreenSaver.framework/Resources/EngineDefaults.plist")
    /// loginwindow's own fallback when that file has no number.
    public static let builtinDefault = 1200

    /// What loginwindow uses (`-[ScreenSaverDaemon idleTimePreference]`: CFPreferencesGetAppIntegerValue
    /// of com.apple.screensaver `idleTime`, whose search list puts a profile's forced value first, then
    /// the user's current-host and any-host values; without one, the default from EngineDefaults.plist,
    /// else 1200 s). Values that aren't non-negative numbers are skipped.
    /// - Parameters:
    ///   - forced: what CFPreferences reports as forced by a profile (nil: not forced).
    ///   - managed: the merged configuration-profile plists for com.apple.screensaver.
    ///   - userCurrentHost, userAnyHost: the user's values (System Settings writes the current host's).
    ///   - engineDefaults: the contents of EngineDefaults.plist (nil: unreadable).
    public static func resolve(forced: Any?, managed: [String: Any], userCurrentHost: Any?, userAnyHost: Any?,
                               engineDefaults: [String: Any]?) -> LPScreenSaverIdle {
        if let seconds = seconds(forced) ?? seconds(managed[key]) { return LPScreenSaverIdle(seconds: seconds, source: .managed) }
        if let seconds = seconds(userCurrentHost) ?? seconds(userAnyHost) { return LPScreenSaverIdle(seconds: seconds, source: .user) }
        return LPScreenSaverIdle(seconds: seconds(engineDefaults?[key]) ?? builtinDefault, source: .systemDefault)
    }

    /// A preference value as whole seconds (NSNumber, or a string from a hand-edited plist).
    static func seconds(_ value: Any?) -> Int? {
        let double: Double?
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            double = number.doubleValue
        } else if let text = value as? String {
            double = Double(text.trimmingCharacters(in: .whitespaces))
        } else {
            double = nil
        }
        guard let double, double.isFinite, double >= 0 else { return nil }
        return Int(min(double, 1e9).rounded(.down))
    }
}

/// The display-sleep timers and the screen saver's idle time, plus the power source in use.
public struct LPScreenTimers: Codable, Equatable, Sendable {
    /// Seconds without user activity after which each power source turns the displays off
    /// (`pmset displaysleep`, minutes × 60); 0 = never. A missing source is unknown (a desktop Mac
    /// has no battery section; nothing could be read).
    public var displaySleep: [LPPowerSource: Int]
    /// The power source in use (nil: unknown).
    public var currentSource: LPPowerSource?
    /// When macOS starts the screen saver (nil: not read).
    public var screenSaverIdle: LPScreenSaverIdle?

    public init(displaySleep: [LPPowerSource: Int] = [:], currentSource: LPPowerSource? = nil,
                screenSaverIdle: LPScreenSaverIdle? = nil) {
        self.displaySleep = displaySleep; self.currentSource = currentSource; self.screenSaverIdle = screenSaverIdle
    }

    /// The current source's display-sleep time (nil: unknown).
    public var currentDisplaySleep: Int? { currentSource.flatMap { displaySleep[$0] } }

    /// `displaysleep` (minutes) per section of `pmset -g custom`, as seconds. Lines look like
    /// "Battery Power:" and " displaysleep         5"; `pmset -g` may append "(display sleep
    /// prevented by …)", which is ignored. Unknown sections and malformed values are skipped.
    public static func parsePmsetCustom(_ output: String) -> [LPPowerSource: Int] {
        var result: [LPPowerSource: Int] = [:]
        var section: LPPowerSource?
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix(" "), !line.hasPrefix("\t"), trimmed.hasSuffix(":") {
                section = LPPowerSource(pmsetName: String(trimmed.dropLast()))
                continue
            }
            let words = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let section, words.count >= 2, words[0] == "displaysleep", let minutes = Int(words[1]), minutes >= 0 else { continue }
            result[section] = minutes * 60
        }
        return result
    }

    /// The same from /Library/Preferences/com.apple.PowerManagement.plist ("Battery Power" →
    /// "Display Sleep Timer", minutes), for when pmset can't be run. It only holds what was changed
    /// from macOS's defaults, so a missing value stays unknown.
    public static func parsePowerManagementPreferences(_ plist: [String: Any]) -> [LPPowerSource: Int] {
        var result: [LPPowerSource: Int] = [:]
        for source in LPPowerSource.allCases {
            guard let settings = plist[source.pmsetName] as? [String: Any],
                  let minutes = LPScreenSaverIdle.seconds(settings["Display Sleep Timer"]) else { continue }
            result[source] = minutes * 60
        }
        return result
    }
}

/// What keeps the displays on, and until when macOS counts the user as active, from powerd's
/// assertions (docs/RESEARCH.md §7).
public struct LPPowerAssertions: Equatable, Sendable {
    /// Assertions that keep the displays on with no end in sight ("MSTeams: Microsoft Teams Call in
    /// progress"): the displays won't turn off by themselves while one is held.
    public var preventingDisplaySleep: [String]
    /// When the last timed display-sleep preventer ends (e.g. powerd's "delay display off" proxy).
    public var preventionEnds: Date?
    /// When the last `UserIsActive` assertion times out. Activity (HID input, apps declaring user
    /// activity) re-arms them with the display-sleep time; macOS dims the displays once the last
    /// one has timed out and turns them off about 10 s later (RESEARCH §7).
    public var userActivityEnds: Date?

    public init(preventingDisplaySleep: [String] = [], preventionEnds: Date? = nil, userActivityEnds: Date? = nil) {
        self.preventingDisplaySleep = preventingDisplaySleep; self.preventionEnds = preventionEnds
        self.userActivityEnds = userActivityEnds
    }

    /// Assertion types that keep the displays on. `NoDisplaySleepAssertion` (the old name, still used
    /// by call apps) counts under PreventUserIdleDisplaySleep in the summary; powerd's own proxies
    /// are InternalPreventDisplaySleep.
    public static let displayPreventingTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion",
                                                             "InternalPreventDisplaySleep"]
    public static let userActivityType = "UserIsActive"

    /// Reads the per-assertion dictionaries of `IOPMCopyAssertionsByProcess` (all processes' lists
    /// joined). A timed assertion (TimeoutSeconds > 0, a release or turn-off action) ends at
    /// AssertTimeoutUpdateTime + AssertTimeoutTimeLeft (the time left when it was last re-armed;
    /// the value isn't live); one that already ended, or is switched off (AssertLevel 0), is ignored.
    public static func parse(_ assertions: [[String: Any]], now: Date) -> LPPowerAssertions {
        var result = LPPowerAssertions()
        for assertion in assertions {
            guard let type = (assertion["AssertionTrueType"] as? String) ?? (assertion["AssertType"] as? String) else { continue }
            if let level = assertion["AssertLevel"] as? NSNumber, level.intValue == 0 { continue }
            let isDisplay = displayPreventingTypes.contains(type)
            guard isDisplay || type == userActivityType else { continue }
            let ends = end(of: assertion)
            if let ends, ends <= now { continue }
            if type == userActivityType {
                if let ends { result.userActivityEnds = max(result.userActivityEnds ?? ends, ends) }
            } else if let ends {
                result.preventionEnds = max(result.preventionEnds ?? ends, ends)
            } else {
                result.preventingDisplaySleep.append(describe(assertion, type: type))
            }
        }
        result.preventingDisplaySleep.sort()
        return result
    }

    /// The summary of `IOPMCopyAssertionsStatus` (type → count), when the per-process list can't be
    /// read: any display preventer counts as one without an end.
    public static func fromSummary(_ summary: [String: Any]) -> LPPowerAssertions {
        let held = displayPreventingTypes.filter { ((summary[$0] as? NSNumber)?.intValue ?? 0) > 0 }.sorted()
        return LPPowerAssertions(preventingDisplaySleep: held)
    }

    static func end(of assertion: [String: Any]) -> Date? {
        guard let timeout = (assertion["TimeoutSeconds"] as? NSNumber)?.doubleValue, timeout > 0 else { return nil }
        // TimeoutActionLog only logs: the assertion stays.
        if let action = assertion["TimeoutAction"] as? String, action == "TimeoutActionLog" { return nil }
        guard let since = (assertion["AssertTimeoutUpdateTime"] as? Date) ?? (assertion["AssertStartWhen"] as? Date) else { return nil }
        let left = (assertion["AssertTimeoutTimeLeft"] as? NSNumber)?.doubleValue ?? timeout
        return since.addingTimeInterval(max(0, left))
    }

    static func describe(_ assertion: [String: Any], type: String) -> String {
        let process = (assertion["Process Name"] as? String).map { "\($0): " } ?? (assertion["AssertPID"] as? NSNumber).map { "pid \($0): " } ?? ""
        let name = (assertion["AssertName"] as? String) ?? (assertion["HumanReadableReason"] as? String) ?? type
        return process + name
    }
}
