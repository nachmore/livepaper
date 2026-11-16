// ThumbnailImage — downsampled, cached scene thumbnails decoded off the main thread (ThumbnailCache);
// also for images held in memory (prepared reference images).
import LivePaperCore
import SwiftUI

/// Pass a new `revision` whenever the file at `url` was rewritten under the same name: images are
/// cached by path + revision + size, so without one a rewritten file keeps showing its old picture.
struct ThumbnailImage: View {
    let url: URL?
    var revision: Int = 0
    var maxPixel: Int = 720
    /// Shown while loading / when there is no thumbnail.
    var placeholderSymbol: String = "photo"
    /// Bytes in memory instead of a file (`url` is then ignored).
    var data: ThumbnailData?

    /// Encoded image bytes with a stable identity (equal by `id`, so views don't compare megabytes).
    struct ThumbnailData: Equatable {
        let id: String
        let bytes: Data
        static func == (a: ThumbnailData, b: ThumbnailData) -> Bool { a.id == b.id }
    }

    @State private var image: CGImage?

    private var key: String {
        data.map { ThumbnailCache.key(dataID: $0.id, maxPixel: maxPixel) } ?? ThumbnailCache.key(url, revision: revision, maxPixel: maxPixel)
    }

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
            if let data {
                image = await ThumbnailCache.shared.load(data: data.bytes, id: data.id, maxPixel: maxPixel)
                return
            }
            guard let url else { image = nil; return }
            image = await ThumbnailCache.shared.load(url, revision: revision, maxPixel: maxPixel)
        }
    }
}

extension ThumbnailImage {
    /// A prepared reference image (its vision copy, decoded small).
    init(reference: PreparedReference, maxPixel: Int) {
        self.init(url: nil, maxPixel: maxPixel, data: ThumbnailData(id: reference.id.uuidString, bytes: reference.vision.data))
    }
}
