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
    /// File extensions the saver plays, per kind (it skips entries with any other extension).
    public static let webExtensions: Set<String> = ["html", "htm"]
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    public var id: String
    public var name: String
    public var kind: Kind
    /// File name (relative to the Playlist directory) of the compiled HTML (web) or the video file.
    public var file: String
    public var clock: LPClockPosition
    public var fit: LPVideoFit?
    /// The scene may stretch across all displays ("Span across displays"): a web scene that declared
    /// `"span": true` in scene.json, or a video (unless it opted out). Nil or false: it can't, and
    /// shows on every display as in "Same". Publish writes it explicitly; older files lack it.
    public var span: Bool?
    public init(id: String, name: String, kind: Kind, file: String, clock: LPClockPosition, fit: LPVideoFit? = nil,
                span: Bool? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.file = file; self.clock = clock; self.fit = fit; self.span = span
    }
}

// MARK: - Multiple displays

/// What several displays show (playlist setting "Multiple displays").
public enum LPDisplayMode: String, Codable, Sendable, CaseIterable {
    /// Every display shows the same scene (the behaviour before display modes existed).
    case same
    /// Display k (in layout order) shows the scene k steps further along the playlist.
    case different
    /// Each display plays the scene assigned to it (`LPDisplaySettings.assignments`); the others play the playlist.
    case choose
    /// One scene stretches across the union of all displays (scenes that support it; the others play as in `same`).
    case span
}

/// What displays other than the main one show on battery power or in Low Power Mode.
public enum LPBatteryDisplays: String, Codable, Sendable, CaseIterable {
    /// The scene, live (as on power).
    case live
    /// One frame of the scene, then nothing runs.
    case still
    /// Nothing: black.
    case off
}

/// Multi-display settings, in playlist-settings.json and published into playlist.json. The defaults
/// are the single-display behaviour, and decoding is tolerant both ways: an unknown mode or battery
/// value, or a malformed field, falls back to that field's default (the app, the CLI and the saver
/// may briefly be different versions).
public struct LPDisplaySettings: Codable, Sendable, Equatable {
    public var mode: LPDisplayMode
    /// Display key (the display's UUID, uppercase — `LPDisplay.normalizedID`) → scene id, for
    /// "Choose per display". A display without one, or whose scene isn't published, plays the playlist.
    public var assignments: [String: String]
    /// On battery or in Low Power Mode, what the displays other than the main one show.
    public var onBattery: LPBatteryDisplays

    public static let standard = LPDisplaySettings()

    public init(mode: LPDisplayMode = .same, assignments: [String: String] = [:], onBattery: LPBatteryDisplays = .live) {
        self.mode = mode
        self.assignments = Self.normalized(assignments)
        self.onBattery = onBattery
    }

