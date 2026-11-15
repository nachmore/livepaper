// AppModel — the single source of truth for the app's UI state. All data goes through the service
// protocols (ServiceProtocols.swift); blocking service calls run off the main actor and report
// failures as banners with recovery actions.
//
// Foundation + Observation only: AppKit side effects (panels, Finder, locking) live in
// Entry/SystemActions.swift. That keeps this file compilable into LivePaperSelfTest (via
// Sources/LivePaperSelfTest/AppLogic/) where its state transitions are tested against the mocks.
import Foundation
import Observation
import LivePaperCore

/// Process-level facts the model needs, injectable for tests.
struct AppEnvironment {
    var isMock: Bool
    var defaults: PreferenceStore
    var stateURL: URL
    /// Persists state.json (the live implementation also notifies the helper).
    var saveState: (LPSharedState) throws -> Void
    /// "Lock Now" asks the helper first (LPNotification.lockNow) …
    var helperLock: HelperLockChannel
    /// … and starts ScreenSaverEngine itself when no helper answers (AppKit; Entry/SystemActions).
    var startScreenSaver: @MainActor () async throws -> Void
    /// Where compiled preview HTML is cached.
    var previewCacheDirectory: URL
    var appVersion: String
    /// The running .app bundle, or nil when not running from one (`swift run`, tests).
    var appBundlePath: String?

    static let onboardingCompletedKey = "onboardingCompleted"
}

/// Runs blocking service work on a background thread.
func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated, operation: work).value
}

@MainActor
@Observable
final class AppModel {
    /// Sidebar destinations.
    enum Section: Hashable {
        case library, create, playlist
        case session(String)
    }

    /// Detail-only facts loaded on demand (they need disk reads).
    struct SceneDetails: Equatable, Sendable {
        var provenance: [ProvenanceEntry]
        var report: CheckReport?
    }

    /// A scene action that needs a sheet or confirmation (driven from cards, detail and menus).
    enum SceneAction: Identifiable, Equatable {
        case clone(String), modify(String), delete(String)
        var id: String {
            switch self {
            case .clone(let s): return "clone:" + s
            case .modify(let s): return "modify:" + s
            case .delete(let s): return "delete:" + s
            }
        }
        var sceneID: String {
            switch self {
            case .clone(let s), .modify(let s), .delete(let s): return s
            }
        }
    }

    /// A video import in progress.
    struct VideoImport: Equatable {
        var fileName: String
        var fraction: Double
    }

    let services: LivePaperServices
    let environment: AppEnvironment
    let banners = BannerCenter()

    // Navigation
    var section: Section? = .library
    /// Scene ids pushed onto the library's navigation stack.
    var libraryPath: [String] = []
    var showOnboarding = false
    var sceneAction: SceneAction?

    // Library
    private(set) var entries: [LibraryEntry] = []
    private(set) var isLoadingLibrary = false
    private(set) var libraryLoadError: String?
    var query = LibraryQuery()
    /// Bumped when a scene's thumbnail file changes so image views reload.
    private(set) var thumbnailRevision: [String: Int] = [:]
    private var thumbnailAttempts: Set<String> = []
    private var previewHTMLCache: [String: URL] = [:]
    private(set) var videoImport: VideoImport?
    /// Scenes with a `livepaper check` in progress.
    private(set) var checkingSceneIDs: Set<String> = []
    /// Bumped when per-scene files (history, check report) change, so detail views reload them.
    private(set) var detailsRevision = 0

    // Screen saver, lock, system
    private(set) var playlist = PlaylistSettings()
    private(set) var isPublishing = false
    /// The last successful publish, including scenes it had to leave out.
    private(set) var lastPublishResult: PublishResult?
    var lastPublished: LPPlaylist? { lastPublishResult?.playlist }
    private(set) var sharedState: LPSharedState
    private(set) var installStatus = InstallStatus()
    private(set) var isInstallBusy = false
    private(set) var isLocking = false

    // AI
    private(set) var harnesses: [AIHarness] = []
    private(set) var isDetectingHarnesses = false
    private(set) var hasDetectedHarnesses = false
    /// Settings › AI, stored by AIServicing (ai-settings.json, shared with the CLI and sessions).
    var aiSettings: AISettings {
        didSet { if aiSettings != oldValue { saveAISettings() } }
    }
    @ObservationIgnored private var aiSettingsSaveFailed = false
    private(set) var sessions: [AISessionModel] = []

