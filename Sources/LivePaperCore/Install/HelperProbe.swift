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

public protocol HelperProcessProbing: Sendable {
    /// Process `pid` exists.
    func isAlive(_ pid: Int32) -> Bool
    /// The path of process `pid`'s executable (proc_pidpath), nil when it can't be found — e.g. it
    /// was deleted.
    func executablePath(_ pid: Int32) -> String?
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

    public func executablePath(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
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
            guard pid > 0, let exe = executablePath(pid), exe == wanted else { return false }
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size && info.pbsi_uid == uid
        }
    }
}
