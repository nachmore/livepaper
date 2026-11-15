// MockServices — complete, self-contained implementations of every service protocol, used with
// LIVEPAPER_MOCK=1, by the snapshot harness and by the self tests.
//
// Everything lives under one temporary root directory; nothing touches the user's real library,
// screen savers, wallpaper store or login items. `pace` scales all artificial delays (0 = instant).
import Foundation
import LivePaperCore

enum MockServices {
    /// Builds a full service container rooted at `root` (seeded with the sample library).
    static func make(root: URL, pace: Double = 1) throws -> LivePaperServices {
        let library = try MockLibraryService(root: root, pace: pace)
        let render = MockRenderClient()
        let compiler = MockSceneCompiler()
        return LivePaperServices(
            library: library,
            publish: MockPublishService(root: root, library: library, pace: pace),
            ai: MockAIService(library: library, workspaces: root.appendingPathComponent("Workspaces"), pace: pace),
            install: MockInstallService(),
            render: render,
            checker: MockSceneChecker(pace: pace),
            compiler: compiler)
    }

    /// A fresh per-process temporary root.
    static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("livepaper-mock-\(ProcessInfo.processInfo.processIdentifier)")
    }

    /// Sleeps `seconds × pace` (cooperatively cancellable).
    static func pause(_ seconds: Double, pace: Double) async throws {
        guard pace > 0 else { return try Task.checkCancellation() }
        try await Task.sleep(nanoseconds: UInt64(seconds * pace * 1_000_000_000))
    }

    static func writeReport(_ report: CheckReport, package: URL) throws {
        let dir = package.appendingPathComponent(".check")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(report).write(to: dir.appendingPathComponent("report.json"), options: .atomic)
    }

    static func appendHistory(_ lines: [[String: String]], package: URL) throws {
        guard !lines.isEmpty else { return }
        let url = package.appendingPathComponent(ProvenanceLog.fileName)
        var data = (try? Data(contentsOf: url)) ?? Data()
        for line in lines {
            data.append(try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Library

final class MockLibraryService: LibraryServicing, @unchecked Sendable {
    let userRoot: URL
    let builtinRoot: URL
    private let pace: Double
    /// Recursive: openPackage holds it across existingScene and importPackage.
    private let lock = NSRecursiveLock()
    private let fm = FileManager.default

    init(root: URL, pace: Double) throws {
        userRoot = root.appendingPathComponent("Library")
        builtinRoot = root.appendingPathComponent("Builtin")
        self.pace = pace
        let seeded = fm.fileExists(atPath: builtinRoot.path)
        try fm.createDirectory(at: userRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: builtinRoot, withIntermediateDirectories: true)
        if !seeded { try seed() }
    }

    private func seed() throws {
        for s in MockSampleData.samples() {
            let pkg = (s.builtin ? builtinRoot : userRoot).appendingPathComponent("\(s.manifest.id).\(SceneManifest.packageExtension)")
            try writePackage(manifest: s.manifest, style: s.style, to: pkg)
            try MockServices.appendHistory(s.history, package: pkg)
            if let r = s.check { try MockServices.writeReport(r, package: pkg) }
        }
    }

    private func writePackage(manifest: SceneManifest, style: MockArtwork.Style, to pkg: URL) throws {
        try fm.createDirectory(at: pkg, withIntermediateDirectories: true)
        try manifest.write(package: pkg)
        if manifest.kind == .web {
            try Data(MockSampleData.sceneJS.utf8).write(to: pkg.appendingPathComponent("scene.js"))
        }
        MockArtwork.writeImage(style: style, seed: MockArtwork.stableHash(manifest.id), width: 640, height: 400,
                               to: pkg.appendingPathComponent("thumbnail.jpg"))
    }

    private func packages(in dir: URL, builtin: Bool) -> [SceneItem] {
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == SceneManifest.packageExtension }.compactMap { url in
            (try? SceneManifest.load(package: url)).map { SceneItem(manifest: $0, packageURL: url, isBuiltin: builtin) }
        }.sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
    }

    func scenes() throws -> [SceneItem] {
        lock.lock(); defer { lock.unlock() }
        return packages(in: userRoot, builtin: false) + packages(in: builtinRoot, builtin: true)
    }

    func scene(id: String) throws -> SceneItem? { try scenes().first { $0.id == id } }

    private func userScene(_ id: String) throws -> SceneItem {
        guard let item = try scene(id: id) else { throw LibraryError.notFound(id) }
        guard !item.isBuiltin else { throw LibraryError.readOnly(item.manifest.name) }
        return item
    }

    private func uniqueID(for name: String) throws -> String {
        let base = SceneManifest.slug(from: name)
        let taken = Set(try scenes().map(\.id))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    private func packageURL(for id: String) -> URL {
        userRoot.appendingPathComponent("\(id).\(SceneManifest.packageExtension)")
    }

    func createWebScene(name: String, description: String) throws -> SceneItem {
        let id = try uniqueID(for: name)
        let m = SceneManifest(id: id, name: name, description: description, kind: .web, author: "you")
        let pkg = packageURL(for: id)
        try writePackage(manifest: m, style: .forScene(id: id, tags: []), to: pkg)
        return SceneItem(manifest: m, packageURL: pkg, isBuiltin: false)
    }

    func importVideo(from url: URL, name: String, optimizeForBattery: Bool,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> SceneItem {
        guard fm.fileExists(atPath: url.path) else { throw LibraryError.notFound(url.lastPathComponent) }
        let steps = optimizeForBattery ? 20 : 8
        for i in 1...steps {
            try await MockServices.pause(0.15, pace: pace)
            progress(Double(i) / Double(steps))
        }
        let id = try uniqueID(for: name)
        let ext = optimizeForBattery ? "mov" : (url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased())
        let m = SceneManifest(id: id, name: name, description: "Imported from \(url.lastPathComponent).", kind: .video,
                              video: .init(file: "video.\(ext)"), author: "you", tags: ["video"])
        let pkg = packageURL(for: id)
        try writePackage(manifest: m, style: .forScene(id: id, tags: ["ocean"]), to: pkg)
        try fm.copyItem(at: url, to: pkg.appendingPathComponent("video.\(ext)"))
        return SceneItem(manifest: m, packageURL: pkg, isBuiltin: false)
    }

    func clone(id: String, newName: String) throws -> SceneItem {
        guard let source = try scene(id: id) else { throw LibraryError.notFound(id) }
        let newID = try uniqueID(for: newName)
        let pkg = packageURL(for: newID)
        try fm.copyItem(at: source.packageURL, to: pkg)
        try? fm.removeItem(at: pkg.appendingPathComponent(".check"))
        var m = source.manifest
        m.id = newID; m.name = newName; m.parent = source.id; m.author = "you"
        m.created = Date(); m.updated = Date()
        try m.write(package: pkg)
        return SceneItem(manifest: m, packageURL: pkg, isBuiltin: false)
    }

    func delete(id: String) throws {
        let item = try userScene(id)
        try fm.removeItem(at: item.packageURL)
    }

    func update(_ manifest: SceneManifest) throws {
        let item = try userScene(manifest.id)
        try manifest.write(package: item.packageURL)
    }

    func replaceContents(id: String, with package: URL) throws -> SceneItem {
        let item = try userScene(id)
        let incoming = try SceneManifest.load(package: package)
        // Keep the previous version, like the real library does (ARCHITECTURE §10).
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = item.packageURL.appendingPathComponent("history/\(stamp)")
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for name in ["scene.json", "scene.js", "thumbnail.jpg"] {
            let src = item.packageURL.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: backup.appendingPathComponent(name)) }
        }
        for name in ["scene.js", "thumbnail.jpg", ".check"] {
            let src = package.appendingPathComponent(name), dst = item.packageURL.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: src, to: dst)
        }
        if let lines = try? Data(contentsOf: package.appendingPathComponent(ProvenanceLog.fileName)) {
            let url = item.packageURL.appendingPathComponent(ProvenanceLog.fileName)
            var data = (try? Data(contentsOf: url)) ?? Data()
            data.append(lines)
            try data.write(to: url, options: .atomic)
        }
        var m = item.manifest
        m.description = incoming.description.isEmpty ? m.description : incoming.description
        m.performance = incoming.performance
        m.updated = Date()
        try m.write(package: item.packageURL)
        return SceneItem(manifest: m, packageURL: item.packageURL, isBuiltin: false)
    }

    func importPackage(at url: URL) throws -> SceneItem {
        guard var m = try? SceneManifest.load(package: url) else { throw LibraryError.invalid("\(url.lastPathComponent) has no readable scene.json") }
        let taken = Set(try scenes().map(\.id))
        if taken.contains(m.id) || !SceneManifest.isValidID(m.id) { m.id = try uniqueID(for: m.name) }
        let pkg = packageURL(for: m.id)
        try fm.copyItem(at: url, to: pkg)
        m.updated = Date()
        try m.write(package: pkg)
        return SceneItem(manifest: m, packageURL: pkg, isBuiltin: false)
    }

    func existingScene(matching url: URL) throws -> SceneImportMatch? {
        let all = try scenes()
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if let item = all.first(where: { $0.packageURL.standardizedFileURL.resolvingSymlinksInPath().path == path }) { return .same(item) }
        guard let m = try? SceneManifest.load(package: url) else { return nil }
        return ScenePackageComparison.match(url, m, in: all)
    }

    func openPackage(at url: URL) throws -> SceneOpenResult {
        lock.lock(); defer { lock.unlock() }
        if let match = try? existingScene(matching: url) { return .existing(match) }
        return .imported(try importPackage(at: url))
    }

    func exportPackage(id: String, to url: URL) throws {
        guard let item = try scene(id: id) else { throw LibraryError.notFound(id) }
        if fm.fileExists(atPath: url.path) { throw LibraryError.exists(url.lastPathComponent) }
        try fm.copyItem(at: item.packageURL, to: url)
    }
}

// MARK: - Publish

final class MockPublishService: PublishServicing, @unchecked Sendable {
    private let settingsURL: URL
    private let library: MockLibraryService
    private let pace: Double
    private let lock = NSLock()
    private var generation = 0
    /// Test hook: the next publish throws.
    var failNextPublish = false
    /// Test/snapshot hook: scene id → reason; those scenes are left out like a real publish
    /// leaves out scenes that don't compile.
    var simulatedSkips: [String: String] = [:]

    struct PublishFailed: LocalizedError {
        var errorDescription: String? { "The screen saver bundle is busy (simulated failure)." }
    }

    init(root: URL, library: MockLibraryService, pace: Double) {
        settingsURL = root.appendingPathComponent("playlist-settings.json")
        self.library = library
        self.pace = pace
    }

    func loadSettings() -> PlaylistSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let s = try? JSONDecoder().decode(PlaylistSettings.self, from: data) else { return PlaylistSettings() }
        return s
    }

    func saveSettings(_ s: PlaylistSettings) throws {
        try JSONEncoder().encode(s).write(to: settingsURL, options: .atomic)
    }

    func publishReport() throws -> PublishResult {
        if pace > 0 { Thread.sleep(forTimeInterval: 0.4 * pace) }
        lock.lock(); defer { lock.unlock() }
        if failNextPublish { failNextPublish = false; throw PublishFailed() }
        let s = loadSettings()
        let scenes = try library.scenes()
        let byID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let chosen = PlaylistDraft(s).effectiveSceneIDs(available: scenes.map(\.id))
        guard !chosen.isEmpty else { throw PublishError.noScenes }
        let skipped = simulatedSkips.filter { chosen.contains($0.key) }
        let ids = chosen.filter { skipped[$0] == nil }
        guard !ids.isEmpty else { throw PublishError.nothingPublishable(skipped.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }) }
        generation += 1
        let entries: [LPPlaylistEntry] = ids.compactMap { id in
            guard let m = byID[id]?.manifest else { return nil }
            return m.kind == .video
                ? LPPlaylistEntry(id: id, name: m.name, kind: .video, file: "\(id).\(m.video.map { ($0.file as NSString).pathExtension } ?? "mov")",
                                  clock: m.clock.position, fit: m.video?.fit)
                : LPPlaylistEntry(id: id, name: m.name, kind: .web, file: "\(id).html", clock: m.clock.position)
        }
        let playlist = LPPlaylist(generation: generation, mode: s.mode, cycleMinutes: s.cycleMinutes, showClock: s.showClock,
                                  performance: s.performance, scenes: entries)
        return PublishResult(playlist: playlist, skipped: skipped)
    }
}

