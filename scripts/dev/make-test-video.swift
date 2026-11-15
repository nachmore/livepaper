// make-test-video — writes a short, small looping H.264 test clip for saver dev runs.
//
//   swiftc -O -o build/dev/make-test-video scripts/dev/make-test-video.swift
//   build/dev/make-test-video <out.mov> [--size 640x400] [--seconds 4] [--fps 30]
//
// AVFoundation (AVAssetWriter) + CoreGraphics only: no AppKit, so it never registers with the
// window server (safe to run any number of times). The clip is a dark gradient with a drifting
// glow and a progress bar along the bottom, so a snapshot shows which frame was on screen.
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

struct Options {
    var output: URL
    var width = 640
    var height = 400
    var seconds = 4.0
    var fps: Int32 = 30
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-test-video: \(message)\n".utf8))
    exit(1)
}

func parseOptions() -> Options {
    var args = Array(CommandLine.arguments.dropFirst())
    guard let first = args.first, !first.hasPrefix("-") else {
        fail("usage: make-test-video <out.mov> [--size WxH] [--seconds S] [--fps N]")
    }
    args.removeFirst()
    var options = Options(output: URL(fileURLWithPath: first))
    while !args.isEmpty {
        let flag = args.removeFirst()
        guard let value = args.first else { fail("\(flag) needs a value") }
        args.removeFirst()
        switch flag {
        case "--size":
            let parts = value.split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0, parts[0] % 2 == 0, parts[1] % 2 == 0 else {
                fail("--size must be WxH with even numbers")
            }
            options.width = parts[0]
            options.height = parts[1]
        case "--seconds":
            guard let s = Double(value), s > 0, s <= 60 else { fail("--seconds must be in (0, 60]") }
            options.seconds = s
        case "--fps":
            guard let f = Int32(value), f > 0, f <= 60 else { fail("--fps must be in 1…60") }
            options.fps = f
        default:
            fail("unknown option \(flag)")
        }
    }
    return options
}

/// Draws frame `index` of `count` into a BGRA pixel buffer.
func draw(_ buffer: CVPixelBuffer, index: Int, count: Int, width: Int, height: Int) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return }
    let w = CGFloat(width), h = CGFloat(height)
    // One full cycle per clip so the loop is seamless.
    let phase = CGFloat(index) / CGFloat(count)
    let angle = phase * 2 * .pi

    let colors = [CGColor(srgbRed: 0.05, green: 0.10, blue: 0.22, alpha: 1), CGColor(srgbRed: 0.01, green: 0.02, blue: 0.05, alpha: 1)]
    if let sky = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: .zero, options: [])
    }
    let center = CGPoint(x: w * (0.5 + 0.3 * cos(angle)), y: h * (0.45 + 0.18 * sin(angle * 2)))
    let glowColors = [CGColor(srgbRed: 0.30, green: 0.85, blue: 0.75, alpha: 0.85), CGColor(srgbRed: 0.30, green: 0.85, blue: 0.75, alpha: 0)]
    if let glow = CGGradient(colorsSpace: nil, colors: glowColors as CFArray, locations: [0, 1]) {
        ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: min(w, h) * 0.28, options: [])
    }
    // Progress bar: which frame this is, readable in any snapshot.
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.02))
    ctx.setFillColor(CGColor(srgbRed: 0.45, green: 0.55, blue: 1, alpha: 0.9))
    ctx.fill(CGRect(x: 0, y: 0, width: w * (phase + 1 / CGFloat(count)), height: h * 0.02))
}

let options = parseOptions()
try? FileManager.default.removeItem(at: options.output)
let fileType: AVFileType = options.output.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
guard let writer = try? AVAssetWriter(outputURL: options.output, fileType: fileType) else { fail("cannot create \(options.output.path)") }
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: options.width,
    AVVideoHeightKey: options.height,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 600_000, AVVideoMaxKeyFrameIntervalKey: Int(options.fps)],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: options.width,
    kCVPixelBufferHeightKey as String: options.height,
])
guard writer.canAdd(input) else { fail("cannot add a video input") }
writer.add(input)
guard writer.startWriting() else { fail("startWriting: \(writer.error?.localizedDescription ?? "?")") }
writer.startSession(atSourceTime: .zero)

let frameCount = max(1, Int((options.seconds * Double(options.fps)).rounded()))
for index in 0..<frameCount {
    while !input.isReadyForMoreMediaData { usleep(2_000) }
    guard let pool = adaptor.pixelBufferPool else { fail("no pixel buffer pool") }
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { fail("no pixel buffer") }
    draw(buffer, index: index, count: frameCount, width: options.width, height: options.height)
    guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: options.fps)) else {
        fail("append frame \(index): \(writer.error?.localizedDescription ?? "?")")
    }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fail("finishWriting: \(writer.error?.localizedDescription ?? "?")") }
let bytes = (try? FileManager.default.attributesOfItem(atPath: options.output.path)[.size] as? Int) ?? 0
print("wrote \(options.output.path) (\(options.width)x\(options.height), \(frameCount) frames, \(bytes / 1024) KB)")
