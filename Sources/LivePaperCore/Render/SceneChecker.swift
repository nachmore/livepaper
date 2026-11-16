// SceneChecker — `livepaper check` (ARCHITECTURE §9): compile, render stills, bench, judge budgets,
// write <package>/.check/report.json + PNGs. Owner: WS-runtime.
//
// The report is read by AI agents as much as by people, so every problem is one sentence that says
// what is wrong, where (size, time), by how much, and what to do about it.
import Darwin
import Foundation

/// Budgets and thresholds a scene must meet. Luminance is mean Rec. 709 luma, 0–255.
public struct CheckBudgets: Sendable, Equatable {
    /// ms/frame at 1512×982@2 (a MacBook Pro display) — the headline budget.
    public var benchMs: Double = 4
    /// ms/frame at 5120×1440@1 (a 32:9 ultra-wide monitor).
    public var wideBenchMs: Double = 6
    /// Above this fraction of a budget, warn that the scene is close to it.
    public var nearBudgetFraction: Double = 0.75
    /// Brighter than this on average and the lock screen looks washed out.
    public var maxMeanLuma: Double = 165
    /// Darker than this everywhere and the scene is probably not drawing.
    public var blackLuma: Double = 2
    /// The scene behind the clock must stay at most this bright so the white clock stays legible.
    public var maxClockLuma: Double = 120
    /// A wider spread of clock-region brightness across sampled times means the area is busy.
    public var clockLumaSpread: Double = 50
    /// CPU energy of the WebKit processes in the battery profile (30 fps, 75 % scale), mW.
    public var energyWarnMw: Double = 150
    public var energyMaxMw: Double = 300
    /// Live fps must reach this fraction of the battery profile's 30 fps cap.
    public var minLiveFpsFraction: Double = 0.85
    /// How alive the scene must feel: coverage, spread, busyness and flicker (MotionAnalysis.swift).
    public var motion = MotionBudgets()
    /// How much an "animate" scene's stills must look like the picture (ReferenceResemblance.swift).
    public var reference = ReferenceBudgets()
    public init() {}
}

/// One render size/time a check samples.
public struct CheckFrame: Sendable, Equatable, Hashable {
    public var width: Int, height: Int, dpr: Double, t: Double
    public init(_ width: Int, _ height: Int, dpr: Double, t: Double) { self.width = width; self.height = height; self.dpr = dpr; self.t = t }
    /// "1512x982@2" — the label used in report keys and problem sentences.
    public var sizeLabel: String { "\(width)x\(height)@\(Self.num(dpr))" }
    /// "1512x982@2 t=12"
    public var label: String { "\(sizeLabel) t=\(Self.num(t))" }
    /// "1512x982@2-t12.png"
    public var fileName: String { "\(sizeLabel)-t\(Self.num(t)).png" }
    /// Compact number: "2", "0.75".
    public static func num(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%g", x) }
}

/// What a check renders. `standard`/`quick` follow ARCHITECTURE §9.
public struct CheckPlan: Sendable, Equatable {
    /// Times sampled at the primary size; the last one is the long-run sample.
    public var times: [Double]
    public var stills: [CheckFrame]
    /// Short benches at the primary size (one per sampled time) that find the heaviest phase.
    public var probeFrames: Int
    public var probeTimes: [Double]
    /// Full benches, run at the heaviest probed time (or the first time when not probing).
    public var benchSizes: [CheckFrame]
    public var benchFrames: Int
    public var power: Bool
    /// Sizes the motion check renders (`t` unused), the moments it samples and the gaps it compares.
    public var motionSizes: [CheckFrame] = []
    public var motionTimes: [Double] = MotionAnalysis.defaultTimes
    public var motionGaps: [Double] = MotionAnalysis.defaultGaps
    /// Stills (a subset of `stills`) compared with the picture to animate, when the check has one.
    public var resemblanceFrames: [CheckFrame] = []

    public static let primary = CheckFrame(1512, 982, dpr: 2, t: 0)
    public static let ultraWide = CheckFrame(5120, 1440, dpr: 1, t: 0)
    /// Motion is analysed on small frames laid out at desktop sizes: 16:9 (640×360 px) and 5:4 (512×410 px).
    public static let motionWide = CheckFrame(1280, 720, dpr: 0.5, t: 0)
    public static let motionSquare = CheckFrame(1024, 820, dpr: 0.5, t: 0)

