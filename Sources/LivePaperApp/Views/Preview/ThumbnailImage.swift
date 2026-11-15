// ThumbnailImage — downsampled, cached scene thumbnails decoded off the main thread (ThumbnailCache).
import LivePaperCore
import SwiftUI

/// Pass a new `revision` whenever the file at `url` was rewritten under the same name; the same
/// path + revision + size is never decoded twice.
struct ThumbnailImage: View {
    let url: URL?
    var revision: Int = 0
    var maxPixel: Int = 720
    /// Shown while loading / when there is no thumbnail.
    var placeholderSymbol: String = "photo"

    @State private var image: CGImage?

    private var key: String { ThumbnailCache.key(url, revision: revision, maxPixel: maxPixel) }

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
            image = await ThumbnailCache.shared.load(url, revision: revision, maxPixel: maxPixel)
        }
    }
}
