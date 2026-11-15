// LibraryWatcher — notices changes other processes make to the scene library and the playlist
// settings (the `livepaper` CLI, Finder, an editor) so the app shows them without a relaunch.
// Foundation + CoreServices only; also compiled into LivePaperSelfTest via
// Sources/LivePaperSelfTest/AppLogic/.
//
// Why FSEvents rather than kqueue (DispatchSource.makeFileSystemObjectSource):
//   * The UI shows files *inside* packages (scene.json, thumbnail.jpg, history.jsonl,
//     .check/report.json). One FSEvents stream covers the whole tree. kqueue needs an open
//     descriptor per watched vnode (a directory's vnode doesn't see in-place rewrites of its files,
//     so it would be one per file): hundreds of descriptors for a big library, in a GUI process
//     whose soft limit starts at 256.
//   * FSEvents is path based, so deleting, replacing or creating the library or support directory
//     later is just more events (plus RootChanged, handled below). kqueue watches inodes and has to
//     be re-armed by hand whenever a directory is replaced.
//   * fseventsd coalesces events (`latency`), and excluded subtrees (AI workspaces, logs, backups)
//     never reach the process. While nothing changes, nothing runs here: no timers, no polling.
// The built-in scenes aren't watched: they ship inside the signed app bundle and can't change.
//
// Pipeline: FSEvents batches (latency 0.2 s) → `classify` keeps only the paths the UI shows → a
// trailing debounce (0.3 s after the last relevant event, at most 2 s after the first) → one
// `onChange` on the delivery queue with the union of what changed.
import CoreServices
import Foundation
import LivePaperCore
import os

/// What changed on disk, as far as the UI is concerned.
struct DiskChanges: OptionSet, Sendable, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    /// The scene library: a package added, removed or renamed, or a file the UI reads changed.
    static let library = DiskChanges(rawValue: 1 << 0)
    /// playlist-settings.json (e.g. `livepaper publish --scenes …`).
    static let playlist = DiskChanges(rawValue: 1 << 1)
    static let all: DiskChanges = [.library, .playlist]
}

/// Coalesces bursts of signals: `fire` runs once, `delay` after the last `signal` but never later
/// than `maxDelay` after the first signal of the burst, with the union of everything signalled.
/// Confined to `queue`: call `signal` and `cancel` there (`fire` runs there too).
final class ChangeDebouncer: @unchecked Sendable {
    let delay: TimeInterval
    let maxDelay: TimeInterval
    private let queue: DispatchQueue
    private let fire: (DiskChanges) -> Void
    private var pending: DiskChanges = []
    private var burstStart: DispatchTime?
    private var scheduled: DispatchWorkItem?

    init(queue: DispatchQueue, delay: TimeInterval = 0.3, maxDelay: TimeInterval = 2, fire: @escaping (DiskChanges) -> Void) {
        self.queue = queue
        self.delay = delay
        self.maxDelay = max(maxDelay, delay)
        self.fire = fire
    }

    func signal(_ changes: DiskChanges) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !changes.isEmpty else { return }
        pending.formUnion(changes)
        let now = DispatchTime.now()
        let start = burstStart ?? now
        burstStart = start
        scheduled?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        scheduled = item
        queue.asyncAfter(deadline: min(now + delay, start + maxDelay), execute: item)
    }

    /// Drops anything pending; nothing fires until the next `signal`.
    func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        scheduled?.cancel()
        scheduled = nil
        pending = []
        burstStart = nil
    }

    private func flush() {
        let changes = pending
        pending = []
        burstStart = nil
        scheduled = nil
        if !changes.isEmpty { fire(changes) }
    }
}

/// Watches one support directory (LPPaths.supportRoot, or the mock root in sample mode):
/// `Library/` recursively and `playlist-settings.json`.
final class LibraryWatcher: @unchecked Sendable {
    /// Paths relative to the watched root.
    static let libraryDirectoryName = LPPaths.library.lastPathComponent
    static let playlistSettingsName = PublishService.settingsFileName
    /// Never delivered at all (busy while agents work, irrelevant to the UI).
    static let excludedNames = [LPPaths.workspaces, LPPaths.logs, LPPaths.backups].map(\.lastPathComponent)
    /// Files inside a package that the library grid, the playlist and the detail view read.
    static let packageFiles: Set<String> = [SceneManifest.fileName, "thumbnail.jpg", ProvenanceLog.fileName, CheckReportFile.relativePath]

    let root: URL
    private let latency: CFTimeInterval
    private let queue = DispatchQueue(label: "com.nachmore.livepaper.library-watcher", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private let deliveryQueue: DispatchQueue
    private let onChange: @Sendable (DiskChanges) -> Void
    private let box = WatcherBox()
    private let log = Logger(subsystem: LPPaths.bundleID, category: "library-watcher")
    private var debouncer: ChangeDebouncer!
    // Confined to `queue`:
    private var stream: FSEventStreamRef?
    private var canonicalRoot = ""
    /// (device, inode) of the root when the stream started; nil while it doesn't exist.
    private var rootIdentity: FileIdentity?
    private var isRunning = false
    /// `isRunning` for the delivery queue: nothing is delivered once `stop` has returned.
    private let delivering = OSAllocatedUnfairLock(initialState: false)

    /// `onChange` runs on `deliveryQueue` (default: main).
    init(root: URL, latency: TimeInterval = 0.2, debounce: TimeInterval = 0.3, maxDelay: TimeInterval = 2,
         deliveryQueue: DispatchQueue = .main, onChange: @escaping @Sendable (DiskChanges) -> Void) {
        self.root = root
        self.latency = latency
        self.deliveryQueue = deliveryQueue
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: ())
        box.watcher = self
        debouncer = ChangeDebouncer(queue: queue, delay: debounce, maxDelay: maxDelay) { [weak self] changes in
            guard let self, self.isRunning else { return }
            self.deliveryQueue.async {
                guard self.delivering.withLock({ $0 }) else { return }
                self.onChange(changes)
            }
        }
    }

