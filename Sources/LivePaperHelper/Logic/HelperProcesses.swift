// HelperProcesses — process-table queries through libproc (kernel only: no Launch Services, no
// window server, so `--print-config` can use them too), and the helper's instance file.
//
// Foundation/Darwin only, also compiled into LivePaperSelfTest.
import Darwin
import Foundation
import LivePaperCore

enum HelperProcesses {
    /// What the lock flow launches; a running ScreenSaverEngine means a screen saver is up.
    static let screenSaverEngineApp = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
    /// Matched as a path suffix: system executables may be reported under a firmlinked/cryptex prefix.
    static let screenSaverEngineExecutableSuffix = "/ScreenSaverEngine.app/Contents/MacOS/ScreenSaverEngine"

    /// Holds an exclusive flock while an agent runs, and its pid (see HelperSingleInstance).
    static var instanceFile: URL { LPPaths.supportRoot.appendingPathComponent("helper.pid") }

    /// All current pids (a snapshot; processes may exit right after).
    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)   // room for processes started meanwhile
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return pids.prefix(Int(min(count, Int32(pids.count)))).filter { $0 > 0 }
    }

    /// The executable of `pid`, or nil if it is gone or not inspectable.
    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))   // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Whether any process's executable path satisfies `matches`. A few ms for ~1000 processes;
    /// used once per lock request or report, never periodically.
    static func isRunning(where matches: (String) -> Bool) -> Bool {
        allPIDs().contains { pid in executablePath(of: pid).map(matches) ?? false }
    }

    static func isRunning(executable: String) -> Bool { isRunning { $0 == executable } }

    static var isScreenSaverEngineRunning: Bool { isRunning { $0.hasSuffix(screenSaverEngineExecutableSuffix) } }

    /// The pid recorded in an instance file ("<pid>\n"); nil for anything else.
    static func parsePID(_ text: String) -> pid_t? {
        guard let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        return pid
    }

    /// The running agent's pid according to the instance file: alive and running an executable with
    /// the helper's name (guards against a stale file whose pid was reused).
    static func runningAgentPID(instanceFile: URL = instanceFile, executableName: String = "LivePaperHelper") -> pid_t? {
        guard let text = try? String(contentsOf: instanceFile, encoding: .utf8), let pid = parsePID(text),
              pid != getpid(), let path = executablePath(of: pid),
              (path as NSString).lastPathComponent == executableName else { return nil }
        return pid
    }
}
