// DisplayLayout — the displays of a Mac as arranged in System Settings › Displays: stable display
// keys, a stable order, the "main" display and the virtual canvas that "Span across displays" draws on.
//
// IMPORTANT: like PlaylistModel.swift this file is compiled into BOTH LivePaperCore and the sandboxed
// LivePaper.saver (scripts/build-saver.sh, Swift 5 mode). Keep it Foundation-only and self-contained.
//
// Coordinates are points with a top-left origin and y growing downwards — CGDisplayBounds'
// convention: the menu-bar display's top-left corner is (0, 0). NSScreen.frame (Cocoa: y up, origin
// at the menu-bar screen's bottom-left) is converted with `LPDisplay.cocoa`.
import Foundation

/// A rectangle in points, top-left origin, y down. (Foundation's CGRect lacks its geometry helpers
/// without CoreGraphics on some toolchains, and this file must stay Foundation-only.)
public struct LPRect: Codable, Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public static let zero = LPRect(x: 0, y: 0, width: 0, height: 0)

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    /// No area (or not a number).
    public var isEmpty: Bool { !(width > 0) || !(height > 0) }

    /// The smallest rectangle containing both (an empty one doesn't count).
    public func union(_ other: LPRect) -> LPRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let x0 = min(minX, other.minX), y0 = min(minY, other.minY)
        return LPRect(x: x0, y: y0, width: max(maxX, other.maxX) - x0, height: max(maxY, other.maxY) - y0)
    }

    /// Whether the two overlap with a positive area (touching edges don't).
    public func intersects(_ other: LPRect) -> Bool {
        !isEmpty && !other.isEmpty && minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }

    public func offsetBy(dx: Double, dy: Double) -> LPRect { LPRect(x: x + dx, y: y + dy, width: width, height: height) }

    /// Every coordinate multiplied by `s` (points → pixels).
    public func scaled(_ s: Double) -> LPRect { LPRect(x: x * s, y: y * s, width: width * s, height: height * s) }
}

/// One display as the saver and the app see it.
public struct LPDisplay: Codable, Sendable, Equatable, Identifiable {
    /// Display key: the display's UUID as an uppercase string (CFUUIDCreateString of
    /// CGDisplayCreateUUIDFromDisplayID — the form the wallpaper store uses), or "DISPLAY-<id>" for a
    /// display without one. Always `normalizedID`.
    public var id: String
    /// NSScreen.localizedName ("" when unknown).
    public var name: String
    /// Global frame in points: top-left origin at the menu-bar display's top-left, y down.
    public var frame: LPRect
    /// backingScaleFactor (pixels per point).
    public var scale: Double
    /// CGDisplayIsBuiltin: the laptop's own panel.
    public var isBuiltin: Bool
    /// The display with the menu bar (NSScreen.screens[0]).
    public var isMenuBar: Bool

    public init(id: String, name: String = "", frame: LPRect, scale: Double = 2, isBuiltin: Bool = false, isMenuBar: Bool = false) {
        self.id = LPDisplay.normalizedID(id); self.name = name; self.frame = frame; self.scale = scale
        self.isBuiltin = isBuiltin; self.isMenuBar = isMenuBar
    }

    /// A display from its NSScreen.frame (Cocoa: y up, origin at the menu-bar screen's bottom-left):
    /// top-left y' = menuBarScreenHeight − (y + height).
    public static func cocoa(id: String, name: String = "", x: Double, y: Double, width: Double, height: Double,
                             menuBarScreenHeight: Double, scale: Double = 2, isBuiltin: Bool = false, isMenuBar: Bool = false) -> LPDisplay {
        LPDisplay(id: id, name: name, frame: LPRect(x: x, y: menuBarScreenHeight - (y + height), width: width, height: height),
                  scale: scale, isBuiltin: isBuiltin, isMenuBar: isMenuBar)
    }

    /// Keys compare case-insensitively and without surrounding whitespace.
    public static func normalizedID(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }

    /// The key of a display without a UUID.
    public static func fallbackID(_ displayID: UInt32) -> String { "DISPLAY-\(displayID)" }
}

/// All connected displays in a stable order: left to right by the left edge, then top to bottom by
/// the top edge, then by key — the same order in every process, whichever display asks.
public struct LPDisplayLayout: Sendable, Equatable {
    /// Stable order; ids normalised; duplicate ids (the first wins) and empty frames dropped.
    public let displays: [LPDisplay]

    public init(_ displays: [LPDisplay]) {
        var seen = Set<String>(), kept: [LPDisplay] = []
        for var d in displays {
            d.id = LPDisplay.normalizedID(d.id)
            guard !d.id.isEmpty, !d.frame.isEmpty, d.frame.x.isFinite, d.frame.y.isFinite, seen.insert(d.id).inserted else { continue }
            kept.append(d)
        }
        self.displays = kept.sorted { a, b in
            if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
            if a.frame.minY != b.frame.minY { return a.frame.minY < b.frame.minY }
            return a.id < b.id
        }
    }

    public var count: Int { displays.count }

    /// Position of the display `id` (any case) in the stable order.
    public func index(of id: String) -> Int? {
        let key = LPDisplay.normalizedID(id)
        return displays.firstIndex { $0.id == key }
    }

    public func display(_ id: String) -> LPDisplay? { index(of: id).map { displays[$0] } }

    /// The "main" display: the built-in one if it is connected (and on), else the one with the menu
    /// bar, else the first.
    public var main: LPDisplay? {
        displays.first(where: \.isBuiltin) ?? displays.first(where: \.isMenuBar) ?? displays.first
    }

    /// The virtual canvas: the union of all frames (global coordinates). Regions no display covers
    /// (gaps, an L-shaped arrangement) are part of it and simply never shown.
    public var canvas: LPRect {
        displays.reduce(LPRect.zero) { $0.union($1.frame) }
    }

    /// The display's frame relative to the canvas origin (canvas coordinates, points, top-left): the
    /// part of the canvas it shows.
    public func viewport(of id: String) -> LPRect? {
        guard let d = display(id) else { return nil }
        let c = canvas
        return d.frame.offsetBy(dx: -c.minX, dy: -c.minY)
    }
}