// MARK: - Install

final class MockInstallService: InstallServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var current: InstallStatus
    private var selectAttempts = 0
    /// The lock-keys value from before LivePaper's first change (what uninstall restores).
    private var lockKeysBefore = false
    /// Test hook: uninstall steps whose title contains this fail (and leave their part in place).
    var failingUninstallStep: String?

    init(status: InstallStatus = InstallStatus()) {
        current = status
    }

    private func mutate(_ f: (inout InstallStatus) -> Void) { lock.lock(); f(&current); lock.unlock() }

    func status() -> InstallStatus { lock.lock(); defer { lock.unlock() }; return current }

    /// Test hook: how often a saver was put in place (installSaver, updateSaver).
    private(set) var installCount = 0

    @discardableResult func installSaver() throws -> PublishResult? {
        mutate { $0.saverInstalled = true; $0.saverUpToDate = true; $0.saverNewerInstalled = false; installCount += 1 }
        return nil
    }

    /// InstallService's rules, minus the files: only an older installed build is replaced.
    func updateSaver(isSessionLocked: () -> Bool) throws -> SaverUpdateOutcome {
        lock.lock(); defer { lock.unlock() }
        guard current.saverUpdateAvailable else {
            return .skipped(current.saverInstalled ? (current.saverNewerInstalled ? "a newer build is installed" : "already this build")
                                                   : "not installed")
        }
        guard !isSessionLocked() else { return .skipped("the Mac is locked") }
        current.saverUpToDate = true
        installCount += 1
        return .updated(nil)
    }

    /// The first attempt "fails" so the guided step can be exercised; opening Screen Saver
    /// settings then simulates the user picking LivePaper there.
    func selectSaver() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard current.saverInstalled else { throw LibraryError.invalid("install the screen saver first") }
        selectAttempts += 1
        if selectAttempts > 1 { current.saverSelected = true }
        return current.saverSelected
    }

    func registerHelper() throws { mutate { $0.helperRunning = true; $0.helperLoginItem = .enabled; $0.passwordImmediately = true } }
    func unregisterHelper() throws { mutate { $0.helperRunning = false; $0.helperLoginItem = .notRegistered } }
    func openScreenSaverSettings() { mutate { $0.saverSelected = $0.saverInstalled } }
    /// Test hook: "Require password after screen saver begins" isn't Immediately.
    func simulatePasswordDelay() { mutate { $0.passwordImmediately = false } }
    /// Snapshot/test hook: the helper is registered but macOS waits for approval in Login Items.
    func simulateHelperApprovalPending() { mutate { $0.helperRunning = false; $0.helperLoginItem = .requiresApproval } }

    /// Same backup semantics as InstallService: the value from before LivePaper's first change is
    /// kept until the toggle returns to it or uninstall puts it back.
    func setLockKeysShowScene(_ on: Bool) throws {
        mutate { s in
            if s.lockKeysChangedByLivePaper && lockKeysBefore == on {
                s.lockKeysShowScene = on; s.lockKeysChangedByLivePaper = false
                return
            }
            guard s.lockKeysShowScene != on else { return }
            if !s.lockKeysChangedByLivePaper { lockKeysBefore = s.lockKeysShowScene; s.lockKeysChangedByLivePaper = true }
            s.lockKeysShowScene = on
        }
    }

    func performUninstall(removeLibrary: Bool) -> [InstallStep] {
        lock.lock(); defer { lock.unlock() }
        var steps: [InstallStep] = []
        func step(_ title: String, needed: Bool, skipReason: String, _ apply: () -> Void) {
            if !needed { steps.append(InstallStep(title: title, outcome: .skipped(skipReason))); return }
            if let failing = failingUninstallStep, title.contains(failing) {
                steps.append(InstallStep(title: title, outcome: .failed("simulated failure")))
                return
            }
            apply()
            steps.append(InstallStep(title: title, outcome: .done))
        }
        step("Unregister the helper login item", needed: current.helperRunning, skipReason: "not registered") {
            current.helperRunning = false; current.helperLoginItem = .notRegistered
        }
        step("Restore the previous screen saver choice", needed: current.saverSelected, skipReason: "LivePaper didn't change it") {
            current.saverSelected = false
        }
        step(InstallService.restoreLockKeysTitle, needed: current.lockKeysChangedByLivePaper, skipReason: "not changed by LivePaper") {
            current.lockKeysShowScene = lockKeysBefore; current.lockKeysChangedByLivePaper = false
        }
        step("Remove \(LPPaths.installedSaver.path)", needed: current.saverInstalled, skipReason: "not installed") {
            current.saverInstalled = false; current.saverUpToDate = false
        }
        step(removeLibrary ? "Delete \(LPPaths.supportRoot.path), including the scene library"
                           : "Delete LivePaper's caches, workspaces and backups (keeping the scene library)",
             needed: true, skipReason: "") {}
        return steps
    }
}

