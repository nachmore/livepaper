// Self tests for picking up changes other processes make on disk (WS-app): LibraryWatcher's
// classification and debounce, the real FSEvents stream over a scratch LIVEPAPER_HOME, and
// AppModel's quiet refresh. Packages are added the way the CLI adds them (LibraryService: a hidden
// staging directory renamed into place). Nothing here touches the user's real support directory.
import CoreServices
import Foundation
import LivePaperCore

extension SelfTests {
    static var appWatch: [TestCase] { [
        TestCase(name: "app.watch.classify") {
            let root = "/private/tmp/lp/Support"
            func c(_ relative: String, flags: Int = 0) -> DiskChanges {
                LibraryWatcher.classify(path: relative.isEmpty ? root : root + "/" + relative,
                                        flags: FSEventStreamEventFlags(flags), root: root)
            }
            // Packages appearing, disappearing or being renamed, and the files the UI reads.
            try expectEqual(c("Library"), .library)
            try expectEqual(c("Library/harbor.lpscene"), .library)
            try expectEqual(c("Library/harbor.lpscene/scene.json"), .library)
            try expectEqual(c("Library/harbor.lpscene/thumbnail.jpg"), .library)
            try expectEqual(c("Library/harbor.lpscene/history.jsonl"), .library)
            try expectEqual(c("Library/harbor.lpscene/.check/report.json"), .library)
            // What the live previews compile: scene.js and everything in assets/.
            try expectEqual(c("Library/harbor.lpscene/scene.js"), .library)
            try expectEqual(c("Library/harbor.lpscene/assets"), .library)
            try expectEqual(c("Library/harbor.lpscene/assets/water.png"), .library)
            try expectEqual(c("Library/harbor.lpscene/assets/tiles/a.png"), .library)
            try expectEqual(c("playlist-settings.json"), .playlist)
            // Noise: staging/deleted directories, atomic-write temporaries, check frames, contents
            // the UI doesn't show, other support files, AI workspaces.
            try expectEqual(c("Library/.staging-1234/scene.json"), [])
            try expectEqual(c("Library/.deleted-1234"), [])
            try expectEqual(c("Library/.DS_Store"), [])
            try expectEqual(c("Library/notes.txt"), [])
            try expectEqual(c("Library/harbor.lpscene/scene.json.sb-0c75a21f-F6iG7W"), [])
            try expectEqual(c("Library/harbor.lpscene/.check/still-8.png"), [])
            try expectEqual(c("Library/harbor.lpscene/scene.js.sb-0c75a21f-F6iG7W"), [])
            try expectEqual(c("Library/harbor.lpscene/.scene.js.swp"), [])
            try expectEqual(c("Library/harbor.lpscene/assets/.DS_Store"), [])
            try expectEqual(c("Library/harbor.lpscene/history/2026-11-15T10:00:00Z/scene.json"), [])
            try expectEqual(c("playlist-settings.json.sb-0c75a21f-HD9soJ"), [])
            try expectEqual(c("state.json"), [])
            try expectEqual(c("render.sock"), [])
            try expectEqual(c("Workspaces/s1/scene/scene.json"), [])
            // The root itself, a parent of it, and events that call for a rescan: everything.
            try expectEqual(c(""), .all)
            try expectEqual(LibraryWatcher.classify(path: "/private/tmp/lp", flags: 0, root: root), .all)
            try expectEqual(c("state.json", flags: kFSEventStreamEventFlagMustScanSubDirs), .all)
            try expectEqual(c("", flags: kFSEventStreamEventFlagRootChanged), .all)
            try expectEqual(c("Logs/x", flags: kFSEventStreamEventFlagKernelDropped), .all)
            // Outside the root, including a sibling that merely shares the prefix.
            try expectEqual(LibraryWatcher.classify(path: "/private/tmp/lp/Support2/Library/a.lpscene", flags: 0, root: root), [])
            try expectEqual(LibraryWatcher.classify(path: "/private/tmp/other/Library/a.lpscene", flags: 0, root: root), [])
        },
        TestCase(name: "app.watch.canonical-path") {
            let dir = try tempDir("canonical")
            defer { try? FileManager.default.removeItem(at: dir) }
            let real = LibraryWatcher.canonicalPath(dir)
            try expect(real.hasPrefix("/private/"), "the temporary directory resolves through /var → /private/var: \(real)")
            try expectEqual(LibraryWatcher.canonicalPath(dir.appendingPathComponent("not/yet")), real + "/not/yet")
        },
        TestCase(name: "app.watch.debounce") {
            let queue = DispatchQueue(label: "selftest.debounce")
            let fired = WatchLog<DiskChanges>()
            let debouncer = ChangeDebouncer(queue: queue, delay: 0.15, maxDelay: 0.6) { fired.append($0) }
            // A burst (signals 30 ms apart) fires once, after it ends, with the union.
            for i in 0..<6 {
                queue.async { debouncer.signal(i == 3 ? .playlist : .library) }
                Thread.sleep(forTimeInterval: 0.03)
            }
            try expectEqual(fired.values, [])
            Thread.sleep(forTimeInterval: 0.4)
            try expectEqual(fired.values, [.all])
            // Nothing pending: nothing fires; an empty signal is ignored.
            queue.async { debouncer.signal([]) }
            Thread.sleep(forTimeInterval: 0.3)
            try expectEqual(fired.values.count, 1)
            // A burst that doesn't end still fires (maxDelay), so the UI can't fall behind for long.
            for _ in 0..<30 {
                queue.async { debouncer.signal(.library) }
                Thread.sleep(forTimeInterval: 0.05)
            }
            try expect(fired.values.count >= 3, "fired \(fired.values.count - 1) times during a 1.5 s burst")
            Thread.sleep(forTimeInterval: 0.4)
            let afterBurst = fired.values.count
            // cancel() drops what is pending.
            queue.sync { debouncer.signal(.playlist); debouncer.cancel() }
            Thread.sleep(forTimeInterval: 0.4)
            try expectEqual(fired.values.count, afterBurst)
        },
        TestCase(name: "app.watch.package-add-remove") {
            try withScratchPaths("watch") { root in
                try FileManager.default.createDirectory(at: LPPaths.library, withIntermediateDirectories: true)
                let deliveries = Deliveries()
                let watcher = LibraryWatcher(root: LPPaths.supportRoot, deliveryQueue: deliveries.queue) { deliveries.append($0) }
                watcher.start()
                defer { watcher.stop() }
                try expect(watcher.isWatching)
                // Creating the directories just before the stream started may still be reported.
                try deliveries.settle(probe: LPPaths.library.appendingPathComponent("settle-probe.lpscene"))
                let library = cliLibrary(root: root, directory: LPPaths.library)

                // `livepaper import` adds a package: exactly one debounced change.
                let item = try library.importPackage(at: try makeScenePackage(in: root, id: "harbor-lights"))
                try expectEqual(deliveries.collect(), [.library])
                // Deleting it: exactly one more.
                try library.delete(id: item.id)
                try expectEqual(deliveries.collect(), [.library])

                // What the UI doesn't show reports nothing: AI workspaces, logs, state.json, staging
                // directories and check frames.
                let fm = FileManager.default
                let support = LPPaths.supportRoot
                let kept = try library.importPackage(at: try makeScenePackage(in: root, id: "tide-pool"))
                try expectEqual(deliveries.collect(), [.library])
                for dir in [LPPaths.workspaces.appendingPathComponent("s1/scene"), LPPaths.logs,
                            LPPaths.library.appendingPathComponent(".staging-test"), kept.packageURL.appendingPathComponent(".check")] {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                try Data("{}".utf8).write(to: LPPaths.workspaces.appendingPathComponent("s1/scene/scene.json"))
                try Data("log".utf8).write(to: LPPaths.logs.appendingPathComponent("renderd.log"))
                try Data("{}".utf8).write(to: support.appendingPathComponent("state.json"), options: .atomic)
                try Data("{}".utf8).write(to: LPPaths.library.appendingPathComponent(".staging-test/scene.json"))
                try Data("png".utf8).write(to: kept.packageURL.appendingPathComponent(".check/still-8.png"))
                try expectEqual(deliveries.collect(first: 1.2), [])
                // scene.js saved in an editor: the live previews compile it.
                try Data("// edited".utf8).write(to: kept.packageURL.appendingPathComponent("scene.js"))
                try expectEqual(deliveries.collect(), [.library])

                // `livepaper publish --scenes …` rewrites the playlist settings.
                try Data("{}".utf8).write(to: support.appendingPathComponent(PublishService.settingsFileName), options: .atomic)
                try expectEqual(deliveries.collect(), [.playlist])
                // Files inside a package rewritten in place (`livepaper thumbnail`, an editor).
                try Data("new jpeg".utf8).write(to: kept.packageURL.appendingPathComponent("thumbnail.jpg"))
                try expectEqual(deliveries.collect(), [.library])
                let handle = try FileHandle(forWritingTo: kept.packageURL.appendingPathComponent(SceneManifest.fileName))
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("\n".utf8))
                try handle.close()
                try expectEqual(deliveries.collect(), [.library])
                try Data("{}".utf8).write(to: kept.packageURL.appendingPathComponent(".check/report.json"), options: .atomic)
                try expectEqual(deliveries.collect(), [.library])

                // Stopped: nothing more, even for changes it would report. stop() is idempotent and
                // start() resumes.
                watcher.stop()
                watcher.stop()
                try expect(!watcher.isWatching)
                try library.delete(id: kept.id)
                try expectEqual(deliveries.collect(first: 1.2), [])
                watcher.start()
                _ = try library.importPackage(at: try makeScenePackage(in: root, id: "second-wind"))
                try expectEqual(deliveries.collect(), [.library])
            }
        },
        TestCase(name: "app.watch.cli-import-and-publish") {
            // The bug's repro end to end, with the real `livepaper` binary in a CLI sandbox:
            // `livepaper import` and `livepaper publish --scenes …` while a watcher watches.
            guard let binary = try CLITestSupport.binary() else { return }
            let sb = try CLISandbox(binary: binary)
            defer { sb.cleanup() }
            try sb.installFakeSaver()
            let deliveries = Deliveries()
            let watcher = LibraryWatcher(root: sb.support, deliveryQueue: deliveries.queue) { deliveries.append($0) }
            watcher.start()
            defer { watcher.stop() }
            try deliveries.settle(probe: sb.library.appendingPathComponent("settle-probe.lpscene"))

            let source = try makeScenePackage(in: sb.work, id: "harbor-lights")
            var r = try sb.run(["import", source.path])
            try expectEqual(r.status, 0)
            try expectEqual(deliveries.collect(), [.library])
            r = try sb.run(["list"])
            try expect(r.out.contains("harbor-lights"), r.out)

            r = try sb.run(["publish", "--scenes", "harbor-lights"])
            try expect(r.status == 0, "publish: \(r.status) \(r.err)")
            try expectEqual(deliveries.collect(), [.playlist])
        },
        TestCase(name: "app.watch.root-replaced") {
            // The support directory doesn't exist yet (first launch), then is deleted and created
            // again (uninstall, a reset): the watcher follows it each time.
            try withScratchPaths("watch-root") { root in
                let fm = FileManager.default
                try expect(!fm.fileExists(atPath: LPPaths.supportRoot.path))
                let deliveries = Deliveries()
                let watcher = LibraryWatcher(root: LPPaths.supportRoot, deliveryQueue: deliveries.queue) { deliveries.append($0) }
                watcher.start()
                defer { watcher.stop() }
                let library = cliLibrary(root: root, directory: LPPaths.library)

                _ = try library.importPackage(at: try makeScenePackage(in: root, id: "first-light"))
                try expect(deliveries.collectUnion().contains(.library), "creating the support directory is reported")
                _ = try library.importPackage(at: try makeScenePackage(in: root, id: "second-light"))
                try expectEqual(deliveries.collect(), [.library])

                try fm.removeItem(at: LPPaths.supportRoot)
                try expect(deliveries.collectUnion() == .all, "deleting the support directory is reported")
                _ = try library.importPackage(at: try makeScenePackage(in: root, id: "third-light"))
                try expect(deliveries.collectUnion().contains(.library), "re-creating it is reported")
                _ = try library.importPackage(at: try makeScenePackage(in: root, id: "fourth-light"))
                try expectEqual(deliveries.collect(), [.library])
            }
        },
        TestCase(name: "app.watch.release-without-stop") {
            try withScratchPaths("watch-release") { root in
                try FileManager.default.createDirectory(at: LPPaths.library, withIntermediateDirectories: true)
                let deliveries = Deliveries()
                var watcher: LibraryWatcher? = LibraryWatcher(root: LPPaths.supportRoot, deliveryQueue: deliveries.queue) { deliveries.append($0) }
                watcher?.start()
                try deliveries.settle(probe: LPPaths.library.appendingPathComponent("settle-probe.lpscene"))
                weak var released = watcher
                watcher = nil
                try expect(released == nil, "the stream doesn't keep the watcher alive")
                _ = try cliLibrary(root: root, directory: LPPaths.library).importPackage(at: try makeScenePackage(in: root, id: "gone"))
                try expectEqual(deliveries.collect(first: 1.2), [])
            }
        },
        TestCase(name: "app.model.picks-up-external-changes") {
            try withScratchPaths("disk-refresh") { root in
                let mockRoot = root.appendingPathComponent("Mock")
                let services = try MockServices.make(root: mockRoot, pace: 0)
                try MainActor.assumeIsolated {
                    var env = testEnvironment(root: root, saved: SavedStates())
                    env.diskWatchRoot = mockRoot   // the mocks keep Library/ and playlist-settings.json here
                    let model = AppModel(services: services, environment: env)
                    try awaitMain { await model.start() }
                    defer { model.stopWatchingDisk() }
                    try expect(model.isWatchingDisk)
                    // Seeding the mock library just before the stream started can still be reported;
                    // on a slow machine (CI) after more than a fixed pause. Wait until refreshes stop.
                    var seen = model.diskRefreshCount, quietSince = Date()
                    let settleLimit = Date().addingTimeInterval(10)
                    while Date().timeIntervalSince(quietSince) < 1.2 && Date() < settleLimit {
                        pumpMain(0.1)
                        if model.diskRefreshCount != seen { seen = model.diskRefreshCount; quietSince = Date() }
                    }
                    let baseline = model.diskRefreshCount
                    let before = model.entries.count
                    model.section = .library
                    model.libraryPath = ["neon-rain"]
                    model.query.text = "a"
                    let library = cliLibrary(root: root, directory: mockRoot.appendingPathComponent("Library"))

                    // Added by the CLI: shows up after exactly one quiet refresh; navigation and
                    // the search are untouched.
                    let item = try library.importPackage(at: try makeScenePackage(in: root, id: "harbor-lights"))
                    try awaitMain(timeout: 5, until: { model.entry(id: item.id) != nil })
                    pumpMain(1.0)
                    try expectEqual(model.diskRefreshCount - baseline, 1)
                    try expectEqual(model.entries.count, before + 1)
                    try expectEqual(model.libraryPath, ["neon-rain"])
                    try expectEqual(model.query.text, "a")
                    try expect(!model.isLoadingLibrary)
                    try expect(model.isInPlaylist(item.id), "\u{201C}all scenes\u{201D} includes it")

                    // The playlist settings changed by `livepaper publish --scenes …`.
                    var settings = model.playlist
                    settings.mode = .single
                    settings.sceneIDs = [item.id]
                    try JSONEncoder().encode(settings).write(to: mockRoot.appendingPathComponent("playlist-settings.json"), options: .atomic)
                    try awaitMain(timeout: 5, until: { model.playlist == settings })
                    try expect(!model.isInPlaylist("neon-rain"))
                    try expect(model.lastPublishResult == nil)

                    // A thumbnail rewritten under the same name gets a new revision (image views reload).
                    let revision = model.thumbnailRevision[item.id] ?? 0
                    try Data("re-rendered".utf8).write(to: item.packageURL.appendingPathComponent("thumbnail.jpg"))
                    try awaitMain(timeout: 5, until: { (model.thumbnailRevision[item.id] ?? 0) > revision })
                    // A new check report: open details reload.
                    let details = model.detailsRevision
                    try FileManager.default.createDirectory(at: item.packageURL.appendingPathComponent(".check"), withIntermediateDirectories: true)
                    try Data("{}".utf8).write(to: CheckReportFile.url(package: item.packageURL), options: .atomic)
                    try awaitMain(timeout: 5, until: { model.detailsRevision > details })

                    // Deleted in Finder while its details are open: the detail view is popped.
                    model.libraryPath = [item.id]
                    try FileManager.default.removeItem(at: item.packageURL)
                    try awaitMain(timeout: 5, until: { model.entry(id: item.id) == nil })
                    try expectEqual(model.libraryPath, [])

                    // Stopped: nothing is picked up any more.
                    model.stopWatchingDisk()
                    try expect(!model.isWatchingDisk)
                    let stoppedAt = model.diskRefreshCount
                    let late = try library.importPackage(at: try makeScenePackage(in: root, id: "too-late"))
                    pumpMain(1.2)
                    try expectEqual(model.diskRefreshCount, stoppedAt)
                    try expect(model.entry(id: late.id) == nil)
                    // … until the safety net (activation, the window opening) refreshes.
                    try awaitMain { await model.refreshFromDisk() }
                    try expect(model.entry(id: late.id) != nil)
                }
            }
        },
        TestCase(name: "app.model.failed-publish-stays-unpublished") {
            // A publish that fails leaves the saver on the previous playlist. The disk watcher sees
            // the settings file being written: it must not make the failed draft look current —
            // neither while the publish runs nor after it failed (Save & Publish would then have
            // nothing left to publish, and the menu bar would name a playlist that isn't playing).
            try withScratchPaths("failed-publish") { root in
                let mockRoot = root.appendingPathComponent("Mock")
                let mocks = try MockServices.make(root: mockRoot, pace: 0)
                let publish = try unwrap(mocks.publish as? MockPublishService)
                let services = LivePaperServices(library: mocks.library, publish: SlowPublish(base: publish, delay: 1.0), ai: mocks.ai,
                                                 install: mocks.install, render: mocks.render, checker: mocks.checker, compiler: mocks.compiler)
                try mocks.install.installSaver()
                try MainActor.assumeIsolated {
                    var env = testEnvironment(root: root, saved: SavedStates())
                    env.diskWatchRoot = mockRoot
                    let model = AppModel(services: services, environment: env)
                    try awaitMain { await model.start() }
                    defer { model.stopWatchingDisk() }
                    pumpMain(0.8)
                    let before = model.playlist
                    let draft = PlaylistSettings(mode: .single, sceneIDs: ["neon-rain"])
                    try expect(draft != before)
                    publish.failNextPublish = true
                    let done = WatchLog<Bool>()
                    Task { @MainActor in done.append(await model.savePlaylist(draft)) }
                    var sawDraft = false
                    try awaitMain(timeout: 10, until: {
                        sawDraft = sawDraft || model.playlist == draft
                        return !done.values.isEmpty
                    })
                    try expectEqual(done.values, [false])
                    pumpMain(1.2)   // the watcher has seen both writes
                    try expect(!sawDraft, "the failed draft looked current while it was being published")
                    try expectEqual(model.playlist, before)
                    try expectEqual(publish.loadSettings(), before)
                    // Published the second time: now it is current, on disk too.
                    try awaitMain { done.append(await model.savePlaylist(draft)) }
                    pumpMain(1.2)
                    try expectEqual(model.playlist, draft)
                    try expectEqual(publish.loadSettings(), draft)
                    try expect(model.lastPublishResult != nil)
                }
            }
        },
        TestCase(name: "app.model.refresh-coalesces") {
            try withModel("coalesce") { model, _ in
                try awaitMain {
                    async let a: Void = model.refreshFromDisk()
                    async let b: Void = model.refreshFromDisk(.library)
                    async let c: Void = model.refreshFromDisk(.playlist)
                    _ = await (a, b, c)
                }
                try expect((1...2).contains(model.diskRefreshCount), "three overlapping requests took \(model.diskRefreshCount) passes")
                try expect(!model.isLoadingLibrary, "quiet refreshes show no loading state")
            }
        },
        TestCase(name: "app.model.stale-read-dropped") {
            // Library reads run off the main actor: one that started earlier but finishes later
            // must not overwrite a newer result.
            try withScratchPaths("stale-read") { root in
                let mockRoot = root.appendingPathComponent("Mock")
                let mocks = try MockServices.make(root: mockRoot, pace: 0)
                let gated = GatedLibrary(base: mocks.library)
                let services = LivePaperServices(library: gated, publish: mocks.publish, ai: mocks.ai, install: mocks.install,
                                                 render: mocks.render, checker: mocks.checker, compiler: mocks.compiler)
                try MainActor.assumeIsolated {
                    let model = AppModel(services: services, environment: testEnvironment(root: root, saved: SavedStates()))
                    try awaitMain { await model.start() }
                    let before = model.entries.count
                    gated.holdNextRead()
                    let olderDone = WatchLog<Bool>()
                    Task { @MainActor in await model.reloadLibrary(); olderDone.append(true) }
                    try awaitMain(until: { gated.isHolding })   // the older read has taken its snapshot
                    _ = try cliLibrary(root: root, directory: mockRoot.appendingPathComponent("Library"))
                        .importPackage(at: try makeScenePackage(in: root, id: "harbor-lights"))
                    try awaitMain { await model.reloadLibrary() }
                    try expectEqual(model.entries.count, before + 1)
                    gated.release()
                    try awaitMain(until: { !olderDone.values.isEmpty })
                    try expectEqual(model.entries.count, before + 1)
                    try expect(model.entry(id: "harbor-lights") != nil)
                    try expect(!model.isLoadingLibrary)
                }
            }
        },
    ] }

