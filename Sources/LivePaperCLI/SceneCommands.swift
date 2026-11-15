// SceneCommands — check / still / bench / live / compile: the scene authoring loop (ARCHITECTURE §9).
import Darwin
import Foundation
import LivePaperCore

enum SceneCommands {
    static var all: [CLICommand] {
        [
            CLICommand(name: "check", synopsis: "<dir.lpscene> [--quick] [--power] [--json]",
                       summary: "build + validate a scene: stills, JS errors, benchmarks, brightness; exit 0 only if it passes",
                       run: check),
            CLICommand(name: "still", synopsis: "<dir.lpscene> [--t 8] [--size 1512x982] [--dpr 2] [--out x.png] [--no-clock] [--json]",
                       summary: "render one frame of a scene to a PNG", run: still),
            CLICommand(name: "bench", synopsis: "<dir.lpscene> [--t 0] [--size 1512x982] [--dpr 2] [--frames 120] [--json]",
                       summary: "measure a scene's frame time (ms/frame) at one moment", run: bench),
            CLICommand(name: "live", synopsis: "<dir.lpscene> [--size 1512x982] [--dpr 2] [--fps 30] [--scale 0.75] [--seconds 10] [--json]",
                       summary: "run a scene live and measure fps, CPU and energy", run: live),
            CLICommand(name: "compile", synopsis: "<dir.lpscene> [--out file.html|-]",
                       summary: "compile a web scene into one self-contained HTML file", run: compile),
            CLICommand(name: "thumbnail", synopsis: "<dir.lpscene> [--t 8] [--out file.jpg] [--json]",
                       summary: "render the library thumbnail (640x400 JPEG, no clock) into the scene's thumbnail.jpg",
                       run: thumbnail),
        ]
    }

    // MARK: - check

    static func check(_ argv: [String]) async throws -> Int32 {
        let args = try Arguments(argv, flags: ["quick", "power", "json"])
        let pkg = try sceneDirectory(args)
        let checker = SceneChecker()
        let json = args.flag("json")
        let started = Date()
        if !json { checker.progress = { line in stderr("  … \(line)") } }
        let report = try await checker.check(package: pkg, options: CheckOptions(quick: args.flag("quick"), power: args.flag("power")))
        let previews = StillPreviews.write(for: report, package: pkg)
        if json {
            print(String(decoding: try SceneChecker.reportEncoder().encode(report), as: UTF8.self))
        } else {
            printSummary(report, package: pkg, seconds: Date().timeIntervalSince(started), previews: previews)
        }
        return report.passed ? ExitCode.ok : ExitCode.failed
    }

    /// - Parameter previews: the directory of small JPEG copies of the stills, when `check` wrote them.
    static func printSummary(_ r: CheckReport, package: URL, seconds: Double, previews: URL? = nil) {
        let checkDir = package.appendingPathComponent(SceneChecker.checkDirectory)
        let name = (try? SceneManifest.load(package: package))?.name ?? package.lastPathComponent
        print("livepaper check: \(r.passed ? "PASSED" : "FAILED") — \(name) (\(displayPath(package))) in \(Int(seconds.rounded())) s")
        let budgets = CheckBudgets()
        let benches = SceneChecker.fullBenches(r)
        if !benches.isEmpty {
            let parts = benches.sorted { $0.key < $1.key }.map { k, v in
                "\(k): \(fmt(v, 2)) ms (budget \(fmt(k.hasPrefix(CheckPlan.ultraWide.sizeLabel) ? budgets.wideBenchMs : budgets.benchMs, 1)))"
            }
            print("  frame time   " + parts.joined(separator: "  ·  "))
        }
        let frame = r.stills.compactMap(\.meanLuma), clock = r.stills.compactMap(\.clockLuma)
        if let lo = frame.min(), let hi = frame.max() {
            var line = "  brightness   frame \(fmt(lo))–\(fmt(hi))/255 (max \(fmt(budgets.maxMeanLuma)))"
            if let clo = clock.min(), let chi = clock.max() {
                line += "  ·  behind clock \(fmt(clo))–\(fmt(chi))/255 (max \(fmt(budgets.maxClockLuma)))"
            }
            print(line)
        }
        printMotion(r, checkDir: checkDir, previews: previews)
        if let mw = r.energyMw {
            let p = SceneChecker.powerProfile
            print("  energy       \(fmt(mw)) mW at \(p.fps) fps, \(Int(p.scale * 100)) % scale (battery profile; budget \(fmt(budgets.energyMaxMw)))")
        }
        print("  JS errors    \(r.jsErrors.isEmpty ? "none" : String(r.jsErrors.count))")
        if !r.stills.isEmpty {
            let examples = r.stills.prefix(2).map { URL(fileURLWithPath: $0.path).lastPathComponent }.joined(separator: ", ")
            print("  stills       \(r.stills.count) PNGs in \(displayPath(checkDir))/ (e.g. \(examples))")
        }
        if let previews {
            print("  previews     the same stills as small JPEGs (≤ \(StillPreviews.maxPixels) px) in \(displayPath(previews))/ — view these")
        }
        print("  report       \(displayPath(checkDir.appendingPathComponent(SceneChecker.reportFile)))")
        if !r.problems.isEmpty {
            print("\nProblems (fix all of these, then run the check again):")
            for (i, p) in r.problems.enumerated() { print("  \(i + 1). \(p)") }
        }
        if !r.warnings.isEmpty {
            print("\nWarnings:")
            for w in r.warnings { print("  - \(w)") }
        }
    }

