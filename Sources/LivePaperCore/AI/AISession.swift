// AISession — runs one AI authoring session (ARCHITECTURE §10):
//
//   harness process (own process group, PATH = workspace/bin first, prompt via TASK.md)
//     → stdout parsed into AISessionEvents (and teed to .livepaper/stdout.log)
//     → scene/.check/*.png reported as .stillRendered while the agent iterates
//   harness exits → LivePaper runs SceneChecker itself (the agent's word is never trusted)
//     → .checkResult, then .finished(package: scene/) or .failed
//
// Cancellation and the timeout kill the harness's whole process group. Everything mutable lives
// on one serial queue.
import Darwin
import Foundation
import os

/// A session handle that can also stop its agent synchronously, for a process that is about to
/// exit. The agent runs in its own process group, so it doesn't die with its parent, and
/// `cancel()` leaves the SIGKILL escalation to a timer that never fires once the parent is gone:
/// an agent (or a tool it started) that ignores SIGTERM would otherwise keep running.
public protocol AISessionTerminating: AISessionHandle {
    /// Stops the agent's whole process group and returns once nothing in it is left: SIGTERM, up
    /// to `grace` seconds to exit, then SIGKILL. The session then ends as after `cancel()`. Blocks
    /// for at most `grace` + `AISession.killWait` (plus however long a launch in progress takes to
    /// spawn); returns false if something in the group was still there at the end. Idempotent.
    @discardableResult func terminateNow(grace: TimeInterval) -> Bool
}

public final class AISession: AISessionTerminating, @unchecked Sendable {
    public let id: String
    public var workspace: URL { ws.root }
    public let events: AsyncStream<AISessionEvent>
    public let request: AISessionRequest
    public let harness: AIHarness
    public let model: String?

    /// What the session needs from its environment. Closures are evaluated on the session's queue
    /// when it launches, so slow lookups (login shell, capability probes) never block `start()`.
    struct Dependencies {
        var checker: SceneChecking
        var adapter: () -> HarnessAdapter
        var environment: () -> [String: String]
        var searchPath: () -> [String]
        var extraArguments: [String]
        var timeout: TimeInterval
        /// Makes sure the render server runs before the harness starts, so the agent's `livepaper`
        /// calls find it instead of starting LivePaperRenderd from inside the agent's process tree
        /// (where a sandbox such as Codex's would also confine it). Failures are left to the check.
        var prepareRenderer: () -> Void = {}
        /// Relays the render requests a sandboxed agent can only leave in the spool (RenderSpool).
        var renderRelay: RenderRelay?
    }

    private enum StopReason { case cancelled, timedOut }
    private enum Phase { case idle, running, checking, done }

    /// How often scene/.check/ is scanned for new stills. Polling (rather than a kqueue/FSEvents
    /// watch) because the directory doesn't exist when the agent starts and `livepaper check`
    /// replaces it on every run, which a vnode watch doesn't survive.
    static let stillPollInterval: TimeInterval = 1
    /// stderr lines kept for the failure message.
    static let stderrTailLines = 8
    /// How long `stopGroup` waits for SIGKILLed processes to be gone.
    public static let killWait: TimeInterval = 0.5
    /// After the harness exits, how long whatever it left in its group gets to exit on SIGTERM.
    static let leftoverGrace: TimeInterval = 1

    private let ws: AIWorkspace
    private let deps: Dependencies
    private let continuation: AsyncStream<AISessionEvent>.Continuation
    private let queue = DispatchQueue(label: "com.nachmore.livepaper.ai-session")
    private let log = Logger(subsystem: LPPaths.bundleID, category: "ai")

    // Mutable state: touched only on `queue`.
    private var phase = Phase.idle
    private var stopReason: StopReason?
    private var child: ChildProcess?
    /// The harness's process group while anything in it may still run: from the spawn until the
    /// leftovers were stopped after the harness exited (so after that, a recycled pid is never signalled).
    private var group: pid_t?
    private var parser: HarnessStreamParser?
    private var stdoutLines = LineSplitter()
    private var stderrLines = LineSplitter()
    private var stderrTail: [String] = []
    private var stdoutLog: FileHandle?
    private var stderrLog: FileHandle?
    private var poller: DispatchSourceTimer?
    private var stillDates: [String: Date] = [:]
    private var sceneBefore: Data?
    private var lastStatus: String?

    init(id: String, workspace: AIWorkspace, request: AISessionRequest, harness: AIHarness, model: String?,
         dependencies: Dependencies) {
        self.id = id; self.ws = workspace; self.request = request; self.harness = harness
        self.model = model?.trimmingCharacters(in: .whitespaces).nilIfEmpty; self.deps = dependencies
        (events, continuation) = AsyncStream<AISessionEvent>.makeStream()
    }

