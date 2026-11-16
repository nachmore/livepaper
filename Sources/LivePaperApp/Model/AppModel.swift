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
    /// "0.1.0.195": CFBundleShortVersionString, then the build number (CFBundleVersion, the commit
    /// count), so Settings › About tells builds of the same version apart.
    var appVersion: String
    /// The running .app bundle, or nil when not running from one (`swift run`, tests).
    var appBundlePath: String?
    /// System Settings › Lock Screen (AppKit; Entry/SystemActions). A no-op in mock mode and tests.
    var openLockScreenSettings: @MainActor () -> Void = {}
    /// System Settings › General › Login Items (AppKit; Entry/SystemActions). A no-op in mock mode and tests.
    var openLoginItemsSettings: @MainActor () -> Void = {}
    /// Calls the handler on the main actor whenever the login session is unlocked
    /// (com.apple.screenIsUnlocked) until the returned closure cancels it. Live: SessionUnlockObserver;
    /// mock mode and tests: never, unless a test fires it.
    var observeUnlock: @MainActor (@escaping @MainActor () -> Void) -> (@MainActor () -> Void) = { _ in {} }
    /// The support directory whose `Library/` and `playlist-settings.json` are watched for changes
    /// made by other processes (LibraryWatcher). nil: not watched (tests, snapshots).
    var diskWatchRoot: URL? = nil
    /// The login session is locked right now (any thread; live: CGSSessionScreenIsLocked). The
    /// installed saver is never swapped under a running lock screen.
    var isSessionLocked: @Sendable () -> Bool = { false }

    static let onboardingCompletedKey = "onboardingCompleted"
}

/// Modification dates of the per-scene files the UI shows beyond what LibraryEntry compares, so a
/// file rewritten under the same name (`livepaper thumbnail`, `livepaper check`, an editor) is
/// noticed.
struct SceneFileStamps: Equatable, Sendable {
    var thumbnail: Date?
    var history: Date?
    var report: Date?
    /// What a compiled preview is made of (`content(package:)`).
    var content: UInt64