    /// One line per analysed size, plus — when motion needs attention — the map of where the worst
    /// size moves, so an agent can see at a glance which parts of the frame are still.
    static func printMotion(_ r: CheckReport, checkDir: URL, previews: URL?) {
        guard let motion = r.motion, !motion.isEmpty else { return }
        let b = CheckBudgets().motion
        let pct = MotionAnalysis.percent
        for (i, m) in motion.enumerated() {
            print((i == 0 ? "  motion       " : "               ") + "\(m.size): \(pct(m.coverage5s)) of the frame changes within 5 s " +
                  "(min \(pct(b.minCoverage5s))), \(pct(m.coverage2s)) within 2 s  ·  moving in \(m.movingRegions)/9 regions " +
                  "(min \(b.minRegions))  ·  busy \(pct(m.busy)) (max \(pct(b.maxBusy)))  ·  flicker \(pct(m.flicker)) (max \(pct(b.maxFlicker)))")
        }
        let verdict = MotionAnalysis.verdict(motion, budgets: b)
        guard !verdict.problems.isEmpty || !verdict.warnings.isEmpty,
              let worst = motion.min(by: { ($0.coverage5s, $0.movingRegions) < ($1.coverage5s, $1.movingRegions) }) else { return }
        print("               where \(worst.size) changes within 5 s (# at most sampled moments, + at some, . never):")
        for row in worst.map { print("                 " + row) }
        if let heatmap = worst.heatmap {
            let name = URL(fileURLWithPath: heatmap).deletingPathExtension().lastPathComponent
            let preview = previews.map { $0.appendingPathComponent(name + ".jpg") }
            let shown = preview.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? URL(fileURLWithPath: heatmap)
            print("               heat map \(displayPath(shown)) (amber = moves most of the time, blue = sometimes, grey = still, " +
                  "red outline = flicker)")
        }
    }

    // MARK: - still / bench / live

    static func still(_ argv: [String]) async throws -> Int32 {
        let args = try Arguments(argv, flags: ["no-clock", "json"], options: ["t", "size", "dpr", "out"])
        let pkg = try sceneDirectory(args)
        let html = try compileForRender(pkg)
        let size = try args.size("size") ?? (1512, 982)
        let dpr = try args.double("dpr") ?? 2
        let t = try args.double("t") ?? 8
        let frame = CheckFrame(Int(size.width), Int(size.height), dpr: dpr, t: t)
        let checkDir = pkg.appendingPathComponent(SceneChecker.checkDirectory)
        let out = try outURL(args) ?? checkDir.appendingPathComponent(frame.fileName)
        let target = RenderTarget(out, package: pkg, inside: [checkDir], ext: "png")
        let req = RenderRequest(op: .still, html: html.path, width: size.width, height: size.height, dpr: dpr, t: t,
                                out: target.serverOut.path, clock: !args.flag("no-clock"))
        var r = try await RenderClient().send(req, timeout: RenderClient.defaultTimeout(for: req))
        try target.finish(&r)
        if args.flag("json") { printJSON(r) } else if r.ok {
            var line = "wrote \(displayPath(out)) (\(frame.label)"
            if let l = r.meanLuma { line += ", brightness \(fmt(l))/255" }
            if let c = r.clockLuma { line += ", behind clock \(fmt(c))/255" }
            print(line + ")")
        }
        return report(r)
    }

