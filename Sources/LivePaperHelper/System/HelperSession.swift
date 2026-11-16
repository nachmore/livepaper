// HelperSession — facts about the login session that come from the window server (CoreGraphics),
// so only the agent uses them (never --print-config / --self-check). Safe on any thread.
import CoreGraphics
import Foundation

enum HelperSession {
    /// `CGSSessionScreenIsLocked` is present (true) in the session dictionary only while locked.
    static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    /// Seconds since the last keyboard, mouse or trackpad input of the session's HID system
    /// (kCGAnyInputEventType). WindowServer's view of HID input — the same events whose
    /// `UserIsActive` tickles macOS's display-sleep timer follows (docs/RESEARCH.md §7). Needs no
    /// permission (it says when, never what).
    static var idleSeconds: TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return max(0, CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any))
    }
}