    /// Starts the harness asynchronously; events arrive on `events`.
    func start() { queue.async { self.launch() } }

    /// Stops the harness (SIGTERM to its process group, SIGKILL after a grace period). The stream
    /// ends with `.failed("Cancelled.")` once the harness is gone. Safe to call at any time.
    public func cancel() {
        queue.async { [self] in
            guard phase != .done else { return }
            if stopReason == nil { stopReason = .cancelled }
            switch phase {
            case .idle, .checking: finish(.failed("Cancelled."))
            case .running: child?.terminateGroup()
            case .done: break
            }
        }
    }

    public func terminateNow(grace: TimeInterval) -> Bool {
        // Serialised behind a pending launch, so a harness being spawned right now is caught too.
        let pgid: pid_t? = queue.sync {
            if phase != .done, stopReason == nil { stopReason = .cancelled }
            switch phase {
            case .idle, .checking: finish(.failed("Cancelled."))
            case .running, .done: break   // running: the harness's exit ends the stream
            }
            return group
        }
        guard let pgid else { return true }
        log.info("session \(self.id, privacy: .public): stopping process group \(pgid) now")
        return Self.stopGroup(pgid, grace: grace)
    }

    /// SIGTERM to process group `pgid`, up to `grace` seconds for it to empty, then SIGKILL for
    /// whatever is left and up to `killWait` for that to go. Blocks; true once nobody is left.
    /// (The group can outlive its leader — orphaned grandchildren — so this watches the group.)
    static func stopGroup(_ pgid: pid_t, grace: TimeInterval) -> Bool {
        func gone(within timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while killpg(pgid, 0) == 0 {
                if Date() >= deadline { return false }
                usleep(10_000)
            }
            return true
        }
        guard killpg(pgid, SIGTERM) == 0 else { return errno == ESRCH }   // ESRCH: nobody left
        if gone(within: grace) { return true }
        _ = killpg(pgid, SIGKILL)
        return gone(within: killWait)
    }

    // MARK: - Running the harness

    private var sceneScript: URL { ws.scene.appendingPathComponent("scene.js") }

    private func launch() {
        guard phase == .idle else { return }
        guard FileManager.default.isExecutableFile(atPath: harness.executable) || harness.kind == .custom else {
            finish(.failed(AIError.harnessNotFound(harness.executable).localizedDescription)); return
        }
        let adapter = deps.adapter()
        let invocation: HarnessInvocation
        do {
            invocation = try adapter.invocation(for: harness, context: HarnessContext(
                workspace: ws, model: model, searchPath: deps.searchPath(), extraArguments: deps.extraArguments))
        } catch {
            finish(.failed(error.localizedDescription)); return
        }
        sceneBefore = try? Data(contentsOf: sceneScript)
        deps.prepareRenderer()
        deps.renderRelay?.start()
        parser = adapter.makeParser(workspaceRoot: ws.root)
        stdoutLog = Self.openLog(ws.stdoutLog)
        stderrLog = Self.openLog(ws.stderrLog)
        emit(.status("Running \(harness.name)…"))

        let process: ChildProcess
        do {
            process = try ChildProcess.spawn(executable: invocation.executable, arguments: invocation.arguments,
                                             environment: deps.environment(), currentDirectory: invocation.currentDirectory,
                                             stdinFile: invocation.stdinFile)
        } catch {
            finish(.failed(error.localizedDescription)); return
        }
        child = process
        group = process.pid
        phase = .running
        log.info("session \(self.id, privacy: .public): started \(invocation.executable, privacy: .public) pid \(process.pid)")

        let pipes = DispatchGroup()
        pipes.enter()
        PipeReader.start(fd: process.stdoutFD, onData: { data in self.queue.async { self.received(stdout: data) } },
                         onEOF: { pipes.leave() })
        pipes.enter()
        PipeReader.start(fd: process.stderrFD, onData: { data in self.queue.async { self.received(stderr: data) } },
                         onEOF: { pipes.leave() })
        startPolling()
        queue.asyncAfter(deadline: .now() + deps.timeout) { [weak self] in self?.timeoutFired() }

        Thread {
            let status = process.waitForExit()
            // Whatever the harness left running in its group (MCP servers, watchers) goes too —
            // synchronously, so the group is known to be empty before it's forgotten.
            _ = Self.stopGroup(process.pid, grace: Self.leftoverGrace)
            self.queue.async { self.group = nil }
            // A grandchild that escaped the group could hold the pipes open; don't wait forever.
            _ = pipes.wait(timeout: .now() + 5)
            self.queue.async { self.harnessExited(status: status) }
        }.start()
    }