    init(package: URL) {
        func modified(_ relative: String) -> Date? {
            (try? package.appendingPathComponent(relative).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        thumbnail = modified("thumbnail.jpg")
        history = modified(ProvenanceLog.fileName)
        report = modified(CheckReportFile.relativePath)
        content = Self.content(package: package)
    }

    /// A stamp of the files SceneCompiler reads — scene.json, scene.js and everything in assets/
    /// (names, sizes, modification dates). A preview compiled earlier is stale once it changes,
    /// even when the manifest's `updated` didn't (an edit in an editor, `livepaper check`).
    static func content(package: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        func line(_ url: URL, _ name: String) -> String? {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), let date = values.contentModificationDate else { return nil }
            return "\(name)\t\(date.timeIntervalSinceReferenceDate)\t\(values.fileSize ?? -1)"
        }
        var lines = [SceneManifest.fileName, SceneCompiler.sceneFile, SceneCompiler.assetsDirectory].compactMap {
            line(package.appendingPathComponent($0), $0)
        }
        let assets = package.appendingPathComponent(SceneCompiler.assetsDirectory)
        if let walker = FileManager.default.enumerator(at: assets, includingPropertiesForKeys: keys) {
            for case let url as URL in walker {
                if let l = line(url, String(url.path.dropFirst(assets.path.count))) { lines.append(l) }
            }
        }
        return AppModel.stableHash(lines.sorted().joined(separator: "\n"))
    }
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
    /// Bumped when what a scene's live preview is compiled from changes on disk without a new
    /// `updated` (an editor, `livepaper check`), so open previews recompile.
    private(set) var previewRevision: [String: Int] = [:]
    private var thumbnailAttempts: Set<String> = []
    private var previewHTMLCache: [String: URL] = [:]
    private(set) var videoImport: VideoImport?
    /// Scenes with a `livepaper check` in progress.
    private(set) var checkingSceneIDs: Set<String> = []
    /// Bumped when per-scene files (history, check report) change, so detail views reload them.
    private(set) var detailsRevision = 0
    /// Modification dates of the per-scene files the UI shows beyond what LibraryEntry compares.
    @ObservationIgnored private var fileStamps: [String: SceneFileStamps] = [:]
    @ObservationIgnored private var activeLibraryLoads = 0
    // Reads run off the main actor and can finish out of order: a read only applies if no read that
    // started after it has applied already (so callers of reloadLibrary/loadPlaylist always see data
    // read after their call, never an older read finishing late).
    @ObservationIgnored private var libraryReadSeq = 0
    @ObservationIgnored private var libraryAppliedSeq = 0
    @ObservationIgnored private var playlistReadSeq = 0
    @ObservationIgnored private var playlistAppliedSeq = 0

    // Changes made by other processes (CLI, Finder, editors)
    @ObservationIgnored private var diskWatcher: LibraryWatcher?
    @ObservationIgnored private var pendingDiskChanges: DiskChanges = []
    @ObservationIgnored private var diskRefresh: Task<Void, Never>?
    /// Passes refreshFromDisk has made (diagnostics, tests).
    @ObservationIgnored private(set) var diskRefreshCount = 0

    // Screen saver, lock, system
    private(set) var playlist = PlaylistSettings()
    /// savePlaylist calls in progress.
    private var playlistSaves = 0
    var isPublishing: Bool { playlistSaves > 0 }
    /// A playlist read finished while a save was in flight and wasn't applied (the save may roll
    /// back what it wrote): read again once the saves are done.
    @ObservationIgnored private var playlistRereadAfterSave = false
    /// The last successful publish, including scenes it had to leave out.
    private(set) var lastPublishResult: PublishResult?
    var lastPublished: LPPlaylist? { lastPublishResult?.playlist }
    private(set) var sharedState: LPSharedState
    private(set) var installStatus = InstallStatus()
    /// installStatus has been read at least once (until then nothing is known about the system).
    private(set) var installStatusLoaded = false
    /// Install, setup and uninstall work in progress (the launch-time saver update included).
    var isInstallBusy: Bool { installJobs > 0 }
    private var installJobs = 0
    /// The launch-time saver update while it runs: uninstall and setup wait for it.
    @ObservationIgnored private var saverUpdate: Task<Void, Never>?
    /// Set while a saver update waits for the next unlock (the Mac was locked when it was due);
    /// calling it stops waiting.
    @ObservationIgnored private var cancelUnlockWait: (@MainActor () -> Void)?
    /// What the unlock started (re-reading the status, then the update): uninstall and setup wait for
    /// it, so nothing runs between the unlock and the update unaccounted for.
    @ObservationIgnored private var unlockRetry: Task<Void, Never>?
    /// Uninstall or setup is running: no saver update starts meanwhile (uninstall removes the saver;
    /// setup installs this build's itself).
    @ObservationIgnored private var exclusiveInstallWork = 0
    /// The automatic helper repair while it runs (uninstall and "Start Helper" wait for it), and
    /// whether this launch has had its one attempt (the user's own attempts and an uninstall count too).
    @ObservationIgnored private var helperRepair: Task<Void, Never>?
    @ObservationIgnored private(set) var helperRepairAttempted = false
    /// Banners about the helper not running (the repair's, Start Helper's): dismissed once a status
    /// read shows it running.
    @ObservationIgnored private var helperBanners: Set<UUID> = []
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
        // Before the first read, so nothing changed during the initial load goes unnoticed.
        startWatchingDisk()
        await clearPreviewCache()
        async let lib: Void = reloadLibrary()
        async let pl: Void = loadPlaylist()
        async let st: Void = refreshInstallStatus()
        _ = await (lib, pl, st)
        // Alongside the rest: waiting for publish.lock (another process publishing) mustn't hold
        // up the launch.
        let update = beginSaverUpdateIfNeeded()
        syncLockKeysMirror()
        await detectHarnesses()
        await generateMissingThumbnails()
        await update?.value
    }

    // MARK: - Library

    var visibleEntries: [LibraryEntry] { query.apply(entries) }
    var userEntries: [LibraryEntry] { entries.filter { !$0.item.isBuiltin } }
    var availableSceneIDs: [String] { entries.map(\.id) }
    var sceneNames: [String: String] { Dictionary(entries.map { ($0.id, $0.manifest.name) }, uniquingKeysWith: { a, _ in a }) }

    func entry(id: String) -> LibraryEntry? { entries.first { $0.id == id } }

    func reloadLibrary() async { await reloadLibrary(quiet: false) }

