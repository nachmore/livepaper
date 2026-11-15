// Self tests owned by WS-package: the packaging inputs (VERSION, Info.plist, the SMAppService
// plist, scripts) and the `livepaper` CLI end to end.
//
// The CLI is an executable target, so it can't be linked into this runner; the tests run the
// built binary (next to this one in .build/<config>/) as a subprocess. `swift run LivePaperSelfTest`
// builds only this target, so run `swift build` first — a missing or out-of-date binary makes the
// command tests skip with a note instead of testing stale code.
//
// Every run is sandboxed: LIVEPAPER_HOME / _SAVERS_DIR / _LAUNCH_AGENTS_DIR / _WALLPAPER_STORE /
// _RESOURCES point into a temp directory; LIVEPAPER_NO_SPAWN=1 (and LIVEPAPER_RENDERD=/usr/bin/false)
// mean no render daemon can ever start; LIVEPAPER_NO_SYSTEM_COMMANDS=1 makes install/uninstall/
// doctor record launchctl & co. and keep preference changes in memory. Nothing here launches a GUI
// process or touches the user's real state.
import Foundation
import LivePaperCore

extension SelfTests {
    static var cli: [TestCase] { cliPackaging + cliCommands }

    // MARK: - Packaging inputs

    static var cliPackaging: [TestCase] { [
        TestCase(name: "cli.packaging.version-file") {
            let version = try String(contentsOf: CLITestSupport.repo.appendingPathComponent("VERSION"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try expect(version.range(of: #"^\d+\.\d+\.\d+([.-][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil,
                       "VERSION is \(version)")
        },
        TestCase(name: "cli.packaging.app-info-plist") {
            let info = try CLITestSupport.plist(CLITestSupport.repo.appendingPathComponent("App/Info.plist"))
            try expectEqual(info["CFBundleExecutable"] as? String, "LivePaper")
            try expectEqual(info["CFBundleIconFile"] as? String, "AppIcon")
            try expectEqual(info["CFBundleIdentifier"] as? String, LPPaths.bundleID)
            try expectEqual(info["CFBundlePackageType"] as? String, "APPL")
            try expectEqual(info["LSUIElement"] as? Bool, true)
        },
        TestCase(name: "cli.packaging.helper-launch-agent") {
            // SMAppServiceAgent looks for Contents/Library/LaunchAgents/<helperLabel>.plist.
            let url = CLITestSupport.repo.appendingPathComponent("App/LaunchAgents/\(LPPaths.helperLabel).plist")
            let p = try CLITestSupport.plist(url)
            try expectEqual(p["Label"] as? String, LPPaths.helperLabel)
            try expectEqual(p["BundleProgram"] as? String, "Contents/Helpers/LivePaperHelper")
            try expect(p["ProgramArguments"] == nil && p["Program"] == nil, "SMAppService plists use BundleProgram only")
            try expectEqual(p["AssociatedBundleIdentifiers"] as? [String], [LPPaths.bundleID])
            try expectEqual(p["ProcessType"] as? String, "Interactive")
            try expectEqual(p["RunAtLoad"] as? Bool, true)
            try expectEqual((p["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool, false)
            try expectEqual(p["LimitLoadToSessionType"] as? String, "Aqua")
        },
        TestCase(name: "cli.packaging.scripts") {
            for name in ["build.sh", "build-saver.sh", "dev-install.sh", "uninstall-dev.sh"] {
                let path = CLITestSupport.repo.appendingPathComponent("scripts/\(name)").path
                try expect(FileManager.default.isExecutableFile(atPath: path), "\(name) must be executable")
            }
            let build = try String(contentsOf: CLITestSupport.repo.appendingPathComponent("scripts/build.sh"), encoding: .utf8)
            for needle in ["Contents/Helpers/LivePaperHelper", "Contents/Helpers/livepaper", "Contents/Helpers/LivePaperRenderd",
                           "Contents/MacOS/LivePaper", "Library/LaunchAgents", "\(LPPaths.helperLabel).plist", "LivePaper.saver",
                           "codesign --verify --deep --strict"] {
                try expect(build.contains(needle), "build.sh doesn't mention \(needle)")
            }
        },
    ] }

    // MARK: - Commands

    static var cliCommands: [TestCase] { [
        cliTest("cli.help") { sb in
            let r = try sb.run(["help"])
            try expectEqual(r.status, 0)
            for command in ["check", "still", "bench", "new", "list", "import", "publish", "ai", "doctor", "uninstall", "server"] {
                try expect(r.out.contains("\n  \(command) "), "help doesn't list \(command)")
            }
            try expect(!r.out.contains("not available"), "help still lists placeholder commands")
            try expectEqual(try sb.run([]).status, 2)
            try expectEqual(try sb.run(["frobnicate"]).status, 2)
            let usage = try sb.run(["help", "ai"]).out
            try expect(usage.contains("usage: livepaper ai create"), usage)
        },
        cliTest("cli.version") { sb in
            let r = try sb.run(["--version"])
            try expectEqual(r.status, 0)
            let version = try String(contentsOf: CLITestSupport.repo.appendingPathComponent("VERSION"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try expect(r.out.contains("livepaper \(version)"), r.out)
            try expect(r.out.contains("runtime API \(SceneCompiler.supportedRuntime)"), r.out)
        },
        cliTest("cli.new-list-clone") { sb in
            var r = try sb.run(["new", "aurora-lake"])
            try expectEqual(r.status, 0)
            try expect(r.out.contains("(aurora-lake)") && r.out.contains("\u{201C}Aurora Lake\u{201D}"), r.out)
            r = try sb.run(["new", "Aurora Lake", "--json"])
            try expectEqual(r.status, 0)
            let second = try CLITestSupport.jsonObject(r.out)
            try expectEqual(second["id"] as? String, "aurora-lake-2")
            try expectEqual(second["name"] as? String, "Aurora Lake")
            r = try sb.run(["new", "Night Copy", "--from", "starter", "--description", "A copy.", "--json"])
            try expectEqual(r.status, 0)
            let copy = try CLITestSupport.jsonObject(r.out)
            try expectEqual(copy["parent"] as? String, "starter")
            try expectEqual(copy["description"] as? String, "A copy.")
            try expect(FileManager.default.fileExists(atPath: sb.library.appendingPathComponent("night-copy.lpscene/scene.js").path))

            r = try sb.run(["list", "--json"])
            try expectEqual(r.status, 0)
            let rows = try CLITestSupport.jsonArray(r.out)
            try expectEqual(rows.compactMap { $0["id"] as? String }, ["aurora-lake", "aurora-lake-2", "night-copy", "starter"])
            try expectEqual(rows.compactMap { $0["builtin"] as? Bool }, [false, false, false, true])
            try expect(rows.allSatisfy { $0["inPlaylist"] as? Bool == true }, "an empty selection means every scene")
            r = try sb.run(["list"])
            try expect(r.out.contains("3 of yours, 1 built-in"), r.out)

            try expectEqual(try sb.run(["new", "X", "--from", "missing"]).status, 1)
            try expectEqual(try sb.run(["new"]).status, 2)
            try expectEqual(try sb.run(["new", "a", "b"]).status, 2)
            try expectEqual(try sb.run(["new", "X", "--bogus"]).status, 2)
        },
        cliTest("cli.import-package") { sb in
            let pkg = sb.root.appendingPathComponent("outside/glow.lpscene")
            try CLITestSupport.writeWebScene(at: pkg, id: "glow", name: "Glow")
            var r = try sb.run(["import", pkg.path, "--name", "Soft Glow", "--json"])
            try expectEqual(r.status, 0)
            let item = try CLITestSupport.jsonObject(r.out)
            try expectEqual(item["id"] as? String, "glow")
            try expectEqual(item["name"] as? String, "Soft Glow")
            r = try sb.run(["import", sb.root.appendingPathComponent("nope.mov").path])
            try expectEqual(r.status, 2)
            r = try sb.run(["import", pkg.path, "--battery"])
            try expectEqual(r.status, 2)
        },
        cliTest("cli.publish") { sb in
            _ = try sb.run(["new", "aurora-lake"])
            var r = try sb.run(["publish"])
            try expectEqual(r.status, 3)
            try expect(r.err.contains("isn't installed"), r.err)
            try sb.installFakeSaver()
            r = try sb.run(["publish", "--mode", "sequence", "--cycle", "2", "--no-clock", "--scenes", "aurora-lake,starter", "--json"])
            try expectEqual(r.status, 0)
            let summary = try CLITestSupport.jsonObject(r.out)
            try expectEqual(summary["scenes"] as? [String], ["aurora-lake", "starter"])
            try expectEqual(summary["generation"] as? Int, 1)
            let playlist = try LPPlaylist.load(from: sb.saver.appendingPathComponent("Contents/Resources/Playlist"))
            try expectEqual(playlist.mode, .sequence)
            try expectEqual(playlist.cycleMinutes, 2)
            try expectEqual(playlist.showClock, false)
            try expectEqual(playlist.scenes.map(\.file), ["aurora-lake.html", "starter.html"])
            // Settings persist: a plain publish keeps them and bumps the generation.
            r = try sb.run(["publish"])
            try expectEqual(r.status, 0)
            try expect(r.out.contains("generation 2") && r.out.contains("sequence"), r.out)
            r = try sb.run(["list", "--json"])
            let inPlaylist = try CLITestSupport.jsonArray(r.out).filter { $0["inPlaylist"] as? Bool == true }.compactMap { $0["id"] as? String }
            try expectEqual(inPlaylist, ["aurora-lake", "starter"])
            try expectEqual(try sb.run(["publish", "--scenes", "nope"]).status, 2)
            try expectEqual(try sb.run(["publish", "--mode", "random"]).status, 2)
            try expectEqual(try sb.run(["publish", "--cycle", "-1"]).status, 2)
            try expectEqual(try sb.run(["publish", "--clock", "--no-clock"]).status, 2)
            r = try sb.run(["publish", "--scenes", "all", "--json"])
            try expectEqual(try CLITestSupport.jsonObject(r.out)["scenes"] as? [String], ["aurora-lake", "starter"])
        },
        cliTest("cli.doctor") { sb in
            var r = try sb.run(["doctor", "--no-ai", "--json"])
            try expectEqual(r.status, 1)
            var report = try CLITestSupport.jsonObject(r.out)
            var checks = (report["checks"] as? [[String: Any]]) ?? []
            func status(_ section: String, _ name: String) -> String? {
                checks.first { $0["section"] as? String == section && $0["name"] as? String == name }?["status"] as? String
            }
            try expectEqual(status("Screen saver", "installed"), "problem")
            try expectEqual(status("LivePaper", "runtime"), "ok")
            try expectEqual(status("Lock screen", "lock keys"), "warning")
            try expectEqual(status("Lock screen", "helper"), "problem")
            try expect(checks.allSatisfy { $0["section"] as? String != "AI" }, "--no-ai skips harness detection")
            try expectEqual((report["paths"] as? [String: String])?["support"], sb.support.path)
            try expect((report["problems"] as? Int ?? 0) >= 2)

            try sb.installFakeSaver()
            _ = try sb.run(["publish"])
            r = try sb.run(["doctor", "--no-ai", "--json"])
            report = try CLITestSupport.jsonObject(r.out)
            checks = (report["checks"] as? [[String: Any]]) ?? []
            try expectEqual(status("Screen saver", "installed"), "ok")
            try expectEqual(status("Screen saver", "published"), "ok")
            r = try sb.run(["doctor", "--no-ai"])
            try expect(r.out.contains("LivePaper doctor") && r.out.contains("problem"), r.out)
        },
        cliTest("cli.uninstall") { sb in
            _ = try sb.run(["new", "aurora-lake"])
            try sb.installFakeSaver()
            _ = try sb.run(["publish"])
            // (Lock-keys backup/restore is covered by core.install.* — it lives in InstallService.)
            // Declined (stdin at EOF) and dry run: nothing changes.
            var r = try sb.run(["uninstall"])
            try expectEqual(r.status, 1)
            try expect(r.out.contains("Nothing was changed"), r.out)
            r = try sb.run(["uninstall", "--dry-run"])
            try expectEqual(r.status, 0)
            try expect(r.out.contains("Remove \(sb.saver.path)"), r.out)
            try expect(FileManager.default.fileExists(atPath: sb.saver.path))

            // Answer "y" on stdin, keeping the scenes.
            r = try sb.run(["uninstall", "--keep-scenes"], stdin: "y\n")
            try expectEqual(r.status, 0)
            try expect(!FileManager.default.fileExists(atPath: sb.saver.path), "saver removed")
            try expect(!FileManager.default.fileExists(atPath: sb.support.appendingPathComponent("backups").path), "backups removed")
            try expect(FileManager.default.fileExists(atPath: sb.library.appendingPathComponent("aurora-lake.lpscene/scene.json").path),
                       "--keep-scenes keeps the library")

            // Everything; running it again is a no-op that still succeeds.
            r = try sb.run(["uninstall", "--yes"])
            try expectEqual(r.status, 0)
            try expect(!FileManager.default.fileExists(atPath: sb.support.path), "support directory removed")
            r = try sb.run(["uninstall", "--yes"])
            try expectEqual(r.status, 0)
            try expectEqual(try sb.run(["uninstall", "extra"]).status, 2)
        },
        cliTest("cli.ai") { sb in
            // A stand-in agent: writes a scene, prints two lines, exits 0.
            let agent = sb.root.appendingPathComponent("tools/fake-agent")
            try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("""
            #!/bin/sh
            echo "Reading TASK.md"
            printf '%s\\n' "LivePaper.scene({ draw(lp) { lp.ctx.fillStyle = '#000'; lp.ctx.fillRect(0, 0, lp.w, lp.h); } });" > scene/scene.js
            echo "Done."

            """.utf8).write(to: agent)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)

            // Runs the agent, then LivePaper's own check — which can't render here (no server may
            // start), so the session fails at validation, after every earlier stage ran.
            var r = try sb.run(["ai", "create", "a calm black screen", "--command", agent.path, "--json"])
            try expectEqual(r.status, 1)
            let events = r.out.split(separator: "\n").compactMap { try? CLITestSupport.jsonObject(String($0)) }
            try expectEqual(events.first?["event"] as? String, "started")
            try expect(events.contains { $0["event"] as? String == "text" && $0["text"] as? String == "Reading TASK.md" }, r.out)
            try expect(events.contains { $0["event"] as? String == "status" && ($0["message"] as? String ?? "").hasPrefix("Validating") }, r.out)
            let failure = events.last { $0["event"] as? String == "failed" }?["message"] as? String ?? ""
            try expect(failure.contains("render server"), failure)
            if let ws = events.first?["workspace"] as? String {
                let script = try String(contentsOfFile: ws + "/scene/scene.js", encoding: .utf8)
                try expect(script.contains("fillRect"), "the agent ran in the workspace")
            }

            r = try sb.run(["ai", "create", "x", "--command", "/nonexistent/agent {prompt_file}"])
            try expectEqual(r.status, 1)
            try expect(r.err.contains("/nonexistent/agent"), r.err)
            try expectEqual(try sb.run(["ai"]).status, 2)
            try expectEqual(try sb.run(["ai", "create"]).status, 2)
            try expectEqual(try sb.run(["ai", "create", "x", "--harness", "nope"]).status, 2)
            try expectEqual(try sb.run(["ai", "create", "x", "--harness", "claude", "--command", "a"]).status, 2)
            try expectEqual(try sb.run(["ai", "create", "x", "--timeout", "0"]).status, 2)
            r = try sb.run(["ai", "modify", "starter", "make it blue", "--command", agent.path])
            try expectEqual(r.status, 1)
            try expect(r.err.contains("built-in"), r.err)
            try expectEqual(try sb.run(["ai", "modify", "missing", "make it blue", "--command", agent.path]).status, 1)
            try expectEqual(try sb.run(["ai", "dance"]).status, 2)
        },
        cliTest("cli.path-invocation") { sb in
            // Run from PATH (argv[0] is the bare name) in another directory without
            // LIVEPAPER_RESOURCES: the CLI must still find the runtime template next to itself.
            let r = try sb.run(["livepaper", "new", "from-path"], viaPATH: true, unset: ["LIVEPAPER_RESOURCES"])
            try expectEqual(r.status, 0)
            try expect(FileManager.default.fileExists(atPath: sb.library.appendingPathComponent("from-path.lpscene/scene.js").path), r.err)
        },
        cliTest("cli.no-appkit") { sb in
            let r = try CLITestSupport.exec(URL(fileURLWithPath: "/usr/bin/otool"), ["-L", sb.binary.path], environment: nil, stdin: nil)
            guard r.status == 0 else { print("  (skipped: otool unavailable)"); return }
            for framework in ["AppKit", "WebKit", "SwiftUI"] {
                try expect(!r.out.contains("/\(framework).framework/"), "livepaper links \(framework)")
            }
            try expect(r.out.contains("Foundation.framework"), r.out)
        },
    ] }

    /// A command test with a fresh sandbox; skipped (with a note) when the binary isn't usable.
    private static func cliTest(_ name: String, _ body: @escaping (CLISandbox) throws -> Void) -> TestCase {
        TestCase(name: name) {
            guard let binary = try CLITestSupport.binary() else { return }
            let sb = try CLISandbox(binary: binary)
            defer { sb.cleanup() }
            try body(sb)
        }
    }
}

// MARK: - Support

enum CLITestSupport {
    /// The repository root (this file is Sources/LivePaperSelfTest/CLITests.swift).
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    nonisolated(unsafe) private static var warned = false

    /// The `livepaper` built next to this runner, or nil (after printing why, once) when it is
    /// missing or older than the CLI/Core sources.
    static func binary() throws -> URL? {
        let me = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let cli = me.deletingLastPathComponent().appendingPathComponent("livepaper")
        let fm = FileManager.default
        func note(_ s: String) -> URL? {
            print("  (skipped: \(s) — run `swift build` first)\(warned ? "" : "\n  (the other cli.* command tests skip too)")")
            warned = true
            return nil
        }
        guard fm.isExecutableFile(atPath: cli.path) else { return note("\(cli.path) doesn't exist") }
        let built = (try fm.attributesOfItem(atPath: cli.path)[.modificationDate] as? Date) ?? .distantPast
        for dir in ["Sources/LivePaperCLI", "Sources/LivePaperCore"] {
            let root = repo.appendingPathComponent(dir)
            guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if changed > built { return note("livepaper is older than \(dir)/\(file.lastPathComponent)") }
            }
        }
        return cli
    }

    struct Result { var status: Int32; var out: String; var err: String }

    /// Runs a process with stdout/stderr captured in files (no pipe-buffer deadlocks) and a timeout.
    static func exec(_ executable: URL, _ arguments: [String], environment: [String: String]?, stdin: String?,
                     directory: URL? = nil, timeout: TimeInterval = 60) throws -> Result {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lpcli-io-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outURL = scratch.appendingPathComponent("out"), errURL = scratch.appendingPathComponent("err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        if let environment { p.environment = environment }
        if let directory { p.currentDirectoryURL = directory }
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        p.standardError = try FileHandle(forWritingTo: errURL)
        if let stdin {
            let inURL = scratch.appendingPathComponent("in")
            try Data(stdin.utf8).write(to: inURL)
            p.standardInput = try FileHandle(forReadingFrom: inURL)
        } else {
            p.standardInput = FileHandle.nullDevice
        }
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); p.waitUntilExit(); throw TestFailure(description: "timed out: \(arguments.joined(separator: " "))") }
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      out: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
                      err: (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
    }

    static func plist(_ url: URL) throws -> [String: Any] {
        guard let p = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] else {
            throw TestFailure(description: "\(url.lastPathComponent) is not a dictionary plist")
        }
        return p
    }

    static func jsonObject(_ s: String) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else {
            throw TestFailure(description: "not a JSON object: \(s.prefix(200))")
        }
        return o
    }

    static func jsonArray(_ s: String) throws -> [[String: Any]] {
        guard let a = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [[String: Any]] else {
            throw TestFailure(description: "not a JSON array: \(s.prefix(200))")
        }
        return a
    }

    static func writeWebScene(at package: URL, id: String, name: String) throws {
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(#"{"schema":1,"id":"\#(id)","name":"\#(name)","kind":"web","runtime":1}"#.utf8)
            .write(to: package.appendingPathComponent("scene.json"))
        try Data("LivePaper.scene({ draw(lp) { lp.ctx.fillStyle = '#000'; lp.ctx.fillRect(0, 0, lp.w, lp.h); } });\n".utf8)
            .write(to: package.appendingPathComponent("scene.js"))
    }
}

/// A temp tree the CLI runs in: resources (the real Runtime/ + one built-in scene), support dir,
/// savers, launch agents and wallpaper store — all redirected via LIVEPAPER_* variables.
final class CLISandbox {
    let binary: URL
    let root: URL
    var resources: URL { root.appendingPathComponent("res") }
    var support: URL { root.appendingPathComponent("home") }
    var library: URL { support.appendingPathComponent("Library") }
    var savers: URL { root.appendingPathComponent("savers") }
    var saver: URL { savers.appendingPathComponent(LPPaths.saverName) }
    var work: URL { root.appendingPathComponent("cwd") }

    init(binary: URL) throws {
        self.binary = binary
        // Short and under /tmp: the render socket path (inside `home`) must stay < 104 bytes.
        root = URL(fileURLWithPath: "/tmp/lpcli-\(UUID().uuidString.prefix(8).lowercased())").resolvingSymlinksInPath()
        let fm = FileManager.default
        for dir in [resources, support, savers, work, root.appendingPathComponent("agents"), root.appendingPathComponent("store")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try fm.copyItem(at: CLITestSupport.repo.appendingPathComponent("Runtime"), to: resources.appendingPathComponent("Runtime"))
        try CLITestSupport.writeWebScene(at: resources.appendingPathComponent("Scenes/starter.lpscene"), id: "starter", name: "Starter")
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("LIVEPAPER_") }
        env["LIVEPAPER_HOME"] = support.path
        env["LIVEPAPER_SAVERS_DIR"] = savers.path
        env["LIVEPAPER_LAUNCH_AGENTS_DIR"] = root.appendingPathComponent("agents").path
        env["LIVEPAPER_WALLPAPER_STORE"] = root.appendingPathComponent("store/Index.plist").path
        env["LIVEPAPER_RESOURCES"] = resources.path
        env["LIVEPAPER_NO_SPAWN"] = "1"
        env["LIVEPAPER_RENDERD"] = "/usr/bin/false"   // belt and braces: nothing could start anyway
        env["LIVEPAPER_NO_SYSTEM_COMMANDS"] = "1"
        env["NO_COLOR"] = "1"
        return env
    }

    /// Runs `livepaper <arguments>` (or, `viaPATH`, `/usr/bin/env <arguments>` with the binary's
    /// directory first on PATH) in the sandbox's working directory.
    func run(_ arguments: [String], stdin: String? = nil, viaPATH: Bool = false, unset: [String] = []) throws -> CLITestSupport.Result {
        var env = environment
        for key in unset { env.removeValue(forKey: key) }
        if viaPATH {
            env["PATH"] = binary.deletingLastPathComponent().path + ":/usr/bin:/bin"
            return try CLITestSupport.exec(URL(fileURLWithPath: "/usr/bin/env"), arguments, environment: env, stdin: stdin, directory: work)
        }
        return try CLITestSupport.exec(binary, arguments, environment: env, stdin: stdin, directory: work)
    }

    /// A minimal installed saver (enough for publish and InstallService to treat it as installed).
    func installFakeSaver() throws {
        let contents = saver.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: CLITestSupport.repo.appendingPathComponent("Saver/Info.plist"),
                                         to: contents.appendingPathComponent("Info.plist"))
    }
}
