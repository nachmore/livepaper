// VideoSceneHost — a looping video scene: AVPlayerLayer + AVPlayerLooper with a native clock.
//
// Power: AVFoundation decodes H.264/HEVC in hardware and drives presentation itself, so the only
// timer here is the clock's once-a-minute tick. Pausing stops decoding entirely.
//
// Several displays: every display's view runs in the same legacyScreenSaver process (verified), so
// displays showing the same video share ONE decoder — one AVQueuePlayer + AVPlayerLooper per file and
// publish (SharedVideoPlayers) behind each display's own AVPlayerLayer. Spanning is layer geometry:
// the player layer covers the whole virtual canvas, offset so this display's viewport shows, and the
// host view clips it. A still display shows one decoded frame in a plain layer, with no player.
import AppKit
import AVFoundation

/// One looping player shared by every AVPlayerLayer in this process that shows the same file.
final class SharedVideoPlayer {
    let key: String
    let player: AVQueuePlayer
    let looper: AVPlayerLooper
    fileprivate var statusObservation: NSKeyValueObservation?
    /// Leaseholder → whether it wants the video running.
    fileprivate var leases: [ObjectIdentifier: Bool] = [:]
    fileprivate var failureHandlers: [ObjectIdentifier: (String) -> Void] = [:]

    fileprivate init(key: String, url: URL) {
        self.key = key
        let player = AVQueuePlayer()
        player.isMuted = true
        // AVPlayer keeps the display awake while video plays by default; a screen saver must let
        // the display sleep on schedule (that is the single biggest battery saving).
        player.preventsDisplaySleepDuringVideoPlayback = false
        // Local file: start as soon as a frame is decodable instead of buffering ahead.
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: AVURLAsset(url: url)))
    }

    var leaseCount: Int { leases.count }

    fileprivate func applyRate() {
        if leases.values.contains(true) { player.play() } else { player.pause() }
    }

    fileprivate func stop() {
        statusObservation?.invalidate()
        statusObservation = nil
        player.pause()
        looper.disableLooping()
        player.removeAllItems()
    }
}

/// The process-wide registry of shared players (main thread only, like everything in the saver).
enum SharedVideoPlayers {
    private static var players: [String: SharedVideoPlayer] = [:]
    private static var leaseKeys: [ObjectIdentifier: String] = [:]

    /// Players are per file and publish generation: a republish never reuses an old decoder.
    static func key(url: URL, generation: Int) -> String { url.standardizedFileURL.path + "#\(generation)" }

    static func existing(url: URL, generation: Int) -> SharedVideoPlayer? { players[key(url: url, generation: generation)] }

    /// Leases the player for `url` (creating it), not yet running. `onFail` is called if the player
    /// fails; the lease is gone by then, and the next acquire gets a fresh player.
    static func acquire(url: URL, generation: Int, host: AnyObject, onFail: @escaping (String) -> Void) -> SharedVideoPlayer {
        let id = ObjectIdentifier(host)
        release(host: host)
        let k = key(url: url, generation: generation)
        let shared: SharedVideoPlayer
        if let existing = players[k] {
            shared = existing
        } else {
            shared = SharedVideoPlayer(key: k, url: url)
            players[k] = shared
            shared.statusObservation = shared.looper.observe(\.status, options: [.new]) { looper, _ in
                guard looper.status == .failed else { return }
                let reason = looper.error?.localizedDescription ?? "unknown error"
                DispatchQueue.main.async { fail(k, reason: "video failed: \(reason)") }
            }
        }
        shared.leases[id] = false
        shared.failureHandlers[id] = onFail
        leaseKeys[id] = k
        return shared
    }

    /// The video plays while any of its leaseholders runs.
    static func setRunning(_ running: Bool, for host: AnyObject) {
        let id = ObjectIdentifier(host)
        guard let k = leaseKeys[id], let shared = players[k] else { return }
        shared.leases[id] = running
        shared.applyRate()
    }

    /// Ends the lease; the last one stops and drops the player.
    static func release(host: AnyObject) {
        let id = ObjectIdentifier(host)
        guard let k = leaseKeys.removeValue(forKey: id), let shared = players[k] else { return }
        shared.leases.removeValue(forKey: id)
        shared.failureHandlers.removeValue(forKey: id)
        if shared.leases.isEmpty {
            shared.stop()
            players.removeValue(forKey: k)
        } else {
            shared.applyRate()
        }
    }

