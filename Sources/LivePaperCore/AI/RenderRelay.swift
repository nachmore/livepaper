// RenderRelay — the session runner's half of RenderSpool: relays render requests a sandboxed
// agent's `livepaper` left in <workspace>/.livepaper/render-spool to the real render server.
//
// The runner is outside the agent's sandbox, so it relays only what a scene command of that
// workspace would send, and never lets a request widen what the agent can reach:
//
//   * ops: still, bench, live, motion, thumbnail and ping (no shutdown);
//   * still/bench/live/motion name `<package>/.check/scene.html` of a package inside the workspace; the
//     relay compiles that package itself (CSP, offline scanner) into a folder next to the
//     workspaces that the agent can't write, and sends that file instead — so the server never
//     renders HTML the agent wrote, which could otherwise load anything from the network;
//   * every path (package, `out`) must resolve inside the workspace, outputs with the op's image
//     extension only (the server checks again when it writes: RenderOutputPolicy).
//
// The spool folder is agent-writable, so the relay touches it only through a descriptor whose real
// path it has checked, and never follows links in it.
import Darwin
import Foundation
import os

final class RenderRelay: @unchecked Sendable {
    static let pollInterval: TimeInterval = 0.1

    let workspace: AIWorkspace
    /// Where the relay puts the HTML it compiles (outside the workspace).
    let privateDirectory: URL
    private let render: RenderClienting
    private let compiler: SceneCompiling
    private let workspaceReal: String
    private let queue = DispatchQueue(label: "com.nachmore.livepaper.render-relay")
    private let log = Logger(subsystem: LPPaths.bundleID, category: "ai")

    // Touched only on `queue`.
    private var timer: DispatchSourceTimer?
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var stopped = false

    init(workspace: AIWorkspace, privateDirectory: URL, render: RenderClienting, compiler: SceneCompiling) {
        self.workspace = workspace; self.privateDirectory = privateDirectory; self.render = render; self.compiler = compiler
        workspaceReal = AISessionPolicy.realPath(workspace.root.path) ?? workspace.root.standardizedFileURL.path
    }

