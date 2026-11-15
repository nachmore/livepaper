// HotkeyRecorderView — a shortcut field: click, press a key combination, done.
//
// While recording, an in-app *local* event monitor (not an event tap; no permissions needed) sees
// key presses before the menu bar does, so even ⌘-combinations can be captured. The decision logic
// lives in HotkeyRecorder (Logic/HotkeyRecording.swift) so it can be tested without AppKit.
import AppKit
import LivePaperCore
import SwiftUI

struct HotkeyRecorderView: View {
    @Binding var hotkey: LPHotkey?
    @State private var recorder = RecorderSession()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        Image(systemName: recorder.isRecording ? "record.circle" : "keyboard")
                            .foregroundStyle(recorder.isRecording ? Color.red : .secondary)
                        Text(fieldText)
                            .font(.body.monospaced())
                            .foregroundStyle(hotkey == nil && !recorder.isRecording ? .secondary : .primary)
                            .frame(minWidth: 110, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(recorder.isRecording ? Color.accentColor : Color.secondary.opacity(0.35),
                                          lineWidth: recorder.isRecording ? 2 : 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Lock shortcut")
                .accessibilityValue(recorder.isRecording ? "Recording" : HotkeyRecorder.accessibilityLabel(hotkey))
                .accessibilityHint(recorder.isRecording ? "Press the new key combination, or Escape to cancel."
                                                        : "Press to record a new shortcut.")
                if hotkey != nil && !recorder.isRecording {
                    Button {
                        hotkey = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Turn the shortcut off")
                    .accessibilityLabel("Clear shortcut")
                }
            }
            if let message = recorder.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if recorder.isRecording {
                Text("Press the new shortcut. Esc cancels, Delete turns it off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { recorder.stop() }
    }

    private var fieldText: String {
        if recorder.isRecording {
            let held = HotkeyRecorder.modifierGlyphs(recorder.heldModifiers)
            return held.isEmpty ? "Type shortcut\u{2026}" : held
        }
        return hotkey.map(HotkeyRecorder.display) ?? "Not set"
    }

    private func toggle() {
        if recorder.isRecording {
            recorder.stop()
        } else {
            recorder.start { outcome in
                switch outcome {
                case .accepted(let key): hotkey = key
                case .cleared: hotkey = nil
                case .cancelled, .rejected, .ignored: break
                }
            }
        }
    }
}

/// The live part of a recording: the event monitor and what the user is currently holding.
@MainActor
@Observable
final class RecorderSession {
    private(set) var isRecording = false
    private(set) var heldModifiers: [LPHotkey.Modifier] = []
    private(set) var message: String?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?

    func start(onOutcome: @escaping @MainActor (HotkeyRecorder.Outcome) -> Void) {
        guard !isRecording else { return }
        isRecording = true
        message = nil
        heldModifiers = []
        announce(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let raw = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            let isFlags = event.type == .flagsChanged
            let keyCode = event.keyCode
            // Local monitors run on the main thread. The shortcut being recorded is swallowed so it
            // can't also trigger a menu item; modifier changes pass through.
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if isFlags {
                    self.heldModifiers = HotkeyRecorder.modifiers(fromRawFlags: raw)
                    return false
                }
                let outcome = HotkeyRecorder.evaluate(keyCode: keyCode, rawFlags: raw)
                switch outcome {
                case .ignored:
                    break
                case .rejected(let why):
                    self.message = why
                case .accepted, .cleared, .cancelled:
                    self.message = nil
                    onOutcome(outcome)
                    self.stop()
                }
                return true
            }
            return swallow ? nil : event
        }
        // Clicking into another window or app ends recording (like the system's shortcut fields).
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        heldModifiers = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        announce(false)
    }

    /// LPNotification.hotkeyRecording (distributed) when recording starts/stops, so the helper
    /// suspends its own hotkey meanwhile; otherwise pressing the current shortcut to re-record it
    /// would lock the screen. deliverImmediately: the helper is a background agent.
    private func announce(_ active: Bool) {
        DistributedNotificationCenter.default().postNotificationName(
            .init(LPNotification.hotkeyRecording), object: nil,
            userInfo: [LPNotification.activeKey: active], deliverImmediately: true)
    }
}