    static func bench(_ argv: [String]) async throws -> Int32 {
        let args = try Arguments(argv, flags: ["json"], options: ["t", "size", "dpr", "frames"])
        let pkg = try sceneDirectory(args)
        let html = try compileForRender(pkg)
        let size = try args.size("size") ?? (1512, 982)
        let dpr = try args.double("dpr") ?? 2
        let t = try args.double("t") ?? 0
        let frames = try args.int("frames") ?? 120
        let req = RenderRequest(op: .bench, html: html.path, width: size.width, height: size.height, dpr: dpr, t: t, frames: frames)
        let r = try await RenderClient().send(req, timeout: RenderClient.defaultTimeout(for: req))
        if args.flag("json") { printJSON(r) } else if r.ok, let ms = r.benchMs {
            let label = CheckFrame(Int(size.width), Int(size.height), dpr: dpr, t: t).label
            print("\(label): \(fmt(ms, 3)) ms/frame over \(frames) frames (check budget: \(fmt(CheckBudgets().benchMs, 1)) ms at 1512x982@2)")
        }
        return report(r)
    }

    static func live(_ argv: [String]) async throws -> Int32 {
        let args = try Arguments(argv, flags: ["json"], options: ["size", "dpr", "fps", "scale", "seconds", "warmup"])
        let pkg = try sceneDirectory(args)
        let html = try compileForRender(pkg)
        let size = try args.size("size") ?? (1512, 982)
        let p = SceneChecker.powerProfile
        let req = RenderRequest(op: .live, html: html.path, width: size.width, height: size.height, dpr: try args.double("dpr") ?? 2,
                                fps: try args.double("fps") ?? Double(p.fps), scale: try args.double("scale") ?? p.scale,
                                seconds: try args.double("seconds") ?? 10, warmup: try args.double("warmup") ?? 3)
        stderr("  … measuring for \(Int((req.seconds ?? 10) + (req.warmup ?? 3))) s")
        let r = try await RenderClient().send(req, timeout: RenderClient.defaultTimeout(for: req))
        if args.flag("json") { printJSON(r) } else if r.ok {
            print("\(Int(size.width))x\(Int(size.height))@\(CheckFrame.num(req.dpr ?? 2)), cap \(CheckFrame.num(req.fps ?? 30)) fps, " +
                  "scale \(CheckFrame.num(req.scale ?? 1)): \(fmt(r.fps ?? 0, 1)) fps, CPU \(fmt(r.cpuPct ?? 0, 1)) %, " +
                  "\(fmt(r.cpuMW ?? 0)) mW over \(fmt(r.seconds ?? 0, 1)) s")
        }
        return report(r)
    }

    // MARK: - compile

    static func compile(_ argv: [String]) async throws -> Int32 {
        let args = try Arguments(argv, options: ["out"])
        let pkg = try sceneDirectory(args)
        if args.string("out") == "-" {
            let compiled = try SceneCompiler().build(package: pkg)
            FileHandle.standardOutput.write(Data(compiled.html.utf8))
            return ExitCode.ok
        }
        let out = try outURL(args)
            ?? pkg.appendingPathComponent(SceneChecker.checkDirectory).appendingPathComponent(SceneChecker.compiledFile)
        try SceneCompiler().compile(package: pkg, to: out)
        print("wrote \(displayPath(out))")
        return ExitCode.ok
    }

    // MARK: - thumbnail

