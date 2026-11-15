// ServiceProtocols — the API surface the app (UI) and CLI program against.
// Concrete implementations live next to this file (Library/, Publish/, AI/, Install/, Render/).
// The UI may ship mocks for previews; real wiring happens in LivePaperServices.live().
import Foundation

// MARK: - Library

public struct SceneItem: Identifiable, Sendable, Equatable, Hashable {
    public var id: String { manifest.id }
    public var manifest: SceneManifest
    /// The .lpscene directory.
    public var packageURL: URL
    /// Built-in scenes ship inside the app and are read-only (clone to edit).
    public var isBuiltin: Bool
    public var thumbnailURL: URL? {
        let u = packageURL.appendingPathComponent("thumbnail.jpg")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    public init(manifest: SceneManifest, packageURL: URL, isBuiltin: Bool) {
        self.manifest = manifest; self.packageURL = packageURL; self.isBuiltin = isBuiltin
    }
    public static func == (a: SceneItem, b: SceneItem) -> Bool { a.packageURL == b.packageURL && a.manifest == b.manifest }
    public func hash(into h: inout Hasher) { h.combine(packageURL) }
}

public enum LibraryError: Error, LocalizedError, Sendable {
    case notFound(String), readOnly(String), invalid(String), exists(String)
    public var errorDescription: String? {
        switch self {
        case .notFound(let s): return "Scene not found: \(s)"
        case .readOnly(let s): return "\(s) is a built-in scene; clone it to make changes."
        case .invalid(let s): return "Invalid scene: \(s)"
        case .exists(let s): return "A scene named \(s) already exists."
        }
    }
}

/// What the library already has for a scene package someone opened (ScenePackageComparison).
public enum SceneImportMatch: Sendable, Equatable {
    /// The package is this library or built-in scene, or a copy of it with the same contents:
    /// open it rather than importing a duplicate.
    case same(SceneItem)
    /// A user scene with the package's id but different contents (an older or newer version).
    case otherVersion(SceneItem)
}

public protocol LibraryServicing: AnyObject, Sendable {
    /// Built-in + user scenes, user scenes first, each group sorted by name.
    func scenes() throws -> [SceneItem]
    func scene(id: String) throws -> SceneItem?
    /// New web scene from the runtime template (used by AI "create" before the agent fills it in).
    func createWebScene(name: String, description: String) throws -> SceneItem
    /// Copies (and optionally transcodes to HEVC for battery) a video into a new video scene.
    func importVideo(from url: URL, name: String, optimizeForBattery: Bool,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> SceneItem
    func clone(id: String, newName: String) throws -> SceneItem
    func delete(id: String) throws
    func update(_ manifest: SceneManifest) throws
    /// Replace a user scene's contents with another package (AI "modify" accept). Keeps history.
    func replaceContents(id: String, with package: URL) throws -> SceneItem
    func importPackage(at url: URL) throws -> SceneItem
    /// The scene a package to be imported already is, if any (nil: import it). Only scene
    /// packages are compared; archives and invalid packages return nil (import reports them).
    func existingScene(matching url: URL) throws -> SceneImportMatch?
    func exportPackage(id: String, to url: URL) throws
}

// MARK: - Publishing (what the screen saver shows)

public struct PlaylistSettings: Codable, Sendable, Equatable {
    public var mode: LPPlaylistMode
    public var cycleMinutes: Int
    public var showClock: Bool
    public var performance: LPPerformanceProfile
    /// Scenes in the playlist, in order. Empty = all scenes.
    public var sceneIDs: [String]
    public init(mode: LPPlaylistMode = .shuffle, cycleMinutes: Int = 5, showClock: Bool = true,
                performance: LPPerformanceProfile = .automatic, sceneIDs: [String] = []) {
        self.mode = mode; self.cycleMinutes = cycleMinutes; self.showClock = showClock; self.performance = performance; self.sceneIDs = sceneIDs
    }
}

/// Outcome of a publish, including scenes that were left out (the saver still gets the rest).
public struct PublishResult: Sendable, Equatable {
    /// One scene that couldn't be published, and why (an actionable sentence).
    public struct Skipped: Sendable, Equatable, Identifiable {
        public var id: String
        public var reason: String
        public init(id: String, reason: String) { self.id = id; self.reason = reason }
    }
    /// What the saver now plays (already written into the installed bundle).
    public var playlist: LPPlaylist
    /// Scene id → why it was skipped (compile error, missing or unsupported video, …).
    public var skipped: [String: String]
    public init(playlist: LPPlaylist, skipped: [String: String] = [:]) { self.playlist = playlist; self.skipped = skipped }