// MARK: - Render / check / compile

final class MockRenderClient: RenderClienting, @unchecked Sendable {
    func send(_ request: RenderRequest, timeout: TimeInterval) async throws -> RenderResponse {
        switch request.op {
        case .thumbnail:
            guard let scene = request.scene, let out = request.out else { return RenderResponse(ok: false, errors: ["missing scene/out"]) }
            let m = try? SceneManifest.load(package: URL(fileURLWithPath: scene))
            let style = MockArtwork.Style.forScene(id: m?.id ?? scene, tags: m?.tags ?? [])
            let ok = MockArtwork.writeImage(style: style, seed: MockArtwork.stableHash(m?.id ?? scene), width: 640, height: 400,
                                            to: URL(fileURLWithPath: out))
            return RenderResponse(ok: ok, ready: ok, out: out)
        case .still:
            guard let out = request.out else { return RenderResponse(ok: false, errors: ["missing out"]) }
            let w = Int(request.width ?? 640), h = Int(request.height ?? 400)
            let ok = MockArtwork.writeImage(style: .aurora, seed: 1, width: w, height: h, t: request.t ?? 8, to: URL(fileURLWithPath: out))
            return RenderResponse(ok: ok, ready: ok, out: out, meanLuma: 38, clockLuma: 22)
        case .bench:
            return RenderResponse(ok: true, ready: true, benchMs: 1.4)
        case .live:
            return RenderResponse(ok: true, ready: true, fps: request.fps ?? 30, cpuPct: 4.2, cpuMW: 61, seconds: request.seconds)
        case .motion:
            // Gently alive everywhere: every tile changes a little within 2 s and 5 s.
            let (cols, rows) = MotionAnalysis.grid(width: Int(request.width ?? 1280), height: Int(request.height ?? 720))
            let tiles = { (level: Double) in MotionTiles(level: Array(repeating: level, count: cols * rows), area: Array(repeating: 0.1, count: cols * rows)) }
            let samples = (request.times ?? MotionAnalysis.defaultTimes).map { t in
                MotionSample(t: t, gaps: [MotionGap(gap: 0.5, tiles: tiles(0.4)), MotionGap(gap: 2, tiles: tiles(1.5)), MotionGap(gap: 5, tiles: tiles(3))],
                             flicker: tiles(0.2))
            }
            return RenderResponse(ok: true, ready: true, motion: MotionMeasurement(width: cols * 40, height: rows * 40, cols: cols, rows: rows, samples: samples))
        case .ping, .shutdown:
            return RenderResponse(ok: true, ready: true)
        }
    }
}

