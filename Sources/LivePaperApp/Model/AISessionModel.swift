// AISessionModel — one AI create/modify job as the UI sees it. Consumes the AISessionHandle's
// event stream on the main actor, enforces the user's timeout, and remembers what the user decided
// (accepted / discarded). Foundation + Observation only (also compiled into LivePaperSelfTest).
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

    /// A reference image of the session as the session view shows it: the workspace copy.
    struct SessionReferenceFile: Identifiable, Equatable {
        let id: UUID
        /// `<workspace>/references/ref-01.jpg`
        let url: URL
        let role: AIReferenceRole
        /// The original's name (UI only).
        let displayName: String
    }

    let id: String
    let request: AISessionRequest
    /// The prepared images the session was started with (kept so "Try Again" can reuse them
    /// without opening the originals again).
    let references: [PreparedReference]
    let harness: AIHarness
    let model: String?
    let startedAt: Date
    let timeout: TimeInterval
    /// Built-in scene that was cloned so it could be modified (shown in the header).
    let clonedFrom: String?

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
    /// The workspace copies, in the order the agent got them (ref-01 first).
    var referenceFiles: [SessionReferenceFile] {
        references.enumerated().map { i, r in
            SessionReferenceFile(id: r.id, url: workspace.appendingPathComponent(ReferenceWorkspace.relativeImagePath(index: i + 1, format: r.vision.format)),
                                 role: r.role, displayName: r.displayName)
        }
    }

    init(handle: AISessionHandle, request: AISessionRequest, references: [PreparedReference] = [], harness: AIHarness, model: String?,
         timeout: TimeInterval, clonedFrom: String? = nil, now: Date = Date()) {
        self.id = handle.id
        self.handle = handle
        self.request = request
        self.references = references
        self.harness = harness
        self.model = model
        self.timeout = timeout
        self.clonedFrom = clonedFrom
        self.startedAt = now
    }

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
        let limit = timeout
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
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
