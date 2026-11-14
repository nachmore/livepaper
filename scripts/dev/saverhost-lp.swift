// saverhost-lp — end-to-end dev host for LivePaper.saver (extends scripts/dev/saverhost.swift).
//
// Loads a built bundle the way legacyScreenSaver does (NSBundle principal class →
// ScreenSaverView(frame:isPreview:)), drives it through one scripted scenario in off-screen windows,
// and writes snapshots plus report.json into <out-dir>:
//
//   1. prewarm gate   — a started, non-preview instance loads nothing while the session is unlocked
//   2. web scene      — loads on "screen locked", config injected, clock hand-off (lock UI shown →
//                       hidden), display sleep pauses frames, a second display agrees on the
//                       scene, unlock pauses, session bookkeeping isolated, Options sheet
//   3. queued state   — lock UI already up before the page is ready → scene starts with its clock hidden
//   4. publish after signing — rewrites Playlist/ inside the signed bundle, a new view plays it
//   5. video scene    — AVPlayerLayer plays, native clock fades out/in with the lock UI, sleep pauses
//   6. preview        — small preview instance renders immediately without a lock
//   7. fallback       — empty playlist → built-in fallback; lock UI hides its hint and clock
//   8. recovery       — an undecodable video is retried with back-off, then skipped
//   9. willstop       — ignored by previews; a real instance exits the host (exit code 0)
//
//   xcrun swiftc -O -o build/dev/saverhost-lp scripts/dev/saverhost-lp.swift
//   LIVEPAPER_SAVER_STATE_FILE=/tmp/x/state.json build/dev/saverhost-lp build/LivePaper.saver /tmp/x
//
// Expects the playlist from scripts/dev/make-test-playlist.sh (defaults) and restores it at the end.
//
// Focus safety: activation policy .prohibited (the process can never become active or show a Dock
// icon), every window lives at (-30000, -30000), and the whole scenario is ONE process launch.
// System events reach the saver through its `livepaperHandleNotificationNamed:` test hook — nothing
// is broadcast. LIVEPAPER_SAVER_STATE_FILE keeps the saver away from the user's real
// ScreenSaverDefaults. Video frames can't be read back from an AVPlayerLayer without screen
// recording, so video snapshots composite AVAssetImageGenerator's frame at the player's current
// time under the saver's own layers (clock etc.), and playback is asserted via player time/rate.
import AppKit
import AVFoundation
import ScreenSaver
import WebKit

// MARK: - Arguments & report

var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    print("usage: saverhost-lp <LivePaper.saver> <out-dir> [--size WxH]")
    exit(2)
}
let bundleURL = URL(fileURLWithPath: arguments.removeFirst())
let outDir = URL(fileURLWithPath: arguments.removeFirst())
var fullSize = NSSize(width: 1512, height: 982)
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    if flag == "--size", let value = arguments.first {
        arguments.removeFirst()
        let parts = value.split(separator: "x").compactMap { Double($0) }
        if parts.count == 2 { fullSize = NSSize(width: parts[0], height: parts[1]) }
    }
}
let stateKey = "LIVEPAPER_SAVER_STATE_FILE"
guard let statePath = ProcessInfo.processInfo.environment[stateKey], !statePath.isEmpty else {
    print("FAIL: set \(stateKey) to a temp file so the saver never touches the real ScreenSaverDefaults")
    exit(2)
}
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try? FileManager.default.removeItem(atPath: statePath)

struct Check: Encodable { let name: String; let pass: Bool; let detail: String }
var checks: [Check] = []
var notes: [String: String] = [:]

func check(_ name: String, _ pass: Bool, _ detail: @autoclosure () -> String = "") {
    let d = detail()
    checks.append(Check(name: name, pass: pass, detail: d))
    print("\(pass ? "PASS" : "FAIL") \(name)\(d.isEmpty ? "" : " — \(d)")")
}

func writeReport() {
    struct Report: Encodable { let checks: [Check]; let notes: [String: String]; let passed: Int; let failed: Int }
    let failed = checks.filter { !$0.pass }.count
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(Report(checks: checks, notes: notes, passed: checks.count - failed, failed: failed)) {
        try? data.write(to: outDir.appendingPathComponent("report.json"))
    }
    print("\(checks.count - failed) passed, \(failed) failed — \(outDir.appendingPathComponent("report.json").path)")
}

// MARK: - Helpers

func delay(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

@MainActor func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        await delay(0.1)
    }
    return condition()
}

/// Delivers a system event to the saver in-process (the saver's test hook; nothing is broadcast).
@MainActor func deliver(_ name: String, to view: ScreenSaverView) {
    _ = view.perform(NSSelectorFromString("livepaperHandleNotificationNamed:"), with: name)
}

