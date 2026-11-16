// HelperReport — what `LivePaperHelper --print-config` prints (JSON) and `--self-check` summarises.
// `livepaper doctor` runs the bundled helper with --print-config and reads this.
//
// JSON contract (schema 1; keys are sorted, absent optional values mean "unknown"):
//   schema             1
//   helper             {executable, label, subsystem, version?, agentRunning, agentPID?, carbonConstantsMatch}
//   state              {file, exists, source: stateFile|fallback|defaults|previous, problems[]}
//   hotkey             {enabled, registrable, display?, keyCode?, modifiers[], carbonKeyCode?, carbonModifiers?, problem?}
//   app                {source: enclosingBundle|bundleIdentifier|notFound, path?, version?}
//   screenSaver        {engine, engineExists, running}
//   password           {requirement: immediate|delayed|off|unknown, source, delaySeconds?, warning?}
//   systemLockTakeover com.apple.loginwindow immediateLockLaunchesScreenSaver (absent = not set)
//   preSleep           {enabled, appliesOn[], status, now, powerSource?, displaySleepSeconds{battery|ac|ups},
//                       screenSaverIdleSeconds?, screenSaverIdleSource?, leadSeconds, preventedBy[]}
//                      "show your scene when the screens turn off first" (LPPreSleepPolicy); `now` is the
//                      decision with the session taken as unlocked
//   notifications      distributed notifications the agent observes
//   problems[]         things that are broken (--self-check exits 1 when non-empty)
//   warnings[]         things that work but not as the user probably expects
//
// Pure logic (Foundation + LivePaperCore), also compiled into LivePaperSelfTest.
import Foundation
import LivePaperCore

struct HelperReport: Codable, Equatable, Sendable {
    struct Helper: Codable, Equatable, Sendable {
        var executable: String
        var label: String
        var subsystem: String
        /// The enclosing app's CFBundleShortVersionString.
        var version: String?
        var agentRunning: Bool
        var agentPID: Int32?
        /// The Carbon modifier bits mirrored in HelperHotkeyMapping equal Carbon.HIToolbox's.
        var carbonConstantsMatch: Bool
    }
    struct State: Codable, Equatable, Sendable {
        var file: String
        var exists: Bool
        var source: HelperLockConfig.Source
        var problems: [String]
    }
    struct Hotkey: Codable, Equatable, Sendable {
        /// A shortcut is configured.
        var enabled: Bool
        /// …and the helper would register it.
        var registrable: Bool
        var display: String?
        var keyCode: Int?
        var modifiers: [String]
        var carbonKeyCode: UInt32?
        var carbonModifiers: UInt32?
        var problem: String?
    }
    struct App: Codable, Equatable, Sendable {
        var source: HelperAppLocation.Source
        var path: String?
        var version: String?
    }
    struct ScreenSaver: Codable, Equatable, Sendable {
        var engine: String
        var engineExists: Bool
        var running: Bool
    }
    struct Password: Codable, Equatable, Sendable {
        var requirement: HelperPasswordPolicy.Requirement
        var source: HelperPasswordPolicy.Source
        var delaySeconds: Int?
        var warning: String?
    }
    struct PreSleep: Codable, Equatable, Sendable {
        /// state.json `lock.showSceneBeforeDisplaySleep`.
        var enabled: Bool
        /// The power sources on which the screens turn off before the screen saver starts.
        var appliesOn: [LPPowerSource]
        /// Settings › Lock's status line (LPPreSleepStatus).
        var status: String
        /// What the agent would do right now if the session is unlocked: "watching: …",
        /// "blocked: …" or "inactive: …" (LPPreSleepPolicy.decide).
        var now: String
        var powerSource: LPPowerSource?
        /// Per power source; 0 = never. Missing = unknown.
        var displaySleepSeconds: [LPPowerSource: Int]
        var screenSaverIdleSeconds: Int?
        var screenSaverIdleSource: LPScreenSaverIdle.Source?
        /// How long before the displays would dim the screen saver starts (LPPreSleepSchedule.lead).
        var leadSeconds: Double
        /// Assertions keeping the displays on right now.
        var preventedBy: [String]
    }

    static let currentSchema = 1

    var schema: Int
    var helper: Helper
    var state: State
    var hotkey: Hotkey
    var app: App
    var screenSaver: ScreenSaver
    var password: Password
    var systemLockTakeover: Bool?
    var preSleep: PreSleep
    var notifications: [String]
    var problems: [String]
    var warnings: [String]

    /// Everything the report is built from (gathered by HelperSystem, or faked in tests).
    struct Inputs: Sendable {
        var executable: URL
        var stateFile: URL
        var stateExists: Bool
        var config: HelperLockConfig
        var app: HelperAppLocation
        var appVersion: String?
        var engineExists: Bool
        var screenSaverRunning: Bool
        var password: HelperPasswordPolicy
        var systemLockTakeover: Bool?
        var carbonConstantsMatch: Bool
        var agentPID: Int32?
        var screenTimers: LPScreenTimers = LPScreenTimers()
        /// nil: couldn't be read.
        var assertions: LPPowerAssertions? = nil
    }

    /// The notifications the agent observes (all distributed).
    static let observedNotifications = [LPNotification.stateChanged, LPNotification.hotkeyRecording,
                                        LPNotification.lockNow, LPNotification.openApp]

