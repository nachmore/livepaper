// PlaylistModel — the published content contract between the app and the screen saver.
//
// IMPORTANT: this file is compiled into BOTH LivePaperCore and the sandboxed LivePaper.saver
// (scripts/build.sh passes it to swiftc). Keep it Foundation-only and self-contained.
//
// Layout inside the installed saver bundle:
//   LivePaper.saver/Contents/Resources/Playlist/playlist.json
//   LivePaper.saver/Contents/Resources/Playlist/<scene-id>.html     (web scenes, runtime inlined)
//   LivePaper.saver/Contents/Resources/Playlist/<scene-id>.<ext>    (video scenes)
import Foundation

public enum LPPlaylistMode: String, Codable, Sendable, CaseIterable {
    case shuffle, sequence, single
}

public enum LPPerformanceProfile: String, Codable, Sendable, CaseIterable {
    /// 60 fps full resolution on AC; battery saver on battery or Low Power Mode.
    case automatic
    case best        // 60 fps, 100 %
    case balanced    // 60 fps, 75 %
    case battery     // 30 fps, 75 %

    public struct Resolved: Sendable, Equatable {
        public let fps: Int; public let scale: Double
        public init(fps: Int, scale: Double) { self.fps = fps; self.scale = scale }
    }

    public func resolved(onBatteryOrLowPower: Bool) -> Resolved {
        switch self {
        case .automatic: return onBatteryOrLowPower ? .init(fps: 30, scale: 0.75) : .init(fps: 60, scale: 1)
        case .best: return .init(fps: 60, scale: 1)
        case .balanced: return .init(fps: 60, scale: 0.75)
        case .battery: return .init(fps: 30, scale: 0.75)
        }
    }
}

public enum LPClockPosition: String, Codable, Sendable, CaseIterable {
    case top, bottomLeft = "bottom-left", bottomRight = "bottom-right", none
}

public enum LPVideoFit: String, Codable, Sendable { case fill, fit }

public struct LPPlaylistEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case web, video }
    public var id: String
    public var name: String
    public var kind: Kind
    /// File name (relative to the Playlist directory) of the compiled HTML (web) or the video file.
    public var file: String
    public var clock: LPClockPosition
    public var fit: LPVideoFit?
    public init(id: String, name: String, kind: Kind, file: String, clock: LPClockPosition, fit: LPVideoFit? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.file = file; self.clock = clock; self.fit = fit
    }
}

public struct LPPlaylist: Codable, Sendable, Equatable {
    public static let currentSchema = 1
    public static let fileName = "playlist.json"
    public static let directoryName = "Playlist"

    public var schema: Int
    /// Monotonic publish counter (diagnostics; lets the saver log which publish it is showing).
    public var generation: Int
    public var mode: LPPlaylistMode
    /// Minutes between scene changes while the saver runs (0 = never).
    public var cycleMinutes: Int
    public var showClock: Bool
    public var performance: LPPerformanceProfile
    public var scenes: [LPPlaylistEntry]

    public init(schema: Int = LPPlaylist.currentSchema, generation: Int = 0, mode: LPPlaylistMode = .shuffle,
                cycleMinutes: Int = 5, showClock: Bool = true, performance: LPPerformanceProfile = .automatic,
                scenes: [LPPlaylistEntry] = []) {
        self.schema = schema; self.generation = generation; self.mode = mode; self.cycleMinutes = cycleMinutes
        self.showClock = showClock; self.performance = performance; self.scenes = scenes
    }

    public static func load(from directory: URL) throws -> LPPlaylist {
        let data = try Data(contentsOf: directory.appendingPathComponent(fileName))
        return try JSONDecoder().decode(LPPlaylist.self, from: data)
    }

    public func write(to directory: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: directory.appendingPathComponent(LPPlaylist.fileName), options: .atomic)
    }
}

/// Distributed-notification names shared by app, helper and saver.
public enum LPNotification {
    /// App → helper: state.json changed.
    public static let stateChanged = "com.nachmore.livepaper.stateChanged"
    /// Saver/anyone → helper: please open the LivePaper app (the sandboxed saver can't).
    public static let openApp = "com.nachmore.livepaper.openApp"
    /// App → saver (preview instances): playlist was republished.
    public static let published = "com.nachmore.livepaper.published"
    /// System (distributed; object = the user's uid as a string; verified on macOS 26.7): loginwindow
    /// drew its own clock + password UI over the running saver (hide our clock) / removed it again.
    public static let lockUIShown = "com.apple.screenLockUIIsShown"
    public static let lockUIHidden = "com.apple.screenLockUIIsHidden"
    /// Kept for source compatibility; macOS posts only Shown/Hidden as distributed notifications.
    public static let lockUIShowing = lockUIShown
    /// System: screen saver lifecycle.
    public static let saverWillStop = "com.apple.screensaver.willstop"
    public static let saverDidStart = "com.apple.screensaver.didstart"
    public static let screenLocked = "com.apple.screenIsLocked"
    public static let screenUnlocked = "com.apple.screenIsUnlocked"
}