@MainActor func diagnostics(_ view: ScreenSaverView) -> [String: Any] {
    (view.perform(NSSelectorFromString("livepaperDiagnostics"))?.takeUnretainedValue() as? [String: Any]) ?? [:]
}

@MainActor func currentDiag(_ view: ScreenSaverView) -> [String: Any] { diagnostics(view)["current"] as? [String: Any] ?? [:] }

func webViews(in view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }

func layers(in layer: CALayer) -> [CALayer] { [layer] + (layer.sublayers ?? []).flatMap(layers) }

@MainActor func playerLayer(in view: NSView) -> AVPlayerLayer? {
    view.layer.flatMap { layers(in: $0).compactMap { $0 as? AVPlayerLayer }.first }
}

func writePNG(_ image: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    let url = outDir.appendingPathComponent(name)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    print("  wrote \(url.lastPathComponent) (\(image.width)×\(image.height))")
}

/// Evaluates JS that returns a JSON string and decodes it.
@MainActor func pageState(_ web: WKWebView) async -> [String: Any] {
    let script = "JSON.stringify(window.__lpTest ? Object.assign({}, window.__lpTest, {calls: window.__lpTest.calls.slice(-8)}) : null)"
    guard let json = try? await web.evaluateJavaScript(script) as? String,
          let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [:] }
    return object
}

@MainActor func snapshotWeb(_ web: WKWebView, _ name: String) async {
    let config = WKSnapshotConfiguration()
    config.snapshotWidth = NSNumber(value: Double(web.bounds.width) / 2)   // half size keeps the PNGs small
    guard let image = try? await web.takeSnapshot(configuration: config),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        check("snapshot \(name)", false, "takeSnapshot failed")
        return
    }
    writePNG(cg, name)
}

/// Snapshot of a layer-hosted scene (video / fallback) at half size: the video frame at the
/// player's current time, then the saver's own sublayers (clock, hint…) rendered on top.
@MainActor func snapshotLayers(_ saver: ScreenSaverView, _ name: String) async {
    guard let host = saver.subviews.last, let root = host.layer else { check("snapshot \(name)", false, "no scene view"); return }
    let scale: CGFloat = 0.5
    let width = Int(host.bounds.width * scale), height = Int(host.bounds.height * scale)
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.setFillColor(.black)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.scaleBy(x: scale, y: scale)
    let video = playerLayer(in: host)
    if let video, let player = video.player, let asset = player.currentItem?.asset {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let frame = try? await generator.image(at: player.currentTime()).image {
            let box = video.frame, iw = CGFloat(frame.width), ih = CGFloat(frame.height)
            let fill = video.videoGravity == .resizeAspectFill
            let s = fill ? max(box.width / iw, box.height / ih) : min(box.width / iw, box.height / ih)
            ctx.saveGState()
            ctx.clip(to: box)
            ctx.draw(frame, in: CGRect(x: box.midX - iw * s / 2, y: box.midY - ih * s / 2, width: iw * s, height: ih * s))
            ctx.restoreGState()
        }
    }
    for layer in root.sublayers ?? [] where !(layer is AVPlayerLayer) && !layer.isHidden {
        ctx.saveGState()
        ctx.translateBy(x: layer.frame.minX, y: layer.frame.minY)
        ctx.setAlpha(CGFloat(layer.opacity))
        layer.render(in: ctx)
        ctx.restoreGState()
    }
    if let image = ctx.makeImage() { writePNG(image, name) }
}

@MainActor final class Harness {
    let principal: ScreenSaverView.Type
    private var windows: [NSWindow] = []

    init(principal: ScreenSaverView.Type) { self.principal = principal }

    func makeView(size: NSSize, preview: Bool) -> ScreenSaverView? {
        guard let view = principal.init(frame: NSRect(origin: .zero, size: size), isPreview: preview) else { return nil }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFrontRegardless()
        windows.append(window)
        return view
    }

    func dispose(_ view: ScreenSaverView) {
        view.stopAnimation()
        if let window = view.window { window.orderOut(nil); windows.removeAll { $0 === window } }
    }
}

let playlistDir = bundleURL.appendingPathComponent("Contents/Resources/Playlist")
let playlistFile = playlistDir.appendingPathComponent("playlist.json")

func codesignVerify() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["--verify", "--strict", bundleURL.path]
    let pipe = Pipe()
    process.standardError = pipe
    process.standardOutput = pipe
    do { try process.run() } catch { return "codesign could not run: \(error)" }
    process.waitUntilExit()
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
    return process.terminationStatus == 0 ? "valid" : "invalid (\(firstLine))"
}

