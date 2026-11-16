// PreSleepPolicy — "Show your scene when the screens turn off first" (state.json
// `lock.showSceneBeforeDisplaySleep`, off by default; ARCHITECTURE §4.4, §7, §11; RESEARCH §7).
//
// When the displays are set to turn off before the screen saver would start (typically on battery:
// screens off after 5 min, screen saver after 15), macOS locks at display sleep with no saver
// running, so the lock screen shows the desktop picture: loginwindow only uses a saver that runs
// when the lock begins. With this option the helper starts the screen saver — LivePaper's lock
// flow, so the saver locks — `lead` seconds before the displays would dim; the displays then dim
// and turn off on their own schedule (the saver holds no display assertion), and the saver resumes
// by itself when they wake.
//
// Pure logic, shared by the helper (which acts), the app (Settings › Lock's status line) and the CLI
// (`livepaper doctor`), so all three say the same thing.
import Foundation

/// The facts the decision depends on.
public struct LPPreSleepSituation: Equatable, Sendable {
    /// The option (state.json).
    public var enabled: Bool
    /// "Require password after screen saver begins: Immediately" (nil: couldn't be read).
    public var passwordImmediately: Bool?
    public var timers: LPScreenTimers
    public var sessionLocked: Bool
    public var screenSaverRunning: Bool
    public var assertions: LPPowerAssertions

    public init(enabled: Bool, passwordImmediately: Bool?, timers: LPScreenTimers, sessionLocked: Bool = false,
                screenSaverRunning: Bool = false, assertions: LPPowerAssertions = LPPowerAssertions()) {
        self.enabled = enabled; self.passwordImmediately = passwordImmediately; self.timers = timers
        self.sessionLocked = sessionLocked; self.screenSaverRunning = screenSaverRunning; self.assertions = assertions
    }
}

/// Why the helper doesn't watch for the displays turning off right now.
public enum LPPreSleepReason: Equatable, Sendable, CustomStringConvertible {
    case optionOff
    case sessionLocked
    case screenSaverRunning
    /// Starting the saver early wouldn't lock any sooner; it would only show it earlier than expected.
    case passwordNotImmediate
    case passwordUnknown
    case powerSourceUnknown
    case displaySleepUnknown(LPPowerSource)
    case displaysNeverSleep(LPPowerSource)
    /// The screen saver starts first (or at the same time): macOS already shows it at the lock.
    case screenSaverStartsFirst(LPPowerSource, displaySleep: Int, screenSaverIdle: Int)
    /// Something keeps the displays on (a call, a video): they won't turn off by themselves.
    case displaySleepPrevented([String])

    public var description: String {
        switch self {
        case .optionOff: return "the option is off"
        case .sessionLocked: return "the session is locked"
        case .screenSaverRunning: return "a screen saver is running"
        case .passwordNotImmediate: return "the password isn't required immediately after the screen saver starts"
        case .passwordUnknown: return "couldn't tell whether the password is required immediately"
        case .powerSourceUnknown: return "couldn't tell which power source is in use"
        case .displaySleepUnknown(let source): return "couldn't read when the screens turn off \(source.phrase)"
        case .displaysNeverSleep(let source): return "the screens never turn off by themselves \(source.phrase)"
        case .screenSaverStartsFirst(let source, let displaySleep, let idle):
            return "the screen saver starts first \(source.phrase) (screens off after \(displaySleep) s, screen saver after \(idle) s)"
        case .displaySleepPrevented(let by): return "the screens are kept on by \(by.joined(separator: "; "))"
        }
    }
}

public enum LPPreSleepDecision: Equatable, Sendable {
    /// Nothing to do until something changes (power source, unlock, wake, the option, energy settings).
    case inactive(LPPreSleepReason)
    /// It applies, but the displays are kept on: look again later.
    case blocked(LPPreSleepReason)
    /// Watch the idle time: the displays turn off after `displaySleep` s, the saver would start after
    /// `screenSaverIdle` s (0 = never).
    case watch(displaySleep: Int, screenSaverIdle: Int)
}

public enum LPPreSleepPolicy {
    /// Whether the option has anything to do on `source`: the displays turn off (displaySleep > 0)
    /// before the screen saver starts (idle time longer, or 0 = never). nil when unknown.
    public static func applies(on source: LPPowerSource, timers: LPScreenTimers) -> Bool? {
        guard let displaySleep = timers.displaySleep[source], let idle = timers.screenSaverIdle else { return nil }
        return displaySleep > 0 && (idle.seconds == 0 || displaySleep < idle.seconds)
    }

    public static func decide(_ s: LPPreSleepSituation) -> LPPreSleepDecision {
        guard s.enabled else { return .inactive(.optionOff) }
        if s.sessionLocked { return .inactive(.sessionLocked) }
        if s.screenSaverRunning { return .inactive(.screenSaverRunning) }
        switch s.passwordImmediately {
        case nil: return .inactive(.passwordUnknown)
        case false?: return .inactive(.passwordNotImmediate)
        case true?: break
        }
        guard let source = s.timers.currentSource else { return .inactive(.powerSourceUnknown) }
        guard let displaySleep = s.timers.displaySleep[source] else { return .inactive(.displaySleepUnknown(source)) }
        guard displaySleep > 0 else { return .inactive(.displaysNeverSleep(source)) }
        // Always set: loginwindow falls back to a default (PowerProbe resolves it the same way).
        let idle = s.timers.screenSaverIdle?.seconds ?? LPScreenSaverIdle.builtinDefault
        if idle != 0 && idle <= displaySleep {
            return .inactive(.screenSaverStartsFirst(source, displaySleep: displaySleep, screenSaverIdle: idle))
        }
        if !s.assertions.preventingDisplaySleep.isEmpty { return .blocked(.displaySleepPrevented(s.assertions.preventingDisplaySleep)) }
        return .watch(displaySleep: displaySleep, screenSaverIdle: idle)
    }
}

