// ReferenceTypes — reference images for AI sessions (ARCHITECTURE §10, "References").
//
// The user attaches up to `ReferenceLimits.maxImages` pictures to a create or modify session, each
// either as inspiration (`reference`) or as THE picture to bring to life (`animate`, at most one).
// LivePaper decodes, re-encodes and strips every image once, when it is added (app tray or CLI),
// into a `PreparedReference` held in memory; starting a session then only writes bytes into the
// workspace (ReferenceWorkspace). Nothing here ever leaves the Mac, and file names and paths are
// for the UI only: they never reach the workspace, logs or the scene's history.
import Foundation

/// Limits on reference images. Sizes are checked before anything is decoded.
public enum ReferenceLimits {
    /// Images per session.
    public static let maxImages = 10
    /// "Animate this image" pictures per session.
    public static let maxAnimated = 1
    /// File size (or pasted data size) checked before decoding.
    public static let maxFileBytes = 100 << 20
    /// Pixels in the image header (orientation applied), with each side at most `maxSide`.
    public static let maxPixels = 120_000_000
    public static let maxSide = 32_768
    /// Long edge of the master copy (the animate asset is made from it); never upscaled.
    public static let masterLongEdge = 3840
    /// Long edge of the copy agents look at (vision models scale larger images down anyway; the
    /// Claude API caps images at 2000 px once a request holds many).
    public static let visionLongEdge = 2000
    /// Largest vision copy (the API limit is about 5 MB after base64).
    public static let visionMaxBytes = 3_500_000
    /// Folder levels expanded below a dropped or given folder.
    public static let folderDepth = 3
    /// Entries looked at per folder before LivePaper stops scanning it.
    public static let folderScanLimit = 5_000
    /// Kept free below the compiler's asset limits for the scene's own small assets.
    public static let assetMarginBytes = 128 << 10
    /// An animate asset smaller than this would be too soft to be "this exact picture".
    public static let minAssetBytes = 300 << 10
}

/// What the agent is to do with an image.
public enum AIReferenceRole: String, Codable, Sendable, CaseIterable {
    /// Inspiration: style, palette, composition, subject — a starting point.
    case reference
    /// "Animate this exact image": the scene shows this picture and brings it to life.
    case animate
}

/// Where an image comes from: a file (picked, dropped, typed) or data (pasted, dropped from an app).
public enum AIReferenceSource: Sendable, Equatable {
    case file(URL)
    /// `typeIdentifier` is a hint for ImageIO (e.g. "public.png"); nil lets it sniff the data.
    case data(Data, typeIdentifier: String?)
}

/// An image the user wants to attach, before it is prepared.
public struct ReferenceInput: Sendable, Equatable {
    public var source: AIReferenceSource
    public var role: AIReferenceRole
    /// Shown in the tray / terminal only.
    public var displayName: String
    public init(source: AIReferenceSource, role: AIReferenceRole, displayName: String) {
        self.source = source; self.role = role; self.displayName = displayName
    }

    public static func file(_ url: URL, role: AIReferenceRole = .reference) -> ReferenceInput {
        ReferenceInput(source: .file(url), role: role, displayName: url.lastPathComponent)
    }
}

/// One re-encoded copy of an image: sRGB, 8 bits per channel, no metadata.
public struct EncodedReferenceImage: Sendable, Equatable {
    public enum Format: String, Codable, Sendable {
        case jpeg, png
        public var fileExtension: String { self == .jpeg ? "jpg" : "png" }
        public var typeIdentifier: String { self == .jpeg ? "public.jpeg" : "public.png" }
    }
    public let data: Data
    public let format: Format
    public let width: Int
    public let height: Int
    public init(data: Data, format: Format, width: Int, height: Int) {
        self.data = data; self.format = format; self.width = width; self.height = height
    }
    public var longEdge: Int { max(width, height) }
}

/// What an image's header says (read without decoding the pixels).
public struct ReferenceProbe: Sendable, Equatable {
    /// Display size: EXIF orientation applied.
    public var width: Int
    public var height: Int
    public var typeIdentifier: String
    /// "HEIC", "JPEG", "PNG", …
    public var formatName: String
    /// Frames in the file (GIF/APNG/HEICS); the first one is used.
    public var frameCount: Int
    /// The header announces an alpha channel (whether it is used is decided after decoding).
    public var hasAlpha: Bool
    public var byteCount: Int
    public init(width: Int, height: Int, typeIdentifier: String, formatName: String, frameCount: Int, hasAlpha: Bool, byteCount: Int) {
        self.width = width; self.height = height; self.typeIdentifier = typeIdentifier; self.formatName = formatName
        self.frameCount = frameCount; self.hasAlpha = hasAlpha; self.byteCount = byteCount
    }
}

/// An image ready to be written into a session workspace.
public struct PreparedReference: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var role: AIReferenceRole
    /// Shown in the UI / terminal only; never written to disk or logs.
    public let displayName: String
    /// The path as given (standardized, `~` expanded), for matching mentions in the prompt; nil for data.
    public let requestedPath: String?
    /// The file's real path (symlinks resolved); nil for data.
    public let originPath: String?
    public let original: ReferenceProbe
    /// ≤ `masterLongEdge`, JPEG q0.88 (PNG when transparent): what the animate asset is made from.
    public let master: EncodedReferenceImage
    /// ≤ `visionLongEdge` and ≤ `visionMaxBytes`: the copy agents look at.
    public let vision: EncodedReferenceImage
    public let summary: ReferenceSummary

    public init(id: UUID = UUID(), role: AIReferenceRole, displayName: String, requestedPath: String?, originPath: String?,
                original: ReferenceProbe, master: EncodedReferenceImage, vision: EncodedReferenceImage, summary: ReferenceSummary) {
        self.id = id; self.role = role; self.displayName = displayName; self.requestedPath = requestedPath; self.originPath = originPath
        self.original = original; self.master = master; self.vision = vision; self.summary = summary
    }
}

