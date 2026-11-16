// SharedState — state.json, written by the app, read by the helper. See ARCHITECTURE §4.4.
import Foundation

public struct LPHotkey: Codable, Sendable, Equatable {
    public enum Modifier: String, Codable, Sendable, CaseIterable { case control, option, shift, command }
    /// macOS virtual key code (kVK_*), e.g. 12 = Q, 37 = L.
    public var keyCode: UInt16
    public var modifiers: [Modifier]
    public init(keyCode: UInt16, modifiers: [Modifier]) { self.keyCode = keyCode; self.modifiers = modifiers }

    public static let controlCommandL = LPHotkey(keyCode: 37, modifiers: [.control, .command])
    public static let controlCommandQ = LPHotkey(keyCode: 12, modifiers: [.control, .command])

    public var displayString: String {
        let order: [Modifier] = [.control, .option, .shift, .command]
        let glyph: [Modifier: String] = [.control: "⌃", .option: "⌥", .shift: "⇧", .command: "⌘"]
        return order.filter(modifiers.contains).compactMap { glyph[$0] }.joined() + LPHotkey.keyName(keyCode)
    }

    public static func keyName(_ code: UInt16) -> String {
        let letters: [UInt16: String] = [0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J",
            40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
            13: "W", 7: "X", 16: "Y", 6: "Z", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8",
            25: "9", 29: "0", 49: "Space", 36: "↩", 53: "⎋", 51: "⌫"]
        return letters[code] ?? "key\(code)"
    }
}

public struct LPLockSettings: Codable, Sendable, Equatable {
    /// LivePaper's own lock shortcut (Carbon hotkey registered by the helper, no permissions
    /// needed). nil = no shortcut. Optional extra: the system lock keys already show the scene
    /// when `lockKeysShowScene` is on.
    public var hotkey: LPHotkey?
    /// Mirror of `com.apple.loginwindow immediateLockLaunchesScreenSaver` (⌃⌘Q, Apple menu › Lock
    /// Screen and the Touch ID / lock key start the scene before locking), written by the app when it
    /// changes the preference through `InstallServicing.setLockKeysShowScene`. Informational: the
    /// system preference is the source of truth and loginwindow acts on it by itself.
    public var lockKeysShowScene: Bool
    /// "Show your scene when the screens turn off first" (off by default): when the displays turn
    /// off before the screen saver would start, the helper starts the screen saver a few seconds
    /// before they do, so the lock screen shows the scene instead of the desktop picture
    /// (LPPreSleepPolicy; ARCHITECTURE §7). Files from before the option decode as off.
    public var showSceneBeforeDisplaySleep: Bool

    public init(hotkey: LPHotkey? = .controlCommandL, lockKeysShowScene: Bool = false, showSceneBeforeDisplaySleep: Bool = false) {
        self.hotkey = hotkey; self.lockKeysShowScene = lockKeysShowScene
        self.showSceneBeforeDisplaySleep = showSceneBeforeDisplaySleep
    }

    private enum CodingKeys: String, CodingKey {
        case hotkey, lockKeysShowScene, showSceneBeforeDisplaySleep
        // Before the single toggle: two flags for the same preference.
        case takeOverSystemLock, takeOverLockKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Absent (or null) = no shortcut, as the synthesized coding always wrote it.
        hotkey = try c.decodeIfPresent(LPHotkey.self, forKey: .hotkey)
        if let on = try c.decodeIfPresent(Bool.self, forKey: .lockKeysShowScene) {
            lockKeysShowScene = on
        } else {
            let system = try c.decodeIfPresent(Bool.self, forKey: .takeOverSystemLock) ?? false
            let key = try c.decodeIfPresent(Bool.self, forKey: .takeOverLockKey) ?? false
            lockKeysShowScene = system || key
        }
        // Absent, null or not a Bool (another version's file) = off: it must never turn itself on.
        showSceneBeforeDisplaySleep = (try? c.decodeIfPresent(Bool.self, forKey: .showSceneBeforeDisplaySleep)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(hotkey, forKey: .hotkey)
        try c.encode(lockKeysShowScene, forKey: .lockKeysShowScene)
        try c.encode(showSceneBeforeDisplaySleep, forKey: .showSceneBeforeDisplaySleep)
    }
}

public struct LPSharedState: Codable, Sendable, Equatable {
    public static let currentSchema = 1
    public var schema: Int
    public var lock: LPLockSettings
    public var installedAt: Date?
    public var appVersion: String?

    public init(lock: LPLockSettings = .init(), installedAt: Date? = nil, appVersion: String? = nil) {
        schema = LPSharedState.currentSchema; self.lock = lock; self.installedAt = installedAt; self.appVersion = appVersion
    }

    public static func load(from url: URL = LPPaths.stateFile) -> LPSharedState {
        guard let data = try? Data(contentsOf: url),
              let s = try? SceneManifest.decoder().decode(LPSharedState.self, from: data) else { return LPSharedState() }
        return s
    }

    public func save(to url: URL = LPPaths.stateFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SceneManifest.encoder().encode(self).write(to: url, options: .atomic)
        DistributedNotificationCenter.default().postNotificationName(.init(LPNotification.stateChanged), object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
    }
}