    public static func standard(power: Bool) -> CheckPlan {
        let times: [Double] = [0, 4, 12, 30, 90, 240, 600]
        var stills = times.map { CheckFrame(1512, 982, dpr: 2, t: $0) }
        stills += [12, 90, 600].map { CheckFrame(2560, 720, dpr: 1, t: $0) }     // 32:9
        stills += [12, 90].map { CheckFrame(1280, 1024, dpr: 1, t: $0) }         // 5:4
        stills += [CheckFrame(320, 200, dpr: 2, t: 12)]                          // thumbnail-sized
        let resemblance = [4, 12, 90, 600].map { CheckFrame(1512, 982, dpr: 2, t: $0) } + [12, 90].map { CheckFrame(2560, 720, dpr: 1, t: $0) }
            + [CheckFrame(1280, 1024, dpr: 1, t: 12)]
        return CheckPlan(times: times, stills: stills, probeFrames: 30, probeTimes: Array(times.dropLast()),
                         benchSizes: [primary, ultraWide], benchFrames: 120, power: power, motionSizes: [motionWide, motionSquare],
                         resemblanceFrames: resemblance)
    }

    /// A fast loop for iterating: three stills (+ one 32:9), motion at 16:9 only, one bench, no ultra-wide bench.
    public static func quick(power: Bool) -> CheckPlan {
        let times: [Double] = [4, 30, 600]
        let stills = times.map { CheckFrame(1512, 982, dpr: 2, t: $0) } + [CheckFrame(2560, 720, dpr: 1, t: 30)]
        var bench = primary
        bench.t = 30
        return CheckPlan(times: times, stills: stills, probeFrames: 0, probeTimes: [], benchSizes: [bench],
                         benchFrames: 60, power: power, motionSizes: [motionWide],
                         resemblanceFrames: [4, 30].map { CheckFrame(1512, 982, dpr: 2, t: $0) } + [CheckFrame(2560, 720, dpr: 1, t: 30)])
    }
}

/// Raw results of rendering a plan, before judging. Separated so the verdict logic is testable
/// without a render server.
public struct CheckResults: Sendable {
    public var stills: [(frame: CheckFrame, path: String, response: RenderResponse)] = []
    public var probes: [(frame: CheckFrame, response: RenderResponse)] = []
    public var benches: [(frame: CheckFrame, response: RenderResponse)] = []
    /// One `motion` request per motion size (`frame.t` unused).
    public var motion: [(frame: CheckFrame, response: RenderResponse)] = []
    public var live: RenderResponse?
    /// The stills compared with the picture to animate (only when the check had a reference target).
    public var reference: ReferenceMeasurement?
    public init() {}
}

public final class SceneChecker: SceneChecking, @unchecked Sendable {
    public static let checkDirectory = ".check"
    public static let reportFile = "report.json"
    public static let compiledFile = "scene.html"
    /// Battery profile used for `--power` (LPPerformanceProfile.battery).
    public static let powerProfile = LPPerformanceProfile.battery.resolved(onBatteryOrLowPower: true)

    public let compiler: SceneCompiling
    public let render: RenderClienting
    public var budgets = CheckBudgets()
    /// Progress lines ("rendering stills 3/13") for interactive callers; called on arbitrary threads.
    public var progress: (@Sendable (String) -> Void)?

    public init(compiler: SceneCompiling = SceneCompiler(), render: RenderClienting = RenderClient()) {
        self.compiler = compiler
        self.render = render
    }