    /// `skipped` as a list, in a stable order (by id) for display.
    public var skippedScenes: [Skipped] {
        skipped.sorted { $0.key < $1.key }.map { Skipped(id: $0.key, reason: $0.value) }
    }
}

public protocol PublishServicing: AnyObject, Sendable {
    func loadSettings() -> PlaylistSettings
    func saveSettings(_ s: PlaylistSettings) throws
    /// Compiles the selected scenes and atomically swaps them into the installed saver bundle.
    /// Scenes that can't be published are skipped (and reported) as long as at least one can;
    /// otherwise it throws `PublishError` and the previously published playlist stays in place.
    @discardableResult func publishReport() throws -> PublishResult
}

public extension PublishServicing {
    /// `publishReport()` for callers that don't show skipped scenes (install, CLI scripts).
    @discardableResult func publish() throws -> LPPlaylist { try publishReport().playlist }
}

// MARK: - Rendering / validation

public protocol RenderClienting: AnyObject, Sendable {
    /// Sends one request to the RenderService (starting LivePaperRenderd if no server is listening).
    func send(_ request: RenderRequest, timeout: TimeInterval) async throws -> RenderResponse
}

public struct CheckOptions: Sendable {
    public var quick: Bool
    public var power: Bool
    public init(quick: Bool = false, power: Bool = false) { self.quick = quick; self.power = power }
}

public struct CheckReport: Codable, Sendable, Equatable {
    public struct Still: Codable, Sendable, Equatable {
        public var path: String; public var width: Int; public var height: Int; public var dpr: Double; public var t: Double
        public var meanLuma: Double?; public var clockLuma: Double?
        public init(path: String, width: Int, height: Int, dpr: Double, t: Double, meanLuma: Double? = nil, clockLuma: Double? = nil) {
            self.path = path; self.width = width; self.height = height; self.dpr = dpr; self.t = t; self.meanLuma = meanLuma; self.clockLuma = clockLuma
        }
    }
    public var passed: Bool
    /// Blocking problems (each an actionable sentence an AI agent can fix).
    public var problems: [String]
    /// Non-blocking advice.
    public var warnings: [String]
    public var jsErrors: [String]
    public var stills: [Still]
    /// "1512x982@2 t=14" → ms/frame
    public var benchMs: [String: Double]
    public var energyMw: Double?
    public var checkedAt: Date
    /// How alive the scene is, per analysed size (MotionAnalysis); nil when motion wasn't measured.
    public var motion: [MotionSummary]?
    public init(passed: Bool, problems: [String] = [], warnings: [String] = [], jsErrors: [String] = [], stills: [Still] = [],
                benchMs: [String: Double] = [:], energyMw: Double? = nil, checkedAt: Date = Date(), motion: [MotionSummary]? = nil) {
        self.passed = passed; self.problems = problems; self.warnings = warnings; self.jsErrors = jsErrors; self.stills = stills
        self.benchMs = benchMs; self.energyMw = energyMw; self.checkedAt = checkedAt; self.motion = motion
    }
}

public protocol SceneChecking: AnyObject, Sendable {
    /// Compiles + validates a scene package; writes <package>/.check/report.json and PNGs.
    func check(package: URL, options: CheckOptions) async throws -> CheckReport
}

public protocol SceneCompiling: AnyObject, Sendable {
    /// Produces one self-contained HTML file (runtime + scene.js inlined) for a web scene package.
    func compile(package: URL, to output: URL) throws
}

// MARK: - AI authoring

public struct AIHarness: Identifiable, Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable { case claude, codex, kiro, custom }
    public var id: String { kind.rawValue + ":" + executable }
    public var kind: Kind
    public var name: String
    public var executable: String
    public var version: String?
    /// For .custom: a command template, e.g. `mytool --prompt {prompt_file} --dir {workspace}`.
    public var customTemplate: String?
    public init(kind: Kind, name: String, executable: String, version: String? = nil, customTemplate: String? = nil) {
        self.kind = kind; self.name = name; self.executable = executable; self.version = version; self.customTemplate = customTemplate
    }

