// PublishService — compiles the playlist's scenes into the installed screen saver.
//
// The saver runs sandboxed in legacyScreenSaver and can read only its own bundle, so content is
// published INTO it (ARCHITECTURE §4.3):
//   LivePaper.saver/Contents/Resources/Playlist/{playlist.json, <id>.html, <id>.<video-ext>}
// A publish builds `Playlist.new/` next to the live directory and swaps the two with one atomic
// rename, so a saver starting at any moment (or a crash mid-publish) sees a complete playlist.
import Darwin
import Foundation
import os

public enum PublishError: Error, LocalizedError, Sendable, Equatable {
    case saverNotInstalled(String)
    case noScenes
    case nothingPublishable([String])

    public var errorDescription: String? {
        switch self {
        case .saverNotInstalled(let path):
            return "The LivePaper screen saver isn't installed (expected at \(path)). Install it from LivePaper's settings first."
        case .noScenes:
            return "There are no scenes to publish yet."
        case .nothingPublishable(let reasons):
            return "None of the selected scenes could be published: " + reasons.joined(separator: "; ")
        }
    }
}

public final class PublishService: PublishServicing, @unchecked Sendable {
    public static let settingsFileName = "playlist-settings.json"
    static let stagingName = "Playlist.new"

    public let settingsURL: URL
    /// The installed saver bundle (…/Screen Savers/LivePaper.saver).
    public let saverURL: URL
    private let library: LibraryServicing
    private let compiler: SceneCompiling
    private let lockURL: URL
    private let notify: @Sendable (String) -> Void
    /// The collections a playlist may follow (PlaylistSettings.collectionID); nil: none.
    private let collections: CollectionStore?
    private let lock = NSLock()
    private let log = Logger(subsystem: LPPaths.bundleID, category: "publish")

    /// - Parameter notify: posts a notification name after a successful publish (default: a
    ///   distributed notification so running saver previews reload; tests inject a recorder).
    public init(library: LibraryServicing, compiler: SceneCompiling,
                settingsURL: URL = LPPaths.supportRoot.appendingPathComponent(PublishService.settingsFileName),
                saverURL: URL = LPPaths.installedSaver,
                lockURL: URL = LPPaths.supportRoot.appendingPathComponent("publish.lock"),
                notify: @escaping @Sendable (String) -> Void = { PublishService.postDistributedNotification($0) },
                collections: CollectionStore? = nil) {
        self.library = library; self.compiler = compiler; self.settingsURL = settingsURL
        self.saverURL = saverURL; self.lockURL = lockURL; self.notify = notify; self.collections = collections
    }

    public static func postDistributedNotification(_ name: String) {
        DistributedNotificationCenter.default().postNotificationName(.init(name), object: nil, userInfo: nil, deliverImmediately: true)
    }

    // MARK: - Settings

