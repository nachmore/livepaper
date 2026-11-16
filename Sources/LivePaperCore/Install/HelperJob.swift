// HelperJob — what launchd says about the helper's job (`launchctl print gui/<uid>/<label>`), what
// actually runs in it, and what LivePaper does about it (ARCHITECTURE §7, docs/RESEARCH.md §6). Pure:
// parsed from text and decided from values, so it is tested with recorded output; InstallService
// runs the commands and asks the system about the processes (HelperProbe).
//
// The case this exists for (verified on macOS 26.7 with ad-hoc-signed builds): launchd keeps the
// code requirement it recorded when the login item was registered — for ad-hoc code the helper's
// cdhash, which changes with every build that changes the helper. After an update its "repair" can
// leave the job pointing at a background-item record that no longer exists: every spawn then fails
// ("job state = spawn failed", "last exit code = 78: EX_CONFIG", "needs LWCR update") while
// SMAppService still reports the login item as enabled. Only registering it again (unregister, then
// register — as SMAppService.h asks for after the executable changed) gets launchd a job for the
// current helper.
//
// Registering again isn't free: it ends the running helper, and every new registration makes macOS
// post "“LivePaper” can run in the background" (docs/RESEARCH.md §6.1). So it is only done on
// positive evidence that launchd can't run this build's helper: the failure signs above, launchd not
// having the job at all (exit 113), or a running helper whose code is no longer this copy's and that
// launchd wouldn't start again as it is. `launchctl print` is "NOT API" (man launchctl): text
// LivePaper can't read, a timeout or another error changes nothing, and a running helper is checked
// through its process, not only through launchctl's words.
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

    /// What launchd's text says. InstallService also counts a job whose `pid` is a live process as
    /// running (RunningHelper), whatever `state` says.
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

/// What `launchctl print gui/<uid>/<label>` answered.
public enum LaunchdLookup: Sendable, Equatable {
    /// launchd has the job (its parsed output).
    case loaded(LaunchdJob)
    /// launchd doesn't have it: exit status 113 ("Could not find service …").
    case notFound
    /// No answer LivePaper acts on — a timeout, another exit status, launchctl not running — and why.
    case unknown(String)

    /// launchctl's exit status for a service the domain doesn't have (verified on macOS 26).
    public static let notFoundStatus: Int32 = 113

