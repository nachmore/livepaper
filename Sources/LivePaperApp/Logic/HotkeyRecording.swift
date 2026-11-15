// HotkeyRecording — the rules behind the lock-hotkey recorder control (Foundation-only; also
// compiled into LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/).
//
// The SwiftUI recorder feeds raw `NSEvent` key codes and modifier-flag bits into `evaluate` so the
// decision logic stays testable without AppKit.
import Foundation
import LivePaperCore

enum HotkeyRecorder {
    /// `NSEvent.ModifierFlags` raw bits (stable AppKit ABI values), duplicated here so this file
    /// does not need to import AppKit.
    enum FlagBit {
        static let capsLock: UInt = 1 << 16
        static let shift: UInt = 1 << 17
        static let control: UInt = 1 << 18
        static let option: UInt = 1 << 19
        static let command: UInt = 1 << 20
        static let function: UInt = 1 << 23
    }

    /// Virtual key codes (kVK_*) the recorder treats specially.
    enum KeyCode {
        static let escape: UInt16 = 53
        static let delete: UInt16 = 51
        static let forwardDelete: UInt16 = 117
        static let tab: UInt16 = 48
        static let space: UInt16 = 49
        static let q: UInt16 = 12
        /// Key codes of the modifier keys themselves (they arrive as flagsChanged, never as a combo).
        static let modifierKeys: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                                105, 107, 113, 106, 64, 79, 80, 90]
    }

    /// What the recorder should do with one key press.
    enum Outcome: Equatable {
        /// A valid combination: store it.
        case accepted(LPHotkey)
        /// Not usable; keep recording and show the message.
        case rejected(String)
        /// Esc on its own: stop recording, keep the old value.
        case cancelled
        /// Delete on its own: stop recording and turn the hotkey off.
        case cleared
        /// A modifier key on its own: keep waiting for the actual key.
        case ignored
    }

    /// Converts `NSEvent.ModifierFlags.rawValue` to LPHotkey modifiers (canonical order).
    static func modifiers(fromRawFlags raw: UInt) -> [LPHotkey.Modifier] {
        var out: [LPHotkey.Modifier] = []
        if raw & FlagBit.control != 0 { out.append(.control) }
        if raw & FlagBit.option != 0 { out.append(.option) }
        if raw & FlagBit.shift != 0 { out.append(.shift) }
        if raw & FlagBit.command != 0 { out.append(.command) }
        return out
    }

    /// Decides what a key press means while recording.
    static func evaluate(keyCode: UInt16, rawFlags: UInt) -> Outcome {
        if KeyCode.modifierKeys.contains(keyCode) { return .ignored }
        let mods = modifiers(fromRawFlags: rawFlags)
        if mods.isEmpty {
            if keyCode == KeyCode.escape { return .cancelled }
            if keyCode == KeyCode.delete || keyCode == KeyCode.forwardDelete { return .cleared }
            // F13–F19 and friends are commonly dedicated to global shortcuts; allow them bare.
            if KeyCode.functionKeys.contains(keyCode) { return .accepted(LPHotkey(keyCode: keyCode, modifiers: [])) }
            return .rejected("Hold \u{2303}, \u{2325} or \u{2318} while pressing the key.")
        }
        let set = Set(mods)
        if set == [.shift] && !KeyCode.functionKeys.contains(keyCode) {
            return .rejected("\u{21E7} on its own would block typing. Add \u{2303}, \u{2325} or \u{2318}.")
        }
        let hotkey = LPHotkey(keyCode: keyCode, modifiers: mods)
        if let reason = reservedReason(hotkey) { return .rejected(reason) }
        // ⌘ or ⌘⇧ plus a letter/digit collides with app shortcuts (⌘L is the address bar in every
        // browser); a global hotkey would silently steal them.
        if (set == [.command] || set == [.command, .shift]) && isLetterOrDigit(keyCode) {
            return .rejected("\(display(hotkey)) is used by apps. Add \u{2303} or \u{2325}.")
        }
        return .accepted(hotkey)
    }

    /// Combinations macOS itself owns; registering them would either fail or break system features.
    private static let reserved: [(keyCode: UInt16, modifiers: Set<LPHotkey.Modifier>, what: String)] = [
        (KeyCode.q, [.command], "is a standard app shortcut"),
        (13, [.command], "is a standard app shortcut"),               // ⌘W
        (4, [.command], "is a standard app shortcut"),                // ⌘H
        (46, [.command], "is a standard app shortcut"),               // ⌘M
        (KeyCode.tab, [.command], "switches apps"),
        (KeyCode.tab, [.command, .shift], "switches apps"),
        (KeyCode.space, [.command], "opens Spotlight"),
        (KeyCode.space, [.command, .option], "opens Spotlight"),
        (KeyCode.space, [.control], "switches input sources"),
        (KeyCode.space, [.control, .option], "switches input sources"),
        (20, [.command, .shift], "takes screenshots"),                // ⌘⇧3
        (21, [.command, .shift], "takes screenshots"),                // ⌘⇧4
        (23, [.command, .shift], "takes screenshots"),                // ⌘⇧5
        (KeyCode.escape, [.command, .option], "opens Force Quit"),
    ]

    static func reservedReason(_ hotkey: LPHotkey) -> String? {
        let set = Set(hotkey.modifiers)
        if hotkey.keyCode == KeyCode.q && set == [.control, .command] {
            return "\u{2303}\u{2318}Q is the system lock shortcut. Turn on \u{201C}Use \u{2303}\u{2318}Q and the lock key for LivePaper lock\u{201D} above instead."
        }
        guard let rule = reserved.first(where: { $0.keyCode == hotkey.keyCode && $0.modifiers == set }) else { return nil }
        return "\(display(hotkey)) \(rule.what)."
    }

    /// Key names beyond `LPHotkey.keyName` (which covers letters, digits and a few specials).
    static func keyName(_ code: UInt16) -> String {
        let extra: [UInt16: String] = [
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
            109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
            79: "F18", 80: "F19", 90: "F20",
            123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
            115: "\u{2196}", 119: "\u{2198}", 116: "\u{21DE}", 121: "\u{21DF}", 117: "\u{2326}", 48: "\u{21E5}",
            76: "\u{2324}", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".",
            44: "/", 50: "`",
        ]
        return extra[code] ?? LPHotkey.keyName(code)
    }

    /// "⌃⌘L" — canonical modifier order ⌃⌥⇧⌘, then the key.
    static func display(_ hotkey: LPHotkey) -> String {
        modifierGlyphs(hotkey.modifiers) + keyName(hotkey.keyCode)
    }

    /// Glyphs for the modifiers currently held while recording ("⌃⌥…").
    static func modifierGlyphs(_ mods: [LPHotkey.Modifier]) -> String {
        let glyph: [LPHotkey.Modifier: String] = [.control: "\u{2303}", .option: "\u{2325}", .shift: "\u{21E7}", .command: "\u{2318}"]
        return LPHotkey.Modifier.allCases.filter(mods.contains).compactMap { glyph[$0] }.joined()
    }

    /// Spoken form for VoiceOver: "Control Command L".
    static func accessibilityLabel(_ hotkey: LPHotkey?) -> String {
        guard let hotkey else { return "No shortcut" }
        let names: [LPHotkey.Modifier: String] = [.control: "Control", .option: "Option", .shift: "Shift", .command: "Command"]
        let mods = LPHotkey.Modifier.allCases.filter(hotkey.modifiers.contains).compactMap { names[$0] }
        return (mods + [keyName(hotkey.keyCode)]).joined(separator: " ")
    }

    private static func isLetterOrDigit(_ code: UInt16) -> Bool {
        let name = LPHotkey.keyName(code)
        return name.count == 1 && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }
}