    /// `quiet`: a refresh nobody asked for (disk changes, activation). It shows no loading state
    /// and doesn't announce a failure that is already shown.
    func reloadLibrary(quiet: Bool) async {
        libraryReadSeq += 1
        let seq = libraryReadSeq
        if !quiet { activeLibraryLoads += 1; isLoadingLibrary = true }
        defer { if !quiet { activeLibraryLoads -= 1; isLoadingLibrary = activeLibraryLoads > 0 } }
        let library = services.library
        do {
            let (fresh, stamps) = try await offMain { () -> ([LibraryEntry], [String: SceneFileStamps]) in
                let items = try library.scenes()
                let entries = items.map { LibraryEntry(item: $0, hasAIHistory: ProvenanceLog.hasAIHistory(package: $0.packageURL)) }
                let stamps = Dictionary(items.map { ($0.id, SceneFileStamps(package: $0.packageURL)) }, uniquingKeysWith: { a, _ in a })
                return (entries, stamps)
            }
            guard seq > libraryAppliedSeq else { return }
            libraryAppliedSeq = seq
            applyLibrary(fresh, stamps: stamps)
            if libraryLoadError != nil { libraryLoadError = nil }
        } catch {
            guard seq > libraryAppliedSeq else { return }
            libraryAppliedSeq = seq
            let message = error.localizedDescription
            let alreadyShown = libraryLoadError == message
            libraryLoadError = message
            if !(quiet && alreadyShown) {
                banners.error("Couldn't load your scenes", error) { [weak self] in Task { await self?.reloadLibrary() } }
            }
        }
    }

