// ThumbnailImage — downsampled, cached scene thumbnails decoded off the main thread.
import ImageIO
import LivePaperCore
import SwiftUI

/// Decodes images with ImageIO at the size they're displayed at (a 640×400 JPEG costs ~1 MB
/// decoded; the grid shows dozens) and caches them by path + revision.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, CGImage>()

    init() { cache.countLimit = 300 }

    func cached(_ key: String) -> CGImage? { cache.object(forKey: key as NSString) }

    func load(_ url: URL, maxPixel: Int, key: String) async -> CGImage? {
        if let hit = cached(key) { return hit }
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceShouldCacheImmediately: true]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }.value
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }
}

struct ThumbnailImage: View {
    let url: URL?
    var revision: Int = 0
    var maxPixel: Int = 720
    /// Shown while loading / when there is no thumbnail.
    var placeholderSymbol: String = "photo"

    @State private var image: CGImage?

    private var key: String { "\(url?.path ?? "-")#\(revision)#\(maxPixel)" }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
                Image(systemName: placeholderSymbol)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .task(id: key) {
            if let hit = ThumbnailCache.shared.cached(key) { image = hit; return }
            guard let url else { image = nil; return }
            image = await ThumbnailCache.shared.load(url, maxPixel: maxPixel, key: key)
        }
    }
}
