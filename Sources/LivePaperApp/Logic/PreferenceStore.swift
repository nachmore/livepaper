// PreferenceStore — the tiny key-value surface the app needs from UserDefaults, so mock runs,
// snapshots and self tests can use an in-memory store and never write a preferences file
// (Foundation-only; also compiled into LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/).
import Foundation

protocol PreferenceStore: AnyObject {
    func bool(forKey key: String) -> Bool
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: PreferenceStore {}

/// Process-lifetime preferences (LIVEPAPER_MOCK=1, snapshots, tests).
final class InMemoryPreferences: PreferenceStore {
    private var values: [String: Any] = [:]

    init(_ initial: [String: Any] = [:]) { values = initial }

    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}
