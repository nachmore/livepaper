// SceneCommands — check / still / bench / live / compile: the scene authoring loop (ARCHITECTURE §9).
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
        if json {
            print(String(decoding: try SceneChecker.reportEncoder().encode(report), as: UTF8.self))
        } else {
            printSummary(report, package: pkg, seconds: Date().timeIntervalSince(started))
        }
        return report.passed ? ExitCode.ok : ExitCode.failed
    }

    static func printSummary(_ r: CheckReport, package: URL, seconds: Double) {
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
        if let mw = r.energyMw {
            let p = SceneChecker.powerProfile
            print("  energy       \(fmt(mw)) mW at \(p.fps) fps, \(Int(p.scale * 100)) % scale (battery profile; budget \(fmt(budgets.energyMaxMw)))")
        }
        print("  JS errors    \(r.jsErrors.isEmpty ? "none" : String(r.jsErrors.count))")
        if !r.stills.isEmpty {
            let examples = r.stills.prefix(2).map { URL(fileURLWithPath: $0.path).lastPathComponent }.joined(separator: ", ")
            print("  stills       \(r.stills.count) PNGs in \(displayPath(checkDir))/ (e.g. \(examples))")
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

    // MARK: - still / bench / live

    static func still(_ argv: [String]) async throws -> Int32 {
        let args = try Arguments(argv, flags: ["no-clock", "json"], options: ["t", "size", "dpr", "out"])
        let pkg = try sceneDirectory(args)
        let html = try compileForRender(pkg)
        let size = try args.size("size") ?? (1512, 982)
        let dpr = try args.double("dpr") ?? 2
        let t = try args.double("t") ?? 8
        let frame = CheckFrame(Int(size.width), Int(size.height), dpr: dpr, t: t)
        let out = args.string("out").map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? pkg.appendingPathComponent(SceneChecker.checkDirectory).appendingPathComponent(frame.fileName)
        let req = RenderRequest(op: .still, html: html.path, width: size.width, height: size.height, dpr: dpr, t: t,
                                out: out.path, clock: !args.flag("no-clock"))
        let r = try await RenderClient().send(req, timeout: RenderClient.defaultTimeout(for: req))
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
        let out = args.string("out").map { URL(fileURLWithPath: $0).standardizedFileURL }
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
        let out = args.string("out").map { URL(fileURLWithPath: $0).standardizedFileURL } ?? pkg.appendingPathComponent("thumbnail.jpg")
        let req = RenderRequest(op: .thumbnail, scene: pkg.path, t: try args.double("t"), out: out.path)
        let r = try await RenderClient().send(req, timeout: RenderClient.defaultTimeout(for: req))
        if args.flag("json") { printJSON(r) } else if r.ok { print("wrote \(displayPath(out))") }
        return report(r)
    }

    // MARK: - Helpers

    static func sceneDirectory(_ args: Arguments) throws -> URL {
        let path = try args.single("scene directory")
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw UsageError("\(path) is not a directory (expected a scene package containing scene.json)")
        }
        return url
    }

    /// Compiles into <package>/.check/scene.html, where the render server reads it.
    static func compileForRender(_ pkg: URL) throws -> URL {
        let out = pkg.appendingPathComponent(SceneChecker.checkDirectory).appendingPathComponent(SceneChecker.compiledFile)
        try SceneCompiler().compile(package: pkg, to: out)
        return out
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