    private static func fail(_ k: String, reason: String) {
        guard let shared = players.removeValue(forKey: k) else { return }
        let handlers = shared.failureHandlers
        for id in shared.leases.keys { leaseKeys.removeValue(forKey: id) }
        shared.leases = [:]
        shared.failureHandlers = [:]
        shared.stop()
        for handler in handlers.values { handler(reason) }
    }

    /// Players alive in this process (diagnostics).
    static var count: Int { players.count }
}

final class VideoSceneHost: NSObject, SceneHost {
    /// Give up on a video that never produces a frame (corrupt file, unsupported codec).
    private static let readyDeadline: TimeInterval = 10
    /// A still display's frame: within this much of the requested time is close enough.
    private static let stillTolerance = CMTime(seconds: 0.5, preferredTimescale: 600)

    let entryID: String
    let kind = "video"
    weak var delegate: SceneHostDelegate?
    var view: NSView { hostView }

    private let fileURL: URL
    private let generation: Int
    private let fit: LPVideoFit
    private let span: SaverSpan?
    private let hostView = LayerHostView(frame: .zero)
    private let playerLayer = AVPlayerLayer()
    /// A still display's single frame.
    private let stillLayer = CALayer()
    private let clock: ClockOverlay?
    private var shared: SharedVideoPlayer?
    private var readyObservation: NSKeyValueObservation?
    private var deadline: DispatchWorkItem?
    private var paused: Bool
    private var lockUIShowing: Bool
    private var liveness: SaverDisplayLiveness
    private var stillRequest = 0
    private var isReady = false
    private var failed = false

    init(entry: LPPlaylistEntry, fileURL: URL, context: SceneContext) {
        entryID = entry.id
        self.fileURL = fileURL
        generation = context.generation
        fit = entry.fit ?? .fill
        span = context.span
        paused = context.paused
        lockUIShowing = context.lockUIShowing
        liveness = context.liveness == .still ? .still : .live
        clock = context.wantsNativeClock ? ClockOverlay(position: context.clockPosition) : nil
        super.init()

        playerLayer.videoGravity = fit == .fit ? .resizeAspect : .resizeAspectFill
        playerLayer.backgroundColor = NSColor.black.cgColor
        stillLayer.contentsGravity = fit == .fit ? .resizeAspect : .resizeAspectFill
        stillLayer.backgroundColor = NSColor.black.cgColor
        stillLayer.isHidden = true
        // A spanning layer is the size of the whole canvas: show only this display's part of it.
        hostView.layer?.masksToBounds = true
        hostView.layer?.addSublayer(playerLayer)
        hostView.layer?.addSublayer(stillLayer)
        if let clock {
            hostView.layer?.addSublayer(clock.layer)
            clock.setVisible(clockVisible, animated: false)
        }
        hostView.onLayout = { [weak self] view in
            guard let self else { return }
            let frame = self.videoFrame(in: view.bounds)
            self.playerLayer.frame = frame
            self.stillLayer.frame = frame
            self.stillLayer.contentsScale = view.saverBackingScale
            self.clock?.layout(in: view.bounds, scale: view.saverBackingScale)
        }
    }

    /// The whole canvas, offset to this display's viewport, while spanning; else the view.
    private func videoFrame(in bounds: CGRect) -> CGRect {
        guard let span else { return bounds }
        let r = SaverSpanGeometry.layerFrame(span: span, viewHeight: Double(bounds.height))
        return CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
    }

    private var clockVisible: Bool { !lockUIShowing && liveness == .live }

    // MARK: SceneHost

