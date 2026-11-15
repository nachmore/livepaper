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

/// Outcome of a publish, including scenes that were left out (the saver still gets the rest).
public struct PublishResult: Sendable, Equatable {
    public var playlist: LPPlaylist
    /// Scene id → why it was skipped (compile error, missing video, …).
    public var skipped: [String: String]
    public init(playlist: LPPlaylist, skipped: [String: String]) { self.playlist = playlist; self.skipped = skipped }
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
    private let lock = NSLock()
    private let log = Logger(subsystem: LPPaths.bundleID, category: "publish")

    /// - Parameter notify: posts a notification name after a successful publish (default: a
    ///   distributed notification so running saver previews reload; tests inject a recorder).
    public init(library: LibraryServicing, compiler: SceneCompiling,
                settingsURL: URL = LPPaths.supportRoot.appendingPathComponent(PublishService.settingsFileName),
                saverURL: URL = LPPaths.installedSaver,
                lockURL: URL = LPPaths.supportRoot.appendingPathComponent("publish.lock"),
                notify: @escaping @Sendable (String) -> Void = { PublishService.postDistributedNotification($0) }) {
        self.library = library; self.compiler = compiler; self.settingsURL = settingsURL
        self.saverURL = saverURL; self.lockURL = lockURL; self.notify = notify
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

    @discardableResult public func publish() throws -> LPPlaylist { try publishReport().playlist }

    /// Like publish(), but also reports scenes that had to be skipped.
    @discardableResult public func publishReport() throws -> PublishResult {
        // In-process lock + cross-process file lock: the app and `livepaper publish` may race.
        lock.lock(); defer { lock.unlock() }
        return try FileLock.withLock(at: lockURL) { try publishLocked() }
    }

    private func publishLocked() throws -> PublishResult {
        guard FileOps.isRegularFile(saverURL.appendingPathComponent("Contents/Info.plist")) else {
            throw PublishError.saverNotInstalled(saverURL.path)
        }
        let settings = loadSettings()
        let chosen = try resolveScenes(settings)
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
            let previous = (try? LPPlaylist.load(from: live))?.generation ?? 0
            let playlist = LPPlaylist(generation: previous + 1, mode: settings.mode, cycleMinutes: max(0, settings.cycleMinutes),
                                      showClock: settings.showClock, performance: settings.performance, scenes: entries)
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
    private func resolveScenes(_ settings: PlaylistSettings) throws -> [SceneItem] {
        let all = try library.scenes()
        guard !all.isEmpty else { throw PublishError.noScenes }
        guard !settings.sceneIDs.isEmpty else { return all }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let chosen = settings.sceneIDs.compactMap { id -> SceneItem? in seen.insert(id).inserted ? byID[id] : nil }
        if chosen.isEmpty { log.notice("none of the playlist's scenes exist any more; publishing all scenes") }
        return chosen.isEmpty ? all : chosen
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
            return LPPlaylistEntry(id: scene.id, name: m.name, kind: .web, file: file, clock: m.clock.position)
        case .video:
            // scene.json is untrusted input: the video must be a plain file inside the package.
            guard let video = m.video, LibraryService.isPlainFileName(video.file) else {
                throw LibraryError.invalid("\(scene.id) has no video file.")
            }
            let source = scene.packageURL.appendingPathComponent(video.file)
            guard FileOps.isRegularFile(source) else { throw LibraryError.invalid("\(scene.id): \(video.file) is missing.") }
            let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
            let file = "\(scene.id).\(ext)"
            try FileOps.hardLinkOrCopy(from: source, to: staging.appendingPathComponent(file))
            return LPPlaylistEntry(id: scene.id, name: m.name, kind: .video, file: file, clock: m.clock.position, fit: video.fit)
        }
    }
}