    // MARK: - Helpers

    /// What the CLI uses to add scenes (LibraryService over `directory`; no built-ins).
    static func cliLibrary(root: URL, directory: URL) -> LibraryService {
        LibraryService(libraryDirectory: directory, builtinDirectory: root.appendingPathComponent("NoBuiltins"),
                       templateDirectory: root.appendingPathComponent("NoTemplate"))
    }

    /// A small web scene package (with a thumbnail) outside the watched tree, ready to import.
    static func makeScenePackage(in root: URL, id: String) throws -> URL {
        let package = root.appendingPathComponent("Incoming/\(id).\(SceneManifest.packageExtension)")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let name = id.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
        try SceneManifest(id: id, name: name, kind: .web).write(package: package)
        try Data("LivePaper.scene({ draw(lp) { lp.ctx.fillStyle = '#000'; lp.ctx.fillRect(0, 0, lp.w, lp.h); } });\n".utf8).write(to: package.appendingPathComponent("scene.js"))
        try Data("jpeg".utf8).write(to: package.appendingPathComponent("thumbnail.jpg"))
        return package
    }

    /// Drives the main run loop for `seconds` (MainActor tasks keep running).
    @MainActor static func pumpMain(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        try? awaitMain(timeout: seconds + 5, until: { Date() >= deadline })
    }

