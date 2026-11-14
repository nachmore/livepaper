// RenderServer — serves the JSON-lines render protocol (RenderProtocol.swift) on LPPaths.renderSocket.
//
// Threading: connections are accepted and read on background queues; requests are rendered strictly
// one at a time on the main thread (WebKit is main-thread only, and serialising work keeps live
// power measurements attributable). `ping` and `shutdown` are answered without queuing.
//
// Who serves: the process holding RenderServiceFiles.serverLock. The app calls
// `startEmbeddedServer()` at launch; if LivePaperRenderd is serving at that moment the app asks it to
// shut down and takes over as soon as it exits, so the daemon never outlives the app's launch by more
// than its current request. LivePaperRenderd calls `startDaemonServer()`, which refuses to start if
// anyone else serves.
import AppKit
import Darwin
import Foundation
import LivePaperCore

public enum RenderServerError: Error, LocalizedError, Sendable {
    /// Another process is already serving the socket.
    case alreadyServing(String)
    case setup(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyServing(let s): return "another render server is already running (\(s))"
        case .setup(let s): return "render server could not start: \(s)"
        }
    }
}

extension LivePaperRenderKit {
    /// The render socket server. Create it with `startEmbeddedServer()` (app) or `startDaemonServer()`
    /// (LivePaperRenderd); stop it with `stop()`.
    public final class RenderServer: @unchecked Sendable {
        public enum Role: Sendable { case embedded, daemon }

        public let role: Role
        public let files: RenderServiceFiles

        /// Called on the main thread once the server has stopped (after `stop()` or a `shutdown` request).
        @MainActor public var onStop: (() -> Void)?

        // Set up once; guarded by `lock` where touched from several threads.
        private let lock = NSLock()
        private var lockFD: Int32 = -1
        private var listenFD: Int32 = -1
        private var acceptSource: DispatchSourceRead?
        private var stopped = false
        private let acceptQueue = DispatchQueue(label: "livepaper.render.accept")
        private let ioQueue = DispatchQueue(label: "livepaper.render.io", attributes: .concurrent)

        // Main-thread state.
        @MainActor private var renderer: SceneRenderer?
        @MainActor private var pending: [Job] = []
        @MainActor private var busy = false
        /// A `shutdown` request arrived: stop once the queue is empty.
        @MainActor private var draining = false
        @MainActor private var lastActivity = Date()
        @MainActor private var activity: NSObjectProtocol?
        @MainActor private var activityEnd: DispatchWorkItem?

        private struct Job {
            var fd: Int32
            var request: RenderRequest
        }

        /// The server started by `startEmbeddedServer()`; kept alive here so callers may discard it.
        nonisolated(unsafe) private static var embedded: RenderServer?

        private init(role: Role, files: RenderServiceFiles) {
            self.role = role
            self.files = files
        }

        // MARK: - Starting

        /// Starts serving inside the app. If another server (normally a LivePaperRenderd started by
        /// the CLI) holds the socket, it is asked to shut down and this server takes over the moment
        /// it exits; until then requests keep going to the other server. Calling it again returns
        /// the same server. Throws only for unrecoverable setup errors.
        @MainActor
        public static func startEmbeddedServer() throws -> RenderServer {
            if let s = embedded, !s.isStopped { return s }
            let server = RenderServer(role: .embedded, files: RenderServiceFiles())
            if try !server.tryAcquireServerLock() {
                server.takeOverWhenFree()
            }
            embedded = server
            return server
        }

        /// Starts serving in LivePaperRenderd. Throws `.alreadyServing` if another process serves.
        @MainActor
        public static func startDaemonServer() throws -> RenderServer {
            let server = RenderServer(role: .daemon, files: RenderServiceFiles())
            guard try server.tryAcquireServerLock() else {
                throw RenderServerError.alreadyServing(server.files.serverLock.path)
            }
            return server
        }