/// How many images of each role a session had (what history.jsonl and `started` events record).
public struct ReferenceCounts: Codable, Sendable, Equatable {
    public var reference: Int
    public var animate: Int
    public init(reference: Int, animate: Int) { self.reference = reference; self.animate = animate }
    public init(roles: [AIReferenceRole]) {
        reference = roles.filter { $0 == .reference }.count
        animate = roles.filter { $0 == .animate }.count
    }
    public var total: Int { reference + animate }

    /// "3 reference images (1 to animate)", "1 picture to animate", "2 reference images".
    public var description: String {
        if total == 1 && animate == 1 { return "1 picture to animate" }
        let images = "\(total) reference image\(total == 1 ? "" : "s")"
        return animate > 0 ? "\(images) (\(animate) to animate)" : images
    }
}

/// Why an image can't be attached. Each message is one actionable sentence naming files by their
/// base name only; they are shown to the user (banner, tray, stderr) and never logged.
public enum ReferenceError: Error, LocalizedError, Sendable, Equatable {
    case tooMany(count: Int)
    case tooManyAnimated(count: Int)
    case notFound(name: String)
    case notAFile(name: String)
    case tooLarge(name: String, bytes: Int)
    case tooManyPixels(name: String, width: Int, height: Int)
    case unsupported(name: String, kind: String?)
    case unreadable(name: String)
    case noRoomForAsset(availableKB: Int)
    case animateNeedsFile(name: String)

    public var errorDescription: String? {
        switch self {
        case .tooMany(let n):
            return "A session takes up to \(ReferenceLimits.maxImages) reference images (\(n) were given). Pick the ones that matter most."
        case .tooManyAnimated(let n):
            return "Only one image per session can be animated (\(n) are marked \u{201C}Animate\u{201D})."
        case .notFound(let name):
            return "\u{201C}\(name)\u{201D} doesn't exist (or is a link to nothing). Check the path and try again."
        case .notAFile(let name):
            return "\u{201C}\(name)\u{201D} isn't a regular file. Add an image file (JPEG, PNG, HEIC, …) or a folder of them."
        case .tooLarge(let name, let bytes):
            return "\u{201C}\(name)\u{201D} is \(Self.megabytes(bytes)); LivePaper takes images up to \(ReferenceLimits.maxFileBytes >> 20) MB. " +
                "Export a smaller copy (JPEG or PNG) and add that."
        case .tooManyPixels(let name, let w, let h):
            let mp = Int((Double(w) * Double(h) / 1_000_000).rounded())
            return "\u{201C}\(name)\u{201D} is \(w) \u{00D7} \(h) px (\(mp) megapixels); LivePaper takes images up to " +
                "\(ReferenceLimits.maxPixels / 1_000_000) megapixels. Export a smaller copy (JPEG or PNG) and add that."
        case .unsupported(let name, let kind):
            if kind == "SVG image" {
                return "\u{201C}\(name)\u{201D} is an SVG drawing, which LivePaper doesn't rasterise. Export it as PNG and add that."
            }
            return "\u{201C}\(name)\u{201D} isn't an image macOS can read\(kind.map { " (\($0))" } ?? ""). Export it as PNG or JPEG."
        case .unreadable(let name):
            return "\u{201C}\(name)\u{201D} couldn't be read as an image (it may be damaged or incomplete). Open it in Preview and export a copy."
        case .noRoomForAsset(let kb):
            return "The scene's own assets leave only \(kb) KB of the \(SceneCompiler.maxAssetTotalBytes >> 20) MB asset limit \u{2014} too " +
                "little for the picture to animate. Remove large files from its assets/ folder first."
        case .animateNeedsFile(let name):
            return "\u{201C}\(name)\u{201D} is a folder; --animate takes one image file (use --ref for folders)."
        }
    }

    static func megabytes(_ bytes: Int) -> String {
        bytes >= 1 << 20 ? "\(Int((Double(bytes) / Double(1 << 20)).rounded())) MB" : "\(max(1, bytes >> 10)) KB"
    }
}

public enum ReferencePrompts {
    /// The request used when the user attached images but typed nothing.
    public static func defaultPrompt(roles: [AIReferenceRole]) -> String? {
        if roles.contains(.animate) {
            return "Bring the attached picture to life: animate it subtly and keep it recognisably the same picture."
        }
        return roles.isEmpty ? nil : "Create a scene inspired by the attached reference images."
    }

    /// Throws unless `refs` respects the per-session limits.
    public static func validate(_ refs: [PreparedReference]) throws {
        guard refs.count <= ReferenceLimits.maxImages else { throw ReferenceError.tooMany(count: refs.count) }
        let animated = refs.filter { $0.role == .animate }.count
        guard animated <= ReferenceLimits.maxAnimated else { throw ReferenceError.tooManyAnimated(count: animated) }
    }
}
