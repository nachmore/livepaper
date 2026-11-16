// AICommands — `livepaper ai create|modify|harnesses|sessions`: AI-authored scenes from the terminal.
//
// Same pipeline as the app (ARCHITECTURE §10): AIService builds a workspace and runs the agent;
// its events are streamed here; LivePaper runs `check` itself when the agent exits; a passing
// candidate is added to the library (create) or replaces the scene (modify, previous version kept
// in history/) after the user accepts it — or straight away with --yes. Each session keeps the same
// record as the app's (AISessionRecord), so a session whose CLI was killed is offered for review the
// next time the app starts; `ai sessions` lists them.
//
// Reference images: `--ref <image|folder>` (repeatable) and `--animate <image>` are expanded,
// checked and re-encoded here (ReferenceFolders / ReferenceImporter) before the session starts;
// the agent gets copies in its workspace. A prompt that names image files without them gets a hint.
import Darwin
import Foundation
import LivePaperCore

enum AICommands {
    static var all: [CLICommand] {
        [CLICommand(name: "ai",
                    synopsis: "create [\"<prompt>\"] | modify <scene-id> [\"<prompt>\"] | harnesses | sessions   " +
                              "[--ref <image|folder>]… [--animate <image>] " +
                              "[--harness claude|codex|kiro|custom] [--command <template>] [--model <name>] " +
                              "[--timeout <minutes>] [--yes] [--json]",
                    summary: "create or modify a scene with an AI coding agent (Claude Code, Codex, Kiro CLI or a custom command); " +
                             "--ref attaches reference images (up to \(ReferenceLimits.maxImages); folders expand), --animate one picture to bring to life",
                    run: ai)]
    }

    static let flags: Set<String> = ["yes", "json"]
    static let options: Set<String> = ["harness", "command", "model", "timeout", "ref", "animate"]

    static func ai(_ argv: [String]) async throws -> Int32 {
        var args = try Arguments(argv, flags: flags, options: options)
        guard let action = args.positional.first else {
            throw UsageError("missing action: create, modify, harnesses or sessions")
        }
        args.positional.removeFirst()
        // With images the prompt may be left out (ReferencePrompts.defaultPrompt).
        let hasImages = !args.strings("ref").isEmpty || !args.strings("animate").isEmpty
        switch action {
        case "create":
            let prompt = args.positional.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard args.positional.count <= 1, !prompt.isEmpty || hasImages else {
                throw UsageError("ai create needs exactly one prompt argument (quote it), or images with --ref / --animate")
            }
            return try await run(prompt: prompt, modify: false, request: { .create(prompt: $0) }, args)
        case "modify":
            guard (1...2).contains(args.positional.count), args.positional.count == 2 || hasImages else {
                throw UsageError("ai modify needs a scene id and one prompt argument (quote it), or images with --ref / --animate")
            }
            let id = args.positional[0], prompt = args.positional.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !prompt.isEmpty || hasImages else { throw UsageError("the prompt is empty") }
            guard let scene = try CLIServices.live.library.scene(id: id) else {
                throw LibraryError.notFound("\(id). Run `livepaper list` to see the scene ids.")
            }
            guard !scene.isBuiltin else {
                throw LibraryError.invalid("\(id) is a built-in scene and can't be modified. Clone it first: " +
                                           "`livepaper new \"My \(scene.manifest.name)\" --from \(id)`, then modify the copy.")
            }
            guard scene.manifest.kind == .web else {
                throw LibraryError.invalid("\(id) is a video scene; AI sessions only modify web scenes.")
            }
            return try await run(prompt: prompt, modify: true, request: { .modify(sceneID: id, prompt: $0) }, args)
        case "harnesses":
            guard args.positional.isEmpty else { throw UsageError("ai harnesses takes no arguments") }
            return await harnesses(json: args.flag("json"))
        case "sessions":
            guard args.positional.isEmpty else { throw UsageError("ai sessions takes no arguments") }
            return sessions(json: args.flag("json"))
        default:
            throw UsageError("unknown action '\(action)' (expected create, modify, harnesses or sessions)")
        }
    }

