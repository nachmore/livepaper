// HelperSingleInstance — at most one agent per user. launchd runs one job per label, but the
// SMAppService job and the ~/Library/LaunchAgents fallback (or a manual run) could overlap; two
// agents would each register the hotkey and race to start the screen saver.
//
// An exclusive flock on <support>/helper.pid, held for the process lifetime (the kernel drops it
// when the process dies, so a crash never leaves a stale lock). The file also records the pid for
// --print-config, which only reads it.
import Darwin
import Foundation

final class HelperSingleInstance {
    enum Outcome {
        case acquired(HelperSingleInstance)
        /// Another agent holds the lock (its recorded pid, if readable).
        case heldByOther(pid_t?)
        /// The lock file couldn't be opened; run without the guard.
        case unavailable(String)
    }

    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    static func acquire(at url: URL) -> Outcome {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .unavailable("can't create \(url.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return .unavailable("can't open \(url.path): \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let other = (try? String(contentsOf: url, encoding: .utf8)).flatMap(HelperProcesses.parsePID)
            close(fd)
            return .heldByOther(other)
        }
        let record = "\(getpid())\n"
        _ = ftruncate(fd, 0)
        _ = record.withCString { pwrite(fd, $0, strlen($0), 0) }
        return .acquired(HelperSingleInstance(fd: fd))
    }

    /// Clears the recorded pid and drops the lock (clean shutdown). The file itself stays: unlinking
    /// a locked file would let a second agent lock a fresh inode while a third still sees the old one.
    func release() {
        guard fd >= 0 else { return }
        _ = ftruncate(fd, 0)
        close(fd)
        fd = -1
    }
}