    public func check(package: URL, options: CheckOptions) async throws -> CheckReport {
        let pkg = package.standardizedFileURL
        let checkDir = pkg.appendingPathComponent(Self.checkDirectory)
        try Self.resetCheckDirectory(checkDir)
        try Self.verifyCheckDirectory(checkDir)
        let manifest: SceneManifest
        do {
            manifest = try SceneCompiler.loadManifest(pkg)
        } catch let e as SceneCompileError {
            return try finish(CheckReport(passed: false, problems: e.messages), checkDir: checkDir, package: pkg, manifest: nil)
        }
        var problems = Self.manifestProblems(manifest)
        if manifest.kind == .video {
            problems += Self.videoProblems(manifest, package: pkg)
            let report = CheckReport(passed: problems.isEmpty, problems: problems,
                                     warnings: ["Video scenes are not rendered by check; only the manifest and the video file were verified."])
            return try finish(report, checkDir: checkDir, package: pkg, manifest: manifest)
        }

        let html = checkDir.appendingPathComponent(Self.compiledFile)
        progress?("compiling \(pkg.lastPathComponent)")
        try Self.verifyCheckDirectory(checkDir)
        do {
            try compiler.compile(package: pkg, to: html)
        } catch let e as SceneCompileError {
            return try finish(CheckReport(passed: false, problems: problems + e.messages), checkDir: checkDir, package: pkg, manifest: manifest)
        }

        let plan = options.quick ? CheckPlan.quick(power: options.power) : CheckPlan.standard(power: options.power)
        var results = try await run(plan, html: html, checkDir: checkDir)
        if let target = options.reference {
            progress?("comparing \(plan.resemblanceFrames.count) stills with the picture to animate")
            let wanted = Set(plan.resemblanceFrames)
            let stills = results.stills.filter { wanted.contains($0.frame) && $0.response.ok }.map { (frame: $0.frame, path: $0.path) }
            results.reference = ReferenceResemblance.measure(package: pkg, target: target, stills: stills, clock: manifest.clock.position,
                                                               budgets: budgets.reference)
        }
        var report = Self.evaluate(results, plan: plan, budgets: budgets, quick: options.quick)
        report.problems = problems + report.problems
        report.passed = report.problems.isEmpty
        return try finish(report, checkDir: checkDir, package: pkg, manifest: manifest)
    }

    // MARK: - Rendering

    private func run(_ plan: CheckPlan, html: URL, checkDir: URL) async throws -> CheckResults {
        var results = CheckResults()
        for (i, frame) in plan.stills.enumerated() {
            progress?("still \(i + 1)/\(plan.stills.count): \(frame.label)")
            let out = checkDir.appendingPathComponent(frame.fileName).path
            let r = try await send(RenderRequest(op: .still, html: html.path, width: Double(frame.width), height: Double(frame.height),
                                                 dpr: frame.dpr, t: frame.t, out: out, clock: true))
            results.stills.append((frame, out, r))
        }
        for (i, size) in plan.motionSizes.enumerated() {
            progress?("motion \(i + 1)/\(plan.motionSizes.count): \(size.sizeLabel) at \(MotionAnalysis.timeList(plan.motionTimes)), " +
                      "each compared with \(plan.motionGaps.map { CheckFrame.num($0) + " s" }.joined(separator: ", ")) later")
            let out = checkDir.appendingPathComponent(Self.motionFileName(size)).path
            let grid = MotionAnalysis.grid(width: Int((Double(size.width) * size.dpr).rounded()), height: Int((Double(size.height) * size.dpr).rounded()))
            let r = try await send(RenderRequest(op: .motion, html: html.path, width: Double(size.width), height: Double(size.height),
                                                 dpr: size.dpr, out: out, clock: true, times: plan.motionTimes, gaps: plan.motionGaps,
                                                 grid: [grid.cols, grid.rows]))
            results.motion.append((size, r))
        }
        for (i, t) in plan.probeTimes.enumerated() {
            var frame = CheckPlan.primary
            frame.t = t
            progress?("probe bench \(i + 1)/\(plan.probeTimes.count): \(frame.label)")
            results.probes.append((frame, try await send(bench(frame, html: html, frames: plan.probeFrames))))
        }
        let heaviest = Self.heaviestTime(results.probes) ?? plan.benchSizes.first?.t ?? 0
        for size in plan.benchSizes {
            var frame = size
            if !plan.probeTimes.isEmpty { frame.t = heaviest }
            progress?("bench \(frame.label) (\(plan.benchFrames) frames)")
            results.benches.append((frame, try await send(bench(frame, html: html, frames: plan.benchFrames))))
        }
        if plan.power {
            let p = Self.powerProfile
            progress?("live power measurement at \(CheckPlan.primary.sizeLabel), \(p.fps) fps, \(Int(p.scale * 100)) % scale (~15 s)")
            results.live = try await send(RenderRequest(op: .live, html: html.path, width: 1512, height: 982, dpr: 2,
                                                        fps: Double(p.fps), scale: p.scale, seconds: 10, warmup: 3))
        }
        return results
    }

