// HelperStateReader — reads the part of state.json (ARCHITECTURE §4.4) the helper acts on: the
// LivePaper lock shortcut, `lock.hotkey`.
//
// state.json is decoded through LPSharedState's own Codable conformance first. If that fails — for
// example because an app of a different version renamed or added a non-optional field — the hotkey
// is read from the documented `lock.hotkey` path directly, so a schema change elsewhere in the
// file can neither silently re-enable a shortcut the user turned off nor drop one they set.
//
// Pure logic (Foundation + LivePaperCore), also compiled into LivePaperSelfTest.
import Foundation
import LivePaperCore

/// The lock configuration the helper applies.
struct HelperLockConfig: Equatable, Sendable {
    /// Where `hotkey` came from.
    enum Source: String, Codable, Sendable {
        /// state.json decoded as LPSharedState.
        case stateFile
        /// LPSharedState didn't decode; `lock.hotkey` was read directly from the JSON.
        case fallback
        /// There is no state.json yet: LPSharedState's defaults (what the app shows before it saves).
        case defaults
        /// state.json exists but is unreadable; the configuration in effect before stays.
        case previous
    }

    /// LivePaper's own lock shortcut; nil = off.
    var hotkey: LPHotkey?
    var source: Source
    /// Human-readable reasons the file wasn't decoded normally (empty when it was).
    var problems: [String]

    init(hotkey: LPHotkey?, source: Source, problems: [String] = []) {
        self.hotkey = hotkey; self.source = source; self.problems = problems
    }

    /// LPSharedState's defaults.
    static var defaults: HelperLockConfig { HelperLockConfig(hotkey: LPSharedState().lock.hotkey, source: .defaults) }
}

enum HelperStateReader {
    /// Reads `url`. A missing file yields the defaults; an unreadable one keeps `previous`.
    static func load(from url: URL, previous: HelperLockConfig?) -> HelperLockConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return config(fromStateData: nil, previous: previous) }
        do {
            return config(fromStateData: try Data(contentsOf: url), previous: previous)
        } catch {
            return keep(previous, problem: "state.json can't be read: \(error.localizedDescription)")
        }
    }

    /// Decodes state.json contents (`nil` = the file doesn't exist).
    static func config(fromStateData data: Data?, previous: HelperLockConfig?) -> HelperLockConfig {
        guard let data else { return .defaults }
        let decodeError: Error
        do {
            let state = try SceneManifest.decoder().decode(LPSharedState.self, from: data)
            return HelperLockConfig(hotkey: state.lock.hotkey, source: .stateFile)
        } catch {
            decodeError = error
        }
        let why = "state.json doesn't match this helper's LPSharedState (\(describe(decodeError)))"
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return keep(previous, problem: "state.json is not a JSON object")
        }
        guard let lock = root["lock"] as? [String: Any] else {
            return keep(previous, problem: "\(why); it has no \"lock\" object")
        }
        switch fallbackHotkey(lock: lock) {
        case .success(let hotkey):
            return HelperLockConfig(hotkey: hotkey, source: .fallback, problems: [why])
        case .failure(let failure):
            // A hotkey is present but malformed: turn it off rather than guess.
            return HelperLockConfig(hotkey: nil, source: .fallback, problems: [why, failure.message])
        }
    }

    struct FallbackFailure: Error, Equatable { var message: String }

    /// Reads `lock.hotkey` without LPSharedState. Absent or `null` = off: LPSharedState's synthesized
    /// encoder omits a nil hotkey, so "no key" is how the app writes "off".
    static func fallbackHotkey(lock: [String: Any]) -> Result<LPHotkey?, FallbackFailure> {
        guard let raw = lock["hotkey"], !(raw is NSNull) else { return .success(nil) }
        guard let object = raw as? [String: Any] else { return .failure(.init(message: "lock.hotkey is not an object")) }
        guard let number = object["keyCode"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let keyCode = UInt16(exactly: number.doubleValue) else {
            return .failure(.init(message: "lock.hotkey.keyCode is missing or not a key code"))
        }
        let names = object["modifiers"] as? [Any] ?? []
        var modifiers: [LPHotkey.Modifier] = []
        for name in names {
            guard let text = name as? String, let modifier = LPHotkey.Modifier(rawValue: text) else {
                return .failure(.init(message: "lock.hotkey.modifiers contains an unknown modifier (\(name))"))
            }
            if !modifiers.contains(modifier) { modifiers.append(modifier) }
        }
        return .success(LPHotkey(keyCode: keyCode, modifiers: modifiers))
    }

    private static func keep(_ previous: HelperLockConfig?, problem: String) -> HelperLockConfig {
        guard let previous else {
            var config = HelperLockConfig.defaults
            config.problems = [problem + "; using the defaults"]
            return config
        }
        return HelperLockConfig(hotkey: previous.hotkey, source: .previous, problems: [problem + "; keeping the previous shortcut"])
    }

    /// A short description of a DecodingError (the default one is a wall of text).
    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
            return keys.isEmpty ? "top level" : keys.joined(separator: ".")
        }
        switch decoding {
        case .keyNotFound(let key, let context): return "missing \(path(context) == "top level" ? "" : path(context) + ".")\(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return "unexpected value at \(path(context))"
        case .dataCorrupted(let context): return "corrupt data at \(path(context))"
        @unknown default: return "\(decoding)"
        }
    }
}