    init(services: LivePaperServices, environment: AppEnvironment) {
        self.services = services
        self.environment = environment
        self.sharedState = LPSharedState.load(from: environment.stateURL)
        // A small JSON file: read synchronously so the settings UI never shows defaults first.
        self.aiSettings = services.ai.loadSettings()
        self.showOnboarding = !environment.defaults.bool(forKey: AppEnvironment.onboardingCompletedKey)
    }

    /// Initial load. Safe to call again (e.g. from "Reload").
    func start() async {
        await clearPreviewCache()
        async let lib: Void = reloadLibrary()
        async let pl: Void = loadPlaylist()
        async let st: Void = refreshInstallStatus()
        _ = await (lib, pl, st)
        syncLockKeysMirror()
        await detectHarnesses()
        await generateMissingThumbnails()
    }

    // MARK: - Library

    var visibleEntries: [LibraryEntry] { query.apply(entries) }
    var userEntries: [LibraryEntry] { entries.filter { !$0.item.isBuiltin } }
    var availableSceneIDs: [String] { entries.map(\.id) }
    var sceneNames: [String: String] { Dictionary(entries.map { ($0.id, $0.manifest.name) }, uniquingKeysWith: { a, _ in a }) }

    func entry(id: String) -> LibraryEntry? { entries.first { $0.id == id } }

    func reloadLibrary() async {
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        let library = services.library
        do {
            entries = try await offMain {
                try library.scenes().map { LibraryEntry(item: $0, hasAIHistory: ProvenanceLog.hasAIHistory(package: $0.packageURL)) }
            }
            libraryLoadError = nil
            // Drop navigation to scenes that no longer exist.
            libraryPath.removeAll { id in !entries.contains { $0.id == id } }
        } catch {
            libraryLoadError = error.localizedDescription
            banners.error("Couldn't load your scenes", error) { [weak self] in Task { await self?.reloadLibrary() } }
        }
    }

    func showScene(_ id: String) {
        section = .library
        libraryPath = [id]
    }

    func details(for item: SceneItem) async -> SceneDetails {
        let url = item.packageURL
        return (try? await offMain {
            SceneDetails(provenance: ProvenanceLog.load(package: url), report: CheckReportFile.load(package: url))
        }) ?? SceneDetails(provenance: [], report: nil)
    }