    /// The harness for a user-defined command template (Settings › AI › Custom command). The
    /// executable is the template's first word; placeholders are listed in `CustomAdapter.placeholders`.
    public static func custom(template: String, name: String = "Custom command") -> AIHarness {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let program = (try? CommandTemplate.tokenize(trimmed))?.first ?? trimmed
        return AIHarness(kind: .custom, name: name, executable: program, customTemplate: trimmed)
    }
}

public enum AISessionRequest: Sendable, Equatable {
    case create(prompt: String)
    case modify(sceneID: String, prompt: String)
}

public enum AISessionEvent: Sendable, Equatable {
    case status(String)                 // "Preparing workspace…", "Running claude…", "Validating…"
    case assistantText(String)          // streamed agent prose
    case toolUse(name: String, detail: String)
    case stillRendered(URL)             // a PNG the agent (or final check) produced
    case checkResult(CheckReport)
    case finished(package: URL)         // success: candidate package ready to accept
    case failed(String)
}

public protocol AISessionHandle: AnyObject, Sendable {
    var id: String { get }
    var workspace: URL { get }
    var events: AsyncStream<AISessionEvent> { get }
    func cancel()
}

/// AI preferences (Settings › AI), persisted as JSON in the support directory (`ai-settings.json`).
/// Shared by the app (which edits them) and the AI service / CLI (which use them for sessions).
public struct AISettings: Codable, Sendable, Equatable {
    public static let defaultTimeoutMinutes = 20

    /// `AIHarness.id` of the harness the user picked last.
    public var preferredHarness: String?
    /// Harness kind (`AIHarness.Kind.rawValue`) → model name. Missing = the harness's default.
    public var models: [String: String]
    /// Harness kind → extra command-line options (advanced; e.g. a cheaper reasoning effort).
    public var extraArguments: [String: [String]]
    /// The user-defined command template (`AIHarness.customTemplate`), if any.
    public var customTemplate: String?
    public var timeoutMinutes: Int

    public init(preferredHarness: String? = nil, models: [String: String] = [:], extraArguments: [String: [String]] = [:],
                customTemplate: String? = nil, timeoutMinutes: Int = AISettings.defaultTimeoutMinutes) {
        self.preferredHarness = preferredHarness; self.models = models; self.extraArguments = extraArguments
        self.customTemplate = customTemplate; self.timeoutMinutes = timeoutMinutes
    }

    // Tolerant decoding: settings written by other versions must not reset everything.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preferredHarness = try? c.decodeIfPresent(String.self, forKey: .preferredHarness)
        models = (try? c.decodeIfPresent([String: String].self, forKey: .models)) ?? [:]
        extraArguments = (try? c.decodeIfPresent([String: [String]].self, forKey: .extraArguments)) ?? [:]
        customTemplate = try? c.decodeIfPresent(String.self, forKey: .customTemplate)
        timeoutMinutes = (try? c.decodeIfPresent(Int.self, forKey: .timeoutMinutes)) ?? AISettings.defaultTimeoutMinutes
    }

    /// The session timeout, clamped to 1 minute … 4 hours.
    public var timeout: TimeInterval { TimeInterval(min(max(timeoutMinutes, 1), 240)) * 60 }

    /// The configured model for a harness kind (nil when unset or blank: the harness's default).
    public func model(for kind: AIHarness.Kind) -> String? {
        guard let m = models[kind.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty else { return nil }
        return m
    }

    /// Sets (or, with a blank name, clears) the default model of a harness kind.
    public mutating func setModel(_ name: String?, for kind: AIHarness.Kind) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        models[kind.rawValue] = trimmed.isEmpty ? nil : trimmed
    }
}

public protocol AIServicing: AnyObject, Sendable {
    /// Installed harnesses (login-shell PATH), plus the custom command when one is configured.
    func detectHarnesses() async -> [AIHarness]
    /// `model` nil = the model configured in the settings for that harness (else its default).
    func start(_ request: AISessionRequest, harness: AIHarness, model: String?) throws -> AISessionHandle
    /// The stored settings, or defaults when there are none (never throws: a damaged file reads as defaults).
    func loadSettings() -> AISettings
    func saveSettings(_ settings: AISettings) throws
}

// MARK: - Install / system integration

