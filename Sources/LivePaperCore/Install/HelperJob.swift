// HelperJob — what launchd says about the helper's job (`launchctl print gui/<uid>/<label>`) and
// what LivePaper does about it (ARCHITECTURE §7, docs/RESEARCH.md §6). Pure: parsed from text and
// decided from values, so it is tested with recorded output; InstallService runs the commands.
//
// The case this exists for (verified on macOS 26.7 with ad-hoc-signed builds): launchd keeps the
// code requirement it recorded when the login item was registered — for ad-hoc code the helper's
// cdhash, which changes with every build. After an update its "repair" can leave the job pointing
// at a background-item record that no longer exists: every spawn then fails ("job state = spawn
// failed", "last exit code = 78: EX_CONFIG", "needs LWCR update") while SMAppService still reports
// the login item as enabled. Only registering it again (unregister, then register — as
// SMAppService.h asks for after the executable changed) gets launchd a job for the current helper.
import Foundation

/// The parts of `launchctl print` LivePaper looks at: the job's top-level keys (one tab deep;
/// nested blocks such as the environment, semaphores or coalitions are skipped).
public struct LaunchdJob: Sendable, Equatable {
    /// `state`: "running", "not running", "spawn scheduled", …
    public var state: String?
    /// `job state`: "running", "spawn failed", …
    public var jobState: String?
    public var pid: Int32?
    /// `last exit code`, e.g. "78: EX_CONFIG", "0" or "(never exited)".
    public var lastExit: String?
    /// `runs`: how often launchd tried to start it.
    public var runs: Int?
    /// `parent bundle version`: the CFBundleVersion of the app that registered an SMAppService job
    /// (it stays the registering build's across app updates until the item is registered again).
    public var parentBundleVersion: String?
    /// `program` (a plain plist's absolute path) or `program identifier` (SMAppService's
    /// BundleProgram, relative to the app), without launchd's " (mode: …)" suffix.
    public var program: String?
    /// `properties`, split at " | " (e.g. "needs LWCR update", "has LWCR").
    public var properties: [String]
    /// `managed_by` ("com.apple.xpc.ServiceManagement" for SMAppService jobs).
    public var managedBy: String?
    /// launchd mentions a code-signing exit (a launch-constraint violation) anywhere in the output.
    public var codeSigningFailure: Bool

    public init(state: String? = nil, jobState: String? = nil, pid: Int32? = nil, lastExit: String? = nil, runs: Int? = nil,
                parentBundleVersion: String? = nil, program: String? = nil, properties: [String] = [], managedBy: String? = nil,
                codeSigningFailure: Bool = false) {
        self.state = state; self.jobState = jobState; self.pid = pid; self.lastExit = lastExit; self.runs = runs
        self.parentBundleVersion = parentBundleVersion; self.program = program; self.properties = properties
        self.managedBy = managedBy; self.codeSigningFailure = codeSigningFailure
    }

    /// Parses the output of a successful `launchctl print gui/<uid>/<label>`.
    public static func parse(_ text: String) -> LaunchdJob {
        var fields: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            guard raw.hasPrefix("\t"), !raw.hasPrefix("\t\t"), let eq = raw.range(of: " = ") else { continue }
            let key = raw[raw.startIndex..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = raw[eq.upperBound...].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { fields[key] = value }
        }
        var program = fields["program"] ?? fields["program identifier"]
        if let p = program, let mode = p.range(of: " (mode: ", options: .backwards) { program = String(p[..<mode.lowerBound]) }
        let properties = (fields["properties"] ?? "").components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return LaunchdJob(state: fields["state"], jobState: fields["job state"], pid: fields["pid"].flatMap { Int32($0) },
                          lastExit: fields["last exit code"], runs: fields["runs"].flatMap { Int($0) },
                          parentBundleVersion: fields["parent bundle version"], program: program, properties: properties,
                          managedBy: fields["managed_by"],
                          codeSigningFailure: text.contains("OS_REASON_CODESIGNING") || text.contains("Launch Constraint Violation"))
    }

