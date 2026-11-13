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

public protocol PublishServicing: AnyObject, Sendable {
    func loadSettings() -> PlaylistSettings
    func saveSettings(_ s: PlaylistSettings) throws
    /// Compiles the selected scenes and atomically swaps them into the installed saver bundle.
    @discardableResult func publish() throws -> LPPlaylist
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
    public init(passed: Bool, problems: [String] = [], warnings: [String] = [], jsErrors: [String] = [], stills: [Still] = [],
                benchMs: [String: Double] = [:], energyMw: Double? = nil, checkedAt: Date = Date()) {
        self.passed = passed; self.problems = problems; self.warnings = warnings; self.jsErrors = jsErrors; self.stills = stills
        self.benchMs = benchMs; self.energyMw = energyMw; self.checkedAt = checkedAt
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

public protocol AIServicing: AnyObject, Sendable {
    func detectHarnesses() async -> [AIHarness]
    func start(_ request: AISessionRequest, harness: AIHarness, model: String?) throws -> AISessionHandle
}

// MARK: - Install / system integration

public struct InstallStatus: Sendable, Equatable {
    public var saverInstalled: Bool
    public var saverUpToDate: Bool
    /// The LivePaper saver is the selected screen saver (any display).
    public var saverSelected: Bool
    public var helperRunning: Bool
    /// "Require password after screen saver begins" is Immediately.
    public var passwordImmediately: Bool
    public var accessibilityTrusted: Bool
    /// True when idle time / password settings are enforced by a configuration profile.
    public var managedByMDM: Bool
    public init(saverInstalled: Bool = false, saverUpToDate: Bool = false, saverSelected: Bool = false, helperRunning: Bool = false,
                passwordImmediately: Bool = false, accessibilityTrusted: Bool = false, managedByMDM: Bool = false) {
        self.saverInstalled = saverInstalled; self.saverUpToDate = saverUpToDate; self.saverSelected = saverSelected
        self.helperRunning = helperRunning; self.passwordImmediately = passwordImmediately
        self.accessibilityTrusted = accessibilityTrusted; self.managedByMDM = managedByMDM
    }
}

public protocol InstallServicing: AnyObject, Sendable {
    func status() -> InstallStatus
    /// Copies the saver template into ~/Library/Screen Savers (idempotent) and publishes content.
    func installSaver() throws
    /// Makes LivePaper the selected screen saver. Returns false if it could not be done automatically
    /// (the UI then shows the one-click guided step via openScreenSaverSettings()).
    func selectSaver() throws -> Bool
    func registerHelper() throws
    func unregisterHelper() throws
    func openScreenSaverSettings()
    func openAccessibilitySettings()
    /// Removes helper + saver, restores backed-up settings, optionally deletes the library.
    func uninstall(removeLibrary: Bool) throws
}