/// When to act: one one-shot timer, armed for the moment the idle time reaches the threshold.
public enum LPPreSleepSchedule {
    /// The screen saver starts this long before the displays would dim (they turn off about 10 s
    /// after that). Long enough for a timer that fires a little late and for the saver to come up
    /// before the dim; short enough that a mouse move "just before the screens go dark" rarely meets
    /// the password prompt.
    public static let lead: TimeInterval = 8
    /// A timer may fire this much early and still start (instead of arming a second timer).
    public static let earlyAllowance: TimeInterval = 1
    /// …or this much after the predicted dim: the displays only turn off about 10 s later.
    public static let lateAllowance: TimeInterval = 4

    public enum Step: Equatable, Sendable {
        /// Start the screen saver now; the displays would dim in `dimsIn` s (negative: already dimming).
        case start(dimsIn: TimeInterval)
        /// Look again in `after` s (the idle time will reach the threshold then, unless there's activity).
        case check(after: TimeInterval)
        /// The moment passed unnoticed (the displays may already be off): don't start; the idle time can
        /// reach the threshold again at the earliest `checkAfter` s from now.
        case missed(checkAfter: TimeInterval)
    }

    /// The idle time at which the saver starts.
    public static func threshold(displaySleep: TimeInterval, lead: TimeInterval = lead) -> TimeInterval {
        max(displaySleep - lead, 1)
    }

    /// - Parameters:
    ///   - displaySleep: the current source's display-sleep time (s).
    ///   - idle: seconds since the last HID input.
    ///   - userActivityEndsIn: until the last UserIsActive assertion times out (s; nil = none known).
    ///     Apps that declare user activity (remote-control events, Bluetooth HID, capture apps) push
    ///     the dim past what the HID idle time says.
    ///   - preventionEndsIn: until the last timed display-sleep preventer ends (s; nil = none).
    public static func next(displaySleep: TimeInterval, idle: TimeInterval, userActivityEndsIn: TimeInterval? = nil,
                            preventionEndsIn: TimeInterval? = nil, lead: TimeInterval = lead) -> Step {
        var dimsIn = displaySleep - max(0, idle)
        if let userActivityEndsIn { dimsIn = max(dimsIn, userActivityEndsIn) }
        if let preventionEndsIn { dimsIn = max(dimsIn, preventionEndsIn) }
        if dimsIn > lead + earlyAllowance { return .check(after: dimsIn - lead) }
        if dimsIn >= -lateAllowance { return .start(dimsIn: dimsIn) }
        return .missed(checkAfter: threshold(displaySleep: displaySleep, lead: lead))
    }

    /// How long to wait before looking again while the displays are kept on (or after a start that
    /// didn't lock): one full threshold, the earliest the idle time could reach it after new activity.
    public static func recheck(displaySleep: TimeInterval, lead: TimeInterval = lead) -> TimeInterval {
        threshold(displaySleep: displaySleep, lead: lead)
    }
}

/// Settings › Lock's status line and `livepaper doctor`'s row, from the same facts as the helper.
public enum LPPreSleepStatus {
    /// The power sources on which the option has something to do (known sources only).
    public static func applicableSources(_ timers: LPScreenTimers) -> [LPPowerSource] {
        LPPowerSource.allCases.filter { LPPreSleepPolicy.applies(on: $0, timers: timers) == true }
    }

    /// "Applies on battery: screens off after 5 min, screen saver after 15 min",
    /// "Not needed: the screen saver starts before the screens turn off",
    /// "Off: your password isn't required immediately", …
    public static func text(passwordImmediately: Bool?, timers: LPScreenTimers) -> String {
        switch passwordImmediately {
        case false?: return "Off: your password isn\u{2019}t required immediately after the screen saver starts"
        case nil: return "Off: LivePaper can\u{2019}t tell whether your password is required immediately"
        case true?: break
        }
        let known = LPPowerSource.allCases.filter { timers.displaySleep[$0] != nil }
        guard !known.isEmpty else { return "LivePaper can\u{2019}t tell when your screens turn off" }
        let idle = timers.screenSaverIdle?.seconds ?? LPScreenSaverIdle.builtinDefault
        let sources = applicableSources(timers)
        guard !sources.isEmpty else {
            if known.allSatisfy({ timers.displaySleep[$0] == 0 }) { return "Not needed: your screens don\u{2019}t turn off by themselves" }
            return "Not needed: the screen saver starts before the screens turn off"
        }
        let names = list(sources.map(\.phrase))
        let seconds = sources.map { timers.displaySleep[$0] ?? 0 }
        // "5 and 10 min" when every value is whole minutes (pmset's always are).
        let times = seconds.allSatisfy { $0 % 60 == 0 }
            ? list(seconds.map { "\($0 / 60)" }) + " min"
            : list(seconds.map { duration($0) })
        let saver = idle == 0 ? "the screen saver never starts by itself" : "screen saver after \(duration(idle))"
        return "Applies \(names): screens off after \(times), \(saver)"
    }

    /// "5 min", "90 s", "1 min 30 s".
    public static func duration(_ seconds: Int) -> String {
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        if seconds < 60 { return "\(seconds) s" }
        return "\(seconds / 60) min \(seconds % 60) s"
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
