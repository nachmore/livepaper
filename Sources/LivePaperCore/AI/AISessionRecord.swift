// AISessionRecord — LivePaper's own record of one AI session (ARCHITECTURE §4.1, §10 "Session
// records and recovery"):
//
//   <Workspaces>/.sessions/<session-id>/
//     session.json      this record
//     ref-01.jpg …      copies of the reference images LivePaper gave the agent (vision copies)
//     asset.jpg|png     a copy of the picture to animate as LivePaper wrote it into the scene
//
// Next to the workspace, never inside it: a Codex sandbox and a custom command can write anywhere
// in their workspace, and this record says which process group a later LivePaper may stop (and
// which picture it puts back), so the agent must not be able to change it; and the images' names
// it shows must not reach the agent. Written by whichever process runs the session — the app or
// `livepaper ai` — as the session progresses (started, agent spawned, finished, accepted or
// discarded), so a session whose runner went away (a crash, a force quit, a restart) can be picked
// up again (AISessionRecovery). The copies are kept only while the session may still be reviewed.
// Decoded field by field: a missing or damaged field gets its default, the rest is kept.
import Darwin
import Foundation
import os

/// When a process started (the kernel's start time), which tells it from a later process that got
/// the same pid.
public struct LPProcessStart: Codable, Sendable, Hashable {
    public var seconds: Int64
    public var microseconds: Int32
    public init(seconds: Int64, microseconds: Int32) { self.seconds = seconds; self.microseconds = microseconds }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(microseconds) / 1_000_000) }
}

/// What LivePaper knows about a running process: enough to tell it apart from any later one.
public struct LPProcessFacts: Codable, Sendable, Equatable {
    public var pid: Int32
    /// Its process group (an agent leads its own: group == pid).
    public var group: Int32
    public var start: LPProcessStart
    public init(pid: Int32, group: Int32, start: LPProcessStart) { self.pid = pid; self.group = group; self.start = start }

    /// `live` (what the kernel says about that pid now) is this very process.
    public func isSameProcess(as live: LPProcessFacts?) -> Bool {
        guard let live else { return false }
        return live.pid == pid && live.start == start && live.group == group
    }
}

/// Reads a process's start time and group from the kernel (libproc), for any of the user's processes.
public enum ProcessProbe {
    /// The process now running as `pid`; nil when there is none (or it has exited and is waiting
    /// to be reaped, or it isn't readable — another user's).
    public static func facts(_ pid: pid_t) -> LPProcessFacts? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        guard info.pbi_status != UInt32(SZOMB) else { return nil }
        return LPProcessFacts(pid: pid, group: pid_t(bitPattern: info.pbi_pgid),
                              start: LPProcessStart(seconds: Int64(info.pbi_start_tvsec), microseconds: Int32(truncatingIfNeeded: info.pbi_start_tvusec)))
    }

    /// This process.
    public static var current: LPProcessFacts? { facts(getpid()) }
}

public struct AISessionRecord: Codable, Sendable, Equatable {
    public static let fileName = "session.json"
    public static let currentSchema = 1

    /// Which program ran the session.
    public enum Origin: String, Codable, Sendable { case app, cli }

    /// The harness the session ran (what `AIHarness` needs to run it again).
    public struct Harness: Codable, Sendable, Equatable {
        public var kind: String
        public var name: String
        public var executable: String
        public var version: String?
        /// A custom command's template.
        public var template: String?
        public init(_ h: AIHarness) {
            kind = h.kind.rawValue; name = h.name; executable = h.executable; version = h.version; template = h.customTemplate
        }
        public var harness: AIHarness {
            AIHarness(kind: AIHarness.Kind(rawValue: kind) ?? .custom, name: name, executable: executable, version: version,
                      customTemplate: template)
        }
    }

    /// One reference image, in the workspace's numbering (ref-01 is the picture to animate, if any).
    public struct Reference: Codable, Sendable, Equatable {
        public var role: AIReferenceRole
        /// The name the app shows (the attached file's base name, or "Pasted image"); never a path.
        public var name: String
        /// Workspace-relative: "references/ref-01.jpg".
        public var file: String
        /// LivePaper's copy of it next to this record ("ref-01.jpg"), while the session may still be reviewed.
        public var copy: String
        public var format: EncodedReferenceImage.Format
        public var width: Int
        public var height: Int
        /// The summary as the workspace has it (`references/ref-01.json`).
        public var summary: ReferenceSummary?
        public init(role: AIReferenceRole, name: String, file: String, copy: String, format: EncodedReferenceImage.Format,
                    width: Int, height: Int, summary: ReferenceSummary?) {
            self.role = role; self.name = name; self.file = file; self.copy = copy; self.format = format
            self.width = width; self.height = height; self.summary = summary
        }
    }