    /// From the result of `launchctl print` (nil: it couldn't be run).
    public static func from(_ result: CommandResult?) -> LaunchdLookup {
        guard let result else { return .unknown("launchctl couldn't be run") }
        if result.timedOut { return .unknown("launchctl print timed out") }
        if result.succeeded { return .loaded(LaunchdJob.parse(result.stdout)) }
        if result.status == notFoundStatus { return .notFound }
        let detail = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return .unknown("launchctl print exited \(result.status)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    public var job: LaunchdJob? { if case .loaded(let job) = self { return job }; return nil }
}

/// A code signature, as LivePaper compares helpers by it (Security framework; HelperProbe).
public struct CodeSignature: Codable, Sendable, Equatable {
    /// The code directory hash, in hex (`codesign -dvvv`'s CDHash).
    public var cdhash: String
    /// The Team ID; nil for ad-hoc-signed code.
    public var teamID: String?

    public init(cdhash: String, teamID: String? = nil) { self.cdhash = cdhash; self.teamID = teamID }

    public var isAdHoc: Bool { teamID == nil }

    /// launchd would start `other` under the requirement it recorded for this code: for ad-hoc code
    /// that is its cdhash (docs/RESEARCH.md §6, Verified), for code with a Team ID the team
    /// (Inferred).
    public func passesRecordedRequirement(of other: CodeSignature) -> Bool {
        isAdHoc ? other.cdhash == cdhash : other.teamID == teamID
    }
}

/// The process in a running helper job, as LivePaper checked it itself (HelperProbe: proc_pidpath and
/// SecCodeCheckValidity) — never only from launchctl's text.
public struct RunningHelper: Sendable, Equatable {
    public enum Code: Sendable, Equatable {
        /// This copy's helper, and still the code on disk.
        case current
        /// This copy's helper, but the file there is other code now (errSecCSStaticCodeChanged): the
        /// app was replaced while it ran.
        case replaced
        /// Its executable is gone — deleted, or in the Trash with the app it came from (the path,
        /// when known): an app that was replaced or removed while it ran.
        case gone(String?)
        /// The helper of another copy of LivePaper that is still in place (that copy's path).
        case otherCopy(String)
        /// LivePaper couldn't tell.
        case unknown
    }

    /// nil when launchctl's text says it runs but shows no pid.
    public var pid: Int32?
    public var code: Code

    public init(pid: Int32?, code: Code) { self.pid = pid; self.code = code }
}

/// Which copy of LivePaper the helper's registration belongs to.
public enum HelperRegistration: Sendable, Equatable {
    /// This copy: the login item's record names it (HelperRegistrationRecord, nil for the fallback),
    /// or the fallback's plist runs this copy's helper.
    case thisCopy(HelperRegistrationRecord?)
    /// Another copy that is still in place (its path).
    case otherCopy(String)
    /// Not known: registered before LivePaper kept a record, or by a copy that is gone.
    case unknown
}

/// What LivePaper registered as the helper's login item (Application Support/LivePaper/
/// helper-registration.json): which copy of the app, and its helper's signature at the time.
/// Written after every registration. `pendingSince` is set right before LivePaper unregisters the item
/// to register it again and cleared once registering worked, so a launch after a re-registration that
/// failed half-way registers it again instead of taking the helper for "not set up". Removed with the
/// login item (unregisterHelper, uninstall).
public struct HelperRegistrationRecord: Codable, Sendable, Equatable {
    /// The app bundle that registered it.
    public var app: String
    /// Its CFBundleVersion.
    public var build: String?
    /// Its helper's signature when it registered (what launchd recorded the requirement from).
    public var helper: CodeSignature?
    public var registeredAt: Date?
    /// LivePaper unregistered the item to register it again, and hasn't since.
    public var pendingSince: Date?

    public init(app: String, build: String? = nil, helper: CodeSignature? = nil, registeredAt: Date? = nil, pendingSince: Date? = nil) {
        self.app = app; self.build = build; self.helper = helper; self.registeredAt = registeredAt; self.pendingSince = pendingSince
    }
}

/// What the helper's job needs, and what to report about it (InstallStatus.helperProblem).
public struct HelperJobAssessment: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// Nothing to do, and why (it runs this build's helper, another copy's, launchd didn't answer, …).
        case leave(String)
        /// Loaded and stopped, and launchd should accept this build's helper: start it
        /// (`launchctl kickstart`; InstallService registers it again only if launchd then reports it
        /// can't start it).
        case start
        /// Running an older helper (or one whose executable is now in the Trash) that launchd starts
        /// this build's in place of — the requirement recorded at registration covers this build's
        /// helper: the same Team ID, or for ad-hoc code the same cdhash (an update that left the
        /// helper unchanged, e.g. Finder's Replace, which moved the old app and its running helper's
        /// file to the Trash): `launchctl kickstart -k`, registering again only if launchd then
        /// refuses it or starts the old copy's again.
        case restart
        /// Register again — the login item (unregister, then register), or the fallback plist
        /// (written again and bootstrapped) — for the reason given.
        case reregister(String)
    }

    public var problem: HelperProblem?
    public var action: Action

    public init(problem: HelperProblem?, action: Action) { self.problem = problem; self.action = action }

    static let runsThisBuild = "it runs this build's helper"