    private func timeoutFired() {
        guard phase == .running, stopReason == nil else { return }
        stopReason = .timedOut
        log.notice("session \(self.id, privacy: .public): timed out")
        child?.terminateGroup()
    }

    private func received(stdout data: Data) {
        // write(contentsOf:) throws instead of raising an Objective-C exception (e.g. disk full).
        try? stdoutLog?.write(contentsOf: data)
        guard phase == .running, let parser else { return }
        for line in stdoutLines.feed(data) { parser.parse(line: line).forEach(emit) }
    }

    private func received(stderr data: Data) {
        try? stderrLog?.write(contentsOf: data)
        for line in stderrLines.feed(data) { keepStderr(line) }
    }

    private func keepStderr(_ line: String) {
        let text = StreamText.stripANSI(line).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        stderrTail.append(text)
        if stderrTail.count > Self.stderrTailLines { stderrTail.removeFirst(stderrTail.count - Self.stderrTailLines) }
    }

    private func harnessExited(status: Int32) {
        guard phase == .running else { return }
        child = nil
        deps.renderRelay?.stop()
        stopPolling()
        scanStills()
        if let parser {
            if let rest = stdoutLines.flush() { parser.parse(line: rest).forEach(emit) }
            parser.finish().forEach(emit)
        }
        if let rest = stderrLines.flush() { keepStderr(rest) }
        closeLogs()
        log.info("session \(self.id, privacy: .public): harness exited with \(status)")

        switch stopReason {
        case .cancelled: finish(.failed("Cancelled.")); return
        case .timedOut:
            finish(.failed("\(harness.name) didn't finish within \(Self.describe(deps.timeout)), so LivePaper stopped it."))
            return
        case nil: break
        }
        guard status == 0 else { finish(.failed(exitFailure(status))); return }
        guard (try? Data(contentsOf: sceneScript)) != sceneBefore else {
            finish(.failed("\(harness.name) finished without changing the scene.")); return
        }
        // Everything below runs with the user's full rights, outside any sandbox the agent had: a
        // link the agent left in its candidate would point the check's writes and the clean-up's
        // deletes at files elsewhere (and a scene package must be self-contained anyway).
        if let problem = candidateLinkProblem() { finish(.failed(problem)); return }

        phase = .checking
        emit(.status("Validating the scene…"))
        let checker = deps.checker, scene = ws.scene
        Task.detached {
            let result: Result<CheckReport, Error>
            do { result = .success(try await checker.check(package: scene, options: CheckOptions())) } catch { result = .failure(error) }
            self.queue.async { self.checked(result) }
        }
    }

    private func checked(_ result: Result<CheckReport, Error>) {
        guard phase == .checking else { return }   // cancelled while checking
        let report: CheckReport
        switch result {
        case .failure(let error):
            finish(.failed("LivePaper couldn't validate the scene: \(error.localizedDescription)")); return
        case .success(let r): report = r
        }
        for still in report.stills {
            let url = still.path.hasPrefix("/") ? URL(fileURLWithPath: still.path) : ws.scene.appendingPathComponent(still.path)
            reportStill(url)
        }
        emit(.checkResult(report))
        guard report.passed else { finish(.failed(Self.checkFailure(report))); return }
        do {
            try finalizePackage()
            finish(.finished(package: ws.scene))
        } catch {
            finish(.failed("The scene passed its check but couldn't be prepared: \(error.localizedDescription)"))
        }
    }

    /// Normalises the candidate's manifest (the agent may have edited fields it was told to keep)
    /// and records the session in its history.jsonl, which the library merges on accept.
    /// What a web scene candidate may contain at its top level (ARCHITECTURE §4.2). Anything else is
    /// an agent's scratch work (`.part_ridge.js`, `notes.md`, a backup copy) that would otherwise
    /// be imported into the library with the scene.
    static let candidateEntries: Set<String> = [SceneManifest.fileName, SceneCompiler.sceneFile, SceneCompiler.assetsDirectory,
                                                SceneChecker.checkDirectory]

    /// Why the candidate can't be used because of a symbolic link (scene/ itself or anything in
    /// it), or nil.
    private func candidateLinkProblem() -> String? {
        guard let link = FileOps.firstSymlink(atOrIn: ws.scene) else { return nil }
        let rel = link.path.hasPrefix(ws.root.path + "/") ? String(link.path.dropFirst(ws.root.path.count + 1)) : link.lastPathComponent
        return "\(harness.name) left a symbolic link in the scene (\(rel)); LivePaper doesn't accept links in scenes, so it was discarded."
    }

