// SessionUnlock — tells the app when the login session is unlocked (com.apple.screenIsUnlocked),
// for a saver update that had to wait because the Mac was locked (AppModel.updateSaverAfterUnlock).
// Foundation-only; also compiled into LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/.
import Foundation
import LivePaperCore

/// Observes one distributed notification while it exists (until `invalidate()`).
final class SessionUnlockObserver: NSObject, @unchecked Sendable {
    private let handler: @MainActor () -> Void
    private let session: String

    /// - Parameters:
    ///   - name: LPNotification.screenUnlocked; tests use a private name (nobody else posts it).
    ///   - uid: loginwindow posts the unlock with the user's uid as the object (ARCHITECTURE §1); one
    ///     with another object (another user's session) is ignored, one without any is taken.
    init(name: String = LPNotification.screenUnlocked, uid: uid_t = getuid(), handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        self.session = String(uid)
        super.init()
        // A menu-bar app is almost never active, and AppKit holds back distributed notifications for
        // inactive apps unless they ask for immediate delivery.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(received(_:)), name: Notification.Name(name),
                                                            object: nil, suspensionBehavior: .deliverImmediately)
    }

    static func isOwnSession(_ object: Any?, uid: String) -> Bool {
        guard let object else { return true }
        return (object as? String) == uid
    }

    @objc private func received(_ note: Notification) {
        guard Self.isOwnSession(note.object, uid: session) else { return }
        DispatchQueue.main.async { [handler] in MainActor.assumeIsolated { handler() } }
    }

    func invalidate() { DistributedNotificationCenter.default().removeObserver(self) }

    /// AppEnvironment.observeUnlock for the live app.
    @MainActor
    static func observe(_ handler: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) {
        let observer = SessionUnlockObserver(handler: handler)
        return { observer.invalidate() }
    }
}
