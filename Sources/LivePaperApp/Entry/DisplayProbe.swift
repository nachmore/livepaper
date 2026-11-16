// DisplayProbe — the connected displays for the Screen Saver screen's "Multiple displays" section
// (AppEnvironment.connectedDisplays / observeDisplays in the live app): NSScreen.screens mapped the way
// the saver maps them (Logic/DisplayIdentity.swift), and NSApplication's screen-parameter changes
// (a display connected, disconnected, rearranged or set to another resolution).
import AppKit
import LivePaperCore

@MainActor
enum DisplayProbe {
    /// Every screen, as LPDisplay. NSScreen.screens[0] has the menu bar.
    static func current() -> [LPDisplay] {
        let screens = NSScreen.screens
        guard let menuBar = screens.first else { return [] }
        return screens.enumerated().compactMap { index, screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplayIdentity.display(id: number.uint32Value, name: screen.localizedName, frame: screen.frame,
                                           menuBarScreenHeight: menuBar.frame.height, scale: screen.backingScaleFactor,
                                           isMenuBar: index == 0)
        }
    }

    /// Calls `handler` on the main actor after every change to the screens, until the returned
    /// closure cancels it.
    static func observe(_ handler: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) {
        let center = NotificationCenter.default
        let token = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        return { center.removeObserver(token) }
    }
}
