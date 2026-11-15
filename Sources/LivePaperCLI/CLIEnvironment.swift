// CLIEnvironment — where this `livepaper` binary lives, which LivePaper it belongs to, and the
// small process-level utilities the commands share (prompts, process list, test hooks).
import Darwin
import Foundation
import LivePaperCore

enum CLIEnvironment {
    /// The real path of this executable, symlinks resolved.
    ///
    /// `CommandLine.arguments[0]` is only the bare command name when the CLI is run from PATH (the
    /// shell passes argv[0] as typed), so it can't be used to find the app bundle; dyld knows the
    /// path the binary was actually loaded from.
    static let executable: URL = {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }()

    /// The LivePaper.app this CLI ships in (`…/LivePaper.app/Contents/Helpers/livepaper`), if any.
    static var appBundle: URL? {
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents", app.pathExtension == "app",
              FileManager.default.fileExists(atPath: contents.appendingPathComponent("Info.plist").path) else { return nil }
        return app
    }

    /// The repository checkout this CLI was built from (`swift build` puts it in .build/…), found by
    /// walking up from the executable to a directory containing Runtime/runtime.js.
    static var sourceRoot: URL? {
        guard appBundle == nil else { return nil }
        var dir = executable.deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Runtime/runtime.js").path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// Pins the LIVEPAPER_* locations LivePaperCore derives from argv[0] (resources, the render
    /// daemon, the CLI itself for AI workspaces) to this executable's real location, unless the
    /// caller set them. Must run before any service is created. Children (the render daemon, AI
    /// harnesses and the `livepaper` they run) inherit the same values, so they all agree.
    static func pinLocations() {
        let env = ProcessInfo.processInfo.environment
        func setIfUnset(_ key: String, _ value: @autoclosure () -> String?) {
            guard env[key]?.isEmpty ?? true, let value = value() else { return }
            setenv(key, value, 1)
        }
        setIfUnset("LIVEPAPER_RESOURCES", resourcesDirectory?.path)
        let daemon = executable.deletingLastPathComponent().appendingPathComponent("LivePaperRenderd")
        setIfUnset("LIVEPAPER_RENDERD", FileManager.default.isExecutableFile(atPath: daemon.path) ? daemon.path : nil)
        setIfUnset("LIVEPAPER_CLI", executable.path)
    }

    /// Contents/Resources of the app bundle, or the source tree (Runtime/ and Scenes/ live at its root).
    static var resourcesDirectory: URL? {
        if let app = appBundle {
            let resources = app.appendingPathComponent("Contents/Resources")
            if FileManager.default.fileExists(atPath: resources.appendingPathComponent("Runtime").path) { return resources }
        }
        return sourceRoot
    }

    // MARK: - Version

    struct Version: Equatable {
        var short: String
        var build: String?
        /// "0.1.0 (build 42)" / "0.1.0-dev".
        var display: String { build.map { "\(short) (build \($0))" } ?? short }
    }

    /// From the enclosing app's Info.plist; for development builds, the repository's VERSION file.
    static var version: Version {
        if let app = appBundle, let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) {
            return Version(short: info["CFBundleShortVersionString"] as? String ?? "unknown", build: info["CFBundleVersion"] as? String)
        }
        if let root = sourceRoot,
           let text = try? String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8) {
            return Version(short: text.trimmingCharacters(in: .whitespacesAndNewlines) + "-dev", build: nil)
        }
        return Version(short: "dev", build: nil)
    }

    // MARK: - Test hooks

    /// LIVEPAPER_NO_SYSTEM_COMMANDS=1: install/uninstall/doctor record launchctl, sysadminctl and
    /// open instead of running them, and change preferences only in memory. Used by the self-tests
    /// (together with the LIVEPAPER_HOME / _SAVERS_DIR / _LAUNCH_AGENTS_DIR / _WALLPAPER_STORE
    /// overrides) so nothing outside a temporary directory is ever touched.
    static var noSystemCommands: Bool { ProcessInfo.processInfo.environment["LIVEPAPER_NO_SYSTEM_COMMANDS"] == "1" }

    // MARK: - Terminal

    static var stdinIsTerminal: Bool { isatty(STDIN_FILENO) == 1 }

    /// Asks a yes/no question on stderr and reads the answer from stdin. EOF (e.g. stdin is
    /// /dev/null) and anything but y/yes count as "no".
    static func confirm(_ question: String) -> Bool {
        fflush(stdout)   // print() is buffered when stdout isn't a terminal; keep the order readable
        FileHandle.standardError.write(Data("\(question) [y/N] ".utf8))
        guard let answer = readLine(strippingNewline: true) else {
            FileHandle.standardError.write(Data("\n".utf8))
            return false
        }
        // A piped answer isn't echoed by a terminal; show it so the transcript reads naturally.
        if !stdinIsTerminal { FileHandle.standardError.write(Data("\(answer)\n".utf8)) }
        return ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespaces).lowercased())
    }

    // MARK: - Processes

    struct RunningProcess: Equatable { var pid: pid_t; var path: String }

    /// Processes of this user whose executable is called `name` (libproc; no `ps`, no AppKit).
    static func processes(named name: String) -> [RunningProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        let uid = getuid()
        var result: [RunningProcess] = []
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) isn't imported into Swift.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            guard (path as NSString).lastPathComponent == name else { continue }
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            if proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_uid != uid { continue }
            result.append(RunningProcess(pid: pid, path: path))
        }
        return result
    }
}