        /// True while this process is the one listening on the socket.
        public var isServing: Bool { lock.lock(); defer { lock.unlock() }; return listenFD >= 0 && !stopped }
        private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

        /// Seconds since the last request finished (0 while working). Main thread only.
        @MainActor public var idleSeconds: TimeInterval { busy || !pending.isEmpty ? 0 : Date().timeIntervalSince(lastActivity) }

        /// Takes the server lock without blocking and, if it was free, starts listening.
        @MainActor
        private func tryAcquireServerLock() throws -> Bool {
            try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
            let fd = open(files.serverLock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw RenderServerError.setup("cannot open \(files.serverLock.path): \(String(cString: strerror(errno)))") }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
            do { try startListening(lockFD: fd) } catch { close(fd); throw error }
            return true
        }

        /// Standby for the embedded server: politely ask the current server to exit, then block a
        /// background thread in flock() — zero cost while waiting — and start serving once it's ours.
        @MainActor
        private func takeOverWhenFree() {
            let files = self.files
            Thread.detachNewThread { [weak self] in
                // A daemon finishes its current request, replies, and exits; another app instance
                // refuses (embedded servers ignore shutdown), in which case we simply keep waiting.
                if let fd = try? LineSocket.connect(path: files.socket.path) {
                    var line = (try? JSONEncoder().encode(RenderRequest(op: .shutdown))) ?? Data()
                    line.append(0x0A)
                    try? LineSocket.writeAll(fd, line, deadline: Date().addingTimeInterval(5))
                    _ = try? LineSocket.readLine(fd, deadline: Date().addingTimeInterval(5))
                    close(fd)
                }
                let fd = open(files.serverLock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
                guard fd >= 0, flock(fd, LOCK_EX) == 0 else {
                    if fd >= 0 { close(fd) }
                    NSLog("LivePaper render server: cannot wait for \(files.serverLock.path): \(String(cString: strerror(errno)))")
                    return
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, !self.isStopped else { close(fd); return }
                        do { try self.startListening(lockFD: fd) } catch {
                            close(fd)
                            NSLog("LivePaper render server: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }

        @MainActor
        private func startListening(lockFD fd: Int32) throws {
            let listener: Int32
            do { listener = try LineSocket.listen(path: files.socket.path) } catch {
                throw RenderServerError.setup(error.localizedDescription)
            }
            lock.lock()
            lockFD = fd
            listenFD = listener
            lock.unlock()
            let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: acceptQueue)
            source.setEventHandler { [weak self] in self?.acceptPending() }
            source.setCancelHandler { close(listener) }
            acceptSource = source
            source.resume()
            lastActivity = Date()
        }

        // MARK: - Stopping

        /// Stops accepting, fails queued requests, removes the socket and releases the server lock.
        /// The request being rendered (if any) still gets its reply.
        @MainActor
        public func stop() {
            lock.lock()
            if stopped { lock.unlock(); return }
            stopped = true
            let source = acceptSource, lockFD = self.lockFD, wasListening = listenFD >= 0
            acceptSource = nil
            listenFD = -1
            self.lockFD = -1
            lock.unlock()
            source?.cancel()
            if wasListening { unlink(files.socket.path) } // ours: we hold the server lock
            if lockFD >= 0 { close(lockFD) }             // releases the lock for the next server
            for job in pending { reply(job.fd, RenderResponse(ok: false, note: "render server stopped")) }
            pending.removeAll()
            if !busy { finishStopping() }
        }

        @MainActor
        private func finishStopping() {
            endActivity()
            renderer?.close()
            renderer = nil
            if Self.embedded === self { Self.embedded = nil }
            onStop?()
        }

        /// `shutdown`: finish what is queued, then stop. Requests arriving meanwhile are refused (the
        /// socket stays bound so their clients get an answer instead of a connection error).
        @MainActor
        private func drainAndStop() {
            draining = true
            if !busy && pending.isEmpty { stop() }
        }

        // MARK: - Connections (background queues)

        private func acceptPending() {
            lock.lock()
            let listener = listenFD
            lock.unlock()
            guard listener >= 0 else { return }
            while true {
                let fd = accept(listener, nil, nil)
                if fd < 0 { return } // EAGAIN: drained (or listener closed)
                var on: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                ioQueue.async { [weak self] in self?.readRequest(fd) }
            }
        }

        private func readRequest(_ fd: Int32) {
            let request: RenderRequest
            do {
                let line = try LineSocket.readLine(fd, deadline: Date().addingTimeInterval(15))
                request = try JSONDecoder().decode(RenderRequest.self, from: line)
            } catch {
                reply(fd, RenderResponse(ok: false, note: "bad request: \(error.localizedDescription)"))
                return
            }
            switch request.op {
            case .ping:
                reply(fd, RenderResponse(ok: true, ready: true, note: statusNote()))
            case .shutdown:
                guard role == .daemon else {
                    reply(fd, RenderResponse(ok: false, note: "this render server runs inside LivePaper.app; quit the app to stop it"))
                    return
                }
                reply(fd, RenderResponse(ok: true, ready: true, note: "shutting down after the current request"))
                DispatchQueue.main.async { MainActor.assumeIsolated { self.drainAndStop() } }
            default:
                DispatchQueue.main.async { MainActor.assumeIsolated { self.enqueue(Job(fd: fd, request: request)) } }
            }
        }

        private func statusNote() -> String {
            let who = role == .daemon ? "LivePaperRenderd" : "LivePaper.app"
            return "\(who) pid \(getpid()), runtime renderer \(LivePaperRenderKit.version)"
        }

        /// Writes one response line and closes the connection (off the main thread).
        private func reply(_ fd: Int32, _ response: RenderResponse) {
            ioQueue.async {
                var line = (try? JSONEncoder().encode(response)) ?? Data(#"{"ok":false,"ready":false,"errors":[]}"#.utf8)
                line.append(0x0A)
                try? LineSocket.writeAll(fd, line, deadline: Date().addingTimeInterval(10))
                close(fd)
            }
        }

        // MARK: - Work queue (main thread)

        @MainActor
        private func enqueue(_ job: Job) {
            if isStopped || draining {
                reply(job.fd, RenderResponse(ok: false, note: "render server is shutting down"))
                return
            }
            pending.append(job)
            pump()
        }

        @MainActor
        private func pump() {
            while !busy, !pending.isEmpty {
                let job = pending.removeFirst()
                // Skip work for clients that already gave up (timed out or were cancelled).
                if LineSocket.peerClosed(job.fd) { close(job.fd); continue }
                busy = true
                beginActivity()
                let renderer = self.renderer ?? SceneRenderer()
                self.renderer = renderer
                Task { @MainActor in
                    let response = await renderer.perform(job.request)
                    self.reply(job.fd, response)
                    self.busy = false
                    self.lastActivity = Date()
                    if self.isStopped { self.finishStopping(); return }
                    if self.pending.isEmpty {
                        self.scheduleActivityEnd()
                        if self.draining { self.stop() }
                    }
                    self.pump()
                }
            }
        }

        // MARK: - App Nap

        /// While working, opt out of App Nap and timer coalescing: a napping process gets its timers
        /// and rAF throttled, which caps live scenes at 30 fps and makes every measurement lie. Idle
        /// system sleep stays allowed; the assertion is dropped a few seconds after the queue drains.
        @MainActor
        private func beginActivity() {
            activityEnd?.cancel()
            activityEnd = nil
            guard activity == nil else { return }
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                             reason: "LivePaper render server")
        }

        @MainActor
        private func scheduleActivityEnd() {
            let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.endActivity() } }
            activityEnd = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
        }

        @MainActor
        private func endActivity() {
            activityEnd?.cancel()
            activityEnd = nil
            if let a = activity { ProcessInfo.processInfo.endActivity(a) }
            activity = nil
        }
    }
}