    /// Renders thumbnails for user scenes that don't have one yet, one at a time (the render
    /// service serialises work anyway; one request at a time keeps the machine responsive).
    func generateMissingThumbnails() async {
        let render = services.render
        for entry in entries where !entry.item.isBuiltin && entry.thumbnail == nil && !thumbnailAttempts.contains(entry.id) {
            thumbnailAttempts.insert(entry.id)
            let out = entry.item.packageURL.appendingPathComponent("thumbnail.jpg")
            let request = RenderRequest(op: .thumbnail, scene: entry.item.packageURL.path, out: out.path)
            if let response = try? await render.send(request, timeout: 60), response.ok {
                if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i].thumbnail = out }
                thumbnailRevision[entry.id, default: 0] += 1
            }
        }
    }

    /// A compiled, self-contained HTML file for live previews of a web scene (cached per version).
    /// The key includes the package location so an AI candidate never reuses the library copy.
    func previewHTML(for item: SceneItem) async throws -> URL {
        let stamp = Int(item.manifest.updated?.timeIntervalSince1970 ?? 0)
        let key = "\(item.id)-\(stamp)-\(String(AppModel.stableHash(item.packageURL.path), radix: 36))"
        if let cached = previewHTMLCache[key], FileManager.default.fileExists(atPath: cached.path) { return cached }
        let dir = environment.previewCacheDirectory
        let out = dir.appendingPathComponent("\(key).html")
        let compiler = services.compiler
        let package = item.packageURL
        try await offMain {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try compiler.compile(package: package, to: out)
        }
        previewHTMLCache[key] = out
        return out
    }

    /// Compiled previews are disposable; start each launch with an empty cache so it can't grow.
    private func clearPreviewCache() async {
        let dir = environment.previewCacheDirectory
        _ = try? await offMain { () -> Bool in
            let fm = FileManager.default
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "html" {
                try? fm.removeItem(at: url)
            }
            return true
        }
    }

    /// FNV-1a: stable across launches (Swift's Hasher is randomly seeded per process).
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100_0000_01b3 }
        return h
    }

    /// Runs `livepaper check` on a user scene and records the measured performance in its manifest
    /// (built-in scenes ship already measured and are read-only).
    func runCheck(_ id: String) async {
        guard let entry = entry(id: id), !entry.item.isBuiltin, !checkingSceneIDs.contains(id) else { return }
        checkingSceneIDs.insert(id)
        defer { checkingSceneIDs.remove(id) }
        let name = entry.manifest.name
        do {
            let report = try await services.checker.check(package: entry.item.packageURL, options: CheckOptions(power: true))
            var manifest = entry.manifest
            manifest.performance = SceneManifest.Performance(benchMs: CheckReportFile.primaryBenchMs(report),
                                                             energyMw: report.energyMw, checkedAt: report.checkedAt)
            if manifest.performance != entry.manifest.performance {
                let library = services.library
                let m = manifest
                try await offMain { try library.update(m) }
            }
            detailsRevision += 1
            await reloadLibrary()
            if report.passed {
                banners.post(.success, "\u{201C}\(name)\u{201D} passed its check", message: LPFormat.checkSummary(report))
            } else {
                banners.post(.warning, "\u{201C}\(name)\u{201D} has problems", message: report.problems.first ?? LPFormat.checkSummary(report),
                             actions: [.init(title: "Modify with AI") { [weak self] in self?.sceneAction = .modify(id) }])
            }
        } catch {
            banners.error("Couldn't check \u{201C}\(name)\u{201D}", error) { [weak self] in Task { await self?.runCheck(id) } }
        }
    }

    @discardableResult
    func clone(_ id: String, name: String) async -> SceneItem? {
        let library = services.library
        do {
            let item = try await offMain { try library.clone(id: id, newName: name) }
            await reloadLibrary()
            banners.post(.success, "Created \u{201C}\(item.manifest.name)\u{201D}")
            return item
        } catch {
            banners.error("Couldn't clone the scene", error)
            return nil
        }
    }

    func delete(_ id: String) async {
        let library = services.library
        let name = entry(id: id)?.manifest.name ?? id
        do {
            try await offMain { try library.delete(id: id) }
            libraryPath.removeAll { $0 == id }
            await reloadLibrary()
            if !PlaylistDraft(playlist).includesAllScenes && playlist.sceneIDs.contains(id) {
                var s = playlist
                s.sceneIDs.removeAll { $0 == id }
                await savePlaylist(s, announce: false)
            }
            banners.post(.success, "Deleted \u{201C}\(name)\u{201D}")
        } catch {
            banners.error("Couldn't delete \u{201C}\(name)\u{201D}", error)
        }
    }

    func export(_ id: String, to url: URL) async {
        let library = services.library
        do {
            try await offMain { try library.exportPackage(id: id, to: url) }
            banners.post(.success, "Exported to \(url.lastPathComponent)")
        } catch {
            banners.error("Couldn't export the scene", error)
        }
    }

    @discardableResult
    func importPackage(at url: URL) async -> SceneItem? {
        let library = services.library
        do {
            let item = try await offMain { try library.importPackage(at: url) }
            await reloadLibrary()
            banners.post(.success, "Imported \u{201C}\(item.manifest.name)\u{201D}",
                         actions: [.init(title: "Show") { [weak self] in self?.showScene(item.id) }])
            return item
        } catch {
            banners.error("Couldn't import \(url.lastPathComponent)", error)
            return nil
        }
    }

    /// Imports a video file as a new scene, reporting progress through `videoImport`.
    @discardableResult
    func importVideo(from url: URL, name: String, optimizeForBattery: Bool) async -> SceneItem? {
        guard videoImport == nil else { return nil }
        videoImport = VideoImport(fileName: url.lastPathComponent, fraction: 0)
        defer { videoImport = nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let item = try await services.library.importVideo(from: url, name: name, optimizeForBattery: optimizeForBattery) { [weak self] p in
                Task { @MainActor in
                    guard let self, self.videoImport != nil else { return }
                    self.videoImport?.fraction = min(max(p, 0), 1)
                }
            }
            await reloadLibrary()
            await generateMissingThumbnails()
            banners.post(.success, "Added \u{201C}\(item.manifest.name)\u{201D}",
                         actions: [.init(title: "Show") { [weak self] in self?.showScene(item.id) },
                                   .init(title: "Add to Playlist") { [weak self] in Task { await self?.addToPlaylist(item.id) } }])
            return item
        } catch {
            banners.error("Couldn't import \(url.lastPathComponent)", error) { [weak self] in
                Task { await self?.importVideo(from: url, name: name, optimizeForBattery: optimizeForBattery) }
            }
            return nil
        }
    }

    // MARK: - Playlist / publishing

    var playlistSummary: String {
        PlaylistDraft.summary(playlist, available: availableSceneIDs, names: sceneNames)
    }

    /// Whether the saver will show this scene with the current settings.
    func isInPlaylist(_ id: String) -> Bool {
        PlaylistDraft(playlist).effectiveSceneIDs(available: availableSceneIDs).contains(id)
    }

    func loadPlaylist() async {
        let publish = services.publish
        playlist = (try? await offMain { publish.loadSettings() }) ?? PlaylistSettings()
    }

    /// Saves the settings and publishes them into the installed screen saver. With
    /// `publishNow: false` (no saver installed yet) the settings are only stored; installing the
    /// saver publishes them.
    @discardableResult
    func savePlaylist(_ settings: PlaylistSettings, announce: Bool = true, publishNow: Bool = true) async -> Bool {
        isPublishing = true
        defer { isPublishing = false }
        let publish = services.publish
        do {
            let result = try await offMain { () -> PublishResult? in
                try publish.saveSettings(settings)
                return publishNow ? try publish.publishReport() : nil
            }
            playlist = settings
            guard let result else { return true }
            lastPublishResult = result
            let n = result.playlist.scenes.count
            let published = n == 1 ? "1 scene published" : "\(n) scenes published"
            if !result.skipped.isEmpty {
                // Always shown (even for quiet publishes): the saver won't play these scenes.
                let skipped = result.skippedScenes
                let names = skipped.map { "\u{201C}\(sceneNames[$0.id] ?? $0.id)\u{201D}" }.joined(separator: ", ")
                banners.post(.warning, skipped.count == 1 ? "1 scene was left out of the screen saver"
                                                          : "\(skipped.count) scenes were left out of the screen saver",
                             message: "\(published). Not playable: \(names). \(skipped.first.map { $0.reason } ?? "")",
                             actions: [.init(title: "Show Playlist") { [weak self] in self?.section = .playlist }])
            } else if announce {
                banners.post(.success, "Screen saver updated", message: published + ".")
            }
            return true
        } catch {
            await refreshInstallStatus()
            if !installStatus.saverInstalled {
                // The likely cause; setup installs the saver, which then publishes these settings.
                banners.post(.error, "LivePaper's screen saver isn't installed", message: error.localizedDescription,
                             actions: [.init(title: "Set Up\u{2026}") { [weak self] in self?.showOnboarding = true }])
            } else {
                banners.error("Couldn't update the screen saver", error) { [weak self] in
                    Task { await self?.savePlaylist(settings, announce: announce, publishNow: publishNow) }
                }
            }
            return false
        }
    }

    func useAsScreenSaver(_ id: String) async {
        var draft = PlaylistDraft(playlist)
        draft.useOnly(id)
        await savePlaylist(draft.settings)
    }

    func addToPlaylist(_ id: String) async {
        var draft = PlaylistDraft(playlist)
        guard draft.add(id) else {
            banners.post(.info, "\u{201C}\(entry(id: id)?.manifest.name ?? id)\u{201D} is already in the playlist")
            return
        }
        await savePlaylist(draft.settings)
    }

    var canAdvanceScene: Bool { PlaylistDraft.advanced(playlist, available: availableSceneIDs) != nil }

    /// Menu-bar "Next scene".
    func advanceScene() async {
        guard let next = PlaylistDraft.advanced(playlist, available: availableSceneIDs) else { return }
        await savePlaylist(next, announce: false)
    }

    func setPerformance(_ profile: LPPerformanceProfile) async {
        var s = playlist
        s.performance = profile
        await savePlaylist(s, announce: false)
    }

    // MARK: - Lock settings (state.json, read by the helper)

    func updateLock(_ change: (inout LPLockSettings) -> Void) {
        var next = sharedState
        change(&next.lock)
        guard next != sharedState else { return }
        do {
            try environment.saveState(next)
            sharedState = next
        } catch {
            banners.error("Couldn't save the lock settings", error)
        }
    }

    /// ⌃⌘Q, Apple menu › Lock Screen and the lock key start the scene before locking.
    var lockKeysShowScene: Bool { installStatus.lockKeysShowScene }

    /// Turns the lock keys on or off through InstallServicing (which backs up the previous system
    /// value the first time and restores it on uninstall) and mirrors the result into state.json.
    func setLockKeysShowScene(_ on: Bool) async {
        let before = installStatus
        installStatus.lockKeysShowScene = on   // the toggle follows the click at once
        let install = services.install
        do {
            try await offMain { try install.setLockKeysShowScene(on) }
            await refreshInstallStatus()
        } catch {
            installStatus = before
            banners.error("Couldn't change what the lock keys do", error) { [weak self] in
                Task { await self?.setLockKeysShowScene(on) }
            }
        }
        syncLockKeysMirror()
    }

    /// state.json carries the lock-keys state for the helper; the system preference is the truth
    /// (the user may also have changed it with `defaults`).
    private func syncLockKeysMirror() {
        let on = installStatus.lockKeysShowScene
        if sharedState.lock.lockKeysShowScene != on { updateLock { $0.lockKeysShowScene = on } }
    }

    /// Outcome of "Lock Now".
    enum LockRoute: Equatable {
        case helper, screenSaverEngine, failed
        /// Mock mode: nothing happens on the system.
        case sample
        /// A Lock Now is already in progress.
        case busy
    }

    /// Menu-bar "Lock Now": the helper runs its lock flow; without a helper LivePaper starts the
    /// screen saver itself. With "require password immediately" the saver locks, and loginwindow
    /// draws its lock UI over the running scene (ARCHITECTURE §1, §7).
    @discardableResult
    func lockNow() async -> LockRoute {
        if environment.isMock {
            banners.post(.info, "Sample mode", message: "LivePaper would start the screen saver and lock now.")
            return .sample
        }
        guard !isLocking else { return .busy }
        isLocking = true
        defer { isLocking = false }
        if !installStatus.saverSelected {
            banners.post(.warning, "LivePaper isn't your screen saver yet",
                         message: "Locking will show the regular lock screen.",
                         actions: [.init(title: "Set Up") { [weak self] in Task { await self?.makeLivePaperScreenSaver() } }])
        }
        if await environment.helperLock.requestLock(timeout: AppModel.helperLockTimeout) { return .helper }
        do {
            try await environment.startScreenSaver()
            return .screenSaverEngine
        } catch {
            banners.error("Couldn't start the screen saver", error)
            return .failed
        }
    }

    /// How long "Lock Now" waits for the helper before starting the screen saver itself.
    static let helperLockTimeout: TimeInterval = 1

    // MARK: - Install / system integration

    /// Everything setup and Settings show status for.
    var setupState: SetupState { SetupState(install: installStatus) }

    func refreshInstallStatus() async {
        let install = services.install
        if let s = try? await offMain({ install.status() }) { installStatus = s }
    }

    /// Installs (if needed) and selects the saver. Returns false when macOS needs the user to pick
    /// it in System Settings (the UI then shows the guided step).
    @discardableResult
    func makeLivePaperScreenSaver() async -> Bool {
        isInstallBusy = true
        defer { isInstallBusy = false }
        let install = services.install
        do {
            let selected = try await offMain { () -> Bool in
                let s = install.status()
                if !s.saverInstalled || !s.saverUpToDate { try install.installSaver() }
                return try install.selectSaver()
            }
            await refreshInstallStatus()
            return selected
        } catch {
            await refreshInstallStatus()
            banners.error("Couldn't set up the screen saver", error) { [weak self] in
                Task { await self?.makeLivePaperScreenSaver() }
            }
            return false
        }
    }

    func registerHelper() async {
        await runInstallStep("Couldn't start the LivePaper helper") { try $0.registerHelper() }
    }

    func openScreenSaverSettings() { services.install.openScreenSaverSettings() }

    private func runInstallStep(_ failure: String, _ step: @escaping @Sendable (InstallServicing) throws -> Void) async {
        isInstallBusy = true
        defer { isInstallBusy = false }
        let install = services.install
        do {
            try await offMain { try step(install) }
        } catch {
            banners.error(failure, error) { [weak self] in Task { await self?.runInstallStep(failure, step) } }
        }
        await refreshInstallStatus()
    }

    var hasCompletedOnboarding: Bool { environment.defaults.bool(forKey: AppEnvironment.onboardingCompletedKey) }

    func completeOnboarding() {
        environment.defaults.set(true, forKey: AppEnvironment.onboardingCompletedKey)
        showOnboarding = false
    }

    /// Runs every uninstall step and returns the step log (the sheet shows it). On success the
    /// caller moves the app to the Trash and quits; with failures it offers to try again, which
    /// skips the steps that already finished.
    func uninstall(keepScenes: Bool) async -> UninstallReport {
        isInstallBusy = true
        defer { isInstallBusy = false }
        let install = services.install
        // Agents work inside the support directory this deletes: they must be gone first.
        await stopAllAgents()
        let steps = (try? await offMain { install.performUninstall(removeLibrary: !keepScenes) }) ?? []
        let report = UninstallReport.make(steps)
        await refreshInstallStatus()
        if report.succeeded {
            environment.defaults.removeObject(forKey: AppEnvironment.onboardingCompletedKey)
            // state.json survives when the scenes are kept; don't leave it claiming the lock keys
            // still show the scene (uninstall put the system preference back).
            if keepScenes { syncLockKeysMirror() }
        }
        return report
    }

    func uninstallPlan(keepScenes: Bool) -> UninstallPlan {
        UninstallPlan.make(keepScenes: keepScenes, userSceneCount: userEntries.count,
                           restoresLockKeys: installStatus.lockKeysChangedByLivePaper, appBundlePath: environment.appBundlePath)
    }

    // MARK: - AI sessions

    /// Detected harnesses plus the user's custom command, if configured.
    var availableHarnesses: [AIHarness] {
        AIPreferences.availableHarnesses(detected: harnesses, settings: aiSettings)
    }

    var preferredHarness: AIHarness? {
        AIPreferences.preferredHarness(in: availableHarnesses, preferredID: aiSettings.preferredHarness)
    }

    /// The model configured in Settings › AI for a harness (nil: the harness's own default).
    func defaultModel(for harness: AIHarness?) -> String? {
        harness.flatMap { aiSettings.model(for: $0.kind) }
    }

    private func saveAISettings() {
        let settings = aiSettings
        do {
            try services.ai.saveSettings(settings)
            aiSettingsSaveFailed = false
        } catch {
            // Settings are edited keystroke by keystroke: report a failure once, not per key.
            guard !aiSettingsSaveFailed else { return }
            aiSettingsSaveFailed = true
            banners.error("Couldn't save the AI settings", error)
        }
    }

    var runningSessions: [AISessionModel] { sessions.filter(\.isRunning) }

    /// Stops every AI agent and waits (at most `AgentShutdown.limit`) until their processes are
    /// gone: before LivePaper quits, and before uninstalling deletes their workspaces.
    func stopAllAgents() async { await AgentShutdown.stop(sessions) }

    func session(id: String) -> AISessionModel? { sessions.first { $0.id == id } }

    func detectHarnesses() async {
        guard !isDetectingHarnesses else { return }
        isDetectingHarnesses = true
        harnesses = await services.ai.detectHarnesses()
        isDetectingHarnesses = false
        hasDetectedHarnesses = true
    }

    /// Starts an AI session and navigates to it. `model` nil = the default from Settings › AI.
    @discardableResult
    func startSession(_ request: AISessionRequest, harness: AIHarness, model: String?, clonedFrom: String? = nil) -> AISessionModel? {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = (trimmed?.isEmpty == false ? trimmed : nil) ?? defaultModel(for: harness)
        do {
            let handle = try services.ai.start(request, harness: harness, model: chosen)
            let session = AISessionModel(handle: handle, request: request, harness: harness, model: chosen,
                                         timeout: aiSettings.timeout, clonedFrom: clonedFrom)
            sessions.insert(session, at: 0)
            session.start { [weak self] s in self?.sessionDidFinish(s) }
            section = .session(session.id)
            return session
        } catch {
            banners.error("Couldn't start \(harness.name)", error)
            return nil
        }
    }

    /// "Modify with AI". Built-in scenes are read-only, so a copy is modified instead.
    @discardableResult
    func startModify(sceneID: String, prompt: String, harness: AIHarness, model: String?) async -> AISessionModel? {
        guard let entry = entry(id: sceneID) else { return nil }
        var target = sceneID
        var clonedFrom: String?
        if entry.item.isBuiltin {
            let name = SceneNaming.uniqueCopyName(for: entry.manifest.name, existing: entries.map(\.manifest.name))
            guard let copy = await clone(sceneID, name: name) else { return nil }
            target = copy.id
            clonedFrom = entry.manifest.name
        }
        return startSession(.modify(sceneID: target, prompt: prompt), harness: harness, model: model, clonedFrom: clonedFrom)
    }

    private func sessionDidFinish(_ session: AISessionModel) {
        guard section != .session(session.id) else { return }
        switch session.state.phase {
        case .succeeded:
            banners.post(.success, "\u{201C}\(session.title)\u{201D} is ready to review",
                         actions: [.init(title: "Review") { [weak self] in self?.section = .session(session.id) }])
        case .failed(let message):
            banners.post(.warning, "\u{201C}\(session.title)\u{201D} didn't finish", message: message,
                         actions: [.init(title: "Open") { [weak self] in self?.section = .session(session.id) }])
        default:
            break
        }
    }

    /// Accept → library (create) or Replace (modify).
    @discardableResult
    func accept(_ session: AISessionModel) async -> SceneItem? {
        guard let package = session.state.package, session.resolution == nil else { return nil }
        let library = services.library
        let request = session.request
        do {
            let item = try await offMain { () -> SceneItem in
                switch request {
                case .create: return try library.importPackage(at: package)
                case .modify(let id, _): return try library.replaceContents(id: id, with: package)
                }
            }
            session.resolution = .accepted(sceneID: item.id)
            previewHTMLCache = previewHTMLCache.filter { !$0.key.hasPrefix(item.id + "-") }
            thumbnailRevision[item.id, default: 0] += 1
            detailsRevision += 1
            await reloadLibrary()
            let verb = session.isModify ? "Updated" : "Added"
            banners.post(.success, "\(verb) \u{201C}\(item.manifest.name)\u{201D}",
                         actions: [.init(title: "Show") { [weak self] in self?.showScene(item.id) },
                                   .init(title: "Use as Screen Saver") { [weak self] in Task { await self?.useAsScreenSaver(item.id) } }])
            return item
        } catch {
            banners.error(session.isModify ? "Couldn't replace the scene" : "Couldn't add the scene", error) { [weak self] in
                Task { await self?.accept(session) }
            }
            return nil
        }
    }

    /// "Try again with feedback": a new session with the original prompt plus the feedback.
    @discardableResult
    func retry(_ session: AISessionModel, feedback: String) -> AISessionModel? {
        let prompt = PromptComposer.retry(original: session.prompt, feedback: feedback)
        let request: AISessionRequest
        switch session.request {
        case .create: request = .create(prompt: prompt)
        case .modify(let id, _): request = .modify(sceneID: id, prompt: prompt)
        }
        if session.isRunning { session.cancel() }
        if session.resolution == nil { session.resolution = .discarded }
        let next = startSession(request, harness: session.harness, model: session.model, clonedFrom: session.clonedFrom)
        if next != nil { sessions.removeAll { $0 === session } }
        return next
    }

    /// Discard: stops the agent if needed and removes the session from the sidebar.
    func discard(_ session: AISessionModel) {
        if session.isRunning { session.cancel() }
        if session.resolution == nil { session.resolution = .discarded }
        sessions.removeAll { $0 === session }
        if section == .session(session.id) { section = .create }
    }
}
