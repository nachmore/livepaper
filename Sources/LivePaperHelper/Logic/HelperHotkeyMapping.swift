// HelperHotkeyMapping — turns an LPHotkey from state.json into the arguments of Carbon's
// RegisterEventHotKey, and refuses combinations that must never become a global hotkey.
//
// Pure logic: Foundation + LivePaperCore only, so LivePaperSelfTest compiles this file too (symlinked
// from Sources/LivePaperSelfTest/HelperLogic/). The Carbon modifier bits are mirrored here instead
// of importing Carbon; `LivePaperHelper --print-config` checks the mirror against Carbon.HIToolbox
// at runtime (see CarbonHotkeys.swift, `carbonConstantsMatch`).
import Foundation
import LivePaperCore

/// A hotkey in the form `RegisterEventHotKey(inHotKeyCode:inHotKeyModifiers:…)` takes it.
struct HelperCarbonHotkey: Equatable, Sendable {
    /// Virtual key code (`kVK_*`). Carbon uses the same numbering as `LPHotkey.keyCode`.
    var keyCode: UInt32
    /// Carbon modifier mask: a combination of `cmdKey`, `shiftKey`, `optionKey` and `controlKey`.
    var modifiers: UInt32
}

/// Why a hotkey from state.json is not registered.
enum HelperHotkeyProblem: Error, Equatable, Sendable, CustomStringConvertible {
    /// Outside the virtual-key-code range (0…127).
    case invalidKeyCode(UInt16)
    /// The "key" is itself a modifier (⇧, ⌃, ⌥, ⌘, fn, caps lock); it can't be a hotkey.
    case modifierKey(UInt16)
    /// A plain key (or ⇧+key) would swallow normal typing in every app.
    case needsModifier(String)
    /// ⌃⌘Q is macOS's own Lock Screen shortcut. LivePaper covers it through the system lock
    /// takeover (`immediateLockLaunchesScreenSaver`), so the helper must not grab it: a hotkey that
    /// intercepted it would replace a lock that always locks with one that locks only when the
    /// password is required immediately.
    case systemLockShortcut

    var description: String {
        switch self {
        case .invalidKeyCode(let code): return "key code \(code) is not a valid virtual key code (0–127)"
        case .modifierKey(let code): return "key code \(code) is a modifier key and can't be a shortcut on its own"
        case .needsModifier(let display): return "\(display) has no ⌃, ⌥ or ⌘ and would capture normal typing"
        case .systemLockShortcut: return "⌃⌘Q is macOS's Lock Screen shortcut (covered by the lock takeover, not the helper)"
        }
    }
}

enum HelperHotkeyMapping {
    /// Carbon modifier bits from `<HIToolbox/Events.h>` (unchanged since the classic Mac OS).
    enum CarbonModifier {
        /// `cmdKey`
        static let command: UInt32 = 1 << 8
        /// `shiftKey`
        static let shift: UInt32 = 1 << 9
        /// `optionKey`
        static let option: UInt32 = 1 << 11
        /// `controlKey`
        static let control: UInt32 = 1 << 12
    }

    /// `EventHotKeyID.signature` for LivePaper's hotkeys ('LPHK').
    static let signature: UInt32 = fourCharCode("LPHK")

    /// Key codes of the modifier keys themselves (kVK_Command … kVK_Function, kVK_CapsLock).
    static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// F1–F20. Commonly dedicated to global shortcuts, so they may be used without ⌃/⌥/⌘
    /// (same rule as the app's hotkey recorder).
    static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                                105, 107, 113, 106, 64, 79, 80, 90]

    /// Big-endian four-character code, as Carbon's `OSType` literals ('LPHK' = 0x4C50484B).
    /// Characters beyond the first four are ignored; non-ASCII characters become `?`.
    static func fourCharCode(_ text: String) -> UInt32 {
        text.unicodeScalars.prefix(4).reduce(UInt32(0)) { code, scalar in
            (code << 8) | (scalar.isASCII ? scalar.value : 0x3F)
        }
    }

    /// The Carbon bit for one modifier.
    static func carbonMask(_ modifier: LPHotkey.Modifier) -> UInt32 {
        switch modifier {
        case .command: return CarbonModifier.command
        case .shift: return CarbonModifier.shift
        case .option: return CarbonModifier.option
        case .control: return CarbonModifier.control
        }
    }

    /// The Carbon mask for a modifier list (order and duplicates don't matter).
    static func carbonModifiers(_ modifiers: [LPHotkey.Modifier]) -> UInt32 {
        modifiers.reduce(UInt32(0)) { $0 | carbonMask($1) }
    }

    /// Why `hotkey` must not be registered as a global hotkey, or nil when it may be.
    ///
    /// The app's recorder already enforces stricter rules; this is the helper's own guard against a
    /// hand-edited or foreign state.json grabbing a key the user needs for typing.
    static func problem(with hotkey: LPHotkey) -> HelperHotkeyProblem? {
        guard hotkey.keyCode <= 0x7F else { return .invalidKeyCode(hotkey.keyCode) }
        if modifierKeyCodes.contains(hotkey.keyCode) { return .modifierKey(hotkey.keyCode) }
        let modifiers = Set(hotkey.modifiers)
        let hasRealModifier = !modifiers.isDisjoint(with: [.control, .option, .command])
        if !hasRealModifier && !functionKeyCodes.contains(hotkey.keyCode) { return .needsModifier(hotkey.displayString) }
        if modifiers == [.control, .command] && hotkey.keyCode == LPHotkey.controlCommandQ.keyCode { return .systemLockShortcut }
        return nil
    }

    /// The RegisterEventHotKey arguments for `hotkey`, or the reason it is refused.
    static func carbon(for hotkey: LPHotkey) -> Result<HelperCarbonHotkey, HelperHotkeyProblem> {
        if let problem = problem(with: hotkey) { return .failure(problem) }
        return .success(HelperCarbonHotkey(keyCode: UInt32(hotkey.keyCode), modifiers: carbonModifiers(hotkey.modifiers)))
    }
}