    private func finalizePackage() throws {
        let fm = FileManager.default
        if let problem = candidateLinkProblem() { throw AIError.unsupported(problem) }
        for name in (try? fm.contentsOfDirectory(atPath: ws.scene.path)) ?? [] where !Self.candidateEntries.contains(name) {
            // Re-checked right before each delete: never follow a link out of the candidate.
            guard FileOps.isRealDirectory(ws.scene) else { throw AIError.unsupported("The scene directory was replaced while LivePaper finished it.") }
            try? fm.removeItem(at: ws.scene.appendingPathComponent(name))
        }
        var m = try SceneManifest.load(package: ws.scene)
        let now = Date()
        m.schema = SceneManifest.currentSchema
        m.kind = .web
        m.runtime = m.runtime ?? 1
        m.video = nil
        let action: SceneHistoryEntry.Action, prompt: String
        switch request {
        case .create(let p):
            // A fresh id from the name the agent chose; the library makes it unique on import.
            m.id = SceneManifest.slug(from: m.name)
            m.created = now
            action = .create; prompt = p
        case .modify(let sceneID, let p):
            m.id = sceneID
            action = .modify; prompt = p
        }
        m.updated = now
        try m.write(package: ws.scene)
        let summary = parser?.finalMessage ?? (try? String(contentsOf: ws.lastMessageFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        // What the harness reported running beats what was asked for ("opus" → the full model id),
        // and covers sessions that used the harness's own default.
        let usedModel = parser?.reportedModel ?? model
        try SceneHistory.append(SceneHistoryEntry(date: now, action: action, harness: harness.kind.rawValue, model: usedModel,
                                                  prompt: prompt, summary: summary), to: ws.scene)
    }

    // MARK: - Stills

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.stillPollInterval, repeating: Self.stillPollInterval, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.scanStills() }
        timer.resume()
        poller = timer
    }

    private func stopPolling() { poller?.cancel(); poller = nil }

    private func scanStills() {
        let dir = ws.scene.appendingPathComponent(".check")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        // URLs built from the workspace path (not the listing's), so they match `workspace`.
        for name in names.sorted() where !name.hasPrefix(".") && (name as NSString).pathExtension.lowercased() == "png" {
            reportStill(dir.appendingPathComponent(name, isDirectory: false))
        }
    }

    /// Emits `.stillRendered` for a PNG that is new or was rewritten since it was last reported.
    private func reportStill(_ url: URL) {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return }
        guard stillDates[url.path] != date else { return }
        stillDates[url.path] = date
        emit(.stillRendered(url))
    }

    // MARK: - Ending

    private func emit(_ event: AISessionEvent) {
        // Agents emit long runs of identical "Thinking…" updates; one is enough.
        if case .status(let s) = event {
            guard s != lastStatus else { return }
            lastStatus = s
        } else {
            lastStatus = nil
        }
        continuation.yield(event)
    }

    private func finish(_ event: AISessionEvent) {
        guard phase != .done else { return }
        phase = .done
        stopPolling()
        deps.renderRelay?.stop()
        closeLogs()
        child?.terminateGroup()
        if case .failed(let reason) = event { log.notice("session \(self.id, privacy: .public) failed: \(reason, privacy: .public)") }
        emit(event)
        continuation.finish()
    }

    private func closeLogs() {
        try? stdoutLog?.close(); stdoutLog = nil
        try? stderrLog?.close(); stderrLog = nil
    }

    private func exitFailure(_ status: Int32) -> String {
        let how = status > 128 ? "was stopped by signal \(status - 128)" : "exited with status \(status)"
        // The harness's own error report first: stderr often ends with unrelated warnings.
        let detail = parser?.lastError ?? stderrTail.suffix(3).joined(separator: " ").nilIfEmpty ?? parser?.finalMessage
        return "\(harness.name) \(how)" + (detail.map { ": " + StreamText.truncate($0, 400) } ?? ".")
    }

    /// "20 minutes", "1 minute", "45 seconds".
    static func describe(_ interval: TimeInterval) -> String {
        if interval < 60 {
            let s = Int(interval.rounded()); return "\(s) second\(s == 1 ? "" : "s")"
        }
        let m = Int((interval / 60).rounded()); return "\(m) minute\(m == 1 ? "" : "s")"
    }

    static func checkFailure(_ report: CheckReport) -> String {
        let problems = (report.problems + report.jsErrors.map { "JavaScript error: \($0)" })
        guard !problems.isEmpty else { return "The scene didn't pass LivePaper's check." }
        let shown = problems.prefix(3).joined(separator: "; ")
        let more = problems.count > 3 ? " (and \(problems.count - 3) more)" : ""
        return "The scene didn't pass LivePaper's check: \(shown)\(more)"
    }

    private static func openLog(_ url: URL) -> FileHandle? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        return try? FileHandle(forWritingTo: url)
    }
}
