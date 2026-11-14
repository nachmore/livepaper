// LineSocket — minimal POSIX Unix-domain socket helpers for the JSON-lines render protocol.
// Used by RenderClient (here, Foundation-only) and by the RenderKit server. Owner: WS-runtime.
import Darwin
import Foundation

/// Errors from the socket layer. Messages are written for humans (they end up in CLI output).
public enum LineSocketError: Error, LocalizedError, Sendable, Equatable {
    case pathTooLong(String)
    case system(String, Int32)
    case timedOut(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let p):
            return "socket path is too long for a Unix socket (max 103 bytes): \(p). Use a shorter LIVEPAPER_HOME."
        case .system(let what, let code): return "\(what) failed: \(String(cString: strerror(code)))"
        case .timedOut(let what): return "timed out \(what)"
        case .closed: return "connection closed before a reply was received"
        }
    }
}

/// Blocking-with-deadline socket I/O on file descriptors. Works for blocking and non-blocking fds.
public enum LineSocket {
    /// Largest request/response line accepted (a still response is tiny; this only guards against garbage).
    public static let maxLineBytes = 1 << 20

    /// Fills a `sockaddr_un` for `path`, or throws if the path doesn't fit.
    public static func address(for path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw LineSocketError.pathTooLong(path) }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    /// Creates a stream socket that never raises SIGPIPE (a vanished peer must not kill the process).
    public static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LineSocketError.system("socket()", errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    /// Connects to a listening socket. Throws `.system("connect()", ENOENT/ECONNREFUSED)` when nobody listens.
    public static func connect(path: String) throws -> Int32 {
        var addr = try address(for: path)
        let fd = try makeSocket()
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if r != 0 {
            let e = errno
            close(fd)
            throw LineSocketError.system("connect()", e)
        }
        return fd
    }

    /// Binds a non-blocking listening socket at `path`, replacing any existing socket file.
    /// Only call this while holding `RenderServiceFiles.serverLock`: the lock is what proves an
    /// existing file is stale. The socket is private to the user (0600): it is local IPC only and is
    /// never reachable from the network.
    public static func listen(path: String, backlog: Int32 = 32) throws -> Int32 {
        var addr = try address(for: path)
        let fd = try makeSocket()
        unlink(path)
        // umask makes the file 0600 from the moment it exists (no window between bind and chmod).
        let oldMask = umask(0o077)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard r == 0 else { let e = errno; close(fd); throw LineSocketError.system("bind(\(path))", e) }
        guard Darwin.listen(fd, backlog) == 0 else { let e = errno; close(fd); unlink(path); throw LineSocketError.system("listen()", e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    /// True if something accepts connections on `path` right now.
    public static func isListening(path: String) -> Bool {
        guard let fd = try? connect(path: path) else { return false }
        close(fd)
        return true
    }

    /// Writes all of `data` before `deadline`.
    public static func writeAll(_ fd: Int32, _ data: Data, deadline: Date) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                try waitFor(fd, events: Int16(POLLOUT), deadline: deadline, what: "writing to the render socket")
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw LineSocketError.system("write()", errno)
                }
                offset += n
            }
        }
    }

    /// Reads up to (and excluding) the first newline before `deadline`. A final line without a newline
    /// is returned if the peer closes after sending it.
    public static func readLine(_ fd: Int32, deadline: Date) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try waitFor(fd, events: Int16(POLLIN), deadline: deadline, what: "waiting for the render server")
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw LineSocketError.system("read()", errno)
            }
            if n == 0 {
                if buffer.isEmpty { throw LineSocketError.closed }
                return buffer
            }
            if let nl = chunk[0..<n].firstIndex(of: 0x0A) {
                buffer.append(contentsOf: chunk[0..<nl])
                return buffer
            }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > maxLineBytes { throw LineSocketError.system("read() (line too long)", EMSGSIZE) }
        }
    }

    /// True if the peer has closed its end (used to skip queued work whose client already gave up).
    public static func peerClosed(_ fd: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 0) > 0 else { return false }
        if p.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
    }

    private static func waitFor(_ fd: Int32, events: Int16, deadline: Date, what: String) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw LineSocketError.timedOut(what) }
            var p = pollfd(fd: fd, events: events, revents: 0)
            let r = poll(&p, 1, Int32(min(remaining, 3600) * 1000) + 1)
            if r < 0 {
                if errno == EINTR { continue }
                throw LineSocketError.system("poll()", errno)
            }
            if r == 0 { continue } // re-check the deadline
            if p.revents & Int16(POLLNVAL) != 0 { throw LineSocketError.closed }
            return // readable/writable, or HUP/ERR which the following read/write reports
        }
    }
}
