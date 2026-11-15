// VideoImporter — turns a user's video file into the media of a video scene:
//   * copy (mov/mp4/m4v) or remux other containers AVFoundation can read into .mov;
//   * "optimise for battery": HEVC, ≤ 3840×2160 (≤ 2160×3840 portrait), ≤ 30 fps, no audio;
//   * poster.jpg (AVAssetImageGenerator) and thumbnail.jpg (16:10, 640×400, cropped from the poster).
// Foundation/AVFoundation/CoreGraphics only — nothing here talks to the window server.
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum VideoImporter {
    /// Containers the saver's AVPlayer plays directly; anything else is remuxed into .mov.
    static let directCopyExtensions: Set<String> = ["mov", "mp4", "m4v"]
    static let maxLongSide: CGFloat = 3840
    static let maxShortSide: CGFloat = 2160
    static let maxFrameRate: Int32 = 30
    static let posterMaxSide: CGFloat = 1920
    static let thumbnailSize = CGSize(width: 640, height: 400)

    struct Source {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let duration: CMTime
        /// Display size (after the track's rotation).
        let orientedSize: CGSize
        /// The track's preferredTransform, translated so the rotated frame starts at the origin.
        let orientation: CGAffineTransform
        let minFrameDuration: CMTime
    }

    /// Loads and validates a video; throws `LibraryError.invalid` with a user-readable reason.
    static func inspect(_ url: URL) async throws -> Source {
        let asset = AVURLAsset(url: url)
        let name = url.lastPathComponent
        let tracks: [AVAssetTrack]
        do { tracks = try await asset.loadTracks(withMediaType: .video) } catch {
            throw LibraryError.invalid("\(name) can't be read as a video (\(error.localizedDescription)).")
        }
        guard let track = tracks.first else { throw LibraryError.invalid("\(name) has no video track.") }
        let (natural, transform, minFrame) = try await track.load(.naturalSize, .preferredTransform, .minFrameDuration)
        let (duration, playable) = try await asset.load(.duration, .isPlayable)
        guard playable else { throw LibraryError.invalid("\(name) uses a format macOS can't play.") }
        guard duration.isNumeric, duration.seconds > 0, natural.width > 0, natural.height > 0 else {
            throw LibraryError.invalid("\(name) contains no video frames.")
        }
        let box = CGRect(origin: .zero, size: natural).applying(transform)
        return Source(asset: asset, track: track, duration: duration,
                      orientedSize: CGSize(width: abs(box.width), height: abs(box.height)),
                      orientation: transform.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY)),
                      minFrameDuration: minFrame)
    }

    /// Writes the scene's video into `package` and returns its file name (e.g. "video.mov").
    /// `progress` receives 0…1.
    static func importVideo(from url: URL, into package: URL, optimizeForBattery: Bool,
                            progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let source = try await inspect(url)
        let ext = url.pathExtension.lowercased()
        if !optimizeForBattery, directCopyExtensions.contains(ext) {
            let name = "video.\(ext)"
            try FileManager.default.copyItem(at: url, to: package.appendingPathComponent(name))
            progress(1)
            return name
        }
        let name = "video.mov"
        let output = package.appendingPathComponent(name)
        if optimizeForBattery {
            try await transcode(source, to: output, progress: progress)
        } else {
            try await export(source.asset, preset: AVAssetExportPresetPassthrough, videoComposition: nil, to: output, progress: progress)
        }
        return name
    }

    /// Render size and scale for the battery profile: fit inside the bounds, never upscale, even
    /// dimensions (required by the HEVC/H.264 encoders).
    static func batteryRenderSize(for size: CGSize) -> (size: CGSize, scale: CGFloat) {
        let portrait = size.height > size.width
        let bounds = portrait ? CGSize(width: maxShortSide, height: maxLongSide) : CGSize(width: maxLongSide, height: maxShortSide)
        let scale = min(1, bounds.width / size.width, bounds.height / size.height)
        func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded(.down) * 2) }
        return (CGSize(width: even(size.width * scale), height: even(size.height * scale)), scale)
    }

    /// The output frame interval: the source's own if it is already ≤ 30 fps, else 1/30 s.
    static func batteryFrameDuration(sourceMinFrameDuration d: CMTime) -> CMTime {
        let cap = CMTime(value: 1, timescale: maxFrameRate)
        return d.isNumeric && d.seconds > 0 && d >= cap ? d : cap
    }

    private static func transcode(_ s: Source, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        // Video only: the screen saver is silent, so audio would just cost decode work and space.
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw LibraryError.invalid("Could not prepare the video for conversion.")
        }
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: s.duration), of: s.track, at: .zero)

        let (renderSize, scale) = batteryRenderSize(for: s.orientedSize)
        let video = AVMutableVideoComposition()
        video.renderSize = renderSize
        video.frameDuration = batteryFrameDuration(sourceMinFrameDuration: s.minFrameDuration)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        // Rotate upright first, then scale down: the composition renders in display orientation.
        layer.setTransform(s.orientation.concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        instruction.layerInstructions = [layer]
        video.instructions = [instruction]

        // HEVC where the hardware/OS supports it ("where possible"), else H.264.
        let hevc = await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetHEVCHighestQuality,
                                                            with: composition, outputFileType: .mov)
        try await export(composition, preset: hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality,
                         videoComposition: video, to: output, progress: progress)
    }

    private static func export(_ asset: AVAsset, preset: String, videoComposition: AVVideoComposition?, to output: URL,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw LibraryError.invalid("This video can't be converted on this Mac.")
        }
        session.outputURL = output
        session.outputFileType = .mov
        session.videoComposition = videoComposition
        let box = UncheckedSendableBox(session)
        // AVAssetExportSession.progress isn't observable on macOS 14; poll it.
        let poller = Task {
            while !Task.isCancelled {
                progress(Double(box.value.progress))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                box.value.exportAsynchronously { done.resume() }
            }
        } onCancel: {
            box.value.cancelExport()
        }
        // Wait for the poller so no stale value is reported after the final one.
        poller.cancel()
        await poller.value
        switch session.status {
        case .completed: progress(1)
        case .cancelled: throw CancellationError()
        default:
            throw LibraryError.invalid("Video conversion failed: \(session.error?.localizedDescription ?? "unknown error").")
        }
    }

    /// Writes poster.jpg and thumbnail.jpg for the video at `video` into `package`.
    static func writePosterAndThumbnail(for video: URL, in package: URL) async throws {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: posterMaxSide, height: posterMaxSide)
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        // A frame a little way in: the first frames of many clips are black (fade-in).
        let at = CMTime(seconds: min(1, duration.seconds / 2), preferredTimescale: 600)
        let (poster, _) = try await generator.image(at: at)
        try writeJPEG(poster, to: package.appendingPathComponent("poster.jpg"), quality: 0.85)
        try writeJPEG(try aspectFill(poster, size: thumbnailSize), to: package.appendingPathComponent("thumbnail.jpg"), quality: 0.8)
    }

    /// Scales and centre-crops `image` to exactly `size`.
    static func aspectFill(_ image: CGImage, size: CGSize) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw LibraryError.invalid("Could not create the thumbnail.")
        }
        ctx.interpolationQuality = .high
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let s = max(size.width / iw, size.height / ih)
        ctx.draw(image, in: CGRect(x: (size.width - iw * s) / 2, y: (size.height - ih * s) / 2, width: iw * s, height: ih * s))
        guard let out = ctx.makeImage() else { throw LibraryError.invalid("Could not create the thumbnail.") }
        return out
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LibraryError.invalid("Could not write \(url.lastPathComponent).")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw LibraryError.invalid("Could not write \(url.lastPathComponent).") }
    }
}

/// Carries a non-Sendable reference across a concurrency boundary where access is known to be safe
/// (AVAssetExportSession is documented as thread-safe for progress/cancel).
final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
