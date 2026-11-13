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
    /// LivePaper's own lock hotkey (Carbon hotkey, no permissions needed). nil = disabled.
    public var hotkey: LPHotkey?
    /// Take over ⌃⌘Q (needs Accessibility; see docs/RESEARCH.md).
    public var takeOverSystemLock: Bool
    /// Take over the Touch ID / lock key, if supported on this Mac.
    public var takeOverLockKey: Bool
    public init(hotkey: LPHotkey? = .controlCommandL, takeOverSystemLock: Bool = false, takeOverLockKey: Bool = false) {
        self.hotkey = hotkey; self.takeOverSystemLock = takeOverSystemLock; self.takeOverLockKey = takeOverLockKey
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