    func load() {
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, !self.isReady else { return }
            self.fail("video produced no frame within \(Int(Self.readyDeadline)) s")
        }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyDeadline, execute: deadline)
        if liveness == .still { showStill() } else { attachPlayer() }
        clock?.setRunning(!paused && liveness == .live)
    }

    /// Leases the shared player and shows it in this display's layer.
    private func attachPlayer() {
        let shared = SharedVideoPlayers.acquire(url: fileURL, generation: generation, host: self) { [weak self] reason in
            self?.shared = nil
            self?.fail(reason)
        }
        self.shared = shared
        playerLayer.player = shared.player
        readyObservation?.invalidate()
        // KVO may fire off the main thread; hop back before touching state.
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.playerBecameReady() }
        }
        SharedVideoPlayers.setRunning(!paused, for: self)
    }

    private func detachPlayer() {
        readyObservation?.invalidate()
        readyObservation = nil
        SharedVideoPlayers.release(host: self)
        playerLayer.player = nil
        shared = nil
    }

    private func playerBecameReady() {
        guard liveness == .live, playerLayer.player != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.isHidden = false
        stillLayer.isHidden = true
        CATransaction.commit()
        markReady()
    }

    /// One decoded frame — where the shared player is now, if another display plays this video —
    /// in a plain layer. No player, no decoding afterwards.
    private func showStill() {
        stillRequest += 1
        let request = stillRequest
        let time = SharedVideoPlayers.existing(url: fileURL, generation: generation)?.player.currentTime() ?? .zero
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = Self.stillTolerance
        generator.requestedTimeToleranceAfter = Self.stillTolerance
        let scale = hostView.saverBackingScale
        let size = videoFrame(in: hostView.bounds).size
        if size.width > 0, size.height > 0 {
            generator.maximumSize = CGSize(width: min(8192, size.width * scale), height: min(8192, size.height * scale))
        }
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time.isValid ? time : .zero)]) { [weak self] _, image, _, result, error in
            DispatchQueue.main.async {
                guard let self, request == self.stillRequest, self.liveness == .still else { return }
                guard result == .succeeded, let image else {
                    self.fail("video frame unavailable: \(error?.localizedDescription ?? "no image")")
                    return
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.stillLayer.contents = image
                self.stillLayer.isHidden = false
                self.playerLayer.isHidden = true
                CATransaction.commit()
                self.markReady()
            }
        }
    }

    func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        if liveness == .live { SharedVideoPlayers.setRunning(!paused, for: self) }
        clock?.setRunning(!paused && liveness == .live)
    }

    func setLockUIShowing(_ showing: Bool, animated: Bool) {
        lockUIShowing = showing
        clock?.setVisible(clockVisible, animated: animated)
    }

    func setLiveness(_ liveness: SaverDisplayLiveness) {
        let target: SaverDisplayLiveness = liveness == .still ? .still : .live
        guard target != self.liveness, !failed else { return }
        self.liveness = target
        if target == .still {
            // Freeze on the current frame first (the player may go away with this lease).
            showStill()
            detachPlayer()
        } else {
            // The still stays up until the player layer has a frame.
            attachPlayer()
        }
        clock?.setVisible(clockVisible, animated: true)
        clock?.setRunning(!paused && target == .live)
    }

    func powerDidChange(profile: LPPerformanceProfile.Resolved, power: SaverPowerState) {
        // Nothing to tune: hardware decode at the file's own frame rate is already the cheapest path.
    }

    func tearDown() {
        delegate = nil
        deadline?.cancel()
        stillRequest += 1
        clock?.setRunning(false)
        detachPlayer()
        stillLayer.contents = nil
        hostView.removeFromSuperview()
    }

    var diagnostics: [String: Any] {
        var d: [String: Any] = ["kind": kind, "id": entryID, "ready": isReady, "paused": paused, "lockUIShowing": lockUIShowing,
                                "file": fileURL.lastPathComponent, "rate": shared?.player.rate ?? 0, "liveness": liveness.rawValue,
                                "sharedLayers": shared?.leaseCount ?? 0, "sharedPlayers": SharedVideoPlayers.count, "span": span != nil]
        if let clock { d["clockOpacity"] = clock.opacity }
        return d
    }

    // MARK: Private

    private func markReady() {
        guard !isReady, !failed else { return }
        isReady = true
        deadline?.cancel()
        delegate?.sceneHostDidBecomeReady(self)
    }

    private func fail(_ reason: String) {
        guard !failed else { return }
        failed = true
        deadline?.cancel()
        detachPlayer()
        SaverLog.scene.error("\(self.entryID, privacy: .public): \(reason, privacy: .public)")
        delegate?.sceneHost(self, didFail: reason)
    }
}