    init(_ inputs: Inputs) {
        var problems: [String] = []
        var warnings: [String] = []

        if !inputs.carbonConstantsMatch {
            problems.append("The helper's Carbon modifier constants don't match Carbon.HIToolbox; hotkeys would use the wrong modifiers.")
        }
        if !inputs.engineExists {
            problems.append("\(HelperProcesses.screenSaverEngineApp.path) is missing; the LivePaper lock can't start the screen saver.")
        }
        // A file that didn't decode normally is a problem only when it couldn't be read at all.
        if inputs.config.source == .previous || (inputs.stateExists && inputs.config.source == .defaults) {
            problems.append(contentsOf: inputs.config.problems)
        } else {
            warnings.append(contentsOf: inputs.config.problems)
        }

        var hotkey = Hotkey(enabled: inputs.config.hotkey != nil, registrable: false, modifiers: [])
        if let key = inputs.config.hotkey {
            hotkey.display = key.displayString
            hotkey.keyCode = Int(key.keyCode)
            hotkey.modifiers = key.modifiers.map(\.rawValue)
            switch HelperHotkeyMapping.carbon(for: key) {
            case .success(let carbon):
                hotkey.registrable = true
                hotkey.carbonKeyCode = carbon.keyCode
                hotkey.carbonModifiers = carbon.modifiers
            case .failure(let problem):
                hotkey.problem = problem.description
                problems.append("The lock shortcut isn't registered: \(problem.description).")
            }
        }

        if inputs.app.source == .notFound {
            warnings.append("The LivePaper app wasn't found; the screen saver's \"Open LivePaper…\" button won't open it.")
        }
        if let warning = inputs.password.warning { warnings.append(warning) }
        if inputs.agentPID == nil {
            warnings.append("The helper agent isn't running; the lock shortcut and \"Open LivePaper…\" don't work until it is.")
        }

        schema = Self.currentSchema
        helper = Helper(executable: inputs.executable.path, label: LPPaths.helperLabel, subsystem: LPPaths.bundleID,
                        version: inputs.appVersion, agentRunning: inputs.agentPID != nil, agentPID: inputs.agentPID,
                        carbonConstantsMatch: inputs.carbonConstantsMatch)
        state = State(file: inputs.stateFile.path, exists: inputs.stateExists, source: inputs.config.source,
                      problems: inputs.config.problems)
        self.hotkey = hotkey
        app = App(source: inputs.app.source, path: inputs.app.url?.path, version: inputs.appVersion)
        screenSaver = ScreenSaver(engine: HelperProcesses.screenSaverEngineApp.path, engineExists: inputs.engineExists,
                                  running: inputs.screenSaverRunning)
        password = Password(requirement: inputs.password.requirement, source: inputs.password.source,
                            delaySeconds: inputs.password.delaySeconds, warning: inputs.password.warning)
        systemLockTakeover = inputs.systemLockTakeover
        preSleep = Self.preSleep(inputs)
        notifications = Self.observedNotifications
        self.problems = problems
        self.warnings = warnings
    }

    static func preSleep(_ inputs: Inputs) -> PreSleep {
        let timers = inputs.screenTimers
        let situation = LPPreSleepSituation(enabled: inputs.config.showSceneBeforeDisplaySleep,
                                            passwordImmediately: inputs.password.immediately, timers: timers,
                                            screenSaverRunning: inputs.screenSaverRunning,
                                            assertions: inputs.assertions ?? LPPowerAssertions())
        let now: String
        switch LPPreSleepPolicy.decide(situation) {
        case .watch(let displaySleep, let idle):
            now = "watching: screens off after \(displaySleep) s, screen saver after \(idle == 0 ? "never" : "\(idle) s"); " +
                  "starts the screen saver \(Int(LPPreSleepSchedule.lead)) s before the screens dim"
        case .blocked(let why): now = "blocked: \(why)"
        case .inactive(let why): now = "inactive: \(why)"
        }
        return PreSleep(enabled: situation.enabled, appliesOn: LPPreSleepStatus.applicableSources(timers),
                        status: LPPreSleepStatus.text(passwordImmediately: situation.passwordImmediately, timers: timers),
                        now: now, powerSource: timers.currentSource, displaySleepSeconds: timers.displaySleep,
                        screenSaverIdleSeconds: timers.screenSaverIdle?.seconds, screenSaverIdleSource: timers.screenSaverIdle?.source,
                        leadSeconds: LPPreSleepSchedule.lead, preventedBy: inputs.assertions?.preventingDisplaySleep ?? [])
    }

    /// Pretty, key-sorted JSON (stable for diffing and for `livepaper doctor`).
    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// The `--self-check` text.
    var summary: String {
        var lines: [String] = []
        let shortcut = hotkey.display.map { hotkey.registrable ? $0 : "\($0) (not registrable)" } ?? "off"
        lines.append("LivePaper helper \(helper.version ?? "(unbundled build)")")
        lines.append("  agent:        \(helper.agentPID.map { "running (pid \($0))" } ?? "not running")")
        lines.append("  state:        \(state.exists ? state.file : "\(state.file) (not created yet)") [\(state.source.rawValue)]")
        lines.append("  shortcut:     \(shortcut)")
        lines.append("  app:          \(app.path ?? "not found") [\(app.source.rawValue)]")
        lines.append("  saver engine: \(screenSaver.engineExists ? "present" : "MISSING")\(screenSaver.running ? ", running" : "")")
        lines.append("  password:     \(password.requirement.rawValue)\(password.delaySeconds.map { " (\($0) s)" } ?? "") [\(password.source.rawValue)]")
        lines.append("  lock takeover (immediateLockLaunchesScreenSaver): \(systemLockTakeover.map { $0 ? "on" : "off" } ?? "not set")")
        lines.append("  before screens off: \(preSleep.enabled ? "on" : "off") — \(preSleep.status) [\(preSleep.now)]")
        for problem in problems { lines.append("problem: \(problem)") }
        for warning in warnings { lines.append("warning: \(warning)") }
        lines.append(problems.isEmpty ? "ok" : "\(problems.count) problem(s)")
        return lines.joined(separator: "\n")
    }
}
