// RenderClient — talks to the RenderService socket; starts LivePaperRenderd when nothing listens.
// Foundation/Darwin only: it runs inside the `livepaper` CLI, which must never link AppKit/WebKit.
// Owner: WS-runtime.
//
// Focus rule: every GUI-registering process launch is visible to the user, so the client starts the
// daemon at most once per process, only while holding a cross-process start lock, and never while a
// daemon is already alive (it waits for that one instead).
import Darwin
import Foundation

public enum RenderClientError: Error, LocalizedError, Sendable {
    /// Nothing listens and spawning is disabled (LIVEPAPER_NO_SPAWN=1) or not possible.
    case serverUnavailable(String)
    /// LivePaperRenderd could not be found in any of the searched locations.
    case daemonNotFound([String])
    /// The daemon was started but did not start listening, or died.
    case daemonFailed(String)
    case timedOut(op: String, seconds: Double)
    case badResponse(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .serverUnavailable(let s): return "render server unavailable: \(s)"
        case .daemonNotFound(let paths):
            return "LivePaperRenderd was not found (searched: \(paths.joined(separator: ", "))). Set LIVEPAPER_RENDERD to its path."
        case .daemonFailed(let s): return "LivePaperRenderd failed to start: \(s)"
        case .timedOut(let op, let s): return "render request '\(op)' timed out after \(Int(s)) s"
        case .badResponse(let s): return "unexpected reply from the render server: \(s)"
        case .cancelled: return "render request cancelled"
        }
    }
}

public final class RenderClient: RenderClienting, @unchecked Sendable {
    public let socket: URL
    /// When false the client only talks to an already-running server (LIVEPAPER_NO_SPAWN=1 sets this).
    public var allowSpawn: Bool
    /// In an AI session (RenderSpool): where requests go when the socket can't be reached — the
    /// agent's sandbox may forbid it. The client then never starts a daemon itself.
    public let spool: URL?
    /// How long a spooled request may wait for the session runner to pick it up.
    public var spoolClaimTimeout = RenderSpool.claimTimeout

    public init(socket: URL = LPPaths.renderSocket, spool: URL? = RenderSpool.environmentSpool) {
        self.socket = socket
        self.spool = spool
        allowSpawn = ProcessInfo.processInfo.environment["LIVEPAPER_NO_SPAWN"] != "1" && spool == nil
    }

    /// Generous per-op defaults (they include time spent queued behind other clients' work).
    public static func defaultTimeout(for request: RenderRequest) -> TimeInterval {
        switch request.op {
        case .ping, .shutdown: return 10
        case .live: return (request.seconds ?? 12) + (request.warmup ?? 3) + 120
        case .still, .bench, .thumbnail: return 180
        }
    }