    /// The login item's job (SMAppService).
    /// - Parameters:
    ///   - lookup: `launchctl print` of the job.
    ///   - running: its live process (nil: none).
    ///   - appBuild: CFBundleVersion of this copy (nil: unknown).
    ///   - helper: the signature of this copy's helper on disk (nil: couldn't be read).
    ///   - registration: which copy registered the login item.
    public static func assessLoginItem(_ lookup: LaunchdLookup, running: RunningHelper?, appBuild: String?, helper: CodeSignature?,
                                       registration: HelperRegistration) -> HelperJobAssessment {
        let job: LaunchdJob
        switch lookup {
        case .unknown(let why): return HelperJobAssessment(problem: nil, action: .leave("launchd's answer can't be used (\(why))"))
        case .notFound: return HelperJobAssessment(problem: .notLoaded, action: .reregister("launchd doesn't have its job"))
        case .loaded(let loaded): job = loaded
        }
        if let running {
            switch running.code {
            case .current: return HelperJobAssessment(problem: nil, action: .leave(runsThisBuild))
            case .unknown: return HelperJobAssessment(problem: nil, action: .leave("it runs; LivePaper can't tell which build"))
            case .otherCopy(let app):
                return HelperJobAssessment(problem: .otherCopy(app), action: .leave("it runs the helper of the LivePaper at \(app)"))
            case .replaced, .gone:
                let detail = outdatedDetail(running.code)
                guard let helper else {
                    // Registering a helper whose signature can't be read would likely fail, and the old one works.
                    return HelperJobAssessment(problem: .outdated(detail), action: .leave("this LivePaper's helper signature can't be read"))
                }
                // launchd starts this copy's helper under the recorded requirement: a restart is
                // enough (no unregister, no new "can run in the background" alert) — for ad-hoc code
                // when the helper on disk is the one registered (the same cdhash).
                if case .thisCopy(let record?) = registration, let recorded = record.helper, recorded.passesRecordedRequirement(of: helper) {
                    return HelperJobAssessment(problem: .outdated(detail), action: .restart)
                }
                return HelperJobAssessment(problem: .outdated(detail), action: .reregister("it runs an older build: \(detail)"))
            }
        }
        if let why = job.cannotStartReason {
            return HelperJobAssessment(problem: .cannotStart(why), action: .reregister("launchd can't start it: \(why)"))
        }
        // Stopped (quit, or exited). Starting it is right when launchd should accept this build's
        // helper; one it would refuse is registered again instead — that refused launch is what sets
        // off launchd's repair, which can break the job for good.
        switch registration {
        case .thisCopy(let record?):
            if let recorded = record.helper, let helper, !recorded.passesRecordedRequirement(of: helper) {
                let by = record.build.map { "build \($0)" } ?? "an earlier build"
                return HelperJobAssessment(problem: .stopped,
                                           action: .reregister("this LivePaper's helper changed since \(by) registered it"))
            }
            return HelperJobAssessment(problem: .stopped, action: .start)
        case .otherCopy:
            // That copy's job starts that copy's helper.
            return HelperJobAssessment(problem: .stopped, action: .start)
        case .thisCopy(nil), .unknown:
            // Registered before LivePaper kept a record: only the registering build is known.
            if let registered = job.parentBundleVersion, InstallService.isNewerBuild(appBuild, than: registered) {
                return HelperJobAssessment(problem: .stopped,
                                           action: .reregister("registered by build \(registered); this LivePaper is build \(appBuild ?? "?")"))
            }
            return HelperJobAssessment(problem: .stopped, action: .start)
        }
    }

    /// The LaunchAgent fallback's job (a plain plist; launchd starts whatever it names).
    /// - Parameter registration: which copy the plist's program belongs to.
    public static func assessFallback(_ lookup: LaunchdLookup, running: RunningHelper?, registration: HelperRegistration) -> HelperJobAssessment {
        let job: LaunchdJob?
        switch lookup {
        case .unknown(let why): return HelperJobAssessment(problem: nil, action: .leave("launchd's answer can't be used (\(why))"))
        case .notFound: job = nil
        case .loaded(let loaded): job = loaded
        }
        if let running {
            switch running.code {
            case .current: return HelperJobAssessment(problem: nil, action: .leave(runsThisBuild))
            case .unknown: return HelperJobAssessment(problem: nil, action: .leave("it runs; LivePaper can't tell which build"))
            case .otherCopy(let app):
                return HelperJobAssessment(problem: .otherCopy(app), action: .leave("it runs the helper of the LivePaper at \(app)"))
            case .replaced, .gone:
                let detail = outdatedDetail(running.code)
                return HelperJobAssessment(problem: .outdated(detail), action: .reregister("it runs an older build: \(detail)"))
            }
        }
        let problem: HelperProblem = job == nil ? .notLoaded : job?.cannotStartReason.map(HelperProblem.cannotStart) ?? .stopped
        if case .otherCopy(let app) = registration {
            // Rewriting the plist would move the helper to this copy: only on the user's request.
            return HelperJobAssessment(problem: problem, action: .leave("its plist runs the helper of the LivePaper at \(app)"))
        }
        return HelperJobAssessment(problem: problem, action: .reregister(problem.summary))
    }

    private static func outdatedDetail(_ code: RunningHelper.Code) -> String {
        switch code {
        case .gone(let path?): return "its executable is gone (\(path))"
        case .gone(nil): return "its executable is gone"
        default: return "this LivePaper's helper was replaced while it ran"
        }
    }
}
