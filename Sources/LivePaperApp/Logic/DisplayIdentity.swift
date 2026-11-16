// DisplayIdentity — display keys and frames derived exactly as the saver derives them
// (`SaverDisplays` in Saver/SaverSupport.swift), so a scene chosen for a display in the app names the
// display the saver sees. CoreGraphics/ColorSync only (no AppKit: Entry/DisplayProbe.swift passes the
// NSScreen values in); also compiled into LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/.
import ColorSync
import CoreGraphics
import Foundation
import LivePaperCore

enum DisplayIdentity {
    /// The display's key: its UUID (CGDisplayCreateUUIDFromDisplayID, uppercase — the form the
    /// wallpaper store uses), or "DISPLAY-<id>" when it has none.
    static func key(for id: CGDirectDisplayID) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) as String? {
            return LPDisplay.normalizedID(string)
        }
        return LPDisplay.fallbackID(id)
    }

    /// One screen as the saver describes it. `frame` is NSScreen.frame (Cocoa: y up, origin at the
    /// menu-bar screen's bottom-left), `menuBarScreenHeight` the height of NSScreen.screens[0], which
    /// is the menu-bar screen. `isBuiltin` nil asks CGDisplayIsBuiltin.
    static func display(id: CGDirectDisplayID, name: String, frame: CGRect, menuBarScreenHeight: CGFloat,
                        scale: CGFloat, isMenuBar: Bool, isBuiltin: Bool? = nil) -> LPDisplay {
        LPDisplay.cocoa(id: key(for: id), name: name, x: Double(frame.minX), y: Double(frame.minY),
                        width: Double(frame.width), height: Double(frame.height),
                        menuBarScreenHeight: Double(menuBarScreenHeight), scale: Double(scale),
                        isBuiltin: isBuiltin ?? (CGDisplayIsBuiltin(id) != 0), isMenuBar: isMenuBar)
    }
}