    public func loadSettings() -> PlaylistSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(PlaylistSettings.self, from: data) else { return PlaylistSettings() }
        return settings
    }

    public func saveSettings(_ s: PlaylistSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileOps.writeAtomically(try encoder.encode(s), to: settingsURL)
    }

    // MARK: - Publishing

    public var playlistDirectory: URL {
        saverURL.appendingPathComponent("Contents/Resources").appendingPathComponent(LPPlaylist.directoryName)
    }

    /// Publishes and reports scenes that had to be skipped (`publish()` is the short form).
    @discardableResult public func publishReport() throws -> PublishResult {
        // In-process lock + cross-process file lock: the app and `livepaper publish` may race.
        lock.lock(); defer { lock.unlock() }
        return try FileLock.withLock(at: lockURL) { try publishLocked() }
    }

    private func publishLocked() throws -> PublishResult {
        guard FileOps.isRegularFile(saverURL.appendingPathComponent("Contents/Info.plist")) else {
            throw PublishError.saverNotInstalled(saverURL.path)
        }
        // A playlist that follows a collection plays the collection as it is now (a live link).
        let settings = loadSettings().following(collections?.load().collections ?? [])
        let (chosen, all) = try resolveScenes(settings)
        let fm = FileManager.default
        let live = playlistDirectory
        let staging = live.deletingLastPathComponent().appendingPathComponent(Self.stagingName)
        try FileOps.removeIfPresent(staging)   // leftover from an interrupted publish
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            var entries: [LPPlaylistEntry] = []
            var skipped: [String: String] = [:]
            for scene in chosen {
                do { entries.append(try stage(scene, into: staging)) } catch {
                    skipped[scene.id] = error.localizedDescription
                    log.error("skipping \(scene.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            guard !entries.isEmpty else {
                throw PublishError.nothingPublishable(skipped.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" })
            }
            let (displays, displayScenes) = stageDisplayScenes(settings.displays, deck: entries, library: all,
                                                               into: staging, skipped: &skipped)
            let previous = (try? LPPlaylist.load(from: live))?.generation ?? 0
            let playlist = LPPlaylist(generation: previous + 1, mode: settings.mode, cycleMinutes: max(0, settings.cycleMinutes),
                                      showClock: settings.showClock, performance: settings.performance, scenes: entries,
                                      displays: displays, displayScenes: displayScenes)
            try playlist.write(to: staging)
            try FileOps.installReplacing(live, with: staging)
            log.info("published generation \(playlist.generation) with \(entries.count) scene(s)")
            notify(LPNotification.published)
            return PublishResult(playlist: playlist, skipped: skipped)
        } catch {
            try? FileOps.removeIfPresent(staging)
            throw error
        }
    }

    /// The playlist's scenes in order; an empty selection means every scene. If none of the
    /// selected ids still exist the playlist falls back to every scene rather than going blank.
    /// Also returns the whole library (display assignments may name scenes outside the playlist).
    private func resolveScenes(_ settings: PlaylistSettings) throws -> (chosen: [SceneItem], all: [SceneItem]) {
        let all = try library.scenes()
        guard !all.isEmpty else { throw PublishError.noScenes }
        guard !settings.sceneIDs.isEmpty else { return (all, all) }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let chosen = settings.sceneIDs.compactMap { id -> SceneItem? in seen.insert(id).inserted ? byID[id] : nil }
        if chosen.isEmpty { log.notice("none of the playlist's scenes exist any more; publishing all scenes") }
        return (chosen.isEmpty ? all : chosen, all)
    }

    /// The display settings to publish, and the scenes staged only for displays assigned to them
    /// ("Choose per display", ARCHITECTURE §4.3). Mode and battery behaviour are always published.
    /// Assignments are published only in `choose` mode and only when their scene made it into the
    /// playlist: a deck scene, or a library scene staged here once (into `displayScenes`). An unknown
    /// scene is dropped with a log line (the app shows it as deleted); one that fails to stage is
    /// reported in `skipped` like a deck scene and its displays play the playlist.
    private func stageDisplayScenes(_ requested: LPDisplaySettings, deck: [LPPlaylistEntry], library all: [SceneItem],
                                    into staging: URL, skipped: inout [String: String]) -> (LPDisplaySettings, [LPPlaylistEntry]) {
        var published = LPDisplaySettings(mode: requested.mode, assignments: [:], onBattery: requested.onBattery)
        guard requested.mode == .choose else { return (published, []) }
        let deckIDs = Set(deck.map(\.id))
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var extras: [LPPlaylistEntry] = [], staged: [String: Bool] = [:]
        for (display, id) in LPDisplaySettings.normalized(requested.assignments).sorted(by: { $0.key < $1.key }) {
            if deckIDs.contains(id) { published.assignments[display] = id; continue }
            if let ok = staged[id] {
                if ok { published.assignments[display] = id }
                continue
            }
            // A playlist scene that failed above is already reported; don't stage it twice.
            guard skipped[id] == nil, let scene = byID[id] else {
                if skipped[id] == nil { log.notice("display \(display, privacy: .public) is assigned \(id, privacy: .public), which isn't in the library; it plays the playlist") }
                staged[id] = false
                continue
            }
            do {
                extras.append(try stage(scene, into: staging))
                staged[id] = true
                published.assignments[display] = id
            } catch {
                staged[id] = false
                skipped[id] = error.localizedDescription
                log.error("skipping \(id, privacy: .public) (assigned to a display): \(error.localizedDescription, privacy: .public)")
            }
        }
        return (published, extras)
    }

    private func stage(_ scene: SceneItem, into staging: URL) throws -> LPPlaylistEntry {
        let m = scene.manifest
        switch m.kind {
        case .web:
            let file = "\(scene.id).html"
            let output = staging.appendingPathComponent(file)
            try compiler.compile(package: scene.packageURL, to: output)
            guard let size = (try? output.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else {
                throw LibraryError.invalid("compiling \(scene.id) produced no output.")
            }
            // Not scene.json's claim alone: a scene that breaks the span rules would drift apart (PublishedSpan).
            return LPPlaylistEntry(id: scene.id, name: m.name, kind: .web, file: file, clock: m.clock.position,
                                   span: PublishedSpan.spans(scene))
        case .video:
            // scene.json is untrusted input: the video must be a plain file inside the package.
            guard let video = m.video, LibraryService.isPlainFileName(video.file) else {
                throw LibraryError.invalid("\(scene.id) has no video file.")
            }
            let source = scene.packageURL.appendingPathComponent(video.file)
            guard FileOps.isRegularFile(source) else { throw LibraryError.invalid("\(scene.id): \(video.file) is missing.") }
            let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
            // The saver drops entries it can't play; say so here, where the user can act on it.
            guard LPPlaylistEntry.videoExtensions.contains(ext) else {
                throw LibraryError.invalid("\(scene.id): the screen saver can't play .\(ext) files. Import the video again to convert it.")
            }
            let file = "\(scene.id).\(ext)"
            try FileOps.hardLinkOrCopy(from: source, to: staging.appendingPathComponent(file))
            return LPPlaylistEntry(id: scene.id, name: m.name, kind: .video, file: file, clock: m.clock.position, fit: video.fit,
                                   span: m.spans)
        }
    }
}
