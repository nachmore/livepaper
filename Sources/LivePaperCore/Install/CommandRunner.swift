// CommandRunner — runs short system commands (ditto, launchctl, sysadminctl, open, `<cli> --version`)
// behind a protocol so tests and dry runs can record them instead of touching the system.
import Foundation

/// Result of a finished command.
public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    /// True when the command was killed because it exceeded its timeout.
    public var timedOut: Bool
    public init(status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) {
        self.status = status; self.stdout = stdout; self.stderr = stderr; self.timedOut = timedOut
    }
    public var succeeded: Bool { status == 0 && !timedOut }
    /// stdout + stderr (many system tools, e.g. sysadminctl, report on stderr).
    public var combinedOutput: String { stdout + stderr }
}

public protocol CommandRunning: Sendable {
    /// Runs `executable` (absolute path) and waits for it. Never throws for a non-zero exit — only
    /// when the command can't be started.
    func run(_ executable: String, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval) throws -> CommandResult
}

public extension CommandRunning {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) throws -> CommandResult {
        try run(executable, arguments, environment: nil, timeout: timeout)
    }
}

/// Runs commands for real, each in its own process group so a timeout kills the whole tree.
public struct SystemCommandRunner: CommandRunning {
    /// Also gives each command a session of its own, without a controlling terminal: for commands
    /// that would otherwise use the caller's terminal, such as an interactive shell (LoginShell).
    public var newSession: Bool

    public init(newSession: Bool = false) { self.newSession = newSession }

    public func run(_ executable: String, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval) throws -> CommandResult {
        let child = try ChildProcess.spawn(executable: executable, arguments: arguments,
                                           environment: environment ?? ProcessInfo.processInfo.environment,
                                           currentDirectory: nil, stdinFile: nil, newSession: newSession)
        let out = OutputBuffer(), err = OutputBuffer()
        let done = DispatchGroup()
        for (fd, buffer) in [(child.stdoutFD, out), (child.stderrFD, err)] {
            done.enter()
            PipeReader.start(fd: fd, onData: { buffer.append($0) }, onEOF: { done.leave() })
        }
        var timedOut = false
        var status = child.waitForExit(timeout: timeout)
        if status == nil {
            timedOut = true
            child.terminateGroup(grace: 1)
            status = child.waitForExit()
        }
        // A grandchild may still hold the pipes open; don't wait for it forever.
        _ = done.wait(timeout: .now() + 2)
        return CommandResult(status: status ?? -1, stdout: out.string, stderr: err.string, timedOut: timedOut)
    }
}

/// Records every command instead of running it; answers with canned results. Used by dry runs and
/// tests so that nothing (launchctl, open, sysadminctl, …) ever reaches the real system.
public final class RecordingCommandRunner: CommandRunning, @unchecked Sendable {
    public typealias Responder = @Sendable (_ executable: String, _ arguments: [String]) -> CommandResult?
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let responder: Responder

    /// `responder` returns the result for a command (nil = success with empty output).
    public init(responder: @escaping Responder = { _, _ in nil }) { self.responder = responder }

    /// Every command run so far, as `[executable] + arguments`.
    public var commands: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }

    public func run(_ executable: String, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval) throws -> CommandResult {
        lock.lock(); recorded.append([executable] + arguments); lock.unlock()
        return responder(executable, arguments) ?? CommandResult(status: 0)
    }
}

/// Thread-safe byte accumulator for pipe readers.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
