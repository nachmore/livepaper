// AISessionModel — one AI create/modify job as the UI sees it. Consumes the AISessionHandle's
// event stream on the main actor, enforces the user's timeout, and remembers what the user decided
// (accepted / discarded). A recovered session (one an earlier run left behind, AppModel.recoverSessions)
// is the same, marked `isRecovered`, with the times and settings it started with.
// Foundation + Observation only (also compiled into LivePaperSelfTest).
import Foundation
import Observation
import LivePaperCore

@MainActor
@Observable
final class AISessionModel: Identifiable {
    /// What the user did with a finished session.
    enum Resolution: Equatable {
        /// Added to (create) or replaced in (modify) the library as this scene id.
        case accepted(sceneID: String)
        case discarded
    }

    let id: String
    let request: AISessionRequest
    /// The prepared images the session was started with, in tray order (kept so "Try Again" can
    /// reuse them without opening the originals again, and for the session view's thumbnails). Only
    /// the picture to animate keeps its full-size master (`slimmed`); once the session is accepted
    /// that goes too.
    private(set) var references: [PreparedReference]
    let harness: AIHarness
    let model: String?
    let startedAt: Date
    let timeout: TimeInterval
    /// Built-in scene that was cloned so it could be modified (shown in the header).
    let clonedFrom: String?
    /// The feedback of earlier attempts, oldest first (already part of the prompt); Try Again with
    /// Feedback adds to it.
    let feedback: [String]
    /// Taken over from an earlier run of LivePaper (it quit, crashed or was restarted while the
    /// session ran): no transcript from before, marked "Recovered" in the sidebar and the menu bar.
    let isRecovered: Bool
    /// The time limit applies (not to a recovered session whose agent had already finished: only
    /// LivePaper's check is left to run).
    private let enforcesTimeLimit: Bool

    private(set) var state = AISessionState()
    private(set) var finishedAt: Date?
    var resolution: Resolution?
    /// Bumped on every event so views can follow the newest row without diffing `state`.
    private(set) var revision = 0

    private let handle: AISessionHandle
    private var consumer: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    var workspace: URL { handle.workspace }
    var prompt: String { PromptComposer.prompt(of: request) }
    var title: String { PromptComposer.title(for: prompt) }
    var isRunning: Bool { !state.phase.isTerminal }
    var isModify: Bool { if case .modify = request { return true } else { return false } }
    var targetSceneID: String? { if case .modify(let id, _) = request { return id } else { return nil } }
    /// nil without reference images.
    var referenceCounts: ReferenceCounts? { references.isEmpty ? nil : ReferenceCounts(roles: references.map(\.role)) }
    /// - Parameter now: when the session started (a recovered one: in the earlier run).
    init(handle: AISessionHandle, request: AISessionRequest, references: [PreparedReference] = [], harness: AIHarness, model: String?,
         timeout: TimeInterval, clonedFrom: String? = nil, feedback: [String] = [], now: Date = Date(), recovered: Bool = false,
         enforcesTimeLimit: Bool = true) {
        self.id = handle.id
        self.handle = handle
        self.request = request
        self.references = Self.slimmed(references)
        self.harness = harness
        self.model = model
        self.timeout = timeout
        self.clonedFrom = clonedFrom
        self.feedback = feedback
        self.startedAt = now
        self.isRecovered = recovered
        self.enforcesTimeLimit = enforcesTimeLimit
    }

    /// A session an earlier run left behind, as AIServicing.recoverSessions handed it over (already
    /// watching its agent or checking its scene). The time limit counts from when it started.
    convenience init(recovered r: RecoveredAISession) {
        self.init(handle: r.handle, request: r.record.request, references: r.references, harness: r.record.harness.harness,
                  model: r.record.model, timeout: r.record.timeout, clonedFrom: r.record.clonedFrom, feedback: r.record.feedback,
                  now: r.record.startedAt, recovered: true, enforcesTimeLimit: r.agentRunning)
    }

    /// "Embers drifting… — Still working (recovered)", for the menu bar's AI jobs.
    var menuTitle: String {
        let status = state.lastStatus
        let mark = isRecovered && status.range(of: "recovered", options: .caseInsensitive) == nil ? " (recovered)" : ""
        return "\(title) \u{2014} \(status)\(mark)"
    }

    /// `refs` holding only what a session still needs: a reference image's master (≤ 3840 px, several
    /// MB) is only ever used for the picture to animate, and roles don't change within a session or
    /// on Try Again, so the others share their vision copy's bytes instead (copy-on-write Data).
    static func slimmed(_ refs: [PreparedReference], keepingAnimate: Bool = true) -> [PreparedReference] {
        refs.map { r in
            guard !(keepingAnimate && r.role == .animate), r.master != r.vision else { return r }
            return PreparedReference(id: r.id, role: r.role, displayName: r.displayName, requestedPath: r.requestedPath, originPath: r.originPath,
                                     original: r.original, master: r.vision, vision: r.vision, summary: r.summary)
        }
    }

    /// After the session was accepted (no Try Again any more): drops the picture to animate's
    /// master too; the thumbnails come from the vision copies.
    func releasePictureToAnimate() { references = Self.slimmed(references, keepingAnimate: false) }

    /// Starts consuming events. `onFinish` runs once when the session reaches a terminal phase.
    func start(onFinish: @escaping @MainActor (AISessionModel) -> Void) {
        guard consumer == nil else { return }
        let events = handle.events
        consumer = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                self.state.apply(event)
                self.revision += 1
                if self.state.phase.isTerminal { break }
            }
            guard let self else { return }
            self.state.streamEnded()
            self.finish(onFinish)
        }
        guard enforcesTimeLimit else { return }
        let limit = timeout
        // From the start (for a recovered session: in the earlier run, so it gets what is left).
        let wait = max(0, startedAt.addingTimeInterval(limit).timeIntervalSinceNow)
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.handle.cancel()
            let minutes = max(1, Int((limit / 60).rounded()))
            let duration = minutes == 1 ? "1 minute" : "\(minutes) minutes"
            self.state.apply(.failed("Stopped after \(duration) (the AI time limit in Settings \u{203A} AI)."))
            self.revision += 1
            self.consumer?.cancel()
            self.finish(onFinish)
        }
    }

    /// Stops the agent (kills its process group) and marks the session cancelled.
    func cancel() {
        guard isRunning else { return }
        handle.cancel()
        state.markCancelled()
        revision += 1
        consumer?.cancel()
        watchdog?.cancel()
        finishedAt = Date()
    }

    /// Stops the agent's process group synchronously (SIGTERM, up to `grace` seconds, SIGKILL) and
    /// returns once it is gone — for quitting, when `cancel()`'s timer-based SIGKILL would never run.
    /// Blocks, so call it off the main thread (AgentShutdown does). Call `cancel()` first for the UI.
    nonisolated func terminateAgent(grace: TimeInterval) -> Bool {
        guard let stoppable = handle as? AISessionTerminating else { handle.cancel(); return true }
        return stoppable.terminateNow(grace: grace)
    }

    /// Seconds since start (frozen once finished).
    func elapsed(now: Date = Date()) -> TimeInterval { (finishedAt ?? now).timeIntervalSince(startedAt) }

    private func finish(_ onFinish: @MainActor (AISessionModel) -> Void) {
        guard finishedAt == nil else { return }
        finishedAt = Date()
        watchdog?.cancel()
        onFinish(self)
    }
}
