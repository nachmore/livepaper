// ProcessEnergy — CPU time and energy of this process plus the WebKit processes it owns.
//
// WebKit renders in XPC services (com.apple.WebKit.WebContent / .GPU / .Networking). They are not our
// children, but macOS attributes them to a "responsible" process: the app that hosts the web view —
// or, for a plain executable, whatever launched it (Terminal, an AI harness…). RenderClient spawns
// LivePaperRenderd with responsibility disclaimed so the daemon is responsible for its own WebKit
// processes; when it was started some other way, we fall back to "same responsible process and
// started after us", as the prototype measured it.
import Darwin
import Foundation

struct ProcessEnergyMeter {
    struct Sample { var cpuNs: Double; var energyNj: Double }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFor: ResponsibleFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                                              "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: ResponsibleFn.self) }
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    private let me = getpid()
    private let myResponsible: pid_t
    private let startupPIDs: Set<pid_t>

    init() {
        myResponsible = Self.responsibleFor?(me) ?? me
        startupPIDs = Set(Self.allPIDs())
    }

    /// This process plus every WebKit helper attributed to it.
    func ownedPIDs() -> [pid_t] {
        guard let responsible = Self.responsibleFor else { return [me] }
        let helpers = Self.allPIDs().filter { p in
            guard p != me, Self.name(of: p).hasPrefix("com.apple.WebKit") else { return false }
            let r = responsible(p)
            return r == me || (myResponsible != me && r == myResponsible && !startupPIDs.contains(p))
        }
        return [me] + helpers
    }

    /// Cumulative CPU time (user + system) and energy of `pids` (kernel rusage_info_v6 counters).
    func sample(_ pids: [pid_t]) -> Sample {
        var out = Sample(cpuNs: 0, energyNj: 0)
        for p in pids {
            var info = rusage_info_v6()
            let r = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(p, RUSAGE_INFO_V6, $0) }
            }
            guard r == 0 else { continue } // exited in between
            let ticks = Double(info.ri_user_time + info.ri_system_time)
            out.cpuNs += ticks * Double(Self.timebase.numer) / Double(Self.timebase.denom)
            out.energyNj += Double(info.ri_energy_nj)
        }
        return out
    }

    private static func allPIDs() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return n > 0 ? pids.prefix(Int(n)).filter { $0 > 0 } : []
    }

    private static func name(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
