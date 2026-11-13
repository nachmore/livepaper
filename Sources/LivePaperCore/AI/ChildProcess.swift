// ChildProcess — posix_spawn wrapper that starts a command in its OWN process group.
//
// Foundation's Process can't do that (setpgid after launch races with the child's own fork/exec),
// and AI harnesses spawn whole trees (node → shells → livepaper → …). Putting the child in a fresh
// group lets cancel/timeout signal the entire tree with one killpg(2).
import Darwin
import Foundation

final class ChildProcess: @unchecked Sendable {
    /// Process id (also the process-group id).
    let pid: pid_t
    /// Read ends of the child's stdout and stderr pipes (owned; closed by the readers at EOF).
    let stdoutFD: Int32
    let stderrFD: Int32

    private let lock = NSLock()
    private var exitStatus: Int32?
    private let exited = DispatchSemaphore(value: 0)

    private init(pid: pid_t, stdoutFD: Int32, stderrFD: Int32) {
        self.pid = pid; self.stdoutFD = stdoutFD; self.stderrFD = stderrFD
    }

    /// Spawns `executable` (an absolute path; PATH is not searched) with exactly `environment`.
    /// stdin is `stdinFile` or /dev/null — never the parent's stdin. No other descriptors leak in.
    static func spawn(executable: String, arguments: [String], environment: [String: String],
                      currentDirectory: URL?, stdinFile: URL?) throws -> ChildProcess {
        var outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw spawnError(errno, executable) }
        guard pipe(&errPipe) == 0 else { close(outPipe[0]); close(outPipe[1]); throw spawnError(errno, executable) }
        // Our read ends must not leak into other children spawned concurrently by this process.
        _ = fcntl(outPipe[0], F_SETFD, FD_CLOEXEC); _ = fcntl(errPipe[0], F_SETFD, FD_CLOEXEC)
        defer { close(outPipe[1]); close(errPipe[1]) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, stdinFile?.path ?? "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if let dir = currentDirectory { posix_spawn_file_actions_addchdir_np(&actions, dir.path) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // SETPGROUP with pgroup 0 = new group whose id is the child's pid. CLOEXEC_DEFAULT closes
        // every descriptor not named in the file actions (the app's sockets etc. stay private).
        // SETSIGDEF/SETSIGMASK undo any signal dispositions (e.g. ignored SIGPIPE) we'd otherwise pass on.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t(); sigfillset(&defaults); posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t(); sigemptyset(&mask); posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard rc == 0 else { close(outPipe[0]); close(errPipe[0]); throw spawnError(rc, executable) }
        let child = ChildProcess(pid: pid, stdoutFD: outPipe[0], stderrFD: errPipe[0])
        Thread { child.reap() }.start()
        return child
    }

    var hasExited: Bool { lock.lock(); defer { lock.unlock() }; return exitStatus != nil }

    /// Blocks until the child exits. Returns its exit code, or 128 + signal number if it was killed.
    @discardableResult func waitForExit() -> Int32 {
        exited.wait(); exited.signal()
        lock.lock(); defer { lock.unlock() }
        return exitStatus ?? -1
    }

    /// Waits up to `timeout` seconds; nil if still running.
    func waitForExit(timeout: TimeInterval) -> Int32? {
        guard exited.wait(timeout: .now() + timeout) == .success else { return nil }
        exited.signal()
        lock.lock(); defer { lock.unlock() }
        return exitStatus
    }

    /// Sends `signal` to every process in the child's group (ESRCH — nobody left — is ignored).
    func signalGroup(_ signal: Int32) { _ = killpg(pid, signal) }

    /// SIGTERM to the whole group, then SIGKILL after `grace` seconds for anything still alive.
    func terminateGroup(grace: TimeInterval = 3) {
        signalGroup(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            // The group can outlive its leader (orphaned grandchildren), so check the group, not the pid.
            if killpg(pid, 0) == 0 { signalGroup(SIGKILL) }
        }
    }

    private func reap() {
        var status: Int32 = 0
        var rc: pid_t
        repeat { rc = waitpid(pid, &status, 0) } while rc == -1 && errno == EINTR
        // WIFEXITED/WEXITSTATUS are macros Swift can't import: low 7 bits = terminating signal.
        let signal = status & 0x7f
        let code: Int32 = rc == -1 ? -1 : (signal == 0 ? (status >> 8) & 0xff : 128 + signal)
        lock.lock(); exitStatus = code; lock.unlock()
        exited.signal()
    }

    private static func spawnError(_ code: Int32, _ executable: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "Could not start \(executable): \(String(cString: strerror(code)))"])
    }
}

/// Reads a descriptor to EOF on a dedicated thread, delivering chunks and closing it at the end.
enum PipeReader {
    static func start(fd: Int32, onData: @escaping @Sendable (Data) -> Void, onEOF: @escaping @Sendable () -> Void) {
        Thread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 { onData(Data(buffer[0..<n])); continue }
                if n < 0 && errno == EINTR { continue }
                break
            }
            close(fd)
            onEOF()
        }.start()
    }
}

/// Splits a byte stream into UTF-8 lines (handles chunks that end mid-line or mid-character).
struct LineSplitter {
    private var pending = Data()

    mutating func feed(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(Self.decode(pending[pending.startIndex..<nl]))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }

    /// The unterminated last line, if any.
    mutating func flush() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : Self.decode(pending)
    }

    private static func decode(_ bytes: Data) -> String {
        var s = String(decoding: bytes, as: UTF8.self)
        if s.hasSuffix("\r") { s.removeLast() }
        return s
    }
}