    private func bench(_ frame: CheckFrame, html: URL, frames: Int) -> RenderRequest {
        RenderRequest(op: .bench, html: html.path, width: Double(frame.width), height: Double(frame.height), dpr: frame.dpr,
                      t: frame.t, frames: frames)
    }

    private func send(_ request: RenderRequest) async throws -> RenderResponse {
        try await render.send(request, timeout: RenderClient.defaultTimeout(for: request))
    }

    /// "motion-1280x720@0.5.png": the heat map of one motion size in .check/.
    public static func motionFileName(_ size: CheckFrame) -> String { "motion-\(size.sizeLabel).png" }

    static func heaviestTime(_ probes: [(frame: CheckFrame, response: RenderResponse)]) -> Double? {
        probes.filter { $0.response.ok && $0.response.benchMs != nil }
            .max { ($0.response.benchMs ?? 0) < ($1.response.benchMs ?? 0) }?.frame.t
    }

    // MARK: - Verdict

    /// Turns raw render results into problems (blocking) and warnings (advice).
    public static func evaluate(_ results: CheckResults, plan: CheckPlan, budgets b: CheckBudgets, quick: Bool) -> CheckReport {
        var problems: [String] = [], warnings: [String] = [], jsErrors: [String] = []
        var stills: [CheckReport.Still] = []
        var benchMs: [String: Double] = [:]

        func collectErrors(_ r: RenderResponse) {
            for e in r.errors where !jsErrors.contains(e) { jsErrors.append(e) }
        }
        // Findings that repeat across frames are grouped into one sentence each.
        var failures: [String: [CheckFrame]] = [:], failureOrder: [String] = []
        var neverStarted = false
        func renderFailed(_ r: RenderResponse, _ what: String, _ frame: CheckFrame) {
            let why = r.note ?? "no reason given"
            // The runtime gave up because of JS errors (reported on their own below).
            if !r.ready && !r.errors.isEmpty && why.hasPrefix(startFailureNote) { neverStarted = true; return }
            let key: String
            if !r.ready && why.contains("timed out") {
                key = "The scene did not finish loading for the \(what) (\(why)). Stills replay update() in 1/30 s steps up " +
                      "to t, so t=600 runs it 18,000 times: keep update() cheap, or compute state from lp.t."
            } else {
                key = "The \(what) failed: \(why)."
            }
            if failures[key] == nil { failureOrder.append(key) }
            failures[key, default: []].append(frame)
        }

        // Stills + luminance.
        var tooBright: [(CheckFrame, Double)] = [], clockTooBright: [(CheckFrame, Double)] = []
        var clockLumas: [(CheckFrame, Double)] = []
        for (frame, path, r) in results.stills {
            collectErrors(r)
            guard r.ok else { renderFailed(r, "still", frame); continue }
            stills.append(.init(path: path, width: frame.width, height: frame.height, dpr: frame.dpr, t: frame.t,
                                meanLuma: r.meanLuma, clockLuma: r.clockLuma))
            if let luma = r.meanLuma, luma > b.maxMeanLuma { tooBright.append((frame, luma)) }
            if let c = r.clockLuma {
                clockLumas.append((frame, c))
                if c > b.maxClockLuma { clockTooBright.append((frame, c)) }
            }
        }
        if let worst = tooBright.map(\.1).max() {
            problems.append("The frame is too bright for a lock screen: mean brightness up to \(fmt(worst))/255 (max " +
                            "\(fmt(b.maxMeanLuma))) at \(frameList(tooBright.map(\.0))). Use darker backgrounds and keep bright " +
                            "colours to small accents.")
        }
        if let worst = clockTooBright.map(\.1).max() {
            problems.append("The area behind the clock is too bright: mean up to \(fmt(worst))/255 (max \(fmt(b.maxClockLuma))) at " +
                            "\(frameList(clockTooBright.map(\.0))), so the white clock is hard to read. Keep the clock region " +
                            "(lp.clockRect; top centre for Apple's lock-screen clock) dark and calm, or move bright content away from it.")
        }
        let rendered = results.stills.filter { $0.response.ok }
        let lumas = rendered.compactMap { $0.response.meanLuma }
        if !lumas.isEmpty, lumas.allSatisfy({ $0 < b.blackLuma }) {
            problems.append("Every still is black (mean brightness under \(fmt(b.blackLuma))/255): nothing visible is drawn. Check " +
                            "that draw(lp) paints the canvas and look at the PNGs in .check/.")
        } else {
            let longRun = rendered.filter { $0.frame.t == plan.times.last && ($0.response.meanLuma ?? 99) < b.blackLuma }
            if !longRun.isEmpty {
                problems.append("At \(frameList(longRun.map(\.frame))) the frame is black although earlier stills are not: the scene " +
                                "decays over long runs. Keep state bounded (wrap phases with % or derive them from lp.t; never " +
                                "accumulate without limit).")
            }
        }
        if let lo = clockLumas.min(by: { $0.1 < $1.1 }), let hi = clockLumas.max(by: { $0.1 < $1.1 }), hi.1 - lo.1 > b.clockLumaSpread,
           hi.1 <= b.maxClockLuma {
            warnings.append("The area behind the clock changes a lot (brightness \(fmt(lo.1))–\(fmt(hi.1))/255 between \(lo.0.label) " +
                            "and \(hi.0.label)). Prefer calm, low-contrast motion behind the clock.")
        }

        // An "animate this exact image" scene: do the stills still show the user's picture?
        var reference: ReferenceCheckSummary?
        if let measured = results.reference {
            let v = ReferenceResemblance.verdict(measured, budgets: b.reference)
            problems += v.problems
            warnings += v.warnings
            reference = v.summary
        }

        // Motion: is the scene gently alive everywhere, without being busy or flickering?
        var motion: [MotionSummary] = []
        var motionUnsupported: String?
        for (frame, r) in results.motion {
            collectErrors(r)
            guard r.ok else {
                // A render server from before the motion op can't even decode the request.
                if (r.note ?? "").hasPrefix("bad request") { motionUnsupported = r.note } else { renderFailed(r, "motion measurement", frame) }
                continue
            }
            guard let m = r.motion else { motionUnsupported = "it returned no motion data"; continue }
            // `out` is set only when the server wrote the heat map.
            motion.append(MotionAnalysis.summarize(m, size: frame.sizeLabel, budgets: b.motion, heatmap: r.out))
        }
        let motionVerdict = MotionAnalysis.verdict(motion, budgets: b.motion)
        problems += motionVerdict.problems
        warnings += motionVerdict.warnings
        if let why = motionUnsupported {
            warnings.append("Motion was not measured: the render server doesn't support it (\(why)). It is probably an older " +
                            "LivePaper: quit and reopen LivePaper, or run `livepaper server stop`, then check again.")
        }

        // Benches. Probes are short runs that only locate the heaviest phase.
        for (frame, r) in results.probes {
            collectErrors(r)
            if r.ok, let ms = r.benchMs { benchMs[frame.label + probeSuffix] = ms }
        }
        for (frame, r) in results.benches {
            collectErrors(r)
            guard r.ok, let ms = r.benchMs else { renderFailed(r, "benchmark", frame); continue }
            benchMs[frame.label] = ms
            let budget = frame.width == CheckPlan.ultraWide.width && frame.dpr == CheckPlan.ultraWide.dpr ? b.wideBenchMs : b.benchMs
            if ms > budget {
                problems.append("Too slow at \(frame.label): \(fmt(ms, 2)) ms per frame (budget \(fmt(budget, 1)) ms). Cut draw calls " +
                                "(WebKit's canvas cost tracks the number of calls more than pixels): pre-render static layers in " +
                                "resize(), batch shapes into one Path2D per colour, use LivePaper.util.glow sprites instead of " +
                                "shadowBlur/ctx.filter, and draw fewer particles when lp.quality < 1.")
            } else if ms > budget * b.nearBudgetFraction {
                warnings.append("Close to the frame budget at \(frame.label): \(fmt(ms, 2)) of \(fmt(budget, 1)) ms. Slower Macs and " +
                                "battery mode have less headroom.")
            }
        }

        // Live power.
        var energy: Double?
        if let live = results.live {
            collectErrors(live)
            let p = powerProfile
            if live.ok, let mw = live.cpuMW {
                energy = mw
                let where_ = "in the battery profile (\(p.fps) fps, \(Int(p.scale * 100)) % scale, 1512x982@2)"
                if mw > b.energyMaxMw {
                    problems.append("Uses \(fmt(mw)) mW of CPU energy \(where_), budget \(fmt(b.energyMaxMw)) mW. Draw less per frame " +
                                    "(fewer calls, cached layers), avoid per-frame getImageData/toDataURL and WebGL→2D copies.")
                } else if mw > b.energyWarnMw {
                    warnings.append("Uses \(fmt(mw)) mW of CPU energy \(where_); under \(fmt(b.energyWarnMw)) mW is better for battery life.")
                }
                if let fps = live.fps, fps < Double(p.fps) * b.minLiveFpsFraction {
                    warnings.append("Only reached \(fmt(fps, 1)) of \(p.fps) fps while running live \(where_): frames take too long.")
                }
            } else {
                renderFailed(live, "live power measurement", CheckPlan.primary)
            }
        }

        for key in failureOrder { problems.append(key.dropLast() + " (at \(frameList(failures[key] ?? [])))." ) }
        if neverStarted {
            problems.append("Because of the JavaScript errors above the scene never started, so nothing could be rendered or measured.")
        }
        // JavaScript errors first: they usually explain everything else.
        var errorProblems = jsErrors.prefix(5).map { e -> String in
            let sentence = e.hasSuffix(".") ? e : e + "."
            return "JavaScript error: \(sentence) Fix it in scene.js (errors also appear in red at the bottom of the PNG stills)."
        }
        if jsErrors.count > 5 { errorProblems.append("…and \(jsErrors.count - 5) more JavaScript errors (see jsErrors in report.json).") }
        problems = errorProblems + problems
        if quick {
            warnings.append("Quick check: fewer stills, motion at 16:9 only and no ultra-wide benchmark. Run the full `livepaper check` " +
                            "before you finish.")
        }
        return CheckReport(passed: problems.isEmpty, problems: problems, warnings: warnings, jsErrors: jsErrors, stills: stills,
                           benchMs: benchMs, energyMw: energy, motion: results.motion.isEmpty ? nil : motion, reference: reference)
    }

