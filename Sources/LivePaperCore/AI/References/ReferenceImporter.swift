// ReferenceImporter — turns a user's picture into the copies a session uses (ARCHITECTURE §10).
//
//   1. resolve: a file's real path must be a regular file of at most 100 MB (checked before it is
//      opened); pasted data must be at most 100 MB too
//   2. type: whatever ImageIO decodes as an image (JPEG, PNG, HEIC, WebP, TIFF, GIF/APNG first
//      frame, BMP, RAW…); PDF, SVG and the rest are refused with an actionable sentence
//   3. header: pixel size (orientation applied) from the properties, without decoding; at most
//      120 megapixels and 32,768 px per side
//   4. bounded decode: an ImageIO thumbnail at ≤ 3840 px (JPEG/HEIF/PNG/TIFF are subsampled, so a
//      20k × 20k picture is never decoded at full size), EXIF orientation applied
//   5. normalise: drawn into 8-bit sRGB (P3, CMYK, grey, 16-bit and HDR become sRGB SDR); the draw
//      carries no metadata, so EXIF, GPS, TIFF, IPTC and XMP are gone
//   6. encode: from that pixel buffer only (never CGImageDestinationAddImageFromSource), JPEG, or
//      PNG when the picture is meaningfully transparent (a cut-out; not a photo with a few soft
//      corner pixels, which become black): a master (≤ 3840 px) and a vision copy (≤ 2000 px)
//   7. summary: ReferenceSummary from a ≤ 96 px analysis draw
//
// Synchronous and CPU-heavy (≈ 0.1–1 s per photo): call it off the main thread, one image at a
// time. CoreGraphics, ImageIO, UniformTypeIdentifiers and CryptoKit only — no AppKit.
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ReferenceImporter {
    static let masterQuality = 0.88
    static let visionQuality = 0.85
    /// Long edges tried when a vision copy is over `visionMaxBytes`.
    static let visionSteps = [1600, 1280, 1024]
    /// Animate asset re-encodes tried, in order, until one fits the scene's asset budget (never upscaled).
    static let jpegLadder: [(longEdge: Int, quality: Double)] = [(3840, 0.88), (3840, 0.8), (3200, 0.8), (2880, 0.78), (2560, 0.76),
                                                                 (2048, 0.74), (1600, 0.72), (1280, 0.7)]
    static let pngLadder = [3840, 3200, 2560, 2048, 1600, 1280]
    /// A transparent picture to animate stays PNG down to this long edge, then becomes a JPEG.
    static let minTransparentEdge = 2048

    // MARK: - Probing

    /// The header of an image (no pixels decoded). Throws `ReferenceError` for anything LivePaper
    /// won't take: missing, not a regular file, too large, not an image, too many pixels.
    public static func probe(_ source: AIReferenceSource, name: String) throws -> ReferenceProbe {
        try open(source, name: name).probe
    }

    struct Opened {
        var source: CGImageSource
        var probe: ReferenceProbe
        var requestedPath: String?
        var originPath: String?
    }

    static func open(_ source: AIReferenceSource, name: String) throws -> Opened {
        let imageSource: CGImageSource?
        let byteCount: Int
        var requested: String?, origin: String?
        var extensionHint: String?
        switch source {
        case .file(let url):
            let path = url.standardizedFileURL.path
            requested = path
            extensionHint = url.pathExtension
            let found = AISessionPolicy.lookUp(path)
            guard let real = found.real else { throw found.denied ? ReferenceError.notPermitted(name: name) : ReferenceError.notFound(name: name) }
            var st = stat()
            guard lstat(real, &st) == 0 else { throw ReferenceError.notFound(name: name) }
            guard (st.st_mode & S_IFMT) == S_IFREG else { throw ReferenceError.notAFile(name: name) }
            byteCount = Int(st.st_size)
            guard byteCount <= ReferenceLimits.maxFileBytes else { throw ReferenceError.tooLarge(name: name, bytes: byteCount) }
            guard byteCount > 0 else { throw ReferenceError.unreadable(name: name) }
            origin = real
            imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: real) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        case .data(let data, let type):
            byteCount = data.count
            guard byteCount <= ReferenceLimits.maxFileBytes else { throw ReferenceError.tooLarge(name: name, bytes: byteCount) }
            guard byteCount > 0 else { throw ReferenceError.unreadable(name: name) }
            var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
            if let type { options[kCGImageSourceTypeIdentifierHint] = type }
            imageSource = CGImageSourceCreateWithData(data as CFData, options as CFDictionary)
            extensionHint = type.flatMap { UTType($0)?.preferredFilenameExtension }
        }
        guard let src = imageSource, let typeID = CGImageSourceGetType(src) as String? else {
            let kind = extensionHint.flatMap { UTType(filenameExtension: $0) }.map(kindName)
            throw ReferenceError.unsupported(name: name, kind: kind)
        }
        let type = UTType(typeID)
        if type?.conforms(to: .svg) == true { throw ReferenceError.unsupported(name: name, kind: "SVG image") }
        guard let type, type.conforms(to: .image) else {
            throw ReferenceError.unsupported(name: name, kind: type.map(kindName) ?? extensionHint.flatMap { UTType(filenameExtension: $0) }.map(kindName))
        }
        // The header only: pixel size and orientation, no decode.
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              var width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              var height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0 else {
            throw ReferenceError.unreadable(name: name)
        }
        if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(o) { swap(&width, &height) }
        guard width <= ReferenceLimits.maxSide, height <= ReferenceLimits.maxSide,
              Double(width) * Double(height) <= Double(ReferenceLimits.maxPixels) else {
            throw ReferenceError.tooManyPixels(name: name, width: width, height: height)
        }
        guard CGImageSourceGetStatus(src) == .statusComplete, CGImageSourceGetCount(src) > 0 else {
            throw ReferenceError.unreadable(name: name)
        }
        let probe = ReferenceProbe(width: width, height: height, typeIdentifier: typeID, formatName: formatName(type),
                                   frameCount: CGImageSourceGetCount(src), hasAlpha: (props[kCGImagePropertyHasAlpha] as? Bool) ?? false,
                                   byteCount: byteCount)
        return Opened(source: src, probe: probe, requestedPath: requested, originPath: origin)
    }

    /// "PDF document", "Plain Text" — what the user sees when a file isn't an image.
    static func kindName(_ type: UTType) -> String { type.localizedDescription ?? type.preferredFilenameExtension?.uppercased() ?? type.identifier }

    static func formatName(_ type: UTType) -> String {
        let known: [(UTType, String)] = [(.jpeg, "JPEG"), (.png, "PNG"), (.heic, "HEIC"), (.heif, "HEIF"), (.gif, "GIF"),
                                         (.tiff, "TIFF"), (.bmp, "BMP"), (.webP, "WebP"), (.rawImage, "RAW")]
        return known.first { type.conforms(to: $0.0) }?.1 ?? type.preferredFilenameExtension?.uppercased() ?? "image"
    }

    // MARK: - Preparing

    /// Decodes (bounded), normalises and re-encodes one image; see the header for the steps.
    public static func prepare(_ input: ReferenceInput) throws -> PreparedReference {
        let name = input.displayName
        let opened = try open(input.source, name: name)
        let probe = opened.probe
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: min(ReferenceLimits.masterLongEdge, max(probe.width, probe.height)),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(opened.source, 0, options as CFDictionary),
              let pixels = SRGBBitmap(image: decoded) else { throw ReferenceError.unreadable(name: name) }
        let transparent = pixels.isMeaningfullyTransparent()
        let format: EncodedReferenceImage.Format = transparent ? .png : .jpeg
        guard let masterImage = pixels.cgImage(opaque: !transparent) else { throw ReferenceError.unreadable(name: name) }
        let master = try encode(masterImage, format: format, quality: masterQuality, name: name)
        let vision = try visionCopy(of: masterImage, format: format, transparent: transparent, name: name)
        guard let summary = ReferenceAnalysis.summary(master: masterImage, vision: vision, original: probe, transparent: transparent,
                                                      role: input.role) else { throw ReferenceError.unreadable(name: name) }
        return PreparedReference(role: input.role, displayName: name, requestedPath: opened.requestedPath, originPath: opened.originPath,
                                 original: probe, master: master, vision: vision, summary: summary)
    }

    /// The copy agents look at: ≤ 2000 px (high-quality downscale of the master), ≤ 3.5 MB.
    static func visionCopy(of master: CGImage, format: EncodedReferenceImage.Format, transparent: Bool,
                           name: String) throws -> EncodedReferenceImage {
        var last: EncodedReferenceImage?
        for edge in [ReferenceLimits.visionLongEdge] + visionSteps where edge < max(master.width, master.height) || last == nil {
            let image: CGImage
            if max(master.width, master.height) <= edge {
                image = master
            } else {
                guard let scaled = SRGBBitmap(image: master, maxPixel: edge)?.cgImage(opaque: !transparent) else {
                    throw ReferenceError.unreadable(name: name)
                }
                image = scaled
            }
            let encoded = try encode(image, format: format, quality: visionQuality, name: name)
            last = encoded
            if encoded.data.count <= ReferenceLimits.visionMaxBytes { return encoded }
        }
        guard let last else { throw ReferenceError.unreadable(name: name) }
        return last
    }

    /// Encodes pixels as JPEG or PNG with nothing but the compression quality: no properties, so
    /// no metadata (ImageIO adds only the sRGB colour profile).
    static func encode(_ image: CGImage, format: EncodedReferenceImage.Format, quality: Double, name: String) throws -> EncodedReferenceImage {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, format.typeIdentifier as CFString, 1, nil) else {
            throw ReferenceError.unreadable(name: name)
        }
        let props: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ReferenceError.unreadable(name: name) }
        return EncodedReferenceImage(data: data as Data, format: format, width: image.width, height: image.height)
    }

    /// A decoded thumbnail of encoded image data (the tray's tiles), orientation applied.
    public static func thumbnail(of data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    // MARK: - The animate asset

    /// The copy of the picture that goes into the scene's assets (`assets/reference.jpg`): the
    /// master when it fits the compiler's limits next to the scene's other assets, else the first
    /// rung of the ladder that does. A transparent picture stays PNG down to `minTransparentEdge`;
    /// below that it is flattened over black into the JPEG ladder (sharp beats see-through for
    /// "this exact picture"). Throws `noRoomForAsset` when the other assets leave too little room
    /// (too little to try, or for every rung), `pictureTooDetailed` when even the last rung is over
    /// the full per-file budget.
    static func animateAsset(from master: EncodedReferenceImage, otherAssetBytes: Int) throws -> EncodedReferenceImage {
        let room = SceneCompiler.maxAssetTotalBytes - otherAssetBytes
        let budget = min(SceneCompiler.maxAssetFileBytes, room) - ReferenceLimits.assetMarginBytes
        let noRoom = ReferenceError.noRoomForAsset(availableKB: max(0, room) >> 10)
        guard budget >= ReferenceLimits.minAssetBytes else { throw noRoom }
        if master.data.count <= budget { return master }
        // Whose fault it is when nothing fits: the scene's other assets, or the picture itself.
        let tooDetailed = room < SceneCompiler.maxAssetFileBytes ? noRoom : ReferenceError.pictureTooDetailed(budgetKB: budget >> 10)
        guard let decoded = thumbnail(of: master.data, maxPixel: master.longEdge),
              let pixels = SRGBBitmap(image: decoded) else { throw tooDetailed }
        var scaled: [String: CGImage] = [:]
        func image(longEdge: Int, opaque: Bool) -> CGImage? {
            let edge = min(longEdge, master.longEdge), key = "\(edge) \(opaque)"
            if let cached = scaled[key] { return cached }
            let made = edge >= master.longEdge ? pixels.cgImage(opaque: opaque)
                : SRGBBitmap(image: decoded, maxPixel: edge)?.cgImage(opaque: opaque)
            scaled[key] = made
            return made
        }
        typealias Rung = (edge: Int, quality: Double, format: EncodedReferenceImage.Format)
        let jpeg: [Rung] = jpegLadder.map { ($0.longEdge, $0.quality, .jpeg) }
        let rungs: [Rung] = master.format == .png
            ? pngLadder.filter { $0 >= minTransparentEdge }.map { ($0, 1, .png) } + jpeg
            : jpeg
        // The master's own settings give the master's size again: never worth an encode.
        var tried: Set<String> = ["\(master.longEdge)@\(master.format == .png ? 1 : masterQuality) \(master.format)"]
        for rung in rungs {
            let key = "\(min(rung.edge, master.longEdge))@\(rung.quality) \(rung.format)"
            guard tried.insert(key).inserted, let img = image(longEdge: rung.edge, opaque: rung.format == .jpeg) else { continue }
            let encoded = try encode(img, format: rung.format, quality: rung.quality, name: "reference")
            if encoded.data.count <= budget { return encoded }
        }
        throw tooDetailed
    }

    /// Lower-case hex SHA-256.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