    /// Thread-safe list.
    final class WatchLog<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
        var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
        func take() -> [T] { lock.lock(); defer { items = []; lock.unlock() }; return items }
    }

    /// Changes a watcher delivered, on a queue of their own (the test thread just waits).
    final class Deliveries: @unchecked Sendable {
        let queue = DispatchQueue(label: "selftest.watch.delivery")
        private let recorded = WatchLog<DiskChanges>()
        func append(_ changes: DiskChanges) { recorded.append(changes) }

        /// Waits up to `first` seconds for a delivery, then `quiet` more seconds for any that
        /// follow (latency 0.2 s + debounce 0.3 s, so a second one would show up well within it),
        /// and returns everything delivered.
        func collect(first: TimeInterval = 5, quiet: TimeInterval = 1.0) -> [DiskChanges] {
            let deadline = Date().addingTimeInterval(first)
            while recorded.values.isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if !recorded.values.isEmpty { Thread.sleep(forTimeInterval: quiet) }
            return recorded.take()
        }

        /// Waits until everything that happened on disk before now has been delivered, and drops
        /// it. FSEvents delivers in event order, so once a probe package created and removed now is
        /// reported, nothing older is still on its way — which a fixed pause can't promise on a slow
        /// machine (CI). `probe` must be a visible `<name>.lpscene` in the library, so it's reported.
        func settle(probe: URL) throws {
            let fm = FileManager.default
            try fm.createDirectory(at: probe, withIntermediateDirectories: true)
            try fm.removeItem(at: probe)
            try expect(!collect(first: 10, quiet: 1.0).isEmpty, "the watcher didn't report \(probe.lastPathComponent)")
        }

        /// `collect()` merged into one value.
        func collectUnion() -> DiskChanges { collect().reduce(into: DiskChanges()) { $0.formUnion($1) } }
    }

    /// Forwards to another publisher; publishing takes `delay` seconds longer.
    final class SlowPublish: PublishServicing, @unchecked Sendable {
        let base: PublishServicing
        let delay: TimeInterval
        init(base: PublishServicing, delay: TimeInterval) { self.base = base; self.delay = delay }
        func loadSettings() -> PlaylistSettings { base.loadSettings() }
        func saveSettings(_ s: PlaylistSettings) throws { try base.saveSettings(s) }
        func publishReport() throws -> PublishResult {
            Thread.sleep(forTimeInterval: delay)
            return try base.publishReport()
        }
    }

    /// Forwards to another library, but can hold one read after it has taken its snapshot.
    final class GatedLibrary: LibraryServicing, @unchecked Sendable {
        let base: LibraryServicing
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var holdNext = false
        private var holding = false

        init(base: LibraryServicing) { self.base = base }

        func holdNextRead() { lock.lock(); holdNext = true; lock.unlock() }
        var isHolding: Bool { lock.lock(); defer { lock.unlock() }; return holding }
        func release() { gate.signal() }

        func scenes() throws -> [SceneItem] {
            let snapshot = try base.scenes()
            lock.lock()
            let hold = holdNext
            holdNext = false
            if hold { holding = true }
            lock.unlock()
            if hold {
                gate.wait()
                lock.lock(); holding = false; lock.unlock()
            }
            return snapshot
        }
        func scene(id: String) throws -> SceneItem? { try base.scene(id: id) }
        func createWebScene(name: String, description: String) throws -> SceneItem { try base.createWebScene(name: name, description: description) }
        func importVideo(from url: URL, name: String, optimizeForBattery: Bool,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> SceneItem {
            try await base.importVideo(from: url, name: name, optimizeForBattery: optimizeForBattery, progress: progress)
        }
        func clone(id: String, newName: String) throws -> SceneItem { try base.clone(id: id, newName: newName) }
        func delete(id: String) throws { try base.delete(id: id) }
        func update(_ manifest: SceneManifest) throws { try base.update(manifest) }
        func replaceContents(id: String, with package: URL) throws -> SceneItem { try base.replaceContents(id: id, with: package) }
        func importPackage(at url: URL) throws -> SceneItem { try base.importPackage(at: url) }
        func existingScene(matching url: URL) throws -> SceneImportMatch? { try base.existingScene(matching: url) }
        func openPackage(at url: URL) throws -> SceneOpenResult { try base.openPackage(at: url) }
        func exportPackage(id: String, to url: URL) throws { try base.exportPackage(id: id, to: url) }
    }
}
