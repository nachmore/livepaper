// LockTakeover — makes macOS's own lock gestures show the LivePaper scene (Foundation-only; also
// compiled into LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/).
//
// `com.apple.loginwindow immediateLockLaunchesScreenSaver = true` (user domain) makes ⌃⌘Q, Apple
// menu › Lock Screen and the Touch ID / lock key start the screen saver before locking, so the
// lock screen shows the running scene (ARCHITECTURE §1, §7). It needs no permissions, takes effect
// without logging out and fails safe: if the saver can't run, loginwindow still locks. Lid-close and
// display-sleep locks are not covered (they still show the wallpaper).
//
// The previous value is backed up the first time LivePaper changes it, and restored on uninstall.
import Foundation

/// One Boolean preference (absent = nil), abstracted so the backup logic is testable without
/// touching the real loginwindow domain.
protocol BoolPreference: AnyObject {
    func read() -> Bool?
    func write(_ value: Bool?) throws
}

/// The real setting, read and written through CFPreferences (what `defaults write` uses).
final class LoginWindowLockPreference: BoolPreference {
    static let domain = "com.apple.loginwindow" as CFString
    static let key = "immediateLockLaunchesScreenSaver" as CFString

    struct SyncFailed: LocalizedError {
        var errorDescription: String? { "macOS didn't accept the change to the lock settings." }
    }

    func read() -> Bool? {
        CFPreferencesCopyAppValue(Self.key, Self.domain) as? Bool
    }

    func write(_ value: Bool?) throws {
        let plist: CFPropertyList? = value.map { $0 ? kCFBooleanTrue : kCFBooleanFalse }
        CFPreferencesSetAppValue(Self.key, plist, Self.domain)
        guard CFPreferencesAppSynchronize(Self.domain) else { throw SyncFailed() }
    }
}

/// Process-lifetime stand-in (LIVEPAPER_MOCK=1, snapshots, tests).
final class InMemoryBoolPreference: BoolPreference {
    private var value: Bool?
    init(_ value: Bool? = nil) { self.value = value }
    func read() -> Bool? { value }
    func write(_ value: Bool?) throws { self.value = value }
}

final class LockTakeover {
    /// What the preference was before LivePaper first changed it.
    struct Backup: Codable, Equatable {
        /// nil = the key didn't exist.
        var previous: Bool?
        var date: Date
    }

    private let preference: BoolPreference
    private let backupURL: URL

    /// - Parameter backupURL: e.g. `LPPaths.backups/loginwindow-lock.json`.
    init(preference: BoolPreference, backupURL: URL) {
        self.preference = preference
        self.backupURL = backupURL
    }

    var isEnabled: Bool { preference.read() ?? false }

    /// Whether uninstall has something to restore.
    var hasBackup: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    func setEnabled(_ enabled: Bool) throws {
        guard enabled != isEnabled else { return }
        if !hasBackup {
            let backup = Backup(previous: preference.read(), date: Date())
            try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(backup).write(to: backupURL, options: .atomic)
        }
        try preference.write(enabled)
    }

    /// Puts the preference back as it was before LivePaper touched it (no-op without a backup).
    func restore() throws {
        guard let data = try? Data(contentsOf: backupURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(Backup.self, from: data)
        try preference.write(backup.previous)
        try FileManager.default.removeItem(at: backupURL)
    }
}