    /// The same thumbnail the app makes for library scenes (render server `thumbnail` op: a
    /// 1280x800 viewport downsampled to 640x400, no clock). The app only renders thumbnails for
    /// the user's own scenes, so built-in scenes ship theirs — made with this command.
    static func thumbnail(_ argv: [String]) async throws -> Int32 {
        let args = try Arguments(argv, flags: ["json"], options: ["t", "out"])
        let pkg = try sceneDirectory(args)
        let out = try outURL(args) ?? pkg.appendingPathComponent("thumbnail.jpg")
        let target = RenderTarget(out, package: pkg, inside: [pkg, pkg.appendingPathComponent(SceneChecker.checkDirectory)], ext: "jpg")
        let req = RenderRequest(op: .thumbnail, scene: pkg.path, t: try args.double("t"), out: target.serverOut.path)
        var r = try await RenderClient().send(req, timeout: RenderClient.defaultTimeout(for: req))
        try target.finish(&r)
        if args.flag("json") { printJSON(r) } else if r.ok { print("wrote \(displayPath(out))") }
        return report(r)
    }

    // MARK: - Helpers

    static func sceneDirectory(_ args: Arguments) throws -> URL {
        let path = try args.single("scene directory")
        let url = URL(fileURLWithPath: path).standardizedFileURL
        try AISessionPolicy.confine(url, what: "the scene")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw UsageError("\(path) is not a directory (expected a scene package containing scene.json)")
        }
        return url
    }

    /// `--out`, which inside an AI session must stay in the session's workspace.
    static func outURL(_ args: Arguments) throws -> URL? {
        guard let path = args.string("out") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        try AISessionPolicy.confine(url, what: "--out")
        return url
    }

    /// Compiles into <package>/.check/scene.html, where the render server reads it.
    static func compileForRender(_ pkg: URL) throws -> URL {
        let out = pkg.appendingPathComponent(SceneChecker.checkDirectory).appendingPathComponent(SceneChecker.compiledFile)
        try SceneCompiler().compile(package: pkg, to: out)
        return out
    }

    /// Where the render server writes an image the user asked for. The server only writes into the
    /// scene package (RenderOutputPolicy), so an `--out` elsewhere is rendered into the package's
    /// .check first and then moved by the CLI itself — with the caller's own permissions (and
    /// sandbox), never the server's.
    struct RenderTarget {
        let out: URL
        let serverOut: URL
        init(_ out: URL, package: URL, inside allowed: [URL], ext: String) {
            self.out = out
            let parent = out.deletingLastPathComponent().standardizedFileURL.path
            if allowed.contains(where: { $0.standardizedFileURL.path == parent }) {
                serverOut = out
            } else {
                serverOut = package.appendingPathComponent(SceneChecker.checkDirectory)
                    .appendingPathComponent(".out-\(UUID().uuidString).\(ext)")
            }
        }

        /// Moves the rendered file into place (when it was rendered elsewhere) and reports `out`.
        func finish(_ response: inout RenderResponse) throws {
            guard serverOut != out else { return }
            defer { try? FileManager.default.removeItem(at: serverOut) }
            guard response.ok else { return }
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            if rename(serverOut.path, out.path) != 0 {
                guard errno == EXDEV else {
                    throw CLIFailure("could not write \(out.path): \(String(cString: strerror(errno)))")
                }
                try Data(contentsOf: serverOut).write(to: out, options: .atomic)
            }
            response.out = out.path
        }
    }

    /// Prints problems from a render response; exit code 1 for JS errors or a failed render.
    static func report(_ r: RenderResponse) -> Int32 {
        for e in r.errors { stderr("JavaScript error: \(e)") }
        if !r.ok { stderr("render failed: \(r.note ?? "no reason given")") }
        return r.ok && r.errors.isEmpty ? ExitCode.ok : ExitCode.failed
    }

    static func printJSON(_ r: RenderResponse) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(r) { print(String(decoding: d, as: UTF8.self)) }
    }
}

func fmt(_ x: Double, _ digits: Int = 0) -> String { String(format: "%.\(digits)f", x) }