    // MARK: - Sessions

    /// The sessions LivePaper has records of (the app's and the CLI's, newest first), with what
    /// became of each: running, recovered, orphaned (the agent runs, nobody watches it), unreviewed,
    /// accepted, discarded, failed, cancelled. Workspaces and records are kept for a week.
    static func sessions(json: Bool) -> Int32 {
        let store = AISessionRecordStore(workspacesDirectory: LPPaths.workspaces)
        let records = store.records()
        let rows = records.map { ($0, AISessionRecovery.state(of: $0)) }
        if json {
            struct Row: Encodable {
                var id: String; var state: String; var origin: String; var startedAt: Date; var finishedAt: Date?
                var request: String; var sceneID: String?; var prompt: String; var feedback: [String]; var references: Int
                var harness: String; var harnessName: String; var model: String?; var workspace: String
                var agentPID: Int32?; var outcome: String?; var message: String?; var acceptedID: String?
            }
            printJSONObject(rows.map { r, state -> Row in
                var accepted: String?
                if case .accepted(let id)? = r.resolution { accepted = id }
                return Row(id: r.id, state: state.rawValue, origin: r.origin.rawValue, startedAt: r.startedAt, finishedAt: r.finishedAt,
                           request: r.sceneID == nil ? "create" : "modify", sceneID: r.sceneID, prompt: r.prompt, feedback: r.feedback,
                           references: r.references.count, harness: r.harness.kind, harnessName: r.harness.name, model: r.model,
                           workspace: LPPaths.workspaces.appendingPathComponent(r.id).path,
                           agentPID: state == .running || state == .recovered || state == .orphaned ? r.agent?.pid : nil,
                           outcome: r.outcome?.status.rawValue, message: r.outcome?.message, acceptedID: accepted)
            })
            return ExitCode.ok
        }
        guard !rows.isEmpty else {
            print("No AI sessions in the last week.")
            return ExitCode.ok
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        printTable(header: ["STATE", "STARTED", "AGENT", "REQUEST", "PROMPT", "SESSION"], rows: rows.map { r, state in
            let request = r.sceneID.map { "modify \($0)" } ?? "create"
            let prompt = r.prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return [state.rawValue, formatter.string(from: r.startedAt), r.harness.name, request,
                    prompt.count > 40 ? String(prompt.prefix(39)) + "\u{2026}" : prompt, r.id]
        })
        if rows.contains(where: { $0.1 == .unreviewed || $0.1 == .orphaned }) {
            print("")
            print("LivePaper offers unreviewed and orphaned sessions for review the next time it starts (orphaned ones once their agent finishes).")
        }
        return ExitCode.ok
    }

    // MARK: - Harness selection

    static func harnesses(json: Bool) async -> Int32 {
        let found = await CLIServices.live.ai.detectHarnesses()
        if json {
            struct Row: Encodable { var kind: String; var name: String; var executable: String; var version: String? }
            printJSONObject(found.map { Row(kind: $0.kind.rawValue, name: $0.name, executable: $0.executable, version: $0.version) })
            return ExitCode.ok
        }
        guard !found.isEmpty else {
            print("No AI coding CLI found. LivePaper works with Claude Code (`claude`), Codex (`codex`) and Kiro CLI (`kiro-cli`),")
            print("looked up through your login shell's PATH and the usual install directories, or any command via --command.")
            return ExitCode.failed
        }
        printTable(header: ["KIND", "NAME", "VERSION", "PATH"],
                   rows: found.map { [$0.kind.rawValue, $0.name, $0.version ?? "?", $0.executable] })
        return ExitCode.ok
    }

    /// --command → a custom harness; --harness picks a kind; otherwise the saved preference, then
    /// the first one found.
    static func chooseHarness(_ args: Arguments, service: AIService?) async throws -> AIHarness {
        let settings = service?.loadSettings() ?? AISettings()
        if let template = args.string("command") {
            if let kind = args.string("harness"), kind != AIHarness.Kind.custom.rawValue {
                throw UsageError("--command runs a custom harness; leave out --harness \(kind)")
            }
            return try customHarness(template)
        }
        let requested = try args.string("harness").map { name -> AIHarness.Kind in
            guard let kind = AIHarness.Kind(rawValue: name) else {
                throw UsageError("--harness must be claude, codex, kiro or custom (got \"\(name)\")")
            }
            return kind
        }
        if requested == .custom {
            guard let template = settings.customTemplate?.trimmingCharacters(in: .whitespacesAndNewlines), !template.isEmpty else {
                throw UsageError("no custom command is configured; pass one with --command \"tool {prompt_file}\"")
            }
            return try customHarness(template)
        }
        let found = await CLIServices.live.ai.detectHarnesses().filter { $0.kind != .custom }
        if let requested {
            guard let h = found.first(where: { $0.kind == requested }) else {
                throw CLIFailure("\(requested.rawValue) was not found (looked in your login shell's PATH and the usual install " +
                                 "directories). Run `livepaper ai harnesses` to see what is installed.")
            }
            return h
        }
        if let preferred = settings.preferredHarness, let h = found.first(where: { $0.id == preferred }) { return h }
        guard let first = found.first else {
            throw CLIFailure("no AI coding CLI found. Install Claude Code, Codex or Kiro CLI, or pass any agent command with " +
                             "--command \"tool --prompt-file {prompt_file}\".")
        }
        return first
    }

    static func customHarness(_ template: String) throws -> AIHarness {
        let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw UsageError("--command is empty") }
        do { _ = try CommandTemplate.tokenize(t) } catch { throw UsageError(error.localizedDescription) }
        return AIService.customHarness(template: t)
    }

