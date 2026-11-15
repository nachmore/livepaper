// InstallCommands — `livepaper doctor` (what is installed and what is wrong) and `livepaper
// uninstall` (undo everything LivePaper changed), both through InstallService.
import Foundation
import LivePaperCore

enum InstallCommands {
    static var all: [CLICommand] {
        [
            CLICommand(name: "doctor", synopsis: "[--no-ai] [--json]",
                       summary: "diagnose the installation (saver, helper, lock settings, render server, AI tools); exit 1 on problems",
                       run: doctor),
            CLICommand(name: "uninstall", synopsis: "[--yes] [--keep-scenes] [--dry-run]",
                       summary: "remove the helper and screen saver, restore changed settings, delete LivePaper's data",
                       run: uninstall),
        ]
    }

    // MARK: - doctor

    struct Check: Encodable, Equatable {
        enum Status: String, Encodable { case ok, problem, warning, info }
        var section: String
        var name: String
        var status: Status
        var detail: String
    }

    struct DoctorReport: Encodable {
        var version: String
        var checks: [Check]
        var paths: [String: String]
        var problems: Int { checks.filter { $0.status == .problem }.count }
        var warnings: Int { checks.filter { $0.status == .warning }.count }

        enum CodingKeys: String, CodingKey { case version, checks, paths, problems, warnings }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(version, forKey: .version); try c.encode(checks, forKey: .checks); try c.encode(paths, forKey: .paths)
            try c.encode(problems, forKey: .problems); try c.encode(warnings, forKey: .warnings)
        }
    }

    static func doctor(_ argv: [String]) async throws -> Int32 {
        let args = try Arguments(argv, flags: ["no-ai", "json"])
        guard args.positional.isEmpty else { throw UsageError("doctor takes no arguments") }
        let report = await diagnose(includeAI: !args.flag("no-ai"))
        if args.flag("json") { printJSONObject(report) } else { printDoctor(report) }
        return report.problems == 0 ? ExitCode.ok : ExitCode.failed
    }

    /// Everything doctor looks at. Read-only: `sysadminctl -screenLock status`, `launchctl print`,
    /// a render-server ping (never starts one), file reads, and (unless `includeAI` is false) the
    /// login-shell lookup + `--version` of each AI CLI.
    static func diagnose(includeAI: Bool) async -> DoctorReport {
        let installer = CLIServices.installer()
        let paths = installer.paths
        let status = installer.status()
        var checks: [Check] = []
        func add(_ section: String, _ name: String, _ status: Check.Status, _ detail: String) {
            checks.append(Check(section: section, name: name, status: status, detail: detail))
        }

        // LivePaper itself
        let app = CLIEnvironment.appBundle
        if let app {
            add("LivePaper", "app", .ok, "\(displayPath(app)) · \(CLIEnvironment.version.display)")
        } else {
            add("LivePaper", "app", .info, "development build (\(displayPath(CLIEnvironment.executable)))")
        }
        let running = CLIEnvironment.processes(named: "LivePaper").filter { $0.path.contains(".app/Contents/MacOS/") }
        add("LivePaper", "app running", .info, running.isEmpty ? "no" : running.map { "pid \($0.pid)" }.joined(separator: ", "))
        let runtime = LPPaths.runtimeDir
        if FileManager.default.fileExists(atPath: runtime.appendingPathComponent("runtime.js").path) {
            add("LivePaper", "runtime", .ok, "\(displayPath(runtime)) (API \(SceneCompiler.supportedRuntime))")
        } else {
            add("LivePaper", "runtime", .problem, "missing at \(displayPath(runtime)): scenes can't be compiled. Reinstall LivePaper.")
        }
        let renderd = ProcessInfo.processInfo.environment["LIVEPAPER_RENDERD"].map { URL(fileURLWithPath: $0) }
        if let renderd, FileManager.default.isExecutableFile(atPath: renderd.path) {
            add("LivePaper", "render daemon", .ok, displayPath(renderd))
        } else {
            add("LivePaper", "render daemon", .problem,
                "LivePaperRenderd wasn't found next to \(displayPath(CLIEnvironment.executable)): check/still/bench can only use a running LivePaper.app.")
        }
        add("LivePaper", "render server", .info, await renderServerState())

        // Screen saver
        let section = "Screen saver"
        if !status.saverInstalled {
            add(section, "installed", .problem, "not installed in \(displayPath(paths.screenSaversDir)). Open LivePaper and follow the setup.")
        } else if !status.saverUpToDate {
            let installed = bundleVersion(paths.installedSaver) ?? "?"
            let bundled = bundleVersion(paths.saverTemplate) ?? "?"
            if status.saverNewerInstalled {
                add(section, "installed", .info, "a newer build is installed (build \(installed); this LivePaper has \(bundled)). " +
                    "Launching this LivePaper leaves it alone (only an older saver is updated); its setup can install this build instead.")
            } else {
                add(section, "installed", .problem, "an older version is installed (build \(installed); this LivePaper has \(bundled)). " +
                    "Open LivePaper to update it.")
            }
        } else {
            add(section, "installed", .ok, "\(displayPath(paths.installedSaver)) (build \(bundleVersion(paths.installedSaver) ?? "?"))")
        }
        if status.saverSelected {
            add(section, "selected", .ok, "LivePaper is the selected screen saver")
        } else {
            add(section, "selected", .problem, "LivePaper isn't the selected screen saver, so the lock screen won't show your scenes. " +
                "Choose it in System Settings › Wallpaper › Screen Saver.")
        }
        if status.saverInstalled {
            if let playlist = try? LPPlaylist.load(from: paths.installedPlaylist) {
                add(section, "published", playlist.scenes.isEmpty ? .warning : .ok,
                    "generation \(playlist.generation): \(playlist.scenes.count) scene\(playlist.scenes.count == 1 ? "" : "s") · " +
                    LibraryCommands.describe(playlist))
            } else {
                add(section, "published", .warning, "nothing published yet (the saver shows its fallback). Run `livepaper publish`.")
            }
        }

        // Lock screen
        let lock = "Lock screen"
        if status.passwordImmediately {
            add(lock, "password", .ok, "required immediately when the screen saver starts")
        } else {
            add(lock, "password", .problem, "\u{201C}Require password after screen saver begins\u{201D} isn't Immediately, so starting the " +
                "screen saver doesn't lock the Mac and LivePaper's lock shortcut and Lock Now refuse to run. " +
                (status.passwordManagedByMDM ? "A configuration profile enforces it." : "Set it in System Settings › Lock Screen."))
        }
        let lockKeys = (CLIServices.preferences.value(domain: InstallService.lockTakeoverDomain, key: InstallService.lockTakeoverKey,
                                                      currentHost: false) as? NSNumber)?.boolValue == true
        add(lock, "lock keys", lockKeys ? .ok : .warning, lockKeys
            ? "on: ⌃⌘Q, Lock Screen and the Touch ID / lock key show the scene (\(InstallService.lockTakeoverDomain) \(InstallService.lockTakeoverKey))"
            : "off: ⌃⌘Q, Lock Screen and the Touch ID / lock key lock straight to the wallpaper. Turn it on in LivePaper › Settings › Lock (\u{201C}Use ⌃⌘Q and the lock key for LivePaper lock\u{201D}).")
        add(lock, "idle timeout", .info, "unchanged; macOS starts the screen saver after the idle time set in System Settings › Lock Screen")
        if status.helperRunning {
            add(lock, "helper", .ok, "running (\(LPPaths.helperLabel))")
        } else {
            add(lock, "helper", .problem, "\(LPPaths.helperLabel) isn't running: LivePaper's lock shortcut and \u{201C}Lock now\u{201D} don't work. " +
                "Open LivePaper to start it (and allow it in System Settings › General › Login Items).")
        }
        if FileManager.default.fileExists(atPath: paths.fallbackAgentPlist.path) {
            add(lock, "helper agent", .info, "fallback LaunchAgent at \(displayPath(paths.fallbackAgentPlist))")
        }
        add(lock, "managed", .info, status.managedByMDM
            ? "a configuration profile manages screen-saver settings (idle time / password); LivePaper never changes them"
            : "no configuration profile manages the screen saver")

        // Library
        let services = CLIServices.live
        let scenes = (try? services.library.scenes()) ?? []
        let user = scenes.filter { !$0.isBuiltin }.count
        add("Library", "scenes", scenes.isEmpty ? .warning : .ok,
            "\(user) of yours in \(displayPath(LPPaths.library)), \(scenes.count - user) built-in")
        for name in unreadablePackages(in: LPPaths.library, loaded: Set(scenes.filter { !$0.isBuiltin }.map(\.id))) {
            add("Library", "ignored", .warning, "\(name) isn't a readable scene package (bad id or scene.json); LivePaper skips it")
        }

        // AI
        if includeAI {
            let found = await services.ai.detectHarnesses().filter { $0.kind != .custom }
            for known in HarnessDetector.known {
                if let h = found.first(where: { $0.kind == known.kind }) {
                    add("AI", known.name, .ok, "\(h.version.map { "\($0) · " } ?? "")\(h.executable)")
                } else {
                    add("AI", known.name, .info, "not found (`\(known.tool)`)")
                }
            }
            if found.isEmpty {
                add("AI", "harness", .warning, "no AI coding CLI found: `livepaper ai` needs Claude Code, Codex or Kiro CLI (or --command)")
            }
        }

        let pathList: [String: String] = [
            "cli": CLIEnvironment.executable.path,
            "resources": LPPaths.appResources.path,
            "support": paths.supportRoot.path,
            "library": LPPaths.library.path,
            "workspaces": LPPaths.workspaces.path,
            "savers": paths.screenSaversDir.path,
            "saver": paths.installedSaver.path,
            "saverTemplate": paths.saverTemplate.path,
            "launchAgents": paths.launchAgentsDir.path,
            "wallpaperStore": paths.wallpaperStore.path,
            "renderSocket": LPPaths.renderSocket.path,
            "logs": LPPaths.logs.path,
        ]
        return DoctorReport(version: CLIEnvironment.version.display, checks: checks, paths: pathList)
    }

    static func renderServerState() async -> String {
        let client = RenderClient()
        guard client.isServerRunning() else { return "not running (starts on demand)" }
        // ping never starts a server.
        guard let r = try? await client.send(RenderRequest(op: .ping), timeout: 5) else { return "socket open but not answering" }
        return "running: \(r.note ?? "ok")"
    }

    /// `*.lpscene` directories in the library that LibraryService didn't load.
    static func unreadablePackages(in library: URL, loaded: Set<String>) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && ($0 as NSString).pathExtension == SceneManifest.packageExtension }
            .filter { !loaded.contains(($0 as NSString).deletingPathExtension) }.sorted()
    }

    static func printDoctor(_ report: DoctorReport) {
        print("LivePaper doctor — \(report.version)")
        let width = report.checks.map(\.name.count).max() ?? 10
        var section = ""
        for check in report.checks {
            if check.section != section { section = check.section; print("\n\(section)") }
            let glyph: String
            switch check.status {
            case .ok: glyph = "✓"
            case .problem: glyph = "✗"
            case .warning: glyph = "!"
            case .info: glyph = "·"
            }
            print("  \(glyph) \(check.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(check.detail)")
        }
        print("\nPaths")
        for key in report.paths.keys.sorted() { print("  \(key.padding(toLength: 15, withPad: " ", startingAt: 0)) \(report.paths[key]!)") }
        print("")
        switch (report.problems, report.warnings) {
        case (0, 0): print("No problems found.")
        case (0, let w): print("No problems found (\(w) warning\(w == 1 ? "" : "s")).")
        case (let p, let w): print("\(p) problem\(p == 1 ? "" : "s") found\(w > 0 ? " (and \(w) warning\(w == 1 ? "" : "s"))" : "").")
        }
    }

    // MARK: - uninstall

    static func uninstall(_ argv: [String]) async throws -> Int32 {
        let args = try Arguments(argv, flags: ["yes", "keep-scenes", "dry-run"])
        guard args.positional.isEmpty else { throw UsageError("uninstall takes no arguments") }
        let removeLibrary = !args.flag("keep-scenes")
        let dryRun = args.flag("dry-run")

        if !dryRun && !args.flag("yes") {
            print("This would:")
            printSteps(plan(removeLibrary: removeLibrary), dryRun: true)
            let scenes = (try? CLIServices.live.library.scenes().filter { !$0.isBuiltin }.count) ?? 0
            if removeLibrary && scenes > 0 {
                print("\n\(scenes) scene\(scenes == 1 ? "" : "s") of yours will be deleted (use --keep-scenes to keep them).")
            }
            guard CLIEnvironment.confirm("\nUninstall LivePaper?") else {
                print("Nothing was changed.")
                return ExitCode.failed
            }
        }
        let steps = dryRun ? plan(removeLibrary: removeLibrary) : await perform(removeLibrary: removeLibrary)
        if dryRun { print("Dry run — nothing was changed. Uninstalling would:") }
        printSteps(steps, dryRun: dryRun)
        if dryRun { return ExitCode.ok }

        let failed = steps.filter { if case .failed = $0.outcome { return true }; return false }
        print("")
        guard failed.isEmpty else {
            print("Uninstall didn't finish (\(failed.count) step\(failed.count == 1 ? "" : "s") failed). Run it again to retry; " +
                  "completed steps are skipped.")
            return ExitCode.unavailable
        }
        print("LivePaper's helper, screen saver and settings are removed" + (removeLibrary ? ", and its data deleted." : "."))
        if !removeLibrary { print("Your scenes are kept in \(displayPath(LPPaths.library)).") }
        let loginItemLeft = steps.contains { step in
            guard step.title == InstallService.unregisterLoginItemTitle, case .skipped(let why) = step.outcome else { return false }
            return why.contains("Login Items")
        }
        if loginItemLeft, let app = CLIEnvironment.appBundle {
            // Only the app's own executable can unregister its login item; the uninstall marker keeps
            // the entry from starting the helper in the meantime.
            print("LivePaper's entry in System Settings › General › Login Items can only be removed by the app: it can't " +
                  "start the helper any more, and it goes away once \(displayPath(app)) is deleted (or remove it there).")
        }
        if let app = CLIEnvironment.appBundle { print("Delete \(displayPath(app)) to finish (move it to the Trash).") }
        print("If you picked another screen saver before LivePaper, choose it again in System Settings › Wallpaper › Screen Saver.")
        return ExitCode.ok
    }

    /// What uninstall would do, without changing anything.
    static func plan(removeLibrary: Bool) -> [InstallStep] {
        var steps: [InstallStep] = []
        if RenderClient().isServerRunning() { steps.append(InstallStep(title: "Stop the render server", outcome: .planned)) }
        return steps + CLIServices.installer(dryRun: true).performUninstall(removeLibrary: removeLibrary)
    }

    /// Runs the uninstall: stop the render server (its socket lives in the data directory), then
    /// InstallService's steps (helper, lock keys, wallpaper choice, changed preferences, saver, data).
    static func perform(removeLibrary: Bool) async -> [InstallStep] {
        var steps: [InstallStep] = []
        let client = RenderClient()
        if client.isServerRunning() {
            do {
                let r = try await client.send(RenderRequest(op: .shutdown), timeout: 10)
                steps.append(InstallStep(title: "Stop the render server", outcome: r.ok ? .done : .skipped(r.note ?? "it declined (LivePaper.app serves it)")))
            } catch {
                steps.append(InstallStep(title: "Stop the render server", outcome: .skipped(error.localizedDescription)))
            }
        }
        return steps + CLIServices.installer().performUninstall(removeLibrary: removeLibrary)
    }

    static func printSteps(_ steps: [InstallStep], dryRun: Bool) {
        for step in steps {
            switch step.outcome {
            case .done: print("  ✓ \(step.title)")
            case .planned: print("  • \(step.title)")
            case .skipped(let why): print("  · \(step.title) — \(dryRun ? "nothing to do" : "skipped"): \(why)")
            case .failed(let why): print("  ✗ \(step.title) — failed: \(why)")
            }
        }
    }
}

/// CFBundleVersion of a bundle (FileOps.bundleInfo is internal to LivePaperCore).
func bundleVersion(_ bundle: URL) -> String? {
    NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String
}