/// In-memory preferences for LIVEPAPER_NO_SYSTEM_COMMANDS=1 (tests): reads see what was written.
final class InMemoryPreferences: PreferencesAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    func value(domain: String, key: String, currentHost: Bool) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values["\(currentHost)|\(domain)|\(key)"]
    }

    func set(_ value: Any?, domain: String, key: String, currentHost: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        values["\(currentHost)|\(domain)|\(key)"] = value
        return true
    }
}

/// A login-item registrar that is never available, so InstallService uses only launchctl (which
/// LIVEPAPER_NO_SYSTEM_COMMANDS records) — SMAppService can't be faked from outside the app.
struct UnavailableLoginItem: LoginItemRegistering {
    var isAvailable: Bool { false }
    var status: LoginItemStatus { .notFound }
    func register() throws -> LoginItemStatus { .notFound }
    func unregister() throws {}
}

/// The services every command uses. Built lazily (after `CLIEnvironment.pinLocations()`), once.
enum CLIServices {
    static let live = LivePaperServices.live()

    /// The installer: the live one, or — dry run / LIVEPAPER_NO_SYSTEM_COMMANDS — one that plans or
    /// records instead of changing the system.
    static func installer(dryRun: Bool = false) -> InstallService {
        let live = (Self.live.install as? InstallService) ?? InstallService(publisher: Self.live.publish)
        if CLIEnvironment.noSystemCommands {
            return InstallService(paths: live.paths, publisher: Self.live.publish, runner: sandboxRunner,
                                  loginItem: UnavailableLoginItem(), preferences: sandboxPreferences, dryRun: dryRun,
                                  accessibility: { false })
        }
        guard dryRun else { return live }
        return InstallService(paths: live.paths, publisher: nil, dryRun: true)
    }

    /// Preferences the CLI itself reads or restores (the lock-keys setting).
    static var preferences: PreferencesAccessing { CLIEnvironment.noSystemCommands ? sandboxPreferences : SystemPreferences() }

    private static let sandboxPreferences = InMemoryPreferences()

    /// Records system commands; answers like a Mac where LivePaper's helper was never loaded
    /// (`launchctl print` fails) and everything else succeeds silently.
    private static let sandboxRunner = RecordingCommandRunner { executable, arguments in
        executable == "/bin/launchctl" && arguments.first == "print"
            ? CommandResult(status: 113, stderr: "Could not find service in domain") : nil
    }
}
