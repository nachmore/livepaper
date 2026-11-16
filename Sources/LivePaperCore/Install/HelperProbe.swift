// HelperProbe — what LivePaper asks the system about the helper's process and code, so the repair
// never rests on launchctl's text alone (HelperJob.swift). Read-only; behind a protocol so the
// self-tests answer with fakes.
//
// Verified on macOS 26.7 (docs/RESEARCH.md §6.1): for a running process whose executable was
// replaced, SecCodeCopySigningInformation and `codesign -dvvv <pid>` describe the *new* file at its
// path, while SecCodeCheckValidity (`codesign --verify <pid>`) fails with errSecCSStaticCodeChanged
// ("the code on disk does not match what is running"); identical bytes in a new file pass.
// proc_pidpath follows the file when it is moved (e.g. to the Trash with its app) and fails with
// ENOENT once it is deleted.
import Darwin
import Foundation
import Security

/// Where a process's executable is (proc_pidpath).
public enum ProcessExecutable: Sendable, Equatable {
    case path(String)
    /// It was deleted (ENOENT).
    case deleted
    /// It couldn't be found out (the process is gone, or another error).
    case unknown
}

public protocol HelperProcessProbing: Sendable {
    /// Process `pid` exists.
    func isAlive(_ pid: Int32) -> Bool
    /// Where process `pid`'s executable is.
    func executable(of pid: Int32) -> ProcessExecutable
    /// Process `pid` runs the code that is on disk at its path (true), other code (false:
    /// errSecCSStaticCodeChanged), or LivePaper can't tell (nil).
    func runsCodeOnDisk(_ pid: Int32) -> Bool?
    /// The signature of the code at `url` (nil: unsigned or unreadable).
    func signature(at url: URL) -> CodeSignature?
    /// This user's processes whose executable is at `path`.
    func processes(running path: String) -> [Int32]
}

/// The live system: libproc and the Security framework.
public struct SystemHelperProbe: HelperProcessProbing {
    public init() {}

    public func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    public func executable(of pid: Int32) -> ProcessExecutable {
        guard pid > 0 else { return .unknown }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return errno == ENOENT ? .deleted : .unknown }
        return .path(String(cString: buffer))
    }

    public func runsCodeOnDisk(_ pid: Int32) -> Bool? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return nil }
        switch SecCodeCheckValidity(code, [], nil) {
        case errSecSuccess: return true
        case errSecCSStaticCodeChanged: return false
        default: return nil
        }
    }

    public func signature(at url: URL) -> CodeSignature? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let unique = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        return CodeSignature(cdhash: unique.map { String(format: "%02x", $0) }.joined(),
                             teamID: dict[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    public func processes(running path: String) -> [Int32] {
        let wanted = InstallService.realPath(path)
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }
        let uid = getuid()
        return pids.prefix(Int(filled)).filter { pid in
            guard pid > 0, executable(of: pid) == .path(wanted) else { return false }
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size && info.pbsi_uid == uid
        }
    }
}