    /// Applies a library read without disturbing the UI: unchanged entries aren't reassigned (the
    /// grid, the playlist and open details keep their state and scroll position), and only files
    /// rewritten under the same name bump the revisions their views reload on.
    private func applyLibrary(_ fresh: [LibraryEntry], stamps: [String: SceneFileStamps]) {
        var detailsChanged = false
        for (id, new) in stamps {
            guard let old = fileStamps[id] else { continue }
            if old.thumbnail != nil && old.thumbnail != new.thumbnail { thumbnailRevision[id, default: 0] += 1 }
            if old.history != new.history || old.report != new.report { detailsChanged = true }
            if old.content != new.content { previewRevision[id, default: 0] += 1 }
        }
        fileStamps = stamps
        if detailsChanged { detailsRevision += 1 }
        if fresh != entries { entries = fresh }
        // Drop navigation to scenes that no longer exist.
        let ids = Set(entries.map(\.id))
        if libraryPath.contains(where: { !ids.contains($0) }) { libraryPath.removeAll { !ids.contains($0) } }
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

    /// A compiled, self-contained HTML file for live previews of a web scene, cached per version
    /// of what it is compiled from (SceneFileStamps.content: edits that don't touch `updated`
    /// count too). The key includes the package location so an AI candidate never reuses the
    /// library copy.
    func previewHTML(for item: SceneItem) async throws -> URL {
        let package = item.packageURL
        let content = try await offMain { SceneFileStamps.content(package: package) }
        let stamp = Int(item.manifest.updated?.timeIntervalSince1970 ?? 0)
        let version = String(AppModel.stableHash("\(package.path)\n\(item.id)\n\(content)"), radix: 36)
        let key = "\(item.id)-\(stamp)-\(version)"
        if let cached = previewHTMLCache[key], FileManager.default.fileExists(atPath: cached.path) { return cached }
        let dir = environment.previewCacheDirectory
        // The id names the file only when it is a valid scene id: an AI candidate's scene.json is
        // written by the agent, and its id (say "../../x") must never become a path.
        let name = SceneManifest.isValidID(item.id) ? item.id : "scene"
        let out = dir.appendingPathComponent("\(name)-\(stamp)-\(version).html")
        guard out.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path else {
            throw LibraryError.invalid("\(item.manifest.name) can't be previewed: its id isn't a valid file name.")
        }
        let compiler = services.compiler
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
    nonisolated static func stableHash(_ s: String) -> UInt64 {
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

    /// Opening a scene package (double-click in Finder, Import Scene… in the File menu and the
    /// Library toolbar). A scene the library already has — the package itself, or a copy with the
    /// same contents — just opens. Another version of a scene in the library opens that scene and
    /// offers to replace it or import the package as a copy. Anything else is imported. The check
    /// and the import are one library step (`openPackage`), so opening a new package twice at once
    /// imports it once.
    func openScenePackage(at url: URL) async {
        let library = services.library
        let result: SceneOpenResult
        do {
            result = try await offMain { try library.openPackage(at: url) }
        } catch {
            banners.error("Couldn't import \(url.lastPathComponent)", error)
            return
        }
        switch result {
        case .imported(let item):
            await didImport(item)
        case .existing(.same(let item)):
            await show(item)
            banners.post(.info, "\u{201C}\(item.manifest.name)\u{201D} is already in your library")
        case .existing(.otherVersion(let item)):
            await show(item)
            banners.post(.warning, "\u{201C}\(item.manifest.name)\u{201D} is already in your library",
                         message: "\(url.lastPathComponent) is a different version of it.",
                         actions: [.init(title: "Replace with This Version") { [weak self] in Task { await self?.replaceScene(item.id, with: url) } },
                                   .init(title: "Import as a Copy") { [weak self] in Task { await self?.importPackage(at: url) } }])
        }
    }

    /// Shows a scene, loading the library first when it doesn't know the scene yet (a package
    /// opened from Finder while LivePaper was still starting).
    private func show(_ item: SceneItem) async {
        if entry(id: item.id) == nil { await reloadLibrary(quiet: true) }
        showScene(item.id)
    }

    /// Replaces a library scene with a package's contents (its previous version stays in history).
    func replaceScene(_ id: String, with url: URL) async {
        let library = services.library
        do {
            let item = try await offMain { try library.replaceContents(id: id, with: url) }
            await didChangeContents(of: item)
            showScene(item.id)
            banners.post(.success, "Updated \u{201C}\(item.manifest.name)\u{201D}",
                         message: "The previous version is kept in the scene\u{2019}s history.")
            await republishIfInPlaylist(item.id)
        } catch {
            banners.error("Couldn't replace the scene", error) { [weak self] in Task { await self?.replaceScene(id, with: url) } }
        }
    }

    /// A scene's files were written (Replace, AI accept): drop what was derived from the old ones.
    private func didChangeContents(of item: SceneItem) async {
        previewHTMLCache = previewHTMLCache.filter { !$0.key.hasPrefix(item.id + "-") }
        thumbnailRevision[item.id, default: 0] += 1
        detailsRevision += 1
        await reloadLibrary()
    }

    /// The saver plays the copies compiled when the playlist was published, so a scene in the
    /// playlist whose contents changed is published again (quietly; a scene that is no longer
    /// playable is still reported). Nothing happens while the saver isn't installed.
    private func republishIfInPlaylist(_ id: String) async {
        if !installStatusLoaded { await refreshInstallStatus() }
        guard installStatus.saverInstalled, isInPlaylist(id) else { return }
        await savePlaylist(playlist, announce: false)
    }

    @discardableResult
    func importPackage(at url: URL) async -> SceneItem? {
        let library = services.library
        do {
            let item = try await offMain { try library.importPackage(at: url) }
            await didImport(item)
            return item
        } catch {
            banners.error("Couldn't import \(url.lastPathComponent)", error)
            return nil
        }
    }

    private func didImport(_ item: SceneItem) async {
        await reloadLibrary()
        banners.post(.success, "Imported \u{201C}\(item.manifest.name)\u{201D}",
                     actions: [.init(title: "Show") { [weak self] in self?.showScene(item.id) }])
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

    // MARK: - Changes made by other processes

    /// Starts picking up changes other processes make to the library and the playlist settings
    /// (the `livepaper` CLI, Finder, an editor). Idempotent; nothing runs while nothing changes.
    func startWatchingDisk() {
        guard diskWatcher == nil, let root = environment.diskWatchRoot else { return }
        let watcher = LibraryWatcher(root: root) { [weak self] changes in
            Task { @MainActor in await self?.refreshFromDisk(changes) }
        }
        watcher.start()
        diskWatcher = watcher
    }

    func stopWatchingDisk() {
        diskWatcher?.stop()
        diskWatcher = nil
    }

    var isWatchingDisk: Bool { diskWatcher != nil }

    /// Re-reads what other processes may have changed: on the disk watcher's word, and as a cheap
    /// safety net when LivePaper becomes active or the main window opens. Quiet (see
    /// reloadLibrary(quiet:)) and coalesced: requests arriving while a pass runs share one more pass.
    func refreshFromDisk(_ changes: DiskChanges = .all) async {
        pendingDiskChanges.formUnion(changes)
        if let running = diskRefresh { await running.value; return }
        let pass = Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.pendingDiskChanges.isEmpty {
                let next = self.pendingDiskChanges
                self.pendingDiskChanges = []
                self.diskRefreshCount += 1
                if next.contains(.playlist) { await self.loadPlaylist() }
                if next.contains(.library) {
                    await self.reloadLibrary(quiet: true)
                    // A scene added by the CLI has no thumbnail yet; rendering one mustn't hold up
                    // the next refresh.
                    Task { await self.generateMissingThumbnails() }
                }
            }
            self.diskRefresh = nil
        }
        diskRefresh = pass
        await pass.value
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
        playlistReadSeq += 1
        let seq = playlistReadSeq
        let publish = services.publish
        let settings = (try? await offMain { publish.loadSettings() }) ?? PlaylistSettings()
        guard seq > playlistAppliedSeq else { return }
        // A save in flight wrote settings that it puts back if its publish fails.
        guard playlistSaves == 0 else { playlistRereadAfterSave = true; return }
        playlistAppliedSeq = seq
        guard settings != playlist else { return }
        // Changed elsewhere (e.g. `livepaper publish --scenes …`): this app's last publish no longer
        // describes what the saver plays.
        lastPublishResult = nil
        playlist = settings
    }

    /// Saves the settings and publishes them into the installed screen saver. With
    /// `publishNow: false` (no saver installed yet) the settings are only stored; installing the
    /// saver publishes them. A publish that fails changes nothing: the saver keeps the previous
    /// playlist, so the stored settings go back to it too (otherwise the disk watcher, the CLI and
    /// the menu bar would call the failed draft current, and Save & Publish would have nothing left
    /// to save). Only without a saver do they stay stored, for setup to publish.
    @discardableResult
    func savePlaylist(_ settings: PlaylistSettings, announce: Bool = true, publishNow: Bool = true) async -> Bool {
        playlistSaves += 1
        defer {
            playlistSaves -= 1
            if playlistSaves == 0, playlistRereadAfterSave {
                playlistRereadAfterSave = false
                Task { await self.loadPlaylist() }
            }
        }
        let publish = services.publish
        let previous = publishNow ? try? await offMain { publish.loadSettings() } : nil
        do {
            let result = try await offMain { () -> PublishResult? in
                try publish.saveSettings(settings)
                return publishNow ? try publish.publishReport() : nil
            }
            // Newer than any read still in flight.
            playlistReadSeq += 1
            playlistAppliedSeq = playlistReadSeq
            playlist = settings
            guard let result else { return true }
            reportPublish(result, announce: announce)
            return true
        } catch {
            await refreshInstallStatus()
            if !installStatus.saverInstalled {
                // The likely cause; setup installs the saver, which then publishes these settings.
                banners.post(.error, "LivePaper's screen saver isn't installed", message: error.localizedDescription,
                             actions: [.init(title: "Set Up\u{2026}") { [weak self] in self?.showOnboarding = true }])
            } else {
                if let previous, previous != settings { _ = try? await offMain { try publish.saveSettings(previous) } }
                banners.error("Couldn't update the screen saver", error) { [weak self] in
                    Task { await self?.savePlaylist(settings, announce: announce, publishNow: publishNow) }
                }
            }
            return false
        }
    }

    /// Records a successful publish. Scenes it left out always get a banner, even for quiet
    /// publishes (the saver won't play them); otherwise `announce` posts the success banner.
    private func reportPublish(_ result: PublishResult, announce: Bool) {
        lastPublishResult = result
        let n = result.playlist.scenes.count
        let published = n == 1 ? "1 scene published" : "\(n) scenes published"
        if !result.skipped.isEmpty {
            let skipped = result.skippedScenes
            let names = skipped.map { "\u{201C}\(sceneNames[$0.id] ?? $0.id)\u{201D}" }.joined(separator: ", ")
            banners.post(.warning, skipped.count == 1 ? "1 scene was left out of the screen saver"
                                                      : "\(skipped.count) scenes were left out of the screen saver",
                         message: "\(published). Not playable: \(names). \(skipped.first.map { $0.reason } ?? "")",
                         actions: [.init(title: "Show Playlist") { [weak self] in self?.section = .playlist }])
        } else if announce {
            banners.post(.success, "Screen saver updated", message: published + ".")
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
        /// Starting the screen saver wouldn't lock the Mac (password not required immediately):
        /// nothing was started and the user was told why.
        case refused
        /// Mock mode: nothing happens on the system.
        case sample
        /// A Lock Now is already in progress.
        case busy
    }

    /// Why "Lock Now" (and the helper's shortcut) won't lock right now, as far as the last status
    /// read knows: the menu disables Lock Now and explains. nil until the status has been read.
    var lockRefusal: LPLockRefusal? {
        guard installStatusLoaded, !installStatus.passwordImmediately else { return nil }
        return .passwordNotImmediate
    }

    /// Tells the user why LivePaper didn't lock (from Lock Now, or the helper's LPNotification.lockRefused).
    func showLockRefusal(_ refusal: LPLockRefusal) {
        banners.post(.warning, refusal.title, message: refusal.message,
                     actions: [.init(title: "Open Lock Screen Settings") { [environment] in environment.openLockScreenSettings() }])
    }

    /// Menu-bar "Lock Now": the helper runs its lock flow; without a helper LivePaper starts the
    /// screen saver itself. With "require password immediately" the saver locks, and loginwindow
    /// draws its lock UI over the running scene (ARCHITECTURE §1, §7). Without it, starting the
    /// saver wouldn't lock the Mac, so nothing is started and the user is told why.
    @discardableResult
    func lockNow() async -> LockRoute {
        if environment.isMock {
            banners.post(.info, "Sample mode", message: "LivePaper would start the screen saver and lock now.")
            return .sample
        }
        guard !isLocking else { return .busy }
        isLocking = true
        defer { isLocking = false }
        // Fresh, not the last status shown: the user may just have changed it in System Settings.
        await refreshInstallStatus()
        guard installStatus.passwordImmediately else {
            showLockRefusal(.passwordNotImmediate)
            return .refused
        }
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

    /// After an app update the copy in ~/Library/Screen Savers is still the old build (the saver's
    /// code — shuffle, power gate, clock hand-off — lives there, not in the app): replace it with
    /// the bundled build, then republish the playlist from the current settings and library (the
    /// old Playlist is carried over only so the saver never sees an empty bundle). Scenes that
    /// can't be published any more are reported like after any publish. Only ever an upgrade
    /// (InstallStatus.saverUpdateAvailable: an older LivePaper never replaces a newer saver), never
    /// after an uninstall and never while the Mac is locked; InstallService checks all of that
    /// again right before the swap. An update the lock held back runs after the next unlock.
    func updateInstalledSaverIfNeeded() async {
        await beginSaverUpdateIfNeeded()?.value
    }

    /// A saver update waits for the next unlock (tests, diagnostics).
    var isSaverUpdateWaitingForUnlock: Bool { cancelUnlockWait != nil }

    /// Starts the launch-time update (or returns the one running), nil when there is nothing to do
    /// now. While the Mac is locked it waits for the unlock instead.
    private func beginSaverUpdateIfNeeded() -> Task<Void, Never>? {
        if let running = saverUpdate { return running }
        guard installStatus.saverUpdateAvailable, exclusiveInstallWork == 0 else { return nil }
        if environment.isSessionLocked() {
            NSLog("LivePaper: not updating the installed screen saver now: \(SaverUpdateOutcome.sessionLockedReason); " +
                  "updating it once the Mac is unlocked")
            updateSaverAfterUnlock()
            return nil
        }
        stopWaitingForUnlock()
        installJobs += 1
        let task = Task { @MainActor in
            defer { self.saverUpdate = nil; self.endInstallJob() }
            await self.runSaverUpdate()
        }
        saverUpdate = task
        return task
    }

    private func runSaverUpdate() async {
        let install = services.install
        let isLocked = environment.isSessionLocked
        do {
            switch try await offMain({ try install.updateSaver(isSessionLocked: isLocked) }) {
            case .updated(let result):
                NSLog("LivePaper: updated the installed screen saver to this build")
                if let result { reportPublish(result, announce: false) }
            case .skipped(let why):
                NSLog("LivePaper: left the installed screen saver as it is: \(why)")
                // Locked between the check and the swap: the same wait as at launch.
                if why == SaverUpdateOutcome.sessionLockedReason { updateSaverAfterUnlock() }
            }
        } catch {
            NSLog("LivePaper: couldn't update the installed screen saver: \(error.localizedDescription)")
        }
        await refreshInstallStatus()
    }

    /// Waits for the next unlock (com.apple.screenIsUnlocked), then tries the update once more:
    /// the installed saver is never swapped under a running lock screen, and nothing else would
    /// try again before the next launch. One wait at a time; the unlock ends it (an update that
    /// finds the Mac locked again waits for the following one). What the unlock starts is kept in
    /// `unlockRetry`, which uninstall and setup wait for.
    private func updateSaverAfterUnlock() {
        guard cancelUnlockWait == nil else { return }
        cancelUnlockWait = environment.observeUnlock { [weak self] in
            guard let self, self.cancelUnlockWait != nil else { return }
            self.stopWaitingForUnlock()
            NSLog("LivePaper: the Mac was unlocked; updating the installed screen saver")
            let previous = self.unlockRetry
            self.unlockRetry = Task { @MainActor in
                await previous?.value
                await self.refreshInstallStatus()
                await self.beginSaverUpdateIfNeeded()?.value
            }
        }
    }

    private func stopWaitingForUnlock() {
        let cancel = cancelUnlockWait
        cancelUnlockWait = nil
        cancel?()
    }

    func refreshInstallStatus() async {
        let install = services.install
        if let s = try? await offMain({ install.status() }) {
            installStatus = s
            installStatusLoaded = true
            if s.helperRunning { dismissHelperBanners() }
            beginHelperRepairIfNeeded()
        }
    }

    /// Ends one piece of install work; once none is left, a helper problem the status showed
    /// meanwhile gets its repair (it is held back while other install work runs).
    private func endInstallJob() {
        installJobs -= 1
        if installJobs == 0 { beginHelperRepairIfNeeded() }
    }

    /// The helper runs now (repaired, approved in Login Items, started): what said otherwise goes.
    private func dismissHelperBanners() {
        for id in helperBanners { banners.dismiss(id) }
        helperBanners.removeAll()
    }

    // MARK: - Helper repair

    /// The helper is set up but its job doesn't run this build's helper (InstallStatus.helperProblem;
    /// typically after an update of an ad-hoc-signed LivePaper, when launchd can no longer start the
    /// login item while SMAppService still calls it enabled): repair it — once per launch, whenever
    /// the status first shows it, and not while other install work runs. Quiet unless the user has
    /// to do something; "Start Helper" / "Repair Helper" are the user's further attempts.
    private func beginHelperRepairIfNeeded() {
        guard let problem = installStatus.helperProblem, problem.isRepairable, helperRepair == nil, !helperRepairAttempted,
              installJobs == 0 else { return }
        helperRepairAttempted = true
        installJobs += 1
        NSLog("LivePaper: the helper doesn't run this build: \(problem.summary); repairing it")
        helperRepair = Task { @MainActor in
            defer { self.helperRepair = nil; self.endInstallJob() }
            await self.runHelperRepair()
        }
    }

    /// Waits for an automatic helper repair that is running (tests).
    func awaitHelperRepair() async { await helperRepair?.value }

    private func runHelperRepair() async {
        let install = services.install
        do {
            switch try await offMain({ try install.recoverHelper() }) {
            case .notNeeded(let why):
                NSLog("LivePaper: the helper needs no repair: \(why)")
            case .started:
                NSLog("LivePaper: started the helper again")
            case .reregistered:
                NSLog("LivePaper: registered the helper login item again; it runs this build now")
            case .needsApproval:
                NSLog("LivePaper: registered the helper login item again; macOS waits for approval in Login Items")
                helperBanners.insert(banners.post(.warning, "Allow LivePaper\u{2019}s helper again",
                    message: "After the update macOS asks you to allow the helper again in System Settings \u{203A} General \u{203A} " +
                             "Login Items. Until then your lock shortcut doesn\u{2019}t work.",
                    actions: [.init(title: "Open Login Items") { [environment] in environment.openLoginItemsSettings() }]))
            }
        } catch {
            NSLog("LivePaper: couldn't repair the helper: \(error.localizedDescription)")
            helperBanners.insert(banners.error("LivePaper\u{2019}s helper can\u{2019}t start", error) { [weak self] in
                Task { await self?.registerHelper() }
            })
        }
        await refreshInstallStatus()
    }

    /// Installs (if needed) and selects the saver. Returns false when macOS needs the user to pick
    /// it in System Settings (the UI then shows the guided step).
    @discardableResult
    func makeLivePaperScreenSaver() async -> Bool {
        installJobs += 1
        exclusiveInstallWork += 1
        defer { exclusiveInstallWork -= 1; endInstallJob() }
        // The launch-time update is the same install: let it finish rather than race it (also one an
        // unlock is about to start), and start none meanwhile.
        await unlockRetry?.value
        await saverUpdate?.value
        let install = services.install
        do {
            let published = try await offMain { () -> PublishResult? in
                let s = install.status()
                return !s.saverInstalled || !s.saverUpToDate ? try install.installSaver() : nil
            }
            if let published { reportPublish(published, announce: false) }
            let selected = try await offMain { try install.selectSaver() }
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

    /// "Start Helper" / "Repair Helper": sets the helper up and makes it run this build (it registers
    /// the login item again when launchd can't start it). The user's attempt replaces this launch's
    /// automatic repair.
    func registerHelper() async {
        helperRepairAttempted = true
        await helperRepair?.value
        await runInstallStep("Couldn't start the LivePaper helper", aboutHelper: true) { try $0.registerHelper() }
    }

    func openScreenSaverSettings() { services.install.openScreenSaverSettings() }

    /// `aboutHelper`: a failure banner that goes once the helper runs.
    private func runInstallStep(_ failure: String, aboutHelper: Bool = false,
                                _ step: @escaping @Sendable (InstallServicing) throws -> Void) async {
        installJobs += 1
        defer { endInstallJob() }
        let install = services.install
        do {
            try await offMain { try step(install) }
        } catch {
            let id = banners.error(failure, error) { [weak self] in Task { await self?.runInstallStep(failure, aboutHelper: aboutHelper, step) } }
            if aboutHelper { helperBanners.insert(id) }
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
        installJobs += 1
        exclusiveInstallWork += 1
        defer { exclusiveInstallWork -= 1; endInstallJob() }
        // A launch-time saver update still running (or waiting for an unlock, or about to start after
        // one) would put back what this removes, and a helper repair would register the helper again:
        // wait for those, and start none from here on.
        helperRepairAttempted = true
        stopWaitingForUnlock()
        await unlockRetry?.value
        await saverUpdate?.value
        await helperRepair?.value
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

    /// Sessions being started (their workspaces are built off the main thread): Generate, Start
    /// and Try Again wait meanwhile.
    private(set) var startingSessions = 0
    var isStartingSession: Bool { startingSessions > 0 }

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
    /// `references` are already prepared (ReferenceTray), but building the workspace still copies
    /// the SDK and writes the images, and the picture to animate is decoded for its fingerprint and
    /// re-encoded when it doesn't fit the scene's asset budget (up to about a second for a large
    /// transparent picture), so that runs off the main thread. `isStartingSession` is true meanwhile.
    @discardableResult
    func startSession(_ request: AISessionRequest, references: [PreparedReference] = [], harness: AIHarness, model: String?,
                      clonedFrom: String? = nil) async -> AISessionModel? {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = (trimmed?.isEmpty == false ? trimmed : nil) ?? defaultModel(for: harness)
        let ai = services.ai
        startingSessions += 1
        defer { startingSessions -= 1 }
        do {
            let handle = try await offMain { try ai.start(request, references: references, harness: harness, model: chosen) }
            let session = AISessionModel(handle: handle, request: request, references: references, harness: harness, model: chosen,
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
    func startModify(sceneID: String, prompt: String, references: [PreparedReference] = [], harness: AIHarness,
                     model: String?) async -> AISessionModel? {
        guard let entry = entry(id: sceneID) else { return nil }
        var target = sceneID
        var clonedFrom: String?
        if entry.item.isBuiltin {
            let name = SceneNaming.uniqueCopyName(for: entry.manifest.name, existing: entries.map(\.manifest.name))
            guard let copy = await clone(sceneID, name: name) else { return nil }
            target = copy.id
            clonedFrom = entry.manifest.name
        }
        return await startSession(.modify(sceneID: target, prompt: prompt), references: references, harness: harness, model: model,
                                  clonedFrom: clonedFrom)
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
            // Try Again is gone for an accepted session: its full-size picture isn't needed any more.
            session.releasePictureToAnimate()
            await didChangeContents(of: item)
            let verb = session.isModify ? "Updated" : "Added"
            banners.post(.success, "\(verb) \u{201C}\(item.manifest.name)\u{201D}",
                         actions: [.init(title: "Show") { [weak self] in self?.showScene(item.id) },
                                   .init(title: "Use as Screen Saver") { [weak self] in Task { await self?.useAsScreenSaver(item.id) } }])
            if session.isModify { await republishIfInPlaylist(item.id) }
            return item
        } catch {
            banners.error(session.isModify ? "Couldn't replace the scene" : "Couldn't add the scene", error) { [weak self] in
                Task { await self?.accept(session) }
            }
            return nil
        }
    }

    /// "Try again with feedback": a new session with the original prompt plus the feedback, and
    /// the same reference images (same ids and roles; nothing is read from disk again).
    @discardableResult
    func retry(_ session: AISessionModel, feedback: String) async -> AISessionModel? {
        let prompt = PromptComposer.retry(original: session.prompt, feedback: feedback)
        let request: AISessionRequest
        switch session.request {
        case .create: request = .create(prompt: prompt)
        case .modify(let id, _): request = .modify(sceneID: id, prompt: prompt)
        }
        if session.isRunning { session.cancel() }
        if session.resolution == nil { session.resolution = .discarded }
        let next = await startSession(request, references: session.references, harness: session.harness, model: session.model,
                                      clonedFrom: session.clonedFrom)
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