    enum CodingKeys: String, CodingKey { case mode, assignments, onBattery }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decodeIfPresent(String.self, forKey: .mode)).flatMap { $0 }.flatMap(LPDisplayMode.init(rawValue:)) ?? .same
        onBattery = (try? c.decodeIfPresent(String.self, forKey: .onBattery)).flatMap { $0 }.flatMap(LPBatteryDisplays.init(rawValue:)) ?? .live
        assignments = Self.normalized((try? c.decodeIfPresent([String: String].self, forKey: .assignments)).flatMap { $0 } ?? [:])
    }

    /// Keys trimmed and uppercased (display UUIDs compare case-insensitively), values trimmed; empty
    /// keys or values dropped. Two keys that normalise alike keep the value of the first in sorted order.
    public static func normalized(_ assignments: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for key in assignments.keys.sorted() {
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let v = (assignments[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty, !v.isEmpty, out[k] == nil else { continue }
            out[k] = v
        }
        return out
    }

    /// The mode as it plays with `displayCount` displays: "different" and "span" need two.
    public func effectiveMode(displayCount: Int) -> LPDisplayMode {
        switch mode {
        case .different, .span: return displayCount >= 2 ? mode : .same
        case .same, .choose: return mode
        }
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
    /// Multi-display settings (absent in files from before them: `.standard`).
    public var displays: LPDisplaySettings
    /// Scenes published only because a display is assigned to them ("Choose per display"); never
    /// part of the deck. Savers from before display modes ignore them.
    public var displayScenes: [LPPlaylistEntry]

    public init(schema: Int = LPPlaylist.currentSchema, generation: Int = 0, mode: LPPlaylistMode = .shuffle,
                cycleMinutes: Int = 5, showClock: Bool = true, performance: LPPerformanceProfile = .automatic,
                scenes: [LPPlaylistEntry] = [], displays: LPDisplaySettings = .standard, displayScenes: [LPPlaylistEntry] = []) {
        self.schema = schema; self.generation = generation; self.mode = mode; self.cycleMinutes = cycleMinutes
        self.showClock = showClock; self.performance = performance; self.scenes = scenes
        self.displays = displays; self.displayScenes = displayScenes
    }

    enum CodingKeys: String, CodingKey {
        case schema, generation, mode, cycleMinutes, showClock, performance, scenes, displays, displayScenes
    }

    /// The original seven keys are required, as before (an unreadable playlist shows the saver's
    /// fallback); the multi-display keys are optional and tolerant: a malformed `displays` is
    /// `.standard`, a broken `displayScenes` item is dropped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        generation = try c.decode(Int.self, forKey: .generation)
        mode = try c.decode(LPPlaylistMode.self, forKey: .mode)
        cycleMinutes = try c.decode(Int.self, forKey: .cycleMinutes)
        showClock = try c.decode(Bool.self, forKey: .showClock)
        performance = try c.decode(LPPerformanceProfile.self, forKey: .performance)
        scenes = try c.decode([LPPlaylistEntry].self, forKey: .scenes)
        displays = (try? c.decodeIfPresent(LPDisplaySettings.self, forKey: .displays)).flatMap { $0 } ?? .standard
        displayScenes = (try? c.decodeIfPresent([LossyPlaylistEntry].self, forKey: .displayScenes)).flatMap { $0 }?
            .compactMap(\.entry) ?? []
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

/// One item of a lossily decoded list: nil when it doesn't decode (the list keeps the others).
private struct LossyPlaylistEntry: Decodable {
    let entry: LPPlaylistEntry?
    init(from decoder: Decoder) throws { entry = try? LPPlaylistEntry(from: decoder) }
}

/// Distributed-notification names shared by app, helper and saver.
public enum LPNotification {
    /// App → helper: state.json changed.
    public static let stateChanged = "com.nachmore.livepaper.stateChanged"
    /// Saver/anyone → helper: please open the LivePaper app (the sandboxed saver can't).
    public static let openApp = "com.nachmore.livepaper.openApp"
    /// App → helper: run the LivePaper lock flow now (menu-bar "Lock Now").
    /// userInfo[requestIDKey]: String, echoed in `lockNowAccepted`.
    public static let lockNow = "com.nachmore.livepaper.lockNow"
    /// Helper → app: a `lockNow` request was received and the lock flow is running.
    /// userInfo[requestIDKey]: the request's id. The app falls back to starting ScreenSaverEngine
    /// itself when no answer arrives within a second (no helper running).
    public static let lockNowAccepted = "com.nachmore.livepaper.lockNowAccepted"
    /// Helper → app: the LivePaper lock was refused because starting the screen saver wouldn't lock
    /// the Mac (password not required immediately). userInfo[reasonKey]: an `LPLockRefusal` raw value.
    public static let lockRefused = "com.nachmore.livepaper.lockRefused"
    /// App → helper: the hotkey recorder is active (userInfo[activeKey]: Bool); suspend the shortcut
    /// meanwhile so pressing the current shortcut while re-recording doesn't lock the Mac.
    public static let hotkeyRecording = "com.nachmore.livepaper.hotkeyRecording"
    /// userInfo keys of the notifications above.
    public static let requestIDKey = "requestID"
    public static let activeKey = "active"
    public static let reasonKey = "reason"
    /// App → saver (preview instances): playlist was republished.
    public static let published = "com.nachmore.livepaper.published"
    /// System (distributed; object = the user's uid as a string; verified on macOS 26.7): loginwindow
    /// drew its own clock + password UI over the running saver (hide our clock) / removed it again.
    public static let lockUIShown = "com.apple.screenLockUIIsShown"
    public static let lockUIHidden = "com.apple.screenLockUIIsHidden"
    /// Kept for source compatibility; macOS posts only Shown/Hidden as distributed notifications.
    public static let lockUIShowing = lockUIShown
    /// System: screen saver lifecycle, posted by loginwindow's ScreenSaverDaemon (macOS 26.7
    /// disassembly: `_screenSaverStart:` posts didstart with deliverImmediately for every start —
    /// idle, hot corner, ScreenSaverEngine, lock keys; `_screenSaverStop` posts willstop/didstop).
    public static let saverWillStop = "com.apple.screensaver.willstop"
    public static let saverDidStart = "com.apple.screensaver.didstart"
    public static let saverDidStop = "com.apple.screensaver.didstop"
    public static let screenLocked = "com.apple.screenIsLocked"
    public static let screenUnlocked = "com.apple.screenIsUnlocked"
}