    public func send(_ request: RenderRequest, timeout: TimeInterval) async throws -> RenderResponse {
        let cancel = CancelToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RenderResponse, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { cont.resume(returning: try self.sendBlocking(request, timeout: timeout, cancel: cancel)) }
                    catch { cont.resume(throwing: error) }
                }
            }
        } onCancel: {
            cancel.cancel()
        }
    }

    /// Synchronous variant of `send` for command-line tools and tests.
    public func sendBlocking(_ request: RenderRequest, timeout: TimeInterval) throws -> RenderResponse {
        try sendBlocking(request, timeout: timeout, cancel: CancelToken())
    }

    /// True if a render server accepts connections right now (never starts one).
    public func isServerRunning() -> Bool { LineSocket.isListening(path: socket.path) }

    /// Starts LivePaperRenderd if nothing serves the socket (same rules as `send`).
    public func ensureServer(timeout: TimeInterval) throws {
        if isServerRunning() { return }
        guard allowSpawn else { throw RenderClientError.serverUnavailable("nothing is listening on \(socket.path)") }
        try DaemonLauncher(socket: socket).ensureRunning(deadline: Date().addingTimeInterval(timeout))
    }

    // MARK: - Request

    private func sendBlocking(_ request: RenderRequest, timeout: TimeInterval, cancel: CancelToken) throws -> RenderResponse {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let response = try sendOnce(request, timeout: timeout, deadline: deadline, cancel: cancel)
            // A server that is handing over (to the app, or a --replace daemon) refuses new work for
            // a moment; the next server is up within seconds, so try again rather than fail.
            guard !response.ok, response.note == RenderServiceFiles.shuttingDownNote, request.op != .shutdown,
                  Date().addingTimeInterval(0.25) < deadline, !cancel.isCancelled else { return response }
            usleep(250_000)
        }
    }

    private func sendOnce(_ request: RenderRequest, timeout: TimeInterval, deadline: Date, cancel: CancelToken) throws -> RenderResponse {
        let fd: Int32
        if let spool {
            do { fd = try LineSocket.connect(path: socket.path) } catch {
                // Unreachable from here (a sandbox denies the connect, or nothing listens yet): the
                // session runner relays it.
                return try RenderSpool.send(request, directory: spool, timeout: timeout, deadline: deadline,
                                            claimTimeout: spoolClaimTimeout, isCancelled: { cancel.isCancelled })
            }
        } else {
            fd = try connectOrStart(deadline: deadline, spawn: allowSpawn && request.op != .shutdown && request.op != .ping)
        }
        guard cancel.register(fd) else { close(fd); throw RenderClientError.cancelled }
        defer { cancel.unregister(); close(fd) }
        var line = try JSONEncoder().encode(request)
        line.append(0x0A)
        do {
            try LineSocket.writeAll(fd, line, deadline: deadline)
            let reply = try LineSocket.readLine(fd, deadline: deadline)
            do { return try JSONDecoder().decode(RenderResponse.self, from: reply) }
            catch { throw RenderClientError.badResponse(String(decoding: reply.prefix(300), as: UTF8.self)) }
        } catch let e as LineSocketError {
            if cancel.isCancelled { throw RenderClientError.cancelled }
            if case .timedOut = e { throw RenderClientError.timedOut(op: request.op.rawValue, seconds: timeout) }
            throw RenderClientError.serverUnavailable(e.localizedDescription)
        }
    }

    private func connectOrStart(deadline: Date, spawn: Bool) throws -> Int32 {
        do { return try LineSocket.connect(path: socket.path) }
        catch LineSocketError.pathTooLong(let p) { throw RenderClientError.serverUnavailable(LineSocketError.pathTooLong(p).localizedDescription) }
        catch {
            guard spawn else {
                throw RenderClientError.serverUnavailable("nothing is listening on \(socket.path)")
            }
        }
        try DaemonLauncher(socket: socket).ensureRunning(deadline: deadline)
        do { return try LineSocket.connect(path: socket.path) }
        catch { throw RenderClientError.serverUnavailable("\(error.localizedDescription) (\(socket.path))") }
    }
}

/// Closes the in-flight socket when the awaiting task is cancelled so blocking I/O returns at once.
private final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func register(_ fd: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; self.fd = fd; return !cancelled }
    func unregister() { lock.lock(); fd = -1; lock.unlock() }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }
}

// MARK: - Daemon launch

/// Finds and starts LivePaperRenderd. Clients serialise on `RenderServiceFiles.launchLock` (an
/// flock, so it vanishes with its process and can never go stale).
struct DaemonLauncher {
    let files: RenderServiceFiles
    init(socket: URL) { files = RenderServiceFiles(socket: socket) }

    static let executableName = "LivePaperRenderd"
    private static let processLock = NSLock()
    /// At most one daemon launch per client process: a crash-looping daemon must never turn into a
    /// stream of window-server registrations.
    nonisolated(unsafe) private static var launchedPID: pid_t = 0
    nonisolated(unsafe) private static var reapers: [DispatchSourceProcess] = []