    /// The picture to animate as LivePaper put it into the scene.
    public struct Animate: Codable, Sendable, Equatable {
        /// Package-relative: "assets/reference.jpg".
        public var asset: String
        /// LivePaper's copy next to this record ("asset.jpg").
        public var copy: String
        public var sha256: String
        public var width: Int
        public var height: Int
        public var transparent: Bool
        public var flattened: Bool
        public init(asset: String, copy: String, sha256: String, width: Int, height: Int, transparent: Bool, flattened: Bool) {
            self.asset = asset; self.copy = copy; self.sha256 = sha256; self.width = width; self.height = height
            self.transparent = transparent; self.flattened = flattened
        }
    }

    /// How the session ended, as its runner saw it.
    public struct Outcome: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable {
            /// LivePaper's check passed: the scene is ready to review.
            case passed
            case failed
            case cancelled
        }
        public var status: Status
        /// Why it failed.
        public var message: String?
        /// LivePaper's own check of the result, when it ran.
        public var checkPassed: Bool?
        /// The check's first problems, when it failed.
        public var problems: [String]
        public init(status: Status, message: String? = nil, checkPassed: Bool? = nil, problems: [String] = []) {
            self.status = status; self.message = message; self.checkPassed = checkPassed; self.problems = problems
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // An outcome this version can't name still means the session ended.
            status = (try? c.decode(Status.self, forKey: .status)) ?? .failed
            message = try? c.decodeIfPresent(String.self, forKey: .message)
            checkPassed = try? c.decodeIfPresent(Bool.self, forKey: .checkPassed)
            problems = (try? c.decodeIfPresent([String].self, forKey: .problems)) ?? []
        }
    }

    /// What the user decided.
    public enum Resolution: Sendable, Equatable {
        /// Added to (create) or replaced in (modify) the library as this scene.
        case accepted(sceneID: String)
        /// Discarded, tried again, declined — or, for a recovered session in which nothing happened,
        /// discarded by LivePaper.
        case discarded
    }

    public var schema: Int
    /// The session id, which is also the workspace's directory name.
    public var id: String
    public var origin: Origin
    /// The process running the session (the app or the CLI); a later LivePaper takes over a session
    /// only once this process is gone.
    public var runner: LPProcessFacts?
    /// nil: create.
    public var sceneID: String?
    /// The request as TASK.md states it (attached paths already replaced by `references/ref-NN…`;
    /// with any feedback of earlier attempts): what history.jsonl records.
    public var prompt: String
    /// The feedback of earlier attempts, oldest first (already part of `prompt`).
    public var feedback: [String]
    public var references: [Reference]
    public var animate: Animate?
    public var harness: Harness
    public var model: String?
    /// The time limit the session started with.
    public var timeout: TimeInterval
    /// The built-in scene a modified copy was cloned from (the app's session header).
    public var clonedFrom: String?
    /// SHA-256 of `scene/scene.js` as LivePaper left it for the agent (the template or the scene
    /// being changed): the agent changed the scene when it differs.
    public var sceneBefore: String?
    public var startedAt: Date
    /// The agent's process once spawned.
    public var agent: LPProcessFacts?
    public var finishedAt: Date?
    public var outcome: Outcome?
    public var resolution: Resolution?
    /// When a later run took the session over (the last time, if more than once).
    public var recoveredAt: Date?

    public init(id: String, origin: Origin, runner: LPProcessFacts?, request: AISessionRequest, prompt: String? = nil, feedback: [String] = [],
                references: [Reference] = [], animate: Animate? = nil, harness: AIHarness, model: String?, timeout: TimeInterval,
                clonedFrom: String? = nil, sceneBefore: String? = nil, startedAt: Date = Date()) {
        schema = Self.currentSchema
        self.id = id; self.origin = origin; self.runner = runner
        switch request {
        case .create(let p): sceneID = nil; self.prompt = prompt ?? p
        case .modify(let s, let p): sceneID = s; self.prompt = prompt ?? p
        }
        self.feedback = feedback; self.references = references; self.animate = animate
        self.harness = Harness(harness); self.model = model; self.timeout = timeout; self.clonedFrom = clonedFrom
        self.sceneBefore = sceneBefore; self.startedAt = startedAt
    }

    public var request: AISessionRequest {
        sceneID.map { .modify(sceneID: $0, prompt: prompt) } ?? .create(prompt: prompt)
    }

    /// Ended without anything to review (failed or cancelled), or the user decided.
    public var isSettled: Bool {
        resolution != nil || (outcome.map { $0.status != .passed } ?? false)
    }

    /// Its agent still runs, or its runner (the app or CLI) is still at work on it (not just
    /// waiting for a decision): pruning leaves its workspace alone.
    public func isActive(probe: (pid_t) -> LPProcessFacts? = ProcessProbe.facts) -> Bool {
        if let agent, agent.isSameProcess(as: probe(agent.pid)) { return true }
        if outcome == nil, let runner, runner.isSameProcess(as: probe(runner.pid)) { return true }
        return false
    }

    // MARK: - Coding

    enum CodingKeys: String, CodingKey {
        case schema, id, origin, runner, request, sceneID, prompt, feedback, references, animate, harness, model, timeout, clonedFrom,
             sceneBefore, startedAt, agent, finishedAt, outcome, resolution, recoveredAt
    }
    private enum ResolutionKeys: String, CodingKey { case action, sceneID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Without an id or a request it can't be anything (`load` then returns nil).
        id = try c.decode(String.self, forKey: .id)
        let action = try c.decode(String.self, forKey: .request)
        sceneID = try? c.decodeIfPresent(String.self, forKey: .sceneID)
        switch action {
        case "create": sceneID = nil
        case "modify": guard sceneID?.isEmpty == false else { throw AIError.unsupported("a modify session without a scene id") }
        default: throw AIError.unsupported("unknown request \(action)")
        }
        schema = (try? c.decodeIfPresent(Int.self, forKey: .schema)) ?? Self.currentSchema
        origin = (try? c.decodeIfPresent(Origin.self, forKey: .origin)) ?? .app
        runner = try? c.decodeIfPresent(LPProcessFacts.self, forKey: .runner)
        prompt = (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? ""
        feedback = (try? c.decodeIfPresent([String].self, forKey: .feedback)) ?? []
        // One damaged entry doesn't lose the others.
        references = ((try? c.decodeIfPresent([Tolerant<Reference>].self, forKey: .references)) ?? []).compactMap(\.value)
        animate = try? c.decodeIfPresent(Animate.self, forKey: .animate)
        harness = (try? c.decodeIfPresent(Harness.self, forKey: .harness))
            ?? Harness(AIHarness(kind: .custom, name: "Unknown agent", executable: ""))
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        timeout = (try? c.decodeIfPresent(TimeInterval.self, forKey: .timeout)) ?? AISettings().timeout
        clonedFrom = try? c.decodeIfPresent(String.self, forKey: .clonedFrom)
        sceneBefore = try? c.decodeIfPresent(String.self, forKey: .sceneBefore)
        startedAt = (try? c.decodeIfPresent(Date.self, forKey: .startedAt)) ?? Date(timeIntervalSince1970: 0)
        agent = try? c.decodeIfPresent(LPProcessFacts.self, forKey: .agent)
        finishedAt = try? c.decodeIfPresent(Date.self, forKey: .finishedAt)
        outcome = try? c.decodeIfPresent(Outcome.self, forKey: .outcome)
        recoveredAt = try? c.decodeIfPresent(Date.self, forKey: .recoveredAt)
        if let r = try? c.nestedContainer(keyedBy: ResolutionKeys.self, forKey: .resolution),
           let action = try? r.decode(String.self, forKey: .action) {
            switch action {
            case "accepted": resolution = (try? r.decode(String.self, forKey: .sceneID)).map { .accepted(sceneID: $0) } ?? .discarded
            case "discarded": resolution = .discarded
            default: resolution = .discarded   // a newer version decided something: it's settled either way
            }
        } else {
            resolution = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(id, forKey: .id)
        try c.encode(origin, forKey: .origin)
        try c.encodeIfPresent(runner, forKey: .runner)
        try c.encode(sceneID == nil ? "create" : "modify", forKey: .request)
        try c.encodeIfPresent(sceneID, forKey: .sceneID)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(feedback, forKey: .feedback)
        try c.encode(references, forKey: .references)
        try c.encodeIfPresent(animate, forKey: .animate)
        try c.encode(harness, forKey: .harness)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(timeout, forKey: .timeout)
        try c.encodeIfPresent(clonedFrom, forKey: .clonedFrom)
        try c.encodeIfPresent(sceneBefore, forKey: .sceneBefore)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(agent, forKey: .agent)
        try c.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try c.encodeIfPresent(outcome, forKey: .outcome)
        if let resolution {
            var r = c.nestedContainer(keyedBy: ResolutionKeys.self, forKey: .resolution)
            switch resolution {
            case .accepted(let id): try r.encode("accepted", forKey: .action); try r.encode(id, forKey: .sceneID)
            case .discarded: try r.encode("discarded", forKey: .action)
            }
        }
        try c.encodeIfPresent(recoveredAt, forKey: .recoveredAt)
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// nil when the data isn't a record (no id or request).
    public static func decode(_ data: Data) -> AISessionRecord? { try? decoder().decode(AISessionRecord.self, from: data) }
}

/// Decodes an element of an array, or nil if that one element is damaged.
private struct Tolerant<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// The records of one Workspaces directory (`<Workspaces>/.sessions/`). Changes go through one
/// cross-process lock (the app and the CLI may both be at work), so a read-modify-write never loses
/// another's change.
public final class AISessionRecordStore: @unchecked Sendable {
    public static let directoryName = ".sessions"
    public let directory: URL
    private let log = Logger(subsystem: LPPaths.bundleID, category: "ai")

    public init(workspacesDirectory: URL = LPPaths.workspaces) {
        directory = workspacesDirectory.appendingPathComponent(Self.directoryName)
    }

    private var lockURL: URL { directory.appendingPathComponent(".lock") }

    /// A session id is a plain name (it names the workspace directory too).
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && !id.hasPrefix(".") && !id.contains("/") && id != ".." && !id.contains("\0")
    }

    public func folder(for id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }
    public func url(for id: String) -> URL { folder(for: id).appendingPathComponent(AISessionRecord.fileName) }

    /// Runs `body` under the store's lock (no other process changes a record meanwhile).
    public func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try FileLock.withLock(at: lockURL, body)
    }

    public func load(_ id: String) -> AISessionRecord? {
        guard Self.isValidID(id), FileOps.isRegularFile(url(for: id)), let data = try? Data(contentsOf: url(for: id)),
              let record = AISessionRecord.decode(data), record.id == id else { return nil }
        return record
    }

    /// Writes a new record with its image copies (`copies`: file name → bytes; written first, so a
    /// record never names a copy that isn't there).
    public func create(_ record: AISessionRecord, copies: [String: Data] = [:]) throws {
        guard Self.isValidID(record.id) else { throw AIError.unsupported("Invalid session id \(record.id)") }
        try withLock {
            let folder = folder(for: record.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, data) in copies where Self.isValidID(name) && name != AISessionRecord.fileName {
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            }
            try write(record)
        }
    }

    /// Replaces a record (it must exist or be new; its folder is created).
    public func save(_ record: AISessionRecord) throws {
        guard Self.isValidID(record.id) else { throw AIError.unsupported("Invalid session id \(record.id)") }
        try withLock { try write(record) }
    }

    /// Reads, changes and writes a record under the lock. `change` returns false to leave it as it
    /// is. Returns the record as it is afterwards (nil: there is none, or it couldn't be written).
    @discardableResult
    public func update(_ id: String, _ change: (inout AISessionRecord) -> Bool) -> AISessionRecord? {
        do {
            return try withLock { () -> AISessionRecord? in
                guard var record = load(id) else { return nil }
                guard change(&record) else { return record }
                try write(record)
                return record
            }
        } catch {
            log.error("session \(id, privacy: .public): couldn't update its record: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func write(_ record: AISessionRecord) throws {
        let data = try AISessionRecord.encoder().encode(record) + Data("\n".utf8)
        try FileOps.writeAtomically(data, to: url(for: record.id))
    }

    /// Every readable record (damaged ones are skipped), newest first.
    public func records() -> [AISessionRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter(Self.isValidID).compactMap(load).sorted { $0.startedAt > $1.startedAt }
    }

    /// The ids that have a folder here (readable record or not).
    public func folderIDs() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter(Self.isValidID)
    }

    public func copy(named name: String, for id: String) -> Data? {
        guard Self.isValidID(id), Self.isValidID(name), name != AISessionRecord.fileName else { return nil }
        let url = folder(for: id).appendingPathComponent(name)
        guard FileOps.isRegularFile(url) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Deletes the image copies (the session can't be reviewed any more), keeping the record.
    public func removeCopies(for id: String) {
        guard Self.isValidID(id) else { return }
        let folder = folder(for: id)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name != AISessionRecord.fileName {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Deletes a record with its copies.
    public func remove(_ id: String) {
        guard Self.isValidID(id) else { return }
        try? FileManager.default.removeItem(at: folder(for: id))
    }
}

/// SHA-256 as lowercase hex.
public enum FileDigest {
    /// Of a regular file's bytes; nil when it isn't one (missing, a link, a directory).
    public static func sha256(_ url: URL) -> String? {
        guard FileOps.isRegularFile(url), let data = try? Data(contentsOf: url) else { return nil }
        return ReferenceImporter.sha256(data)
    }
    public static func sha256(_ data: Data) -> String { ReferenceImporter.sha256(data) }
}
