// HelperLock — how "Lock Now" asks the LivePaper helper to run its lock flow (Foundation-only;
// also compiled into LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/).
//
// The app posts LPNotification.lockNow (distributed, with a request id) and waits briefly for the
// helper's LPNotification.lockNowAccepted. The helper owns the lock flow (start the saver unless
// one is running; the saver locks — ARCHITECTURE §7). When no helper answers, AppModel falls back
// to starting ScreenSaverEngine itself, which is allowed because the user explicitly asked to lock.
// Neither route runs when the password isn't required immediately: AppModel.lockNow refuses first,
// and the helper refuses too (LPNotification.lockRefused) if the app's status was stale.
import Foundation
import LivePaperCore

/// Asks a helper to lock, behind a protocol so tests and mock mode never broadcast anything.
@MainActor
protocol HelperLockChannel: AnyObject {
    /// Posts one lock request and waits up to `timeout` seconds for a helper to accept it.
    /// Returns false when nobody answered (no helper running).
    func requestLock(timeout: TimeInterval) async -> Bool
}

/// The real channel: distributed notifications between the app and the helper.
@MainActor
final class DistributedHelperLockChannel: NSObject, HelperLockChannel {
    private let requestName: String
    private let acceptedName: String
    /// Request id → its waiting caller.
    private var waiting: [String: CheckedContinuation<Bool, Never>] = [:]

    /// The names are injectable so a self test can play the helper on private names.
    init(requestName: String = LPNotification.lockNow, acceptedName: String = LPNotification.lockNowAccepted) {
        self.requestName = requestName
        self.acceptedName = acceptedName
        super.init()
        // AppKit suspends distributed-notification delivery while an app is inactive, and a
        // menu-bar app usually is when its menu item is chosen: ask for immediate delivery.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(accepted(_:)), name: .init(acceptedName),
                                                            object: nil, suspensionBehavior: .deliverImmediately)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func requestLock(timeout: TimeInterval) async -> Bool {
        let id = UUID().uuidString
        return await withCheckedContinuation { continuation in
            waiting[id] = continuation
            // deliverImmediately: the helper is a background agent, never the active app.
            DistributedNotificationCenter.default().postNotificationName(
                .init(requestName), object: nil, userInfo: [LPNotification.requestIDKey: id], deliverImmediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated { self?.resolve(id, accepted: false) }
            }
        }
    }

    /// Distributed notifications may arrive on any thread; state lives on the main actor.
    @objc nonisolated private func accepted(_ note: Notification) {
        let id = note.userInfo?[LPNotification.requestIDKey] as? String
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let id {
                    self.resolve(id, accepted: true)
                } else {
                    // A helper that doesn't echo ids still answered: it handles whatever is pending.
                    for pending in Array(self.waiting.keys) { self.resolve(pending, accepted: true) }
                }
            }
        }
    }

    private func resolve(_ id: String, accepted: Bool) {
        waiting.removeValue(forKey: id)?.resume(returning: accepted)
    }
}

/// A channel with a fixed answer (mock mode, tests).
@MainActor
final class FixedHelperLockChannel: HelperLockChannel {
    let answers: Bool
    private(set) var requests = 0
    init(answers: Bool) { self.answers = answers }
    func requestLock(timeout: TimeInterval) async -> Bool {
        requests += 1
        return answers
    }
}
