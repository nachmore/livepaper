// VideoSceneHost — a looping video scene: AVPlayerLayer + AVPlayerLooper with a native clock.
//
// Power: AVFoundation decodes H.264/HEVC in hardware and drives presentation itself, so the only
// timer here is the clock's once-a-minute tick. Pausing stops decoding entirely.
import AppKit
import AVFoundation

final class VideoSceneHost: NSObject, SceneHost {
    /// Give up on a video that never produces a frame (corrupt file, unsupported codec).
    private static let readyDeadline: TimeInterval = 10

    let entryID: String
    let kind = "video"
    weak var delegate: SceneHostDelegate?
    var view: NSView { hostView }

    private let fileURL: URL
    private let hostView = LayerHostView(frame: .zero)
    private let playerLayer = AVPlayerLayer()
    private let clock: ClockOverlay?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var observations: [NSKeyValueObservation] = []
    private var deadline: DispatchWorkItem?
    private var paused: Bool
    private var lockUIShowing: Bool
    private var isReady = false
    private var failed = false

    init(entry: LPPlaylistEntry, fileURL: URL, context: SceneContext) {
        entryID = entry.id
        self.fileURL = fileURL
        paused = context.paused
        lockUIShowing = context.lockUIShowing
        clock = context.wantsNativeClock ? ClockOverlay(position: context.clockPosition) : nil
        super.init()

        playerLayer.videoGravity = entry.fit == .fit ? .resizeAspect : .resizeAspectFill
        playerLayer.backgroundColor = NSColor.black.cgColor
        hostView.layer?.addSublayer(playerLayer)
        if let clock {
            hostView.layer?.addSublayer(clock.layer)
            clock.setVisible(!lockUIShowing, animated: false)
        }
        hostView.onLayout = { [weak self] view in
            guard let self else { return }
            self.playerLayer.frame = view.bounds
            self.clock?.layout(in: view.bounds, scale: view.saverBackingScale)
        }
    }

    // MARK: SceneHost

    func load() {
        let item = AVPlayerItem(asset: AVURLAsset(url: fileURL))
        let player = AVQueuePlayer()
        player.isMuted = true
        // AVPlayer keeps the display awake while video plays by default; a screen saver must let
        // the display sleep on schedule (that is the single biggest battery saving).
        player.preventsDisplaySleepDuringVideoPlayback = false
        // Local file: start as soon as a frame is decodable instead of buffering ahead.
        player.automaticallyWaitsToMinimizeStalling = false
        let looper = AVPlayerLooper(player: player, templateItem: item)
        self.player = player
        self.looper = looper
        playerLayer.player = player

        // KVO may fire off the main thread; hop back before touching state.
        observations.append(playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.markReady() }
        })
        observations.append(looper.observe(\.status, options: [.new]) { [weak self] looper, _ in
            guard looper.status == .failed else { return }
            let reason = looper.error?.localizedDescription ?? "unknown error"
            DispatchQueue.main.async { self?.fail("video failed: \(reason)") }
        })
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, !self.isReady else { return }
            self.fail("video produced no frame within \(Int(Self.readyDeadline)) s")
        }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyDeadline, execute: deadline)

        if !paused { player.play() }
        clock?.setRunning(!paused)
    }

    func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        if paused { player?.pause() } else { player?.play() }
        clock?.setRunning(!paused)
    }

    func setLockUIShowing(_ showing: Bool, animated: Bool) {
        lockUIShowing = showing
        clock?.setVisible(!showing, animated: animated)
    }

    func powerDidChange(profile: LPPerformanceProfile.Resolved, power: SaverPowerState) {
        // Nothing to tune: hardware decode at the file's own frame rate is already the cheapest path.
    }

    func tearDown() {
        delegate = nil
        deadline?.cancel()
        observations.forEach { $0.invalidate() }
        observations = []
        clock?.setRunning(false)
        player?.pause()
        looper?.disableLooping()
        player?.removeAllItems()
        playerLayer.player = nil
        player = nil
        looper = nil
        hostView.removeFromSuperview()
    }

    var diagnostics: [String: Any] {
        var d: [String: Any] = ["kind": kind, "id": entryID, "ready": isReady, "paused": paused, "lockUIShowing": lockUIShowing,
                                "file": fileURL.lastPathComponent, "rate": player?.rate ?? 0]
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
        SaverLog.scene.error("\(self.entryID, privacy: .public): \(reason, privacy: .public)")
        delegate?.sceneHost(self, didFail: reason)
    }
}
