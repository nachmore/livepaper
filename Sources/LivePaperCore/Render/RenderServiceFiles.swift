// RenderServiceFiles — the files next to the render socket that coordinate servers and clients.
// Shared by RenderClient (CLI side) and RenderKit's RenderServer so both agree on the protocol of
// "who serves" without any extra IPC. Owner: WS-runtime.
import Darwin
import Foundation

/// Locations derived from one render socket path (all in the socket's directory).
///
/// * `serverLock` is `flock`ed by whichever process serves the socket (the app or LivePaperRenderd)
///   for as long as it serves. Holding it is what makes a process *the* server, so two servers can
///   never fight over the socket, and a socket file whose lock is free is stale by definition.
///   `flock` locks disappear with their process, so a crash never leaves a stale lock behind.
/// * `launchLock` is taken by clients while they decide whether to launch LivePaperRenderd, so
///   concurrent clients start at most one daemon.
public struct RenderServiceFiles: Sendable, Equatable {
    public let socket: URL

    /// RenderResponse.note of requests refused because the server is stopping or handing over.
    /// Clients retry those (RenderClient) once the next server is up.
    public static let shuttingDownNote = "render server is shutting down"

    public init(socket: URL = LPPaths.renderSocket) { self.socket = socket }

    public var directory: URL { socket.deletingLastPathComponent() }
    public var serverLock: URL { directory.appendingPathComponent("render-server.lock") }
    public var launchLock: URL { directory.appendingPathComponent("renderd-launch.lock") }
    /// Written by LivePaperRenderd (informational: `livepaper server status`, debugging).
    public var pidFile: URL { directory.appendingPathComponent("renderd.pid") }
    /// stdout/stderr of a LivePaperRenderd started by a client.
    public var daemonLog: URL { directory.appendingPathComponent("Logs/renderd.log") }

    /// True if some process currently holds the server lock (it serves, or is about to).
    public func isServerLockHeld() -> Bool {
        let fd = open(serverLock.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false } // never created: nobody ever served here
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}