/// Registration state of a login item, mirroring SMAppService.Status.
public enum LoginItemStatus: String, Sendable, Equatable {
    case notRegistered
    case enabled
    /// Registered, but the user has to allow it in System Settings › General › Login Items.
    case requiresApproval
    /// The agent plist isn't in the app bundle (development builds use a LaunchAgent instead).
    case notFound
}

public struct InstallStatus: Sendable, Equatable {
    public var saverInstalled: Bool
    public var saverUpToDate: Bool
    /// The LivePaper saver is the selected screen saver (any display).
    public var saverSelected: Bool
    public var helperRunning: Bool
    /// The helper's SMAppService login item (`.notFound` when it runs from the LaunchAgent fallback).
    public var helperLoginItem: LoginItemStatus
    /// "Require password after screen saver begins" is Immediately.
    public var passwordImmediately: Bool
    /// True when a configuration profile manages any screen-saver setting (idle time, password, module).
    public var managedByMDM: Bool
    /// The password isn't required immediately *because* a configuration profile forces it off or
    /// forces a delay, so the user can't fix it in System Settings. False whenever the user can.
    public var passwordManagedByMDM: Bool
    /// `com.apple.loginwindow immediateLockLaunchesScreenSaver` is on: ⌃⌘Q, Apple menu › Lock
    /// Screen and the Touch ID / lock key start the screen saver (the scene) before locking.
    public var lockKeysShowScene: Bool
    /// LivePaper changed that preference and keeps its previous value; uninstall puts it back.
    public var lockKeysChangedByLivePaper: Bool

    public init(saverInstalled: Bool = false, saverUpToDate: Bool = false, saverSelected: Bool = false, helperRunning: Bool = false,
                helperLoginItem: LoginItemStatus = .notRegistered, passwordImmediately: Bool = false, managedByMDM: Bool = false,
                passwordManagedByMDM: Bool = false, lockKeysShowScene: Bool = false, lockKeysChangedByLivePaper: Bool = false) {
        self.saverInstalled = saverInstalled; self.saverUpToDate = saverUpToDate; self.saverSelected = saverSelected
        self.helperRunning = helperRunning; self.helperLoginItem = helperLoginItem; self.passwordImmediately = passwordImmediately
        self.managedByMDM = managedByMDM; self.passwordManagedByMDM = passwordManagedByMDM; self.lockKeysShowScene = lockKeysShowScene
        self.lockKeysChangedByLivePaper = lockKeysChangedByLivePaper
    }
}

/// One logged installer step (what the uninstall sheet and `livepaper doctor` show).
public struct InstallStep: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case done
        /// Dry run: would have been done.
        case planned
        /// Nothing to do (already in the desired state).
        case skipped(String)
        case failed(String)
    }
    public var title: String
    public var outcome: Outcome
    public init(title: String, outcome: Outcome) { self.title = title; self.outcome = outcome }

    public var isFailure: Bool { if case .failed = outcome { return true }; return false }
}

public protocol InstallServicing: AnyObject, Sendable {
    /// Blocking (runs read-only system probes): call it off the main thread.
    func status() -> InstallStatus
    /// Copies the saver template into ~/Library/Screen Savers (idempotent) and publishes content.
    func installSaver() throws
    /// Makes LivePaper the selected screen saver. Returns false if it could not be done automatically
    /// (the UI then shows the one-click guided step via openScreenSaverSettings()).
    func selectSaver() throws -> Bool
    func registerHelper() throws
    func unregisterHelper() throws
    /// Turns the lock-keys takeover on or off (`immediateLockLaunchesScreenSaver`). The value from
    /// before LivePaper's first change is backed up; uninstall restores it.
    func setLockKeysShowScene(_ on: Bool) throws
    func openScreenSaverSettings()
    /// Runs every uninstall step — helper, previous screen saver, changed preferences (including
    /// the lock keys), the saver bundle, LivePaper's data (optionally the library) — continuing past
    /// failures, and returns the step log. Running it again retries what failed.
    @discardableResult func performUninstall(removeLibrary: Bool) -> [InstallStep]
}

public extension InstallServicing {
    /// `performUninstall` that throws `InstallError.uninstallIncomplete` if any step failed.
    func uninstall(removeLibrary: Bool) throws {
        let failed = performUninstall(removeLibrary: removeLibrary).compactMap { step -> String? in
            if case .failed(let why) = step.outcome { return "\(step.title): \(why)" }
            return nil
        }
        if !failed.isEmpty { throw InstallError.uninstallIncomplete(failed) }
    }
}
