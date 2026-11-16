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
// doctor record launchctl & co. and keep preference changes in memory, and AI sessions skip the
// login shell (only cli.ai.terminal runs it, with its own ZDOTDIR). Nothing here launches a GUI
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
        TestCase(name: "cli.packaging.uninstall-dev-script") {
            // scripts/uninstall-dev.sh keeps the scene library unless --delete-scenes, and deleting it
            // asks first (after showing the plan) unless --yes. Runs against a fake app whose
            // `livepaper` only logs its arguments (and fails a real uninstall, so the script stops
            // before deleting anything); fake pgrep/pkill keep it away from any real LivePaper.
            let root = try tempDir("uninstall-dev")
            defer { try? FileManager.default.removeItem(at: root) }
            let fm = FileManager.default
            let app = root.appendingPathComponent("Fake.app"), bin = root.appendingPathComponent("bin"), log = root.appendingPathComponent("cli.log")
            func script(_ text: String, _ url: URL) throws {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data((text + "\n").utf8).write(to: url)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            try script("#!/bin/sh\necho \"$*\" >> '\(log.path)'\ncase \"$*\" in *--dry-run*) exit 0 ;; esac\nexit 3",
                       app.appendingPathComponent("Contents/Helpers/livepaper"))
            try script("#!/bin/sh\nexit 1", bin.appendingPathComponent("pgrep"))
            try script("#!/bin/sh\necho \"pkill $*\" >> '\(log.path)'\nexit 1", bin.appendingPathComponent("pkill"))
            var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("LIVEPAPER_") }
            env["PATH"] = bin.path + ":/usr/bin:/bin"
            env["HOME"] = root.path
            let uninstallDev = CLITestSupport.repo.appendingPathComponent("scripts/uninstall-dev.sh").path
            func run(_ args: [String], stdin: String? = nil) throws -> (CLITestSupport.Result, [String]) {
                try? fm.removeItem(at: log)
                let r = try CLITestSupport.exec(URL(fileURLWithPath: "/bin/bash"), [uninstallDev] + args + ["--app", app.path],
                                                environment: env, stdin: stdin)
                let calls = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
                return (r, calls)
            }
            var (r, calls) = try run(["--dry-run"])
            try expectEqual(r.status, 0)
            try expectEqual(calls, ["uninstall --keep-scenes --dry-run"])
            // Default: scenes kept, no question (the app and the rest go).
            (r, calls) = try run([])
            try expectEqual(calls, ["uninstall --keep-scenes --yes"])
            // --delete-scenes: the plan, then a question; EOF or "n" changes nothing.
            for answer in [nil, "n\n"] as [String?] {
                (r, calls) = try run(["--delete-scenes"], stdin: answer)
                try expectEqual(r.status, 1)
                try expectEqual(calls, ["uninstall --dry-run"])
                try expect(r.out.contains("Nothing was changed"), r.out)
            }
            (r, calls) = try run(["--delete-scenes"], stdin: "y\n")
            try expectEqual(calls, ["uninstall --dry-run", "uninstall --yes"])
            (r, calls) = try run(["--delete-scenes", "--yes"])
            try expectEqual(calls, ["uninstall --yes"])
            try expect(fm.fileExists(atPath: app.path), "the fake CLI failed the uninstall, so the app was never deleted")
        },
        TestCase(name: "cli.packaging.dev-install-helper") {
            // scripts/dev-install.sh can't register the helper's login item again (only the app can),
            // so it never restarts one launchd would refuse, and says when launching LivePaper is
            // needed. Installs a fake app into a temp folder; fake launchctl, codesign, pgrep, pkill
            // and lsregister keep it away from the real helper, Launch Services and any LivePaper.
            let root = try tempDir("dev-install")
            defer { try? FileManager.default.removeItem(at: root) }
            let fm = FileManager.default
            let bin = root.appendingPathComponent("bin"), state = root.appendingPathComponent("launchd"), log = root.appendingPathComponent("calls.log")
            let src = root.appendingPathComponent("build/LivePaper.app"), dest = root.appendingPathComponent("Apps")
            func file(_ text: String, _ url: URL, executable: Bool = true) throws {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data((text + "\n").utf8).write(to: url)
                if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
            }
            func fakeApp(_ app: URL, helper: String) throws {
                try file("#!/bin/sh\n# \(helper)", app.appendingPathComponent("Contents/Helpers/LivePaperHelper"))
                try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "190"],
                                                   format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
                try file("#!/bin/sh\nexit 0", app.appendingPathComponent("Contents/Helpers/livepaper"))
            }
            try fakeApp(src, helper: "new helper")
            try file("#!/bin/sh\necho \"launchctl $*\" >> '\(log.path)'\ncase \"$1\" in\n  print) f='\(state.path)/'\"$(basename \"$2\")\".print\n" +
                     "    if [ -f \"$f\" ]; then cat \"$f\"; exit 0; fi\n    echo 'Could not find service' >&2; exit 113 ;;\nesac\nexit 0",
                     bin.appendingPathComponent("launchctl"))
            // codesign -dvvv: a cdhash of the file's contents, ad-hoc; --verify: fine.
            try file("#!/bin/sh\nfor last; do :; done\ncase \"$1\" in\n  -dvvv) echo \"CDHash=$(shasum \"$last\" | cut -c1-40)\" >&2; " +
                     "echo 'Signature=adhoc' >&2 ;;\nesac\nexit 0", bin.appendingPathComponent("codesign"))
            try file("#!/bin/sh\nexit 1", bin.appendingPathComponent("pgrep"))
            try file("#!/bin/sh\nexit 1", bin.appendingPathComponent("pkill"))
            try file("#!/bin/sh\nexit 0", bin.appendingPathComponent("lsregister"))
            var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("LIVEPAPER_") }
            env["PATH"] = bin.path + ":/usr/bin:/bin"
            env["HOME"] = root.path
            env["LIVEPAPER_LSREGISTER"] = bin.appendingPathComponent("lsregister").path
            let devInstall = CLITestSupport.repo.appendingPathComponent("scripts/dev-install.sh").path
            let uid = getuid(), login = "gui/\(uid)/\(LPPaths.helperLabel)", fallback = "gui/\(uid)/\(LPPaths.helperLabel).fallback"
            let running = "gui/\(uid)/\(LPPaths.helperLabel) = {\n\tstate = running\n\tpid = 4242\n\tparent bundle version = 186\n\tjob state = running\n}"
            let broken = "gui/\(uid)/\(LPPaths.helperLabel) = {\n\tstate = spawn scheduled\n\tlast exit code = 78: EX_CONFIG\n" +
                         "\tresource coalition = {\n\t\tstate = active\n\t}\n\tjob state = spawn failed\n" +
                         "\tproperties = partial import | runatload | resolve program | needs LWCR update | has LWCR\n}"
            /// Installs over an app whose helper says `previous`, with these jobs loaded.
            func install(previous: String, loginJob: String?, fallbackJob: String? = nil) throws -> (CLITestSupport.Result, [String]) {
                try? fm.removeItem(at: log); try? fm.removeItem(at: state); try? fm.removeItem(at: dest)
                try fm.createDirectory(at: state, withIntermediateDirectories: true)
                try fakeApp(dest.appendingPathComponent("LivePaper.app"), helper: previous)
                if let loginJob { try file(loginJob, state.appendingPathComponent("\(LPPaths.helperLabel).print"), executable: false) }
                if let fallbackJob { try file(fallbackJob, state.appendingPathComponent("\(LPPaths.helperLabel).fallback.print"), executable: false) }
                let r = try CLITestSupport.exec(URL(fileURLWithPath: "/bin/bash"), [devInstall, "--app", src.path, "--dest", dest.path],
                                                environment: env, stdin: nil)
                let calls = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
                return (r, calls)
            }
            // The owner's state: launchd can't start the login item. No restart; launch the app.
            var (r, calls) = try install(previous: "old helper", loginJob: broken)
            try expect(r.status == 0, r.out + r.err)
            try expect(r.out.contains("has to be registered again: launchd can't start it (spawn failed, last exit code 78: EX_CONFIG, " +
                                      "needs LWCR update)") && r.out.contains("launching LivePaper"), r.out)
            try expect(!calls.contains { $0.hasPrefix("launchctl kickstart") }, "\(calls)")
            try expect(fm.fileExists(atPath: dest.appendingPathComponent("LivePaper.app/Contents/Helpers/LivePaperHelper").path))
            // Running, and this build changes the ad-hoc helper: left running (a restart would be
            // refused), and the same advice.
            (r, calls) = try install(previous: "old helper", loginJob: running)
            try expect(r.out.contains("this build changes the ad-hoc-signed helper") && r.out.contains("keeps running until then"), r.out)
            try expect(!calls.contains { $0.hasPrefix("launchctl kickstart") }, "\(calls)")
            // The helper didn't change: restarted, nothing to say.
            (r, calls) = try install(previous: "new helper", loginJob: running)
            try expect(calls.contains("launchctl kickstart -k \(login)") && !r.out.contains("registered again"), r.out + "\(calls)")
            // The LaunchAgent fallback is a plain plist: always restarted.
            (r, calls) = try install(previous: "old helper", loginJob: nil, fallbackJob: "gui/\(uid)/x = {\n\tstate = running\n}")
            try expect(calls.contains("launchctl kickstart -k \(fallback)") && !r.out.contains("registered again"), r.out + "\(calls)")
        },
    ] }

    // MARK: - Commands

    static var cliCommands: [TestCase] { [
        cliTest("cli.help") { sb in
            let r = try sb.run(["help"])
            try expectEqual(r.status, 0)
            for command in ["check", "still", "bench", "thumbnail", "new", "list", "import", "publish", "ai", "doctor", "uninstall", "server"] {
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
        cliTest("cli.thumbnail") { sb in
            // Argument handling only: no render server runs in the sandbox (LIVEPAPER_NO_SPAWN=1).
            try expectEqual(try sb.run(["thumbnail"]).status, 2)
            try expectEqual(try sb.run(["thumbnail", sb.root.appendingPathComponent("missing.lpscene").path]).status, 2)
            let pkg = sb.root.appendingPathComponent("outside/glow.lpscene")
            try CLITestSupport.writeWebScene(at: pkg, id: "glow", name: "Glow")
            try expectEqual(try sb.run(["thumbnail", pkg.path, "--t", "soon"]).status, 2)
            let r = try sb.run(["thumbnail", pkg.path, "--t", "12"])
            try expectEqual(r.status, 3)
            try expect(!FileManager.default.fileExists(atPath: pkg.appendingPathComponent("thumbnail.jpg").path))
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
        cliTest("cli.ai-session.guard") { sb in
            // Inside an AI session (the variables the session runner and the workspace shim set) the
            // CLI runs only the scene commands, and only on files inside the session's workspace —
            // whatever the agent's tool rules let through, and however it reached the binary.
            let fm = FileManager.default
            _ = try sb.run(["new", "aurora-lake"])
            try sb.installFakeSaver()
            let ws = sb.root.appendingPathComponent("ws")
            let pkg = ws.appendingPathComponent("scene")
            try CLITestSupport.writeWebScene(at: pkg, id: "untitled", name: "Untitled")
            let outside = sb.root.appendingPathComponent("outside/glow.lpscene")
            try CLITestSupport.writeWebScene(at: outside, id: "glow", name: "Glow")
            let session = [AISessionPolicy.sessionVariable: "s1", AISessionPolicy.workspaceVariable: ws.path]
            let marker = sb.root.appendingPathComponent("pwned")
            for args in [["uninstall", "--yes"], ["publish"], ["import", outside.path], ["new", "X"], ["list"], ["doctor"],
                         ["ai", "create", "x", "--command", "/usr/bin/touch \(marker.path)", "--yes"], ["server", "stop"]] {
                let r = try sb.run(args, extraEnv: session)
                try expectEqual(r.status, 2)
                try expect(r.err.contains("not available in an AI session"), "\(args): \(r.err)")
            }
            try expect(fm.fileExists(atPath: sb.saver.path), "saver kept")
            try expect(fm.fileExists(atPath: sb.library.appendingPathComponent("aurora-lake.lpscene/scene.json").path), "library kept")
            try expect(!fm.fileExists(atPath: marker.path), "no nested agent ran")
            // The scene commands work on the workspace…
            var r = try sb.run(["compile", pkg.path], extraEnv: session)
            try expectEqual(r.status, 0)
            try expect(fm.fileExists(atPath: pkg.appendingPathComponent(".check/scene.html").path), r.err)
            r = try sb.run(["compile", pkg.path, "--out", ws.appendingPathComponent("scene/out.html").path], extraEnv: session)
            try expectEqual(r.status, 0)
            // …but not outside it, directly or through a symlink.
            let elsewhere = sb.root.appendingPathComponent("elsewhere.html")
            for args in [["compile", outside.path], ["compile", pkg.path, "--out", elsewhere.path],
                         ["still", pkg.path, "--out", sb.root.appendingPathComponent("x.png").path],
                         ["thumbnail", pkg.path, "--out", sb.root.appendingPathComponent("x.jpg").path]] {
                r = try sb.run(args, extraEnv: session)
                try expectEqual(r.status, 2)
                try expect(r.err.contains("outside this AI session's workspace"), "\(args): \(r.err)")
            }
            try fm.createSymbolicLink(at: ws.appendingPathComponent("link"), withDestinationURL: outside.deletingLastPathComponent())
            r = try sb.run(["compile", ws.appendingPathComponent("link/glow.lpscene").path], extraEnv: session)
            try expectEqual(r.status, 2)
            try expect(!fm.fileExists(atPath: elsewhere.path) && !fm.fileExists(atPath: outside.appendingPathComponent(".check").path))
            // Help stays available.
            try expectEqual(try sb.run(["help", "check"], extraEnv: session).status, 0)
            // A session marker without a workspace refuses the scene commands too.
            try expectEqual(try sb.run(["compile", pkg.path], extraEnv: [AISessionPolicy.sessionVariable: "s1"]).status, 2)
        },
        cliTest("cli.check.motion") { sb in
            // `check` against a stand-in render server whose motion answer is "only the top-left
            // corner moves": the summary shows the motion numbers and the map, the check fails with
            // an actionable problem, and report.json carries the numbers.
            let pkg = sb.root.appendingPathComponent("corner.lpscene")
            try CLITestSupport.writeWebScene(at: pkg, id: "corner", name: "Corner")
            let motionAsked = RuntimeTests.Flag()
            _ = try RuntimeTests.serve(sb.support.appendingPathComponent("render.sock"), count: 12) { line in
                guard let req = try? JSONDecoder().decode(RenderRequest.self, from: line) else { return Data("{}".utf8) }
                var resp: RenderResponse
                switch req.op {
                case .still: resp = RenderResponse(ok: true, ready: true, out: req.out, meanLuma: 30, clockLuma: 10)
                case .bench: resp = RenderResponse(ok: true, ready: true, benchMs: 1.1)
                case .motion:
                    motionAsked.set()
                    resp = RuntimeTests.motionResponse(CheckFrame(Int(req.width ?? 0), Int(req.height ?? 0), dpr: req.dpr ?? 1, t: 0)) { c, r in
                        c < 2 && r < 2 ? 5 : 0
                    }
                    resp.out = req.out
                default: resp = RenderResponse(ok: true, ready: true)
                }
                return (try? JSONEncoder().encode(resp)) ?? Data()
            }
            let r = try sb.run(["check", pkg.path, "--quick"])
            try expectEqual(r.status, 1)
            try expect(r.out.contains("motion       1280x720@0.5: 3 % of the frame changes within 5 s (min 25 %), 3 % within 2 s  ·  moving in 1/9 regions (min 5)"), r.out)
            try expect(r.out.contains("where 1280x720@0.5 changes within 5 s (# at most sampled moments, + at some, . never):\n                 ##..............\n"), r.out)
            try expect(r.out.contains("heat map ") && r.out.contains("motion-1280x720@0.5.png (amber = moves most of the time"), r.out)
            try expect(r.out.contains("1. Too static at 1280x720@0.5: only 3 % of the frame visibly changes within 5 s"), r.out)
            try expect(motionAsked.isSet, "the check asked for motion")
            let report = try SceneManifest.decoder().decode(CheckReport.self, from: Data(contentsOf: pkg.appendingPathComponent(".check/report.json")))
            try expectEqual(report.motion?.first?.size, "1280x720@0.5")
            try expectEqual(report.motion?.first?.coverage5s, 0.028)
            try expectEqual(report.motion?.first?.map.first, "##..............")
            try expect(!report.passed && report.problems.contains { $0.hasPrefix("Too static") }, "\(report.problems)")
        },
        cliTest("cli.ai-session.render-spool") { sb in
            // With the render socket out of reach (Codex's sandbox), the session's CLI hands its
            // requests to the runner through the spool instead of failing or starting a daemon.
            let fm = FileManager.default
            let ws = sb.root.appendingPathComponent("ws")
            let pkg = ws.appendingPathComponent("scene"), spool = ws.appendingPathComponent(".livepaper/render-spool")
            try CLITestSupport.writeWebScene(at: pkg, id: "untitled", name: "Untitled")
            try fm.createDirectory(at: spool, withIntermediateDirectories: true)
            let done = RuntimeTests.Flag()
            let seen = RuntimeTests.ResultBox<RenderRequest>()
            Thread {
                while !done.isSet {
                    for name in (try? fm.contentsOfDirectory(atPath: spool.path)) ?? [] where name.hasSuffix(".request.json") {
                        let id = String(name.dropLast(".request.json".count))
                        let claimed = spool.appendingPathComponent(id + ".working")
                        guard rename(spool.appendingPathComponent(name).path, claimed.path) == 0,
                              let req = try? JSONDecoder().decode(RenderRequest.self, from: Data(contentsOf: claimed)) else { continue }
                        seen.result = .success(req)
                        try? JSONEncoder().encode(RenderResponse(ok: true, ready: true, benchMs: 1.25))
                            .write(to: spool.appendingPathComponent(id + ".response.json"), options: .atomic)
                    }
                    usleep(20_000)
                }
            }.start()
            defer { done.set() }
            let r = try sb.run(["bench", pkg.path, "--frames", "10"],
                               extraEnv: [AISessionPolicy.sessionVariable: "s1", AISessionPolicy.workspaceVariable: ws.path,
                                          AISessionPolicy.renderSpoolVariable: spool.path, "LIVEPAPER_NO_SPAWN": "0"])
            try expectEqual(r.status, 0)
            try expect(r.out.contains("1.250 ms/frame"), r.out + r.err)
            let req = try seen.result?.get()
            try expectEqual(req?.op, .bench)
            try expectEqual(req?.frames, 10)
            try expect(req?.html?.hasSuffix("/ws/scene/.check/scene.html") == true, req?.html ?? "-")
            try expectEqual(try fm.contentsOfDirectory(atPath: spool.path), [])
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

            // Text output: the stills of one check arrive as one line, relative to the workspace.
            let painter = sb.root.appendingPathComponent("tools/still-agent")
            try Data("""
            #!/bin/sh
            mkdir -p scene/.check
            for t in 0 4 12 30 90 600; do printf 'png' > "scene/.check/1512x982@2-t$t.png"; done
            sleep 2
            echo "Looked at the stills."
            echo '// v2' > scene/scene.js

            """.utf8).write(to: painter)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: painter.path)
            r = try sb.run(["ai", "create", "stills", "--command", painter.path])
            try expectEqual(r.status, 1)
            let stillLines = r.out.split(separator: "\n").filter { $0.contains("◻") }
            try expectEqual(stillLines.count, 1)
            try expect(stillLines.first?.contains("◻ 6 stills in scene/.check/: 1512x982@2-t0.png, 1512x982@2-t12.png") == true &&
                       stillLines.first?.hasSuffix(", … (+2)") == true, r.out)

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
        cliTest("cli.ai.terminal") { sb in
            // Regression: in a terminal (here script(1)'s pty is the CLI's controlling terminal), the
            // interactive login-shell probe was stopped by SIGTTOU: every `livepaper ai …` stalled
            // ~11 s and the agent got none of the user's rc environment.
            guard (LoginShell.userShell() as NSString).lastPathComponent == "zsh",
                  FileManager.default.isExecutableFile(atPath: "/usr/bin/script") else {
                print("  (skipped: needs zsh as the login shell, and /usr/bin/script)"); return
            }
            let fm = FileManager.default
            let zdot = sb.root.appendingPathComponent("zdotdir"), agentEnv = sb.root.appendingPathComponent("agent-env.txt")
            try fm.createDirectory(at: zdot, withIntermediateDirectories: true)
            try Data("export LP_FROM_ZSHRC=yes\n".utf8).write(to: zdot.appendingPathComponent(".zshrc"))
            let agent = try CLITestSupport.writeScript(sb.root.appendingPathComponent("tools/env-agent"), """
            #!/bin/sh
            /usr/bin/env > '\(agentEnv.path)'
            echo '// v2' > scene/scene.js

            """)
            var env = sb.environment
            env["ZDOTDIR"] = zdot.path   // the sandbox's rc files, not the developer's
            // The sandbox's LIVEPAPER_NO_SYSTEM_COMMANDS=1 skips the login shell; this test is about it.
            env[LoginShell.selfTestLoginShellVariable] = "1"
            let began = Date()
            let r = try CLITestSupport.exec(URL(fileURLWithPath: "/usr/bin/script"),
                                            ["-q", "/dev/null", sb.binary.path, "ai", "create", "x", "--command", agent.path, "--json"],
                                            environment: env, stdin: nil, directory: sb.work)
            let took = Date().timeIntervalSince(began)
            let seen = (try? String(contentsOf: agentEnv, encoding: .utf8)) ?? ""
            try expect(!seen.isEmpty, "the agent didn't run: \(r.out)")
            try expect(seen.contains("LP_FROM_ZSHRC=yes\n"), "the agent didn't get ~/.zshrc's environment (\(took) s)")
            try expect(took < 8, "took \(took) s")
        },
        cliTest("cli.ai.signals") { sb in
            // Closing the terminal (SIGHUP) stops the agent's process group and exits 129 — but under
            // `nohup` SIGHUP stays ignored and the session goes on (regression: a dispatch source
            // fires even for an ignored signal, so the CLI killed the agent anyway).
            let fm = FileManager.default
            let dir = sb.root.appendingPathComponent("signals")
            let agent = try CLITestSupport.writeScript(sb.root.appendingPathComponent("tools/waiting-agent"), """
            #!/bin/sh
            echo $$ > "$LP_TEST_DIR/agent.pid"
            i=0; while [ ! -e "$LP_TEST_DIR/go" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done
            echo '// v2' > scene/scene.js
            echo "agent finished"

            """)
            for nohup in [false, true] {
                try? fm.removeItem(at: dir)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                var env = sb.environment
                env["LP_TEST_DIR"] = dir.path
                let args = ["ai", "create", "x", "--command", agent.path, "--json"]
                let cli = try CLITestSupport.Background(nohup ? URL(fileURLWithPath: "/usr/bin/nohup") : sb.binary,
                                                        nohup ? [sb.binary.path] + args : args, environment: env, directory: sb.work)
                defer { cli.stop(); fm.createFile(atPath: dir.appendingPathComponent("go").path, contents: nil) }
                var agentPID: pid_t = 0
                let deadline = Date().addingTimeInterval(20)
                while agentPID <= 0 && Date() < deadline && cli.isRunning {
                    agentPID = pid_t((try? String(contentsOf: dir.appendingPathComponent("agent.pid"), encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
                    if agentPID <= 0 { usleep(50_000) }
                }
                try expect(agentPID > 0, "the agent never started: \(cli.output)")
                kill(cli.pid, SIGHUP)
                if nohup {
                    usleep(700_000)
                    try expect(cli.isRunning, "under nohup, SIGHUP ended the CLI: \(cli.output)")
                    try expect(kill(agentPID, 0) == 0, "under nohup, SIGHUP stopped the agent")
                    fm.createFile(atPath: dir.appendingPathComponent("go").path, contents: nil)
                    let status = try cli.wait(timeout: 30)
                    try expect(cli.output.contains("agent finished"), cli.output)
                    try expectEqual(status, 1)   // the check can't render here, after everything else ran
                } else {
                    try expectEqual(try cli.wait(timeout: 10), 129)
                    let gone = Date().addingTimeInterval(3)
                    while kill(agentPID, 0) == 0 && Date() < gone { usleep(20_000) }
                    try expect(kill(agentPID, 0) != 0, "the agent outlived the CLI")
                    try expect(!cli.output.contains("agent finished"), cli.output)
                }
            }
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

    /// Writes an executable script.
    static func writeScript(_ url: URL, _ text: String) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A command running in the background (stdin /dev/null; stdout and stderr into one file), for
    /// tests that signal it while it runs.
    final class Background {
        private let process = Process()
        private let scratch: URL
        private var log: URL { scratch.appendingPathComponent("output") }

        init(_ executable: URL, _ arguments: [String], environment: [String: String], directory: URL) throws {
            scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lpcli-bg-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: log.path, contents: nil)
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = directory
            let out = try FileHandle(forWritingTo: log)
            process.standardOutput = out
            process.standardError = out
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }

        var pid: pid_t { process.processIdentifier }
        var isRunning: Bool { process.isRunning }
        var output: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

        /// Its exit status; throws if it is still running after `timeout` seconds.
        func wait(timeout: TimeInterval) throws -> Int32 {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { usleep(20_000) }
            guard !process.isRunning else { throw TestFailure(description: "still running after \(timeout) s: \(output)") }
            return process.terminationStatus
        }

        /// Kills it if it still runs, and removes its output.
        func stop() {
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: scratch)
        }
    }

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
    func run(_ arguments: [String], stdin: String? = nil, viaPATH: Bool = false, unset: [String] = [],
             extraEnv: [String: String] = [:]) throws -> CLITestSupport.Result {
        var env = environment.merging(extraEnv) { _, new in new }
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