    deinit { onQueue { tearDown() } }

    /// Starts watching; changes made after this returns are reported. Idempotent.
    func start() {
        onQueue {
            guard !isRunning else { return }
            isRunning = true
            delivering.withLock { $0 = true }
            startStream()
        }
    }

    /// Stops watching and drops anything not yet delivered. Idempotent; `start` may follow.
    func stop() { onQueue { tearDown() } }

    var isWatching: Bool { onQueue { stream != nil } }

    // MARK: - Classification (pure)

    /// What one FSEvents event means for the UI. `root` is the canonical (realpath) watched root:
    /// FSEvents reports canonical paths (/private/var/…, not /var/…).
    static func classify(path: String, flags: FSEventStreamEventFlags, root: String) -> DiskChanges {
        let rescan = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
        if flags & FSEventStreamEventFlags(rescan) != 0 { return .all }
        let path = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        // The root itself (or a directory above it) appeared, vanished or moved: everything may differ.
        if path == root || root.hasPrefix(path == "/" ? "/" : path + "/") { return .all }
        guard path.hasPrefix(root + "/") else { return [] }
        let components = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        return classify(relative: components)
    }

    /// `components`: the event's path below the root.
    static func classify(relative components: [String]) -> DiskChanges {
        guard let first = components.first else { return .all }
        if first == playlistSettingsName { return components.count == 1 ? .playlist : [] }
        guard first == libraryDirectoryName else { return [] }   // state.json, render.sock, ai-settings.json, …
        guard components.count > 1 else { return .library }       // the library directory itself
        let package = components[1]
        // Hidden entries are staging/deleted directories (LibraryService) and Finder litter; their
        // contents only become a scene through a rename, which is reported under the final name.
        guard !package.hasPrefix("."), package.hasSuffix("." + SceneManifest.packageExtension) else { return [] }
        guard components.count > 2 else { return .library }       // a package added, removed or renamed
        return packageFiles.contains(components.dropFirst(2).joined(separator: "/")) ? .library : []
    }

    /// realpath() of the deepest existing ancestor plus the components that don't exist yet.
    static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while true {
            if let resolved = realpath(existing.path, nil) {
                defer { free(resolved) }
                var path = String(cString: resolved)
                for component in missing.reversed() { path = (path as NSString).appendingPathComponent(component) }
                return path
            }
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { return url.standardizedFileURL.path }
            missing.append(existing.lastPathComponent)
            existing = parent
        }
    }

    // MARK: - Stream (on `queue`)

    private func onQueue<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: queueKey) != nil ? body() : queue.sync(execute: body)
    }

    private func startStream() {
        guard isRunning, stream == nil else { return }
        canonicalRoot = Self.canonicalPath(root)
        rootIdentity = FileIdentity(path: canonicalRoot)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: { info in
                                               guard let info else { return nil }
                                               _ = Unmanaged<WatcherBox>.fromOpaque(info).retain()
                                               return info
                                           },
                                           release: { info in
                                               guard let info else { return }
                                               Unmanaged<WatcherBox>.fromOpaque(info).release()
                                           },
                                           copyDescription: nil)
        // WatchRoot: a RootChanged event when the root (or a parent) is created, moved or deleted.
        // A stream whose root doesn't exist yet reports nothing else, so it is restarted then.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, Self.callback, &context, [canonicalRoot] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            log.error("couldn't create an FSEvents stream for \(self.canonicalRoot, privacy: .public)")
            return
        }
        // Exclusions only match canonical paths.
        FSEventStreamSetExclusionPaths(created, Self.excludedNames.map { (canonicalRoot as NSString).appendingPathComponent($0) } as CFArray)
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            log.error("couldn't start the FSEvents stream for \(self.canonicalRoot, privacy: .public)")
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func tearDown() {
        isRunning = false
        delivering.withLock { $0 = false }
        debouncer?.cancel()
        stopStream()
    }

    fileprivate func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard isRunning else { return }
        var changes: DiskChanges = []
        var rootChanged = false
        for (path, flag) in zip(paths, flags) {
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 { rootChanged = true }
            changes.formUnion(Self.classify(path: path, flags: flag, root: canonicalRoot))
        }
        // Re-create the stream when the root itself was replaced, appeared or vanished (not from
        // inside its own callback). Comparing identities keeps a spurious RootChanged from looping.
        if rootChanged, FileIdentity(path: canonicalRoot) != rootIdentity || Self.canonicalPath(root) != canonicalRoot {
            queue.async { [weak self] in
                guard let self, self.isRunning else { return }
                self.stopStream()
                self.startStream()
            }
        }
        debouncer.signal(changes)
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info, let watcher = Unmanaged<WatcherBox>.fromOpaque(info).takeUnretainedValue().watcher else { return }
        let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
        let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
        watcher.handle(paths: paths, flags: flags)
    }
}

/// What the FSEvents context points at: a weak reference, so a late callback can't outlive the watcher.
private final class WatcherBox: @unchecked Sendable {
    weak var watcher: LibraryWatcher?
}

/// A file's (device, inode): tells "the same directory" from "deleted and created again".
private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}