    // MARK: - Manifest

    static func manifestProblems(_ m: SceneManifest) -> [String] {
        var p: [String] = []
        if !SceneManifest.isValidID(m.id) {
            p.append("scene.json: \"id\" \"\(m.id)\" must be kebab-case (a–z, 0–9 and inner hyphens, at most 64 characters), " +
                     "e.g. \"\(SceneManifest.slug(from: m.id))\".")
        }
        if m.name.trimmingCharacters(in: .whitespaces).isEmpty { p.append("scene.json: \"name\" must not be empty.") }
        if m.schema > SceneManifest.currentSchema {
            p.append("scene.json: \"schema\" \(m.schema) is newer than this LivePaper supports (\(SceneManifest.currentSchema)).")
        }
        return p
    }

    static func videoProblems(_ m: SceneManifest, package: URL) -> [String] {
        guard let v = m.video else { return ["scene.json: video scenes need a \"video\" section with the file name."] }
        let file = package.appendingPathComponent(v.file)
        return FileManager.default.fileExists(atPath: file.path) ? [] : ["scene.json: the video file \"\(v.file)\" is missing from the package."]
    }

    // MARK: - Output

    /// Makes `dir` (a package's `.check`) a real directory and removes what a previous check wrote
    /// (only our own files; anything else is left alone).
    ///
    /// The checker runs with the user's full rights, including on packages an AI agent just left
    /// behind or that came from elsewhere, so it never follows symbolic links here: a `.check` that
    /// is a link (or any other non-directory) is removed itself — never what it points to — and
    /// replaced by a new directory; inside it only regular files with our names are deleted, through
    /// the directory's descriptor, so a link swapped in meanwhile can't redirect the deletes.
    static func resetCheckDirectory(_ dir: URL) throws {
        var st = stat()
        if lstat(dir.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR {
            guard unlink(dir.path) == 0 || errno == ENOENT else { throw posixError("remove \(dir.path)") }
        }
        if mkdir(dir.path, 0o755) != 0, errno != EEXIST { throw posixError("create \(dir.path)") }
        let fd = open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("open \(dir.path)") }
        defer { close(fd) }
        for name in directoryEntries(fd) where name.hasSuffix(".png") || name == reportFile || name == compiledFile {
            var entry = stat()
            guard fstatat(fd, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let type = entry.st_mode & S_IFMT
            // Our outputs are regular files; a link with one of their names is removed itself.
            if type == S_IFREG || type == S_IFLNK { _ = unlinkat(fd, name, 0) }
        }
    }

    /// Throws unless `dir` is a real directory directly inside its package (no symbolic link
    /// anywhere between the package and it), i.e. writing into it can't land somewhere else.
    static func verifyCheckDirectory(_ dir: URL) throws {
        let parent = dir.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let real = dir.resolvingSymlinksInPath().standardizedFileURL.path
        guard FileOps.isRealDirectory(dir), real == (parent as NSString).appendingPathComponent(dir.lastPathComponent) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ELOOP), userInfo: [NSLocalizedDescriptionKey:
                "\(dir.path) is not a plain directory inside the scene package (a symbolic link?); LivePaper won't write there"])
        }
    }

    private static func directoryEntries(_ fd: Int32) -> [String] {
        let dup = dup(fd)
        guard dup >= 0, let dirp = fdopendir(dup) else { if dup >= 0 { close(dup) }; return [] }
        defer { closedir(dirp) }
        var names: [String] = []
        while let entry = readdir(dirp) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    private static func posixError(_ what: String) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSLocalizedDescriptionKey: "Could not \(what): \(String(cString: strerror(code)))"])
    }

    private func finish(_ report: CheckReport, checkDir: URL, package: URL, manifest: SceneManifest?) throws -> CheckReport {
        try Self.verifyCheckDirectory(checkDir)
        try Self.write(report, to: checkDir.appendingPathComponent(Self.reportFile))
        if report.passed, manifest?.kind == .web {
            try Self.recordPerformance(report, package: package)
        }
        return report
    }

    static func write(_ report: CheckReport, to url: URL) throws {
        try reportEncoder().encode(report).write(to: url, options: .atomic)
    }

    /// Pretty, sorted, ISO-8601 dates, and paths without escaped slashes (agents read this file).
    public static func reportEncoder() -> JSONEncoder {
        let e = SceneManifest.encoder()
        e.outputFormatting.insert(.withoutEscapingSlashes)
        return e
    }

    /// RenderResponse.note when the runtime reported that the scene could not start (RenderKit).
    public static let startFailureNote = "the scene failed to start"

    /// Key suffix of the short probe benches in `CheckReport.benchMs` ("1512x982@2 t=30 probe").
    public static let probeSuffix = " probe"

    /// Full (non-probe) benches, keyed like "1512x982@2 t=30".
    public static func fullBenches(_ report: CheckReport) -> [String: Double] {
        report.benchMs.filter { !$0.key.hasSuffix(probeSuffix) }
    }

    /// The full bench at the primary size, run at the heaviest sampled phase: the number scene.json
    /// and the library show.
    public static func headlineBenchMs(_ report: CheckReport) -> Double? {
        fullBenches(report).filter { $0.key.hasPrefix(CheckPlan.primary.sizeLabel + " ") }.values.max()
    }

    /// Writes `performance` into scene.json, keeping every other key exactly as the author wrote it.
    static func recordPerformance(_ report: CheckReport, package: URL) throws {
        let url = package.appendingPathComponent(SceneManifest.fileName)
        guard var json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] else { return }
        var perf: [String: Any] = ["checkedAt": ISO8601DateFormatter().string(from: report.checkedAt)]
        if let ms = headlineBenchMs(report) { perf["benchMs"] = ms }
        // Only numbers measured now: an older energy figure may describe a different version of the scene.
        if let mw = report.energyMw { perf["energyMw"] = mw }
        json["performance"] = perf
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    static func fmt(_ x: Double, _ digits: Int = 0) -> String { String(format: "%.\(digits)f", x) }

    /// "1512x982@2 t=4, 1512x982@2 t=30 and 3 more"
    static func frameList(_ frames: [CheckFrame]) -> String {
        let labels = frames.map(\.label)
        guard labels.count > 3 else { return labels.joined(separator: ", ") }
        return labels.prefix(3).joined(separator: ", ") + " and \(labels.count - 3) more"
    }
}
