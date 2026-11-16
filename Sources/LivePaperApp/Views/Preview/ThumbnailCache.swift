// ThumbnailCache — downsampled images decoded off the main thread, cached by path + revision + size.
// CoreGraphics + ImageIO only (no SwiftUI/AppKit), so it also runs inside LivePaperSelfTest.
import CoreGraphics
import Foundation
import ImageIO

/// Decodes images with ImageIO at the size they're displayed at (a 640×400 JPEG costs ~1 MB
/// decoded; the grid shows dozens) and caches them by path + revision + size.
///
/// Callers bump `revision` when a file is rewritten under the same name (a re-rendered AI still,
/// an edited scene's thumbnail). Only the newest revision of a path at a given size is kept: a
/// newer one evicts the image it replaces, so re-renders don't accumulate dead images.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, CGImage>()
    private let lock = NSLock()
    /// "path#maxPixel" → the newest revision cached for it (and that entry's key).
    private var newest: [String: (revision: Int, key: String)] = [:]

    init() { cache.countLimit = 300 }

    static func key(_ url: URL?, revision: Int, maxPixel: Int) -> String {
        "\(url?.path ?? "-")#\(revision)#\(maxPixel)"
    }

    func cached(_ key: String) -> CGImage? { cache.object(forKey: key as NSString) }

    func load(_ url: URL, revision: Int = 0, maxPixel: Int) async -> CGImage? {
        let key = Self.key(url, revision: revision, maxPixel: maxPixel)
        if let hit = cached(key) { return hit }
        let image = await Task.detached(priority: .utility) { Self.decode(url, maxPixel: maxPixel) }.value
        if let image { store(image, key: key, slot: "\(url.path)#\(maxPixel)", revision: revision) }
        return image
    }

    /// Images held in memory (a prepared reference image's vision copy), cached under `id`: the
    /// bytes behind an id never change, so there are no revisions.
    static func key(dataID id: String, maxPixel: Int) -> String { "data:\(id)#\(maxPixel)" }

    func load(data: Data, id: String, maxPixel: Int) async -> CGImage? {
        let key = Self.key(dataID: id, maxPixel: maxPixel)
        if let hit = cached(key) { return hit }
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            return Self.thumbnail(src, maxPixel: maxPixel)
        }.value
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }

    private func store(_ image: CGImage, key: String, slot: String, revision: Int) {
        lock.lock(); defer { lock.unlock() }
        if let current = newest[slot] {
            // A load that finished after a newer revision's: the file has changed since, don't keep it.
            guard revision >= current.revision else { return }
            if current.key != key { cache.removeObject(forKey: current.key as NSString) }
        }
        newest[slot] = (revision, key)
        cache.setObject(image, forKey: key as NSString)
    }

    private static func decode(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(src, maxPixel: maxPixel)
    }

    private static func thumbnail(_ src: CGImageSource, maxPixel: Int) -> CGImage? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