    public var isRunning: Bool { state == "running" }

    /// The number in `last exit code` ("78: EX_CONFIG" → 78); nil for "(never exited)".
    public var lastExitCode: Int? {
        guard let lastExit else { return nil }
        return Int(lastExit.prefix { $0 != ":" }.trimmingCharacters(in: .whitespaces))
    }

    /// Why launchd can't start the job, from what it reports (nil while it runs, or when nothing
    /// says so — e.g. it exited cleanly after being quit).
    public var cannotStartReason: String? {
        guard !isRunning else { return nil }
        var signs: [String] = []
        if jobState == "spawn failed" { signs.append("spawn failed") }
        // EX_CONFIG: xpcproxy couldn't set the job up (the helper itself never exits with it).
        if lastExitCode == 78, let lastExit { signs.append("last exit code \(lastExit)") }
        if properties.contains("needs LWCR update") { signs.append("needs LWCR update") }
        if codeSigningFailure { signs.append("launch constraint violation") }
        return signs.isEmpty ? nil : signs.joined(separator: ", ")
    }
}

/// What the helper's job needs, and what to report about it (InstallStatus.helperProblem).
public struct HelperJobAssessment: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// It runs this build's helper.
        case none
        /// Loaded and stopped, and nothing says the registration is stale: start it
        /// (`launchctl kickstart`; InstallService still registers again if it then can't start).
        case start
        /// Register again — the login item (unregister, then register), or the fallback plist
        /// (written again and bootstrapped) — for the reason given.
        case reregister(String)
    }

    public var problem: HelperProblem?
    public var action: Action

    public init(problem: HelperProblem?, action: Action) { self.problem = problem; self.action = action }

    /// - Parameters:
    ///   - job: the parsed `launchctl print` of the job in use; nil when launchd doesn't have it.
    ///   - appBuild: CFBundleVersion of the app whose helper should run (nil: unknown).
    ///   - expectedProgram: for a plain plist (the fallback), the helper it should run; a job
    ///     running anything else is the wrong build. nil for SMAppService jobs (relative paths).
    ///   - helperReplacedSinceStart: the helper file on disk was put in place after the running
    ///     process started, so that process runs an older build.
    public static func assess(_ job: LaunchdJob?, appBuild: String?, expectedProgram: String? = nil,
                              helperReplacedSinceStart: Bool) -> HelperJobAssessment {
        guard let job else { return HelperJobAssessment(problem: .notLoaded, action: .reregister("launchd doesn't have its job loaded")) }
        let otherProgram: String? = {
            guard let expected = expectedProgram, let program = job.program, program.hasPrefix("/"), program != expected else { return nil }
            return program
        }()
        if job.isRunning {
            if let otherProgram {
                return outdated("it runs \(otherProgram), not \(expectedProgram ?? "this LivePaper's helper")")
            }
            if helperReplacedSinceStart { return outdated("it started before this LivePaper's helper was installed") }
            return HelperJobAssessment(problem: nil, action: .none)
        }
        if let why = job.cannotStartReason {
            return HelperJobAssessment(problem: .cannotStart(why), action: .reregister("launchd can't start it: \(why)"))
        }
        if let otherProgram { return HelperJobAssessment(problem: .stopped, action: .reregister("its job runs \(otherProgram)")) }
        // Starting an ad-hoc-signed job registered by another build only gets the launch refused
        // (and sets off launchd's repair, which can break the job for good): register it again.
        if let registered = job.parentBundleVersion, InstallService.isNewerBuild(appBuild, than: registered) {
            return HelperJobAssessment(problem: .stopped,
                                       action: .reregister("registered by build \(registered); this LivePaper is build \(appBuild ?? "?")"))
        }
        return HelperJobAssessment(problem: .stopped, action: .start)
    }

    private static func outdated(_ detail: String) -> HelperJobAssessment {
        HelperJobAssessment(problem: .outdated(detail), action: .reregister("it runs an older build: \(detail)"))
    }
}
