// LockRefusal — why LivePaper declined to "lock" (ARCHITECTURE §7).
//
// LivePaper's own lock (the helper's shortcut, the menu bar's Lock Now) is "start the screen saver;
// the saver locks". That only locks the Mac when "Require password after screen saver begins" is
// Immediately. With a delay, Off, or a setting LivePaper can't read, starting the saver would leave
// the Mac unlocked behind something that looks locked, so LivePaper refuses instead and says why.
// It never falls back to private lock APIs.
//
// The helper posts LPNotification.lockRefused (userInfo[LPNotification.reasonKey] = rawValue); the
// app shows the explanation. When the app isn't running the helper opens it with
// `LPLockRefusal.launchArgument <rawValue>`. The app builds the text itself from the reason, so a
// notification or argument can only pick one of these messages.
import Foundation

public enum LPLockRefusal: String, Codable, Sendable, CaseIterable {
    /// A delay is set ("After 5 minutes" …).
    case passwordDelayed
    /// "Require password" is off.
    case passwordOff
    /// The setting couldn't be read (sysadminctl failed or said something unexpected).
    case passwordUnknown
    /// Not Immediately; the app's own check doesn't tell a delay from Off.
    case passwordNotImmediate

    public var title: String { "LivePaper didn\u{2019}t lock your Mac" }

    public var message: String {
        let setting = "\u{201C}Require password after screen saver begins\u{201D}"
        let fix = "Set it to Immediately in System Settings \u{203A} Lock Screen, or lock with \u{2303}\u{2318}Q."
        switch self {
        case .passwordDelayed:
            return "\(setting) is set to a delay, so starting the screen saver wouldn\u{2019}t lock your Mac. \(fix)"
        case .passwordOff:
            return "\(setting) is off, so starting the screen saver wouldn\u{2019}t lock your Mac. \(fix)"
        case .passwordUnknown:
            return "LivePaper couldn\u{2019}t check \(setting), so it can\u{2019}t be sure the screen saver would lock your Mac. \(fix)"
        case .passwordNotImmediate:
            return "\(setting) isn\u{2019}t Immediately, so starting the screen saver wouldn\u{2019}t lock your Mac. \(fix)"
        }
    }

    /// Short line for the menu bar, under the disabled Lock Now item.
    public var menuNote: String {
        self == .passwordUnknown ? "Won\u{2019}t lock: can\u{2019}t check the password setting"
                                 : "Won\u{2019}t lock: password isn\u{2019}t required immediately"
    }

    /// The app is launched with `[launchArgument, rawValue]` when the helper refused while it wasn't running.
    public static let launchArgument = "--lock-refused"

    public var launchArguments: [String] { [Self.launchArgument, rawValue] }

    /// The reason passed with `launchArgument`, if any (unknown values are ignored).
    public static func fromLaunchArguments(_ arguments: [String]) -> LPLockRefusal? {
        guard let index = arguments.firstIndex(of: launchArgument), index + 1 < arguments.count else { return nil }
        return LPLockRefusal(rawValue: arguments[index + 1])
    }

    /// The reason in a lockRefused notification's userInfo (nil when missing or unknown).
    public static func fromUserInfo(_ userInfo: [AnyHashable: Any]?) -> LPLockRefusal? {
        (userInfo?[LPNotification.reasonKey] as? String).flatMap(LPLockRefusal.init(rawValue:))
    }

    public var userInfo: [String: String] { [LPNotification.reasonKey: rawValue] }
}
