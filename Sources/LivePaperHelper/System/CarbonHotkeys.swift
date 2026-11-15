// CarbonHotkeys — LivePaper's lock shortcut through Carbon's RegisterEventHotKey.
//
// RegisterEventHotKey is the one global-shortcut API that needs no TCC permission (no Accessibility
// or Input Monitoring, unlike event taps and NSEvent global monitors). Registering creates the
// process's window-server connection, so this file is only used by the agent, never by
// --print-config / --self-check. Hotkey events arrive through the Carbon event dispatcher, which
// NSApplication's run loop drives; the handler therefore runs on the main thread.
//
// A combination another app registered exclusively fails with eventHotKeyExistsErr (logged). One
// that a system shortcut (Keyboard Shortcuts settings) already uses may register fine and simply
// never fire here; that can't be detected.
import Carbon.HIToolbox
import LivePaperCore
import os

/// Owns at most one registered hotkey and the application-target handler that receives it.
@MainActor
final class CarbonHotkeyCenter {
    /// Called on the main thread when the registered hotkey is pressed.
    var onPressed: (() -> Void)?
    /// The hotkey currently registered, if any.
    private(set) var registered: LPHotkey?

    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    /// Bumped on every registration so a press queued for a previous registration is ignored.
    private var generation: UInt32 = 0
    private let log = HelperLog.main

    /// Whether the Carbon modifier bits mirrored in HelperHotkeyMapping are the real ones.
    nonisolated static var carbonConstantsMatch: Bool {
        HelperHotkeyMapping.CarbonModifier.command == UInt32(cmdKey)
            && HelperHotkeyMapping.CarbonModifier.shift == UInt32(shiftKey)
            && HelperHotkeyMapping.CarbonModifier.option == UInt32(optionKey)
            && HelperHotkeyMapping.CarbonModifier.control == UInt32(controlKey)
    }

    /// A Carbon status for the log.
    nonisolated static func describe(_ status: OSStatus) -> String {
        status == OSStatus(eventHotKeyExistsErr) ? "OSStatus \(status) (another app already registered it exclusively)" : "OSStatus \(status)"
    }

    /// Installs the kEventHotKeyPressed handler on the application event target (once).
    func installHandler() -> OSStatus {
        guard handler == nil else { return noErr }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The C callback can't capture; `self` travels as userData. The center lives as long as the
        // agent (the whole process), and `uninstall()` removes the handler before it could go away.
        let status = InstallEventHandler(GetApplicationEventTarget(), carbonHotkeyCallback, 1, &spec,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr { log.error("InstallEventHandler failed: \(status, privacy: .public)") }
        return status
    }

    /// Registers `hotkey` (replacing any registered one). Returns the Carbon status.
    @discardableResult
    func register(_ hotkey: LPHotkey, as carbon: HelperCarbonHotkey) -> OSStatus {
        unregister()
        generation &+= 1
        let id = EventHotKeyID(signature: OSType(HelperHotkeyMapping.signature), id: generation)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(carbon.keyCode, carbon.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return status == noErr ? OSStatus(eventInternalErr) : status }
        hotKey = ref
        registered = hotkey
        return noErr
    }

    func unregister() {
        if let hotKey {
            let status = UnregisterEventHotKey(hotKey)
            if status != noErr { log.error("UnregisterEventHotKey failed: \(status, privacy: .public)") }
        }
        hotKey = nil
        registered = nil
    }

    /// Unregisters the hotkey and removes the event handler (shutdown).
    func uninstall() {
        unregister()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    fileprivate func pressed(_ id: EventHotKeyID) -> Bool {
        guard id.signature == OSType(HelperHotkeyMapping.signature), id.id == generation, registered != nil else { return false }
        onPressed?()
        return true
    }
}

/// The Carbon event handler (a C function pointer: no captures).
private func carbonHotkeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let center = Unmanaged<CarbonHotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
    // Carbon dispatches application-target events on the main thread (from NSApplication's loop).
    let handled = MainActor.assumeIsolated { center.pressed(id) }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
