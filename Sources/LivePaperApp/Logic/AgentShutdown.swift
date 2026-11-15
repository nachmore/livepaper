// AgentShutdown — stops every AI agent before LivePaper quits or uninstalls itself
// (Foundation-only; also compiled into LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/).
//
// Agents run in their own process groups, so they don't die with the app, and AISession.cancel()
// leaves its SIGKILL to a timer that never fires once the app has exited. An agent (or a tool it
// started) that ignores SIGTERM would keep working, spending the user's API credits, and its
// `livepaper check` calls would start LivePaperRenderd. So quitting waits — briefly, and never
// longer than `limit` — until the agents' processes are gone.
import Foundation

@MainActor
enum AgentShutdown {
    /// SIGTERM → SIGKILL.
    nonisolated static let grace: TimeInterval = 1
    /// Quitting is never held up longer than this. (Only a session that is still launching can take
    /// longer to stop; the app exiting before its spawn takes care of it.)
    nonisolated static let limit: TimeInterval = 3

    /// Marks running sessions cancelled, then stops every session's agent — finished ones too: an
    /// agent cancelled a moment ago may still be on its way out — in parallel, off the main thread.
    /// Returns once all of them are gone, or after `limit` seconds.
    static func stop(_ sessions: [AISessionModel], grace: TimeInterval = grace, limit: TimeInterval = limit) async {
        guard !sessions.isEmpty else { return }
        for session in sessions where session.isRunning { session.cancel() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = ResumeOnce(continuation)
            let group = DispatchGroup()
            for session in sessions {
                DispatchQueue.global(qos: .userInitiated).async(group: group) { _ = session.terminateAgent(grace: grace) }
            }
            group.notify(queue: .global(qos: .userInitiated)) { done.resume() }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + limit) { done.resume() }
        }
    }
}

/// Resumes a continuation exactly once, whichever caller comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func resume() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}