    func ensureRunning(deadline: Date) throws {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        let socketPath = files.socket.path
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let lockFD = open(files.launchLock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else {
            throw RenderClientError.daemonFailed("cannot open \(files.launchLock.path): \(String(cString: strerror(errno)))")
        }
        defer { close(lockFD) } // releases the flock
        while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else { throw RenderClientError.daemonFailed("timed out waiting for another client to start the render server") }
            usleep(50_000)
        }
        // Somebody holds the server lock: a server is starting up, the app is taking over from a
        // daemon, or a server is on its way out. Wait for it to listen — or to let go of the lock,
        // in which case we launch the daemon ourselves — rather than starting a second server.
        let lockWait = min(deadline, Date().addingTimeInterval(30))
        while true {
            if LineSocket.isListening(path: socketPath) { return }
            guard files.isServerLockHeld() else { break }
            guard Date() < lockWait else {
                throw RenderClientError.daemonFailed("a render server holds \(files.serverLock.path) but is not accepting connections on \(socketPath)")
            }
            usleep(100_000)
        }
        guard Self.launchedPID == 0 else {
            throw RenderClientError.daemonFailed("it already exited once in this session; see \(files.daemonLog.path)")
        }
        let exe = try Self.locateExecutable()
        let pid = try spawn(exe)
        Self.launchedPID = pid
        if waitUntilListening(deadline: min(deadline, Date().addingTimeInterval(30)), child: pid) { return }
        throw RenderClientError.daemonFailed("it did not start listening on \(socketPath). Last log lines:\n\(logTail())")
    }

    /// Search order: $LIVEPAPER_RENDERD, the app bundle's Contents/Helpers, next to this executable
    /// (the CLI lives in Contents/Helpers too; `swift build` puts both in .build/<config>), then
    /// ./.build/debug for `swift run` from the repository root.
    static func locateExecutable() throws -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let e = ProcessInfo.processInfo.environment["LIVEPAPER_RENDERD"], !e.isEmpty { candidates.append(URL(fileURLWithPath: e)) }
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" { candidates.append(bundle.appendingPathComponent("Contents/Helpers/\(executableName)")) }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent(executableName))
        candidates.append(exeDir.deletingLastPathComponent().appendingPathComponent("Helpers/\(executableName)"))
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/debug/\(executableName)"))
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) { return found }
        throw RenderClientError.daemonNotFound(candidates.map(\.path))
    }

    /// Waits for the daemon we launched to listen; gives up early if it exits.
    private func waitUntilListening(deadline: Date, child: pid_t) -> Bool {
        while Date() < deadline {
            if LineSocket.isListening(path: files.socket.path) { return true }
            if kill(child, 0) != 0 { return false }
            usleep(100_000)
        }
        return false
    }

    private func spawn(_ exe: URL) throws -> pid_t {
        let logFile = files.daemonLog
        try FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // New session: an AI harness killing its process group must not take the shared daemon with it.
        // CLOEXEC_DEFAULT: the daemon must not inherit our stdout pipe, or whoever reads it never sees EOF.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        // Make the daemon its own "responsible process" so its WebKit helpers' CPU/energy is attributed to
        // it (live measurements) rather than to whichever terminal or agent happened to start it.
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
            typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
            _ = unsafeBitCast(sym, to: Disclaim.self)(&attr, 1)
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logFile.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var env = ProcessInfo.processInfo.environment
        // A non-default socket location is passed on via LIVEPAPER_HOME (the daemon binds LPPaths.renderSocket).
        if files.socket.standardizedFileURL != LPPaths.renderSocket.standardizedFileURL { env["LIVEPAPER_HOME"] = files.directory.path }
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(exe.path), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe.path, &actions, &attr, argv, envp)
        guard rc == 0 else { throw RenderClientError.daemonFailed("posix_spawn(\(exe.path)): \(String(cString: strerror(rc)))") }
        // Reap it when it exits (only matters for long-lived clients such as the self-tests).
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { var status: Int32 = 0; waitpid(pid, &status, WNOHANG); source.cancel() }
        source.resume()
        Self.reapers.append(source)
        return pid
    }

    private func logTail() -> String {
        let logFile = files.daemonLog
        guard let s = try? String(contentsOf: logFile, encoding: .utf8) else { return "(no log at \(logFile.path))" }
        return s.split(separator: "\n").suffix(8).joined(separator: "\n")
    }
}