final class MockSceneCompiler: SceneCompiling, @unchecked Sendable {
    func compile(package: URL, to output: URL) throws {
        let m = try SceneManifest.load(package: package)
        guard m.kind == .web else { throw LibraryError.invalid("\(m.name) is a video scene") }
        let html = MockArtwork.html(name: m.name, style: .forScene(id: m.id, tags: m.tags))
        try Data(html.utf8).write(to: output, options: .atomic)
    }
}

final class MockSceneChecker: SceneChecking, @unchecked Sendable {
    private let pace: Double
    init(pace: Double) { self.pace = pace }

    func check(package: URL, options: CheckOptions) async throws -> CheckReport {
        try await MockServices.pause(options.quick ? 0.6 : 1.8, pace: pace)
        let m = try SceneManifest.load(package: package)
        let style = MockArtwork.Style.forScene(id: m.id, tags: m.tags)
        let heavy = style == .glass
        let dir = package.appendingPathComponent(".check")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var stills: [CheckReport.Still] = []
        for (i, size) in [(1600, 450), (1512, 945), (1280, 1024)].enumerated() {
            let url = dir.appendingPathComponent("still-\(i).png")
            MockArtwork.writeImage(style: style, seed: MockArtwork.stableHash(m.id), width: size.0 / 4, height: size.1 / 4,
                                   t: Double(4 + i * 6), to: url)
            stills.append(.init(path: url.path, width: size.0, height: size.1, dpr: 2, t: Double(4 + i * 6), meanLuma: 40, clockLuma: 24))
        }
        let bench = heavy ? 5.6 : 1.4
        let report = CheckReport(
            passed: !heavy,
            problems: heavy ? ["Bench is 5.6 ms/frame at 1512x982@2 (budget 4 ms). Draw fewer overlapping translucent shapes."] : [],
            stills: stills, benchMs: ["1512x982@2 t=14": bench, "5120x1440@1 t=14": bench * 1.6],
            energyMw: options.power ? (heavy ? 310 : 64) : nil)
        try MockServices.writeReport(report, package: package)
        return report
    }
}