    // MARK: - Reference images

    /// `~/x` → the home folder's x (the shell doesn't expand `--ref=~/x`).
    static func expandingTilde(_ path: String) -> URL {
        if path == "~" { return LPPaths.home }
        if path.hasPrefix("~/") { return LPPaths.home.appendingPathComponent(String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }

    /// `--ref` / `--animate` → the inputs to prepare (validated, folders expanded, nothing decoded yet).
    static func collectReferences(_ args: Arguments, out: SessionPrinter) throws -> [ReferenceInput] {
        let animate = args.strings("animate")
        guard animate.count <= 1 else { throw UsageError("--animate can be given once (one picture per session is animated)") }
        let refs = args.strings("ref")
        guard !refs.isEmpty || !animate.isEmpty else { return [] }
        do {
            let (inputs, leftOut) = try ReferenceFolders.collect(references: refs.map(expandingTilde), animate: animate.first.map(expandingTilde))
            if let sentence = leftOut.sentence() { out.note("livepaper ai: \(sentence)") }
            guard !inputs.isEmpty else { throw UsageError("--ref found no images in \(refs.joined(separator: ", "))") }
            return inputs
        } catch let e as ReferenceError {
            // Asking for more than a session takes is a usage error; a bad file is the request's problem (exit 1).
            switch e {
            case .tooMany, .tooManyAnimated, .animateNeedsFile: throw UsageError(e.localizedDescription)
            default: throw e
            }
        }
    }

    /// Notes for paths in the prompt the agent won't be able to open (no --ref / --animate given).
    /// Paths in privacy-protected folders (Desktop, Documents, …) aren't looked up: the note is
    /// syntax-based there, so the terminal never gets a privacy prompt for a hint (and says to quote
    /// the whole path when an unquoted one may go on past a space). Others get a note when they, or a
    /// longer reading of an unquoted path ("~/Pictures/Summer Trip for the palette"), exist.
    static func pathHints(_ prompt: String) -> [String] {
        PromptPaths.mentions(in: prompt).prefix(3).compactMap { mention -> String? in
            var m = mention
            let kind: PromptPathMention.Kind
            var mayGoOn = false
            if PromptPaths.isPrivacyProtected(m.url) {
                kind = m.kind
                mayGoOn = m.alternatives.contains { $0.text.count > m.text.count }
            } else {
                let (found, resolution) = PromptPaths.resolveReadings(m)
                switch resolution {
                case .image: kind = .image
                case .folder: kind = .folder
                case .missing, .notAnImage, .notPermitted: return nil
                }
                m = found
            }
            let typed = m.text.replacingOccurrences(of: "\\ ", with: " ")
            let arg = shellQuoted(typed.hasPrefix("file://") ? m.url.path : typed)
            let quote = mayGoOn ? " If its name goes on after the space, quote the whole path." : ""
            if kind == .folder {
                return "livepaper ai: the prompt mentions \(typed) (a folder). The agent can't open files outside its workspace; " +
                    "add --ref \(arg) to attach copies (or --animate <image> to animate one exactly).\(quote)"
            }
            return "livepaper ai: the prompt mentions \(typed) (an image). The agent can't open files outside its workspace; " +
                "add --ref \(arg) to attach a copy (or --animate \(arg) to animate it exactly).\(quote)"
        }
    }

    // MARK: - Running a session

    /// - Parameter typed: the prompt as given (may be empty when images are attached).
    /// - Parameter modify: the request changes a scene (the default request then says so).
    static func run(prompt typed: String, modify: Bool, request make: (String) -> AISessionRequest, _ args: Arguments) async throws -> Int32 {
        let services = CLIServices.live
        let timeout = try args.int("timeout").map { minutes -> TimeInterval in
            guard (1...240).contains(minutes) else { throw UsageError("--timeout must be 1 … 240 minutes") }
            return TimeInterval(minutes * 60)
        }
        let out = SessionPrinter(json: args.flag("json"))
        let inputs = try collectReferences(args, out: out)
        if inputs.isEmpty { pathHints(typed).forEach(out.note) }
        // --timeout needs its own AIService (the live one reads the timeout from the AI settings).
        let ai: AIServicing = timeout.map { AIService(library: services.library, checker: services.checker, timeout: $0) } ?? services.ai
        let harness = try await chooseHarness(args, service: ai as? AIService)
        let model = args.string("model")?.trimmingCharacters(in: .whitespaces)

        // Decoded and re-encoded one at a time (a few hundred ms per photo).
        var references: [PreparedReference] = []
        if !inputs.isEmpty {
            if !out.json { stderr("  \u{2026} preparing \(inputs.count == 1 ? "1 reference image" : "\(inputs.count) reference images")") }
            for input in inputs { references.append(try ReferenceImporter.prepare(input)) }
        }
        let prompt = typed.isEmpty ? (ReferencePrompts.defaultPrompt(roles: references.map(\.role), modify: modify) ?? typed) : typed
        let request = make(prompt)

        let session = try ai.start(request, references: references, harness: harness, model: model?.isEmpty == false ? model : nil,
                                   details: AISessionDetails(origin: .cli))
        out.started(session: session, harness: harness, model: model, request: request, references: references)

        // Ctrl-C cancels the agent (its whole process group); a second Ctrl-C quits at once, and
        // closing the terminal (SIGHUP) stops the agent synchronously before exiting — unless the
        // CLI was started with that signal ignored (`nohup`), which then stays ignored.
        let interrupt = Interrupts(onInterrupt: { session.cancel() },
                                   onExit: { _ = (session as? AISessionTerminating)?.terminateNow(grace: 0) })
        var candidate: URL?
        var failure: String?
        var report: CheckReport?
        for await event in session.events {
            out.event(event)
            switch event {
            case .finished(let package): candidate = package
            case .failed(let message): failure = message
            case .checkResult(let r): report = r
            default: break
            }
        }
        interrupt.waitIfExiting()
        interrupt.stop()
        if interrupt.fired {
            out.note("cancelled; the workspace is kept in \(displayPath(session.workspace))")
            return 130
        }
        guard let package = candidate else {
            out.failed(failure ?? "the session ended without a result", workspace: session.workspace, checked: report != nil)
            return ExitCode.failed
        }
        return try accept(package, request: request, sessionID: session.id, ai: ai, yes: args.flag("yes"), out: out)
    }

    /// Adds (create) or replaces (modify) after confirmation, through AICandidate.accept like the
    /// app (a created scene is named after itself), and records the decision.
    static func accept(_ package: URL, request: AISessionRequest, sessionID: String, ai: AIServicing, yes: Bool,
                       out: SessionPrinter) throws -> Int32 {
        let library = CLIServices.live.library
        let name = (try? SceneManifest.load(package: package))?.name ?? "the new scene"
        let question: String
        switch request {
        case .create: question = "Add \u{201C}\(name)\u{201D} to your library?"
        case .modify(let id, _): question = "Replace \(id) with this version? (the current one is kept in its history)"
        }
        guard yes || CLIEnvironment.confirm(question) else {
            // Declined: never offered for review again.
            ai.recordResolution(.discarded, sessionID: sessionID)
            out.note("not added; the candidate stays in \(displayPath(package)) " +
                     "(add it later with `livepaper import \(shellQuoted(displayPath(package)))`)")
            out.result(accepted: false, item: nil)
            return ExitCode.failed
        }
        let item = try AICandidate.accept(package, request: request, library: library)
        ai.recordResolution(.accepted(sceneID: item.id), sessionID: sessionID)
        if case .modify = request { out.result(accepted: true, item: item, replaced: true) } else { out.result(accepted: true, item: item) }
        return ExitCode.ok
    }
}

/// An error whose message is the whole story (printed as `livepaper <cmd>: <message>`, exit 3).
struct CLIFailure: Error, LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Output

/// Prints session events as readable lines (default) or as JSON lines (--json, one object per event).
final class SessionPrinter {
    let json: Bool
    private var checkStarted = Date()
    /// The session's candidate package (workspace/scene), where check writes its report.
    private var candidate = URL(fileURLWithPath: ".")
    private var workspace = URL(fileURLWithPath: ".")
    /// Stills reported since the last other event: one `livepaper check` writes a dozen or more,
    /// so they are printed as one line when the next event arrives.
    private var pendingStills: [URL] = []
    static let stillNamesShown = 4

    init(json: Bool) { self.json = json }

    func started(session: AISessionHandle, harness: AIHarness, model: String?, request: AISessionRequest,
                 references: [PreparedReference] = []) {
        workspace = session.workspace
        candidate = AIWorkspace(root: session.workspace).scene
        let counts = references.isEmpty ? nil : ReferenceCounts(roles: references.map(\.role))
        if json {
            var o: [String: Any] = ["event": "started", "session": session.id, "workspace": session.workspace.path,
                                    "harness": harness.kind.rawValue, "harnessName": harness.name, "executable": harness.executable,
                                    "model": model ?? NSNull()]
            // Counts only, like history.jsonl.
            if let counts { o["references"] = ["reference": counts.reference, "animate": counts.animate] }
            emit(o)
            return
        }
        let what: String
        switch request {
        case .create: what = "creating a new scene"
        case .modify(let id, _): what = "modifying \(id)"
        }
        let version = harness.version.map { " \($0)" } ?? ""
        print("livepaper ai: \(what) with \(harness.name)\(version)\(model.map { " (model \($0))" } ?? "")" +
              (counts.map { " \u{00B7} \($0.description)" } ?? ""))
        // The user's own terminal: naming their files here is fine (they never reach the workspace).
        for (i, ref) in references.enumerated() {
            let origin = ref.requestedPath.map { displayPath(URL(fileURLWithPath: $0)) } ?? ref.displayName
            print("  \(String(format: "ref-%02d", i + 1)) \u{2190} \(origin)\(ref.role == .animate ? " (animate)" : "")")
        }
        print("  workspace \(displayPath(session.workspace))  ·  Ctrl-C cancels")
    }

    func event(_ event: AISessionEvent) {
        if json { emitJSON(event); return }
        if case .stillRendered(let url) = event { pendingStills.append(url); return }
        flushStills()
        switch event {
        case .status(let s):
            if s.hasPrefix("Validating") { checkStarted = Date() }
            print("… \(s)")
        case .assistantText(let text):
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) { print("  \(line)") }
        case .toolUse(let name, let detail):
            print("  ▸ \(name)\(detail.isEmpty ? "" : "  \(detail)")")
        case .stillRendered:
            break   // batched by flushStills()
        case .checkResult(let report):
            print("")
            SceneCommands.printSummary(report, package: candidate, seconds: Date().timeIntervalSince(checkStarted))
            print("")
        case .finished(let package):
            print("✓ the scene passed LivePaper's check: \(displayPath(package))")
        case .failed:
            break   // reported by failed(_:workspace:checked:)
        }
    }

    /// "◻ 13 stills in scene/.check/: 1512x982@2-t0.png, …" ("13 stills and 2 motion maps" with the
    /// check's heat maps) — paths relative to the workspace (printed at the start), grouped by directory.
    private func flushStills() {
        guard !pendingStills.isEmpty else { return }
        defer { pendingStills = [] }
        var groups: [(dir: URL, names: [String])] = []
        for url in pendingStills {
            let dir = url.deletingLastPathComponent()
            if let i = groups.firstIndex(where: { $0.dir.path == dir.path }) {
                if !groups[i].names.contains(url.lastPathComponent) { groups[i].names.append(url.lastPathComponent) }
            } else {
                groups.append((dir, [url.lastPathComponent]))
            }
        }
        for g in groups {
            let shown = g.names.prefix(Self.stillNamesShown).joined(separator: ", ")
            let more = g.names.count > Self.stillNamesShown ? ", … (+\(g.names.count - Self.stillNamesShown))" : ""
            let maps = g.names.filter { SceneChecker.isMotionMap(URL(fileURLWithPath: $0)) }.count, stills = g.names.count - maps
            let count = [stills > 0 ? (stills == 1 ? "1 still" : "\(stills) stills") : nil,
                         maps > 0 ? (maps == 1 ? "1 motion map" : "\(maps) motion maps") : nil].compactMap { $0 }.joined(separator: " and ")
            print("  ◻ \(count) in \(workspaceRelative(g.dir))/: \(shown)\(more)")
        }
    }

    private func workspaceRelative(_ url: URL) -> String {
        let root = workspace.resolvingSymlinksInPath().path, p = url.resolvingSymlinksInPath().path
        return p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : displayPath(url)
    }

    func failed(_ message: String, workspace: URL, checked: Bool) {
        flushStills()
        if json { return }   // the "failed" event already carries the message
        stderr("livepaper ai: \(message)")
        stderr("  the workspace (agent logs in .livepaper/) is kept in \(displayPath(workspace))")
        if checked { stderr("  ask for a fix with `livepaper ai modify` once a passing version is in the library, or try another prompt") }
    }

    func note(_ s: String) {
        flushStills()
        if json { emit(["event": "note", "message": s]) } else { print(s) }
    }

    func result(accepted: Bool, item: SceneItem?, replaced: Bool = false) {
        if json {
            var o: [String: Any] = ["event": accepted ? "accepted" : "declined"]
            if let item { o["id"] = item.id; o["name"] = item.manifest.name; o["path"] = item.packageURL.path }
            emit(o)
            return
        }
        guard accepted, let item else { return }
        print("\(replaced ? "updated" : "added") \u{201C}\(item.manifest.name)\u{201D} (\(item.id)) → \(displayPath(item.packageURL))" +
              (replaced ? " (previous version in its history/)" : ""))
        print("next: `livepaper publish` puts it in the screen saver")
    }

    private func emitJSON(_ event: AISessionEvent) {
        switch event {
        case .status(let s): emit(["event": "status", "message": s])
        case .assistantText(let t): emit(["event": "text", "text": t])
        case .toolUse(let name, let detail): emit(["event": "tool", "name": name, "detail": detail])
        case .stillRendered(let url): emit(["event": "still", "path": url.path])
        case .checkResult(let report):
            let data = (try? SceneChecker.reportEncoder().encode(report)) ?? Data("{}".utf8)
            emit(["event": "check", "report": (try? JSONSerialization.jsonObject(with: data)) ?? [:]])
        case .finished(let package): emit(["event": "finished", "package": package.path])
        case .failed(let message): emit(["event": "failed", "message": message])
        }
    }

    private func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

/// SIGINT/SIGTERM while a session runs: the first one calls `onInterrupt` (cancel the agent and let
/// the event stream finish); a second one, or SIGHUP (terminal closed), calls `onExit` (stop the
/// agent's process group synchronously, so nothing is orphaned) and exits. A signal the process
/// was started with ignored — SIGHUP under `nohup`, SIGINT in a background job of a script — is
/// left alone: a dispatch source would fire even for an ignored signal.
final class Interrupts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    /// Set (with `count`) when a handler starts stopping the agent to exit with this status.
    private var exitStatus: Int32?
    private enum Step { case cancel, exit(Int32), ignore }
    private var sources: [DispatchSourceSignal] = []
    /// What each handled signal did before; `stop()` puts it back.
    private var previous: [(signal: Int32, action: sigaction)] = []

    init(onInterrupt: @escaping @Sendable () -> Void, onExit: @escaping @Sendable () -> Void) {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            var old = sigaction()
            guard sigaction(sig, nil, &old) == 0, !Self.isIgnored(old) else { continue }
            previous.append((sig, old))
            signal(sig, SIG_IGN)   // handled by the dispatch source below
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let step = self.lock.withLock { () -> Step in
                    self.count += 1
                    guard self.exitStatus == nil else { return .ignore }   // another handler is exiting
                    guard sig == SIGHUP || self.count > 1 else { return .cancel }
                    let status: Int32 = sig == SIGHUP ? 129 : 130
                    self.exitStatus = status
                    return .exit(status)
                }
                switch step {
                case .cancel:
                    FileHandle.standardError.write(Data("\n… cancelling (press Ctrl-C again to quit at once)\n".utf8))
                    onInterrupt()
                case .exit(let status):
                    onExit()
                    exit(status)
                case .ignore:
                    break
                }
            }
            source.resume()
            sources.append(source)
        }
    }

    var fired: Bool { lock.withLock { count > 0 } }

    /// For when the session's events have ended. If a handler is exiting (SIGHUP, a second Ctrl-C),
    /// never returns: that handler exits once the agent's group is gone. Stopping the group lets the
    /// stream end first (the agent's exit ends it), and returning then would exit with the wrong
    /// status, or before the group is known to be empty.
    func waitIfExiting() {
        guard lock.withLock({ exitStatus }) != nil else { return }
        while true { pause() }
    }

    /// Back to what the signals did before (normally the default: Ctrl-C at the accept prompt quits;
    /// under `nohup`, SIGHUP stays ignored).
    func stop() {
        sources.forEach { $0.cancel() }
        sources = []
        for (sig, action) in previous {
            var action = action
            _ = sigaction(sig, &action, nil)
        }
        previous = []
    }

    /// SIG_IGN is the handler value 1 (SIG_DFL is 0, i.e. nil); Swift can't compare C function
    /// pointers, so compare their bits.
    static func isIgnored(_ action: sigaction) -> Bool {
        guard let handler = action.__sigaction_u.__sa_handler else { return false }
        return unsafeBitCast(handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
    }
}