    func start() {
        queue.async { [self] in
            guard !stopped, timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(30))
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            timer = t
        }
    }

    /// Stops relaying, cancels requests in flight and removes the compiled HTML. Idempotent.
    func stop() {
        queue.sync {
            stopped = true
            timer?.cancel(); timer = nil
            inFlight.values.forEach { $0.cancel() }
            inFlight = [:]
        }
        try? FileManager.default.removeItem(at: privateDirectory)
    }

    // MARK: - Spool (on `queue`)

    private func poll() {
        guard !stopped, let dir = openSpool() else { return }
        defer { close(dir) }
        for name in Self.entries(dir) where name.hasSuffix(RenderSpool.requestSuffix) {
            let id = String(name.dropLast(RenderSpool.requestSuffix.count))
            guard Self.isSpoolID(id), inFlight[id] == nil else { continue }
            guard renameat(dir, name, dir, id + RenderSpool.claimedSuffix) == 0 else { continue }
            let data = Self.read(dir, id + RenderSpool.claimedSuffix)
            inFlight[id] = Task.detached { [weak self] in
                guard let self else { return }
                let response = await self.handle(data)
                self.queue.async {
                    guard !self.stopped else { return }
                    self.inFlight[id] = nil
                    self.respond(id, response)
                }
            }
        }
    }

    private func respond(_ id: String, _ response: RenderResponse) {
        guard let dir = openSpool(), let data = try? JSONEncoder().encode(response) else { return }
        defer { close(dir) }
        let tmp = ".\(id).response.tmp"
        let fd = openat(dir, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        if written != data.count || renameat(dir, tmp, dir, id + RenderSpool.responseSuffix) != 0 { unlinkat(dir, tmp, 0) }
    }

    /// The spool folder, opened only if it really is <workspace>/.livepaper/render-spool.
    private func openSpool() -> Int32? {
        let fd = open(workspace.renderSpool.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let expected = (workspaceReal as NSString).appendingPathComponent(".livepaper/render-spool")
        guard RenderOutputPolicy.descriptorPath(fd) == expected else { close(fd); return nil }
        return fd
    }

    private static func isSpoolID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func entries(_ fd: Int32) -> [String] {
        let copy = dup(fd)
        guard copy >= 0, let dirp = fdopendir(copy) else { if copy >= 0 { close(copy) }; return [] }
        defer { closedir(dirp) }
        var names: [String] = []
        while let entry = readdir(dirp) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            names.append(name)
        }
        return names.sorted()
    }

    /// A regular file in the spool (never through a link), at most RenderSpool.maxFileBytes.
    private static func read(_ dir: Int32, _ name: String) -> Data? {
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= RenderSpool.maxFileBytes else { return nil }
        var data = Data(count: Int(st.st_size))
        let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        return n == data.count ? data : nil
    }

    // MARK: - Requests

    private func handle(_ data: Data?) async -> RenderResponse {
        guard let data, let request = try? JSONDecoder().decode(RenderRequest.self, from: data) else {
            return RenderResponse(ok: false, note: "bad request: not a render request")
        }
        let prepared: RenderRequest, compiled: URL?
        do { (prepared, compiled) = try prepare(request) } catch {
            log.notice("render relay refused a \(request.op.rawValue, privacy: .public) request: \(error.localizedDescription, privacy: .public)")
            return RenderResponse(ok: false, note: error.localizedDescription)
        }
        defer { if let compiled { try? FileManager.default.removeItem(at: compiled) } }
        do {
            return try await render.send(prepared, timeout: RenderClient.defaultTimeout(for: prepared))
        } catch {
            return RenderResponse(ok: false, note: error.localizedDescription)
        }
    }

    struct Refusal: Error, LocalizedError {
        let message: String
        var errorDescription: String? { "LivePaper refused this render request: \(message)" }
    }

    /// The request to send on (with LivePaper's own compile of the scene), and that compiled file.
    func prepare(_ r: RenderRequest) throws -> (RenderRequest, URL?) {
        switch r.op {
        case .ping:
            return (RenderRequest(op: .ping), nil)
        case .shutdown:
            throw Refusal(message: "the render server can't be stopped from an AI session")
        case .still, .bench, .live, .motion:
            guard let html = r.html, html.hasPrefix("/") else { throw Refusal(message: "\(r.op.rawValue) needs the scene's compiled html") }
            let htmlURL = URL(fileURLWithPath: html).standardizedFileURL
            guard htmlURL.lastPathComponent == SceneChecker.compiledFile,
                  htmlURL.deletingLastPathComponent().lastPathComponent == SceneChecker.checkDirectory else {
                throw Refusal(message: "only a scene's \(SceneChecker.checkDirectory)/\(SceneChecker.compiledFile) can be rendered")
            }
            let package = htmlURL.deletingLastPathComponent().deletingLastPathComponent()
            try confine(package.path, "the scene")
            if r.op == .still || r.op == .motion, let out = r.out { try confine(out, "out", extensions: ["png"]) }
            try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: true)
            let compiled = privateDirectory.appendingPathComponent("\(UUID().uuidString).html")
            do { try compiler.compile(package: package, to: compiled) } catch let e as SceneCompileError {
                throw Refusal(message: "the scene does not compile: \(e.messages.prefix(3).joined(separator: "; "))")
            }
            var p = r
            p.html = compiled.path
            p.scene = nil
            if r.op != .still && r.op != .motion { p.out = nil }
            return (p, compiled)
        case .thumbnail:
            guard let scene = r.scene, let out = r.out else { throw Refusal(message: "thumbnail needs \"scene\" and \"out\"") }
            try confine(scene, "the scene")
            try confine(out, "out", extensions: ["jpg", "jpeg"])
            var p = r
            p.html = nil
            return (p, nil)
        }
    }

    /// Throws unless `path` is absolute and resolves inside the workspace (and, for outputs, has
    /// one of `extensions`).
    private func confine(_ path: String, _ what: String, extensions: Set<String>? = nil) throws {
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), let real = AISessionPolicy.resolve(url),
              real == workspaceReal || real.hasPrefix(workspaceReal + "/") else {
            throw Refusal(message: "\(what) \(path) is outside this AI session's workspace")
        }
        if let extensions, !extensions.contains(url.pathExtension.lowercased()) {
            throw Refusal(message: "\(what) must be a \(extensions.sorted().map { "." + $0 }.joined(separator: "/")) file")
        }
    }
}