func writePlaylist(mode: String, generation: Int, scenes: [[String: String]]) throws {
    let object: [String: Any] = ["schema": 1, "generation": generation, "mode": mode, "cycleMinutes": 0, "showClock": true,
                                 "performance": "automatic", "scenes": scenes]
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: playlistFile, options: .atomic)
}

// MARK: - Scenario

@MainActor func runScenario() async {
    guard let bundle = Bundle(url: bundleURL), bundle.load() else { check("load bundle", false, bundleURL.path); return }
    guard let principal = bundle.principalClass as? ScreenSaverView.Type else {
        check("principal class", false, String(describing: bundle.principalClass))
        return
    }
    check("principal class", NSStringFromClass(principal) == "LivePaperSaverView", NSStringFromClass(principal))
    guard let original = try? Data(contentsOf: playlistFile) else { check("test playlist present", false, playlistFile.path); return }
    defer { try? original.write(to: playlistFile, options: .atomic) }
    let harness = Harness(principal: principal)

    // 1. Prewarm gate -------------------------------------------------------------------------
    guard let web = harness.makeView(size: fullSize, preview: false) else { check("init", false); return }
    web.startAnimation()
    await delay(1.5)
    let idle = diagnostics(web)
    check("prewarm: unlocked non-preview instance loads nothing", (idle["started"] as? Bool) == false && webViews(in: web).isEmpty
          && web.subviews.isEmpty, "started=\(idle["started"] ?? "?"), subviews=\(web.subviews.count)")

    // 2. Web scene ----------------------------------------------------------------------------
    deliver("com.apple.screenIsLocked", to: web)
    let webReady = await waitUntil(8) { (currentDiag(web)["ready"] as? Bool) == true && (currentDiag(web)["kind"] as? String) == "web" }
    check("web: loads once the session locks", webReady, "\(diagnostics(web))")
    guard webReady, let page = webViews(in: web).last else { return }
    await delay(1.0)   // first-reveal crossfade
    var state = await pageState(page)
    let config = state["config"] as? [String: Any] ?? [:]
    notes["web.config"] = String(describing: config)
    check("web: LIVEPAPER_CONFIG injected", config["clock"] as? Bool == true && config["clockPosition"] as? String == "top"
          && config["fps"] != nil && config["scale"] != nil && config["seed"] != nil && config["power"] != nil, "\(config)")
    check("web: animating, clock visible", (state["frames"] as? Int ?? 0) > 2 && state["clockOpacity"] as? Int == 1, "\(state)")
    await snapshotWeb(page, "web-1-clock.png")

    deliver("com.apple.screenLockUIIsShown", to: web)
    await delay(0.6)
    state = await pageState(page)
    check("web: lock UI shown → LivePaper.host.lockUI(true)", state["lockUI"] as? Bool == true && state["clockOpacity"] as? Int == 0,
          "\(state["calls"] ?? "")")
    await snapshotWeb(page, "web-2-lockui.png")

    deliver("com.apple.screenLockUIIsHidden", to: web)
    await delay(0.6)
    state = await pageState(page)
    check("web: lock UI hidden → clock back", state["lockUI"] as? Bool == false && state["clockOpacity"] as? Int == 1)
    await snapshotWeb(page, "web-3-clock-back.png")

    deliver("NSWorkspaceScreensDidSleepNotification", to: web)
    await delay(0.3)
    let asleep1 = await pageState(page)
    await delay(0.6)
    let asleep2 = await pageState(page)
    check("web: display sleep pauses frames", asleep1["paused"] as? Bool == true && asleep1["frames"] as? Int == asleep2["frames"] as? Int,
          "frames \(asleep1["frames"] ?? "?") → \(asleep2["frames"] ?? "?")")
    deliver("NSWorkspaceScreensDidWakeNotification", to: web)
    await delay(0.6)
    let awake = await pageState(page)
    check("web: wake resumes", awake["paused"] as? Bool == false && (awake["frames"] as? Int ?? 0) > (asleep2["frames"] as? Int ?? 0))

    // A second display starting a moment later joins the same session and shows the same scene.
    if let second = harness.makeView(size: NSSize(width: 1280, height: 800), preview: false) {
        second.startAnimation()
        deliver("com.apple.screenIsLocked", to: second)
        let ready = await waitUntil(8) { (currentDiag(second)["ready"] as? Bool) == true }
        let a = diagnostics(web), b = diagnostics(second)
        check("displays: second display agrees on session, deck and scene",
              ready && a["session"] as? Int == b["session"] as? Int && a["deck"] as? [String] == b["deck"] as? [String]
                && a["scene"] as? String == b["scene"] as? String,
              "session \(a["session"] ?? "?")/\(b["session"] ?? "?"), scene \(a["scene"] ?? "?")/\(b["scene"] ?? "?")")
        harness.dispose(second)
    }

    deliver("com.apple.screenIsUnlocked", to: web)
    await delay(0.3)
    let unlocked = await pageState(page)
    check("web: unlock pauses", unlocked["paused"] as? Bool == true && diagnostics(web)["running"] as? Bool == false)

    // Options sheet (rendered, never clicked: "Open LivePaper…" would broadcast a notification).
    check("options: hasConfigureSheet", web.hasConfigureSheet)
    if let sheet = web.configureSheet, let content = sheet.contentView {
        sheet.appearance = NSAppearance(named: .aqua)
        sheet.setFrameOrigin(NSPoint(x: -30000, y: -28000))
        sheet.orderFrontRegardless()
        content.layoutSubtreeIfNeeded()
        sheet.displayIfNeeded()
        func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
        let titles = buttons(content).map(\.title)
        check("options: Open LivePaper… + Done, not released on close",
              titles.contains("Open LivePaper…") && titles.contains("Done") && !sheet.isReleasedWhenClosed, "\(titles)")
        if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            if let cg = rep.cgImage { writePNG(cg, "options-sheet.png") }
        }
        sheet.orderOut(nil)
    } else {
        check("options: configureSheet", false)
    }
    harness.dispose(web)
    let record = (try? Data(contentsOf: URL(fileURLWithPath: statePath)))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    check("bookkeeping: session record went to \(stateKey)", record["lastShown"] as? String == "test-web", "\(record)")

    // 3. Lock UI state queued before the page is ready ----------------------------------------
    // A fresh session record: in sequence mode a new session continues after the last scene shown.
    try? FileManager.default.removeItem(atPath: statePath)
    if let queued = harness.makeView(size: fullSize, preview: false) {
        queued.startAnimation()
        deliver("com.apple.screenIsLocked", to: queued)
        deliver("com.apple.screenLockUIIsShown", to: queued)   // arrives while the page is still loading
        let ready = await waitUntil(8) { (currentDiag(queued)["ready"] as? Bool) == true }
        await delay(0.8)
        if ready, let page = webViews(in: queued).last {
            let s = await pageState(page)
            check("web: lock UI state queued until ready", s["lockUI"] as? Bool == true && s["clockOpacity"] as? Int == 0, "\(s["calls"] ?? "")")
        } else {
            check("web: lock UI state queued until ready", false, "scene never became ready")
        }
        harness.dispose(queued)
    }

    // 4. Publish into the signed bundle --------------------------------------------------------
    notes["codesign.afterTestPlaylist"] = codesignVerify()
    do {
        try writePlaylist(mode: "single", generation: 2, scenes: [
            ["id": "test-video", "name": "Test video", "kind": "video", "file": "test-video.mov", "clock": "top", "fit": "fill"],
        ])
    } catch {
        check("rewrite playlist", false, "\(error)")
        return
    }
    notes["codesign.afterRewrite"] = codesignVerify()

    // 5. Video scene --------------------------------------------------------------------------
    guard let video = harness.makeView(size: fullSize, preview: false) else { return }
    video.startAnimation()
    deliver("com.apple.screenIsLocked", to: video)
    let videoReady = await waitUntil(10) { (currentDiag(video)["ready"] as? Bool) == true && (currentDiag(video)["kind"] as? String) == "video" }
    check("publish: playlist rewritten after signing is played", videoReady && diagnostics(video)["generation"] as? Int == 2,
          "generation \(diagnostics(video)["generation"] ?? "?"), codesign \(notes["codesign.afterRewrite"] ?? "?")")
    if videoReady, let player = playerLayer(in: video)?.player {
        await delay(1.0)
        let t1 = player.currentTime().seconds
        await delay(0.5)
        let t2 = player.currentTime().seconds
        check("video: playing (muted, looping)", player.rate > 0 && player.isMuted && t2 != t1 && !player.preventsDisplaySleepDuringVideoPlayback,
              "rate \(player.rate), t \(String(format: "%.2f", t1)) → \(String(format: "%.2f", t2))")
        check("video: native clock visible", currentDiag(video)["clockOpacity"] as? Float == 1)
        await snapshotLayers(video, "video-1-clock.png")

        deliver("com.apple.screenLockUIIsShown", to: video)
        await delay(0.5)
        check("video: lock UI shown → native clock faded out", currentDiag(video)["clockOpacity"] as? Float == 0)
        await snapshotLayers(video, "video-2-lockui.png")
        deliver("com.apple.screenLockUIIsHidden", to: video)
        await delay(0.5)
        check("video: lock UI hidden → clock back", currentDiag(video)["clockOpacity"] as? Float == 1)

        deliver("NSWorkspaceScreensDidSleepNotification", to: video)
        await delay(0.3)
        let sleepingRate = player.rate
        deliver("NSWorkspaceScreensDidWakeNotification", to: video)
        await delay(0.3)
        check("video: display sleep pauses, wake resumes", sleepingRate == 0 && player.rate > 0, "rate asleep \(sleepingRate), awake \(player.rate)")
    }
    harness.dispose(video)

    // 6. Preview renders without a lock ---------------------------------------------------------
    guard let preview = harness.makeView(size: NSSize(width: 300, height: 188), preview: true) else { return }
    preview.startAnimation()
    let previewReady = await waitUntil(10) { (currentDiag(preview)["ready"] as? Bool) == true }
    check("preview: renders immediately (no lock needed)", previewReady && diagnostics(preview)["preview"] as? Bool == true)
    await snapshotLayers(preview, "preview.png")

    // 7. Fallback ---------------------------------------------------------------------------------
    do { try writePlaylist(mode: "shuffle", generation: 3, scenes: []) } catch { check("empty playlist", false, "\(error)") }
    guard let fallback = harness.makeView(size: fullSize, preview: false) else { return }
    fallback.startAnimation()
    deliver("com.apple.screenIsLocked", to: fallback)
    let fallbackShown = await waitUntil(5) { (currentDiag(fallback)["kind"] as? String) == "fallback" }
    await delay(0.8)
    check("fallback: empty playlist shows the built-in scene", fallbackShown, "\(currentDiag(fallback))")
    await snapshotLayers(fallback, "fallback.png")
    deliver("com.apple.screenLockUIIsShown", to: fallback)
    await delay(0.5)
    let hidden = currentDiag(fallback)
    check("fallback: lock UI hides hint and clock", hidden["messageOpacity"] as? Float == 0 && hidden["clockOpacity"] as? Float == 0, "\(hidden)")

    // 8. Failure recovery: an undecodable video is retried, then skipped -------------------------
    let broken = playlistDir.appendingPathComponent("broken.mov")
    try? Data(repeating: 0x5A, count: 4096).write(to: broken)
    try? FileManager.default.removeItem(atPath: statePath)
    do {
        try writePlaylist(mode: "sequence", generation: 4, scenes: [
            ["id": "broken", "name": "Broken video", "kind": "video", "file": "broken.mov", "clock": "top"],
            ["id": "test-web", "name": "Test web scene", "kind": "web", "file": "test-web.html", "clock": "top"],
        ])
    } catch { check("broken playlist", false, "\(error)") }
    if let recovering = harness.makeView(size: fullSize, preview: false) {
        recovering.startAnimation()
        deliver("com.apple.screenIsLocked", to: recovering)
        let recovered = await waitUntil(30) {
            (currentDiag(recovering)["kind"] as? String) == "web" && (currentDiag(recovering)["ready"] as? Bool) == true
        }
        let d = diagnostics(recovering)
        check("recovery: failing scene retried, then skipped", recovered && d["skipOffset"] as? Int == 1,
              "scene \(d["scene"] ?? "?"), skipOffset \(d["skipOffset"] ?? "?")")
        harness.dispose(recovering)
    }
    try? FileManager.default.removeItem(at: broken)

    // 9. willstop -------------------------------------------------------------------------------
    deliver("com.apple.screensaver.willstop", to: preview)
    await delay(1.0)
    check("willstop: preview instance keeps running", true, "host still alive 1 s after willstop")
    try? original.write(to: playlistFile, options: .atomic)
    writeReport()
    guard checks.allSatisfy(\.pass) else { exit(1) }
    print("willstop → expecting the saver to exit the host with status 0")
    deliver("com.apple.screensaver.willstop", to: fallback)
    await delay(3)
    print("FAIL: the saver did not exit the host after willstop")
    exit(3)
}

// MARK: - Main

let app = NSApplication.shared
// .prohibited: never activates, no Dock icon, no menu bar — cannot steal focus.
app.setActivationPolicy(.prohibited)
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                     reason: "LivePaper saver dev host")
DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
    print("FAIL: scenario timed out")
    writeReport()
    exit(4)
}
Task { @MainActor in
    await runScenario()
    writeReport()
    exit(1)   // only reached when the scenario stopped early
}
app.run()
_ = activity
