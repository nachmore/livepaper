// StillPreviews — small JPEG copies of `livepaper check`'s stills, for looking at them.
//
// The full-size stills are what users see, but a dithered 3024×1964 PNG is 4–6 MB: several of them
// exceed the request size some AI harnesses allow (Codex on Bedrock fails the whole turn with
// "request_too_large"), and they are slow for any image viewer. `check` therefore also writes
// .check/previews/<still>.jpg, at most `maxPixels` on the long side, which agents are told to view.
// ImageIO + CoreGraphics only: the CLI never links AppKit.
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import LivePaperCore
import UniformTypeIdentifiers

enum StillPreviews {
    /// `.check/previews/`
    static let directoryName = "previews"
    /// Long side of a preview, in pixels.
    static let maxPixels = 1280
    static let jpegQuality = 0.82

    /// Writes a preview for every still of `report` (paths relative to `package` or absolute) and
    /// removes previews of stills that no longer exist. Returns the preview directory, or nil when
    /// nothing was written. Failures are not the scene's fault and never fail the check.
    @discardableResult
    static func write(for report: CheckReport, package: URL) -> URL? {
        let check = package.appendingPathComponent(SceneChecker.checkDirectory)
        let dir = check.appendingPathComponent(directoryName)
        let fm = FileManager.default
        // `check` has just made .check a real directory; never follow a link swapped in since.
        var st = stat()
        guard lstat(check.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        // `check` rewrites .check/ on every run; start from an empty directory so stale previews never linger.
        try? fm.removeItem(at: dir)
        var written = 0
        for still in report.stills {
            let source = still.path.hasPrefix("/") ? URL(fileURLWithPath: still.path) : package.appendingPathComponent(still.path)
            guard (try? source.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if written == 0 { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            let out = dir.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".jpg")
            if writePreview(of: source, to: out) { written += 1 }
        }
        return written > 0 ? dir : nil
    }

    /// One downscaled JPEG (aspect ratio kept; images already small enough are only re-encoded).
    static func writePreview(of source: URL, to out: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
