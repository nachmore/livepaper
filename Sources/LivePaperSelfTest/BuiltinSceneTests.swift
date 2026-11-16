// Self tests for the built-in example scenes in Scenes/ (shipped in LivePaper.app/Contents/Resources/Scenes).
//
// These are static checks of the packages as committed: manifest, compile (runtime inlined, source
// scan), thumbnail, provenance and hygiene, plus time continuity (no jumps, no drift that grows
// with t), which follows the scene's draw calls in JavaScriptCore (SceneTimeline.swift) without
// rendering. Rendering budgets are `livepaper check`'s job and need the render server, which tests
// never start; the numbers it measured are required to be recorded in each scene.json instead.
// See docs/SCENES.md.
import CoreGraphics
import Foundation
import ImageIO
import LivePaperCore

extension SelfTests {
    static var builtinScenes: [TestCase] { [
        TestCase(name: "scenes.builtin.packages") {
            let packages = try BuiltinScenes.packages()
            try expect(packages.count >= BuiltinScenes.minimumCount, "expected at least \(BuiltinScenes.minimumCount) built-in scenes, found \(packages.count)")
            let compiler = SceneCompiler(runtimeDir: BuiltinScenes.repo.appendingPathComponent("Runtime"))
            for pkg in packages {
                let id = pkg.deletingPathExtension().lastPathComponent
                try expect(SceneManifest.isValidID(id), "\(id): not a valid scene id")
                let m = try SceneManifest.load(package: pkg)
                try expectEqual(m.id, id)
                try expectEqual(m.kind, .web)
                try expectEqual(m.runtime, 1)
                try expect(!m.name.isEmpty && !m.description.isEmpty, "\(id): name and description are required")
                let perf = try required(m.performance, "\(id): no performance in scene.json — run `livepaper check --power` before committing")
                let bench = try required(perf.benchMs, "\(id): no benchMs")
                try expect(bench <= CheckBudgets().benchMs, "\(id): recorded frame time \(bench) ms is over budget")
                let energy = try required(perf.energyMw, "\(id): no energyMw — check with --power")
                try expect(energy <= CheckBudgets().energyMaxMw, "\(id): recorded energy \(energy) mW is over budget")
                // Compiles: runtime inlined, no forbidden APIs.
                let compiled = try compiler.build(package: pkg)
                try expect(compiled.html.contains("LivePaper.scene("), "\(id): compiled page has no scene")
            }
        },
        TestCase(name: "scenes.builtin.contents") {
            for pkg in try BuiltinScenes.packages() {
                let id = pkg.deletingPathExtension().lastPathComponent
                let entries = try FileManager.default.contentsOfDirectory(atPath: pkg.path).filter { $0 != ".DS_Store" }
                let unexpected = Set(entries).subtracting(BuiltinScenes.allowedEntries)
                try expect(unexpected.isEmpty, "\(id): unexpected files \(unexpected.sorted()) (ship scene.json, scene.js, thumbnail.jpg, history.jsonl, assets/)")
                // The app renders thumbnails only for the user's scenes: built-ins ship theirs.
                let thumb = pkg.appendingPathComponent("thumbnail.jpg")
                let source = try required(CGImageSourceCreateWithURL(thumb as CFURL, nil), "\(id): thumbnail.jpg is missing (`livepaper thumbnail`)")
                let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
                try expectEqual(props[kCGImagePropertyPixelWidth] as? Int, 640)
                try expectEqual(props[kCGImagePropertyPixelHeight] as? Int, 400)
                try expectEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
            }
        },
        TestCase(name: "scenes.builtin.provenance") {
            // Every built-in was made by LivePaper's own AI pipeline: history.jsonl says how.
            var harnesses = Set<String>()
            for pkg in try BuiltinScenes.packages() {
                let id = pkg.deletingPathExtension().lastPathComponent
                let history = SceneHistory.entries(in: pkg)
                try expectEqual(history.first?.action, .create)
                for entry in history where entry.action == .create || entry.action == .modify {
                    try expect(["claude", "codex", "kiro"].contains(entry.harness ?? ""), "\(id): unexpected harness \(entry.harness ?? "nil")")
                    try expect(!(entry.model ?? "").isEmpty, "\(id): history entry without a model")
                    try expect(!(entry.prompt ?? "").isEmpty, "\(id): history entry without a prompt")
                }
                harnesses.formUnion(history.compactMap(\.harness))
            }
            try expectEqual(harnesses.intersection(["claude", "codex", "kiro"]), ["claude", "codex", "kiro"])
        },
        TestCase(name: "scenes.builtin.hygiene") {
            // Public repository: no machine-specific paths or user names in anything shipped.
            // (Not the account name on CI: GitHub's is "runner", an ordinary word, and not a leak.)
            let user = ProcessInfo.processInfo.environment["CI"] == "true" ? "" : NSUserName()
            for pkg in try BuiltinScenes.packages() {
                let id = pkg.deletingPathExtension().lastPathComponent
                for name in ["scene.json", "scene.js", "history.jsonl"] {
                    let text = try String(contentsOf: pkg.appendingPathComponent(name), encoding: .utf8)
                    for needle in ["/Users/", "/home/", "/private/", "/var/folders/", "/tmp/", "Workspaces/"] + (user.count > 2 ? [user] : []) {
                        try expect(!text.contains(needle), "\(id)/\(name) contains \"\(needle)\"")
                    }
                }
            }
        },
        TestCase(name: "scenes.builtin.gallery") {
            let gallery = try String(contentsOf: BuiltinScenes.repo.appendingPathComponent("docs/SCENES.md"), encoding: .utf8)
            for pkg in try BuiltinScenes.packages() {
                let id = pkg.deletingPathExtension().lastPathComponent
                try expect(gallery.contains("`\(id)`"), "docs/SCENES.md doesn't list \(id)")
            }
        },
        TestCase(name: "scenes.builtin.span") {
            // "Span across displays": which built-ins stretch across displays (docs/SCENES.md), and the
            // static rules for those that do (runtime.e2e.spanCrops renders them).
            let gallery = try String(contentsOf: BuiltinScenes.repo.appendingPathComponent("docs/SCENES.md"), encoding: .utf8)
            for pkg in try BuiltinScenes.packages() {
                let id = pkg.deletingPathExtension().lastPathComponent
                let m = try SceneManifest.load(package: pkg)
                try expect(m.span == BuiltinScenes.spanning.contains(id), "\(id): span is \(m.span.map(String.init) ?? "absent"), docs/SCENES.md says otherwise")
                guard m.spans else { continue }
                let js = try String(contentsOf: pkg.appendingPathComponent("scene.js"), encoding: .utf8)
                try expect(js.range(of: #"\bupdate\s*(\(|:)"#, options: .regularExpression) == nil, "\(id): span scenes have no update()")
                let findings = SceneChecker.spanSourceFindings(js)
                try expect(findings.problems.isEmpty, "\(id): \(findings.problems)")
                try expect(gallery.contains("`\(id)`") && gallery.contains("Spans displays"), "docs/SCENES.md: span status of \(id)")
            }
        },
        TestCase(name: "scenes.builtin.timeContinuity", run: BuiltinScenes.timeContinuity),
    ] }
}

extension BuiltinScenes {
    /// Scenes whose draw calls the continuity check can follow (2D, sprites drawn with drawImage at
    /// moving positions). Of the others, Liquid Glass is WebGL, and the rest paint shapes whose
    /// bounding boxes change on their own (jelly bells, rain streaks) or cross-fade texture pairs,
    /// which would need rules of their own.
    static let continuityChecked = ["ink-and-ember"]

    /// SCENE_API §6–7: the saver runs for hours, nothing may jump when a period wraps, and motion
    /// stays the same however long the scene has run. Draw calls only, in JavaScriptCore (SceneTimeline).
    static func timeContinuity() throws {
        let dt = TimeContinuity.frameDt
        let runtime = repo.appendingPathComponent("Runtime/runtime.js")
        // Moments to straddle (frames at T ± dt/2): every whole second of the first 20 minutes
        // (periods of whole seconds wrap there), later wraps (Ink and Ember's 960 s sun cycle, which
        // starts 5 % in, wraps at 912 + 960 k s) and long runs.
        let moments = [912, 959, 960, 961, 1872, 1920, 2832, 2880, 3600, 3840, 7680, 36000, 360000].map(Double.init)
        let lateStarts = [3600.0, 36000, 360000]
        let lateOffsets = [0, 13.7, 51.3, 97.1, 211.9, 333.3, 517.7, 701.1]
        for id in continuityChecked {
            let scene = directory.appendingPathComponent("\(id).lpscene/scene.js")
            for (w, h, everySecond) in [(1512.0, 982.0, true), (1024.0, 820.0, false), (5120.0, 1440.0, false)] {
                let tl = try SceneTimeline(runtime: runtime, scene: scene, width: w, height: h)
                var jumps: [TimeContinuity.Jump] = []
                func straddle(_ T: Double, reducedMotion: Bool = false) throws {
                    let a = max(0, T - dt / 2)
                    jumps += TimeContinuity.jumps(at: a, try tl.frame(a, reducedMotion: reducedMotion), try tl.frame(a + dt, reducedMotion: reducedMotion), w: w, h: h)
                }
                for T in [0.0] + moments { try straddle(T) }
                if everySecond { for s in 1...1200 { try straddle(Double(s)) } }
                // Reduced motion slows the scene's clock (Ink and Ember: to a quarter), so its long
                // periods wrap at other lp.t.
                for T in [0, 960, 1920, 3648, 3840, 7488, 7680, 15360, 36000, 360000] { try straddle(Double(T), reducedMotion: true) }
                try expect(jumps.isEmpty, "\(id) at \(Int(w))×\(Int(h)): \(jumps.count) jumps, e.g.\n    " +
                           jumps.prefix(6).map(\.description).joined(separator: "\n    "))

                var early: [String: TimeContinuity.Speeds] = [:]
                for i in 0..<160 {
                    let t = 0.5 + Double(i) * 11.25
                    TimeContinuity.addSpeeds(try tl.frame(t), try tl.frame(t + dt), w: w, h: h, into: &early)
                }
                var drift: [String] = []
                for T in lateStarts {
                    for o in lateOffsets {
                        var late: [String: TimeContinuity.Speeds] = [:]
                        TimeContinuity.addSpeeds(try tl.frame(T + o), try tl.frame(T + o + dt), w: w, h: h, into: &late)
                        drift += TimeContinuity.drift(early: early, late: late, at: T + o)
                    }
                }
                try expect(drift.isEmpty, "\(id) at \(Int(w))×\(Int(h)): motion changes the longer it runs (\(drift.count)), e.g.\n    " +
                           drift.sorted().prefix(6).joined(separator: "\n    "))
            }
        }
    }
}

private enum BuiltinScenes {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let directory = repo.appendingPathComponent("Scenes")
    static let minimumCount = 5
    static let allowedEntries: Set<String> = ["scene.json", "scene.js", "thumbnail.jpg", "history.jsonl", "assets"]
    /// Built-ins that declare `"span": true` (they passed runtime.e2e.spanCrops and spanCost; docs/SCENES.md).
    static let spanning: Set<String> = ["abyssal-lanterns", "ink-and-ember", "liquid-glass", "rain-on-the-river", "ringed-giant"]

    static func packages() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == SceneManifest.packageExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

private func required<T>(_ value: T?, _ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(description: "\(file):\(line) \(message())") }
    return value
}
