// CommandRouter — subcommand registry, argument parsing and help for the `livepaper` CLI.
//
// To add commands, create a file with `enum MyCommands { static var all: [CLICommand] }` and list
// it in `CLI.groups`. Commands get pre-split arguments and return an exit code.
import Foundation
import LivePaperCore

/// Exit codes shared by every command (documented in Runtime/AGENTS.md).
enum ExitCode {
    static let ok: Int32 = 0
    /// The scene has problems (check failed, JS errors, compile errors).
    static let failed: Int32 = 1
    static let usage: Int32 = 2
    /// LivePaper itself could not do the work (render server unavailable, missing runtime…).
    static let unavailable: Int32 = 3
}

struct UsageError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Parsed command-line arguments: positionals, `--flag`s and `--option value` / `--option=value`.
struct Arguments {
    var positional: [String] = []
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ args: [String], flags allowedFlags: Set<String> = [], options allowedOptions: Set<String> = []) throws {
        var rest = args[...]
        while let arg = rest.popFirst() {
            // `--` ends the options: everything after it is positional (e.g. a prompt starting with "--").
            if arg == "--" { positional.append(contentsOf: rest); break }
            guard arg.hasPrefix("--"), arg.count > 2 else { positional.append(arg); continue }
            var name = String(arg.dropFirst(2)), inline: String?
            if let eq = name.firstIndex(of: "=") { inline = String(name[name.index(after: eq)...]); name = String(name[..<eq]) }
            if allowedFlags.contains(name), inline == nil {
                flags.insert(name)
            } else if allowedOptions.contains(name) {
                guard let v = inline ?? rest.popFirst() else { throw UsageError("--\(name) needs a value") }
                values[name] = v
            } else {
                throw UsageError("unknown option --\(name)")
            }
        }
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func string(_ name: String) -> String? { values[name] }

    func double(_ name: String) throws -> Double? {
        guard let s = values[name] else { return nil }
        guard let v = Double(s), v.isFinite else { throw UsageError("--\(name) must be a number (got \"\(s)\")") }
        return v
    }

    func int(_ name: String) throws -> Int? {
        guard let s = values[name] else { return nil }
        guard let v = Int(s) else { throw UsageError("--\(name) must be a whole number (got \"\(s)\")") }
        return v
    }

    /// `--size 1512x982`
    func size(_ name: String) throws -> (width: Double, height: Double)? {
        guard let s = values[name] else { return nil }
        let parts = s.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else {
            throw UsageError("--\(name) must look like 1512x982 (got \"\(s)\")")
        }
        return (w, h)
    }

    /// Exactly one positional argument (e.g. the scene directory).
    func single(_ what: String) throws -> String {
        guard positional.count == 1, let p = positional.first else {
            throw UsageError(positional.isEmpty ? "missing \(what)" : "expected one \(what), got \(positional.count) arguments")
        }
        return p
    }
}

struct CLICommand {
    var name: String
    /// Arguments after the command name, e.g. "<dir.lpscene> [--quick]".
    var synopsis: String
    var summary: String
    var run: ([String]) async throws -> Int32
}

enum CLI {
    static var groups: [[CLICommand]] {
        [SceneCommands.all, LibraryCommands.all, AICommands.all, InstallCommands.all, ServerCommands.all]
    }
    static var commands: [CLICommand] { groups.flatMap { $0 } }
    static let groupTitles = ["Scenes", "Library & screen saver", "AI authoring", "Installation", "Render server"]

    static func main(_ argv: [String]) async -> Int32 {
        var args = Array(argv.dropFirst())
        guard let name = args.first, !["-h", "--help", "help"].contains(name) else {
            if args.count > 1, let cmd = commands.first(where: { $0.name == args[1] }) { printUsage(of: cmd); return ExitCode.ok }
            printHelp()
            return args.isEmpty ? ExitCode.usage : ExitCode.ok
        }
        if name == "--version" || name == "version" {
            print("livepaper \(CLIEnvironment.version.display) · LivePaper runtime API \(SceneCompiler.supportedRuntime)")
            return ExitCode.ok
        }
        args.removeFirst()
        // Run by an AI agent (AISessionPolicy): the scene commands only.
        if let refusal = AISessionPolicy.refusal(command: name) {
            stderr(refusal)
            return ExitCode.usage
        }
        guard let cmd = commands.first(where: { $0.name == name }) else {
            stderr("livepaper: unknown command '\(name)'. Run `livepaper help` for the list.")
            return ExitCode.usage
        }
        if args.contains("--help") || args.contains("-h") { printUsage(of: cmd); return ExitCode.ok }
        do {
            return try await cmd.run(args)
        } catch let e as AISessionPolicyError {
            stderr("livepaper \(cmd.name): \(e.message)")
            return ExitCode.usage
        } catch let e as UsageError {
            stderr("livepaper \(cmd.name): \(e.description)\nusage: livepaper \(cmd.name) \(cmd.synopsis)")
            return ExitCode.usage
        } catch let e as SceneCompileError {
            stderr("livepaper \(cmd.name): the scene does not compile:")
            for m in e.messages { stderr("  \(m)") }
            return ExitCode.failed
        } catch let e as LibraryError {
            // Unknown id, built-in (read-only) scene, invalid package: the request can't be done as asked.
            stderr("livepaper \(cmd.name): \(e.localizedDescription)")
            return ExitCode.failed
        } catch {
            stderr("livepaper \(cmd.name): \(error.localizedDescription)")
            return ExitCode.unavailable
        }
    }

    static func printHelp() {
        print("livepaper — create, validate and publish LivePaper scenes\n\nusage: livepaper <command> [options]")
        let width = commands.map(\.name.count).max() ?? 8
        for (title, group) in zip(groupTitles, groups) {
            print("\n\(title):")
            for c in group { print("  \(c.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(c.summary)") }
        }
        print("\nRun `livepaper help <command>` for a command's options; `livepaper --version` for the version.")
    }

    static func printUsage(of c: CLICommand) {
        print("usage: livepaper \(c.name) \(c.synopsis)\n\n\(c.summary)")
    }
}

func stderr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// `path` relative to the working directory when it is inside it (shorter, and what agents type).
func displayPath(_ url: URL) -> String {
    // Compare resolved paths: /tmp vs /private/tmp and friends.
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
    let p = url.standardizedFileURL.resolvingSymlinksInPath().path
    return p.hasPrefix(cwd + "/") ? String(p.dropFirst(cwd.count + 1)) : url.standardizedFileURL.path
}
