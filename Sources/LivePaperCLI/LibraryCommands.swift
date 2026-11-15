// LibraryCommands — new / list / import / publish: the scene library and what the screen saver shows.
import Foundation
import LivePaperCore

enum LibraryCommands {
    static var all: [CLICommand] {
        [
            CLICommand(name: "new", synopsis: "<name> [--from <scene-id>] [--description <text>] [--json]",
                       summary: "scaffold a new web scene in the library (or clone one with --from)", run: new),
            CLICommand(name: "list", synopsis: "[--json]",
                       summary: "list the library's scenes (yours first, then the built-in ones)", run: list),
            CLICommand(name: "import", synopsis: "<video.mov|.mp4|.m4v | scene.lpscene | scene.zip> [--name <name>] [--battery] [--json]",
                       summary: "add a video (as a video scene) or a scene package to the library", run: importItem),
            CLICommand(name: "publish",
                       synopsis: "[--scenes <id,id,…>|all] [--mode shuffle|sequence|single] [--cycle <minutes>] " +
                                 "[--performance automatic|best|balanced|battery] [--clock|--no-clock] [--json]",
                       summary: "update the playlist settings (optional) and publish the scenes into the installed screen saver",
                       run: publish),
        ]
    }

    // MARK: - new

    static func new(_ argv: [String]) async throws -> Int32 {
        let args = try Arguments(argv, flags: ["json"], options: ["from", "description"])
        let requested = try args.single("scene name")
        let library = CLIServices.live.library
        let name = displayName(for: requested)
        var item: SceneItem
        if let source = args.string("from") {
            guard try library.scene(id: source) != nil else {
                throw LibraryError.notFound("\(source). Run `livepaper list` to see the scene ids.")
            }
            item = try library.clone(id: source, newName: name)
            if let description = args.string("description") {
                var m = item.manifest
                m.description = description
                try library.update(m)
                item = try library.scene(id: item.id) ?? item
            }
        } else {
            item = try library.createWebScene(name: name, description: args.string("description") ?? "")
        }
        if args.flag("json") {
            printJSONObject(SceneSummary(item, inPlaylist: nil))
        } else {
            let origin = item.manifest.parent.map { " from \($0)" } ?? ""
            print("created \u{201C}\(item.manifest.name)\u{201D} (\(item.id))\(origin)")
            print("  \(displayPath(item.packageURL))")
            if item.manifest.kind == .web {
                print("next: edit \(displayPath(item.packageURL.appendingPathComponent("scene.js"))), " +
                      "then run `livepaper check \(shellQuoted(displayPath(item.packageURL)))`")
            }
        }
        return ExitCode.ok
    }

    /// "aurora-lake" → "Aurora Lake" (an id-style argument gets a readable name; the id comes out
    /// the same); anything else is used as typed.
    static func displayName(for argument: String) -> String {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SceneManifest.isValidID(trimmed), trimmed.contains(where: \.isLetter) else { return trimmed }
        return trimmed.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: - list

    /// One scene as `list --json` / `new --json` / `import --json` print it.
    struct SceneSummary: Encodable {
        var id: String
        var name: String
        var description: String
        var kind: String
        var builtin: Bool
        var path: String
        var parent: String?
        var tags: [String]
        var benchMs: Double?
        var energyMw: Double?
        var checkedAt: Date?
        var updated: Date?
        /// Whether the playlist settings include it (an empty selection means every scene).
        var inPlaylist: Bool?

        init(_ item: SceneItem, inPlaylist: Bool?) {
            let m = item.manifest
            id = item.id; name = m.name; description = m.description; kind = m.kind.rawValue; builtin = item.isBuiltin
            path = item.packageURL.path; parent = m.parent; tags = m.tags
            benchMs = m.performance?.benchMs; energyMw = m.performance?.energyMw; checkedAt = m.performance?.checkedAt
            updated = m.updated; self.inPlaylist = inPlaylist
        }
    }

    static func list(_ argv: [String]) async throws -> Int32 {
        let args = try Arguments(argv, flags: ["json"])
        guard args.positional.isEmpty else { throw UsageError("list takes no arguments") }
        let services = CLIServices.live
        let scenes = try services.library.scenes()
        let selection = services.publish.loadSettings().sceneIDs
        let inPlaylist = { (id: String) in selection.isEmpty || selection.contains(id) }
        if args.flag("json") {
            printJSONObject(scenes.map { SceneSummary($0, inPlaylist: inPlaylist($0.id)) })
            return ExitCode.ok
        }
        guard !scenes.isEmpty else {
            print("The library is empty (\(displayPath(LPPaths.library))). Create a scene with `livepaper new <name>` " +
                  "or `livepaper ai create \"<prompt>\"`.")
            return ExitCode.ok
        }
        let rows = scenes.map { s -> [String] in
            let perf = s.manifest.performance?.benchMs.map { fmt($0, 1) + " ms" } ?? (s.manifest.kind == .video ? "video" : "unchecked")
            return [inPlaylist(s.id) ? "●" : " ", s.id, s.manifest.name, s.manifest.kind.rawValue, s.isBuiltin ? "built-in" : "yours", perf]
        }
        printTable(header: [" ", "ID", "NAME", "KIND", "SOURCE", "FRAME TIME"], rows: rows)
        let user = scenes.filter { !$0.isBuiltin }.count
        print("\n\(user) of yours, \(scenes.count - user) built-in · ● = in the playlist" +
              (selection.isEmpty ? " (all scenes)" : "") + " · library: \(displayPath(LPPaths.library))")
        return ExitCode.ok
    }

    // MARK: - import

    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    static func importItem(_ argv: [String]) async throws -> Int32 {
        let args = try Arguments(argv, flags: ["battery", "json"], options: ["name"])
        let path = try args.single("file to import")
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw UsageError("\(path) doesn't exist") }
        let library = CLIServices.live.library
        let item: SceneItem
        if videoExtensions.contains(url.pathExtension.lowercased()) {
            let name = args.string("name") ?? url.deletingPathExtension().lastPathComponent
            let progress = ProgressLine(enabled: !args.flag("json"), label: args.flag("battery") ? "converting for battery" : "importing")
            item = try await library.importVideo(from: url, name: name, optimizeForBattery: args.flag("battery")) { progress.update($0) }
            progress.finish()
        } else {
            if args.flag("battery") { throw UsageError("--battery applies to videos only") }
            item = try library.importPackage(at: url)
            if let name = args.string("name") {
                var m = item.manifest
                m.name = name
                try library.update(m)
            }
        }
        let imported = try library.scene(id: item.id) ?? item
        if args.flag("json") {
            printJSONObject(SceneSummary(imported, inPlaylist: nil))
        } else {
            print("imported \u{201C}\(imported.manifest.name)\u{201D} (\(imported.id), \(imported.manifest.kind.rawValue))")
            print("  \(displayPath(imported.packageURL))")
            print("next: `livepaper publish` puts it in the screen saver")
        }
        return ExitCode.ok
    }

    // MARK: - publish

    struct PublishSummary: Encodable {
        var generation: Int
        var mode: String
        var cycleMinutes: Int
        var showClock: Bool
        var performance: String
        var scenes: [String]
        var skipped: [String: String]
        var saver: String
    }

    static func publish(_ argv: [String]) async throws -> Int32 {
        let args = try Arguments(argv, flags: ["clock", "no-clock", "json"], options: ["scenes", "mode", "cycle", "performance"])
        guard args.positional.isEmpty else { throw UsageError("publish takes no positional arguments") }
        let services = CLIServices.live
        var settings = services.publish.loadSettings()
        let before = settings
        if let mode = args.string("mode") {
            guard let m = LPPlaylistMode(rawValue: mode) else { throw UsageError("--mode must be shuffle, sequence or single") }
            settings.mode = m
        }
        if let cycle = try args.int("cycle") {
            guard (0...1440).contains(cycle) else { throw UsageError("--cycle must be 0 (never change) … 1440 minutes") }
            settings.cycleMinutes = cycle
        }
        if let profile = args.string("performance") {
            guard let p = LPPerformanceProfile(rawValue: profile) else {
                throw UsageError("--performance must be automatic, best, balanced or battery")
            }
            settings.performance = p
        }
        if args.flag("clock") && args.flag("no-clock") { throw UsageError("use either --clock or --no-clock") }
        if args.flag("clock") { settings.showClock = true }
        if args.flag("no-clock") { settings.showClock = false }
        if let list = args.string("scenes") {
            settings.sceneIDs = try sceneSelection(list, library: services.library)
        }
        if settings != before { try services.publish.saveSettings(settings) }

        let playlist: LPPlaylist, skipped: [String: String]
        if let concrete = services.publish as? PublishService {
            let result = try concrete.publishReport()
            playlist = result.playlist; skipped = result.skipped
        } else {
            playlist = try services.publish.publish(); skipped = [:]
        }
        if args.flag("json") {
            printJSONObject(PublishSummary(generation: playlist.generation, mode: playlist.mode.rawValue, cycleMinutes: playlist.cycleMinutes,
                                           showClock: playlist.showClock, performance: playlist.performance.rawValue,
                                           scenes: playlist.scenes.map(\.id), skipped: skipped, saver: LPPaths.installedSaver.path))
        } else {
            let n = playlist.scenes.count
            print("published \(n) scene\(n == 1 ? "" : "s") into \(displayPath(LPPaths.installedSaver)) (generation \(playlist.generation))")
            print("  \(describe(playlist))")
            print("  scenes: " + playlist.scenes.map(\.id).joined(separator: ", "))
            for (id, why) in skipped.sorted(by: { $0.key < $1.key }) { print("  skipped \(id): \(why)") }
            print("The screen saver picks it up the next time it starts.")
        }
        return skipped.isEmpty ? ExitCode.ok : ExitCode.failed
    }

    /// `all` → every scene (empty selection); otherwise comma-separated ids that must all exist.
    static func sceneSelection(_ list: String, library: LibraryServicing) throws -> [String] {
        if list.trimmingCharacters(in: .whitespaces).lowercased() == "all" { return [] }
        let ids = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !ids.isEmpty else { throw UsageError("--scenes needs scene ids (comma-separated) or \"all\"") }
        let known = Set(try library.scenes().map(\.id))
        let unknown = ids.filter { !known.contains($0) }
        guard unknown.isEmpty else {
            throw UsageError("unknown scene id\(unknown.count == 1 ? "" : "s"): \(unknown.joined(separator: ", ")) (see `livepaper list`)")
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// "shuffle · a new scene every 5 min · clock on · automatic performance"
    static func describe(_ p: LPPlaylist) -> String {
        let cycle = p.cycleMinutes == 0 ? "one scene per run" : "a new scene every \(p.cycleMinutes) min"
        return [p.mode.rawValue, cycle, p.showClock ? "clock on" : "clock off", "\(p.performance.rawValue) performance"]
            .joined(separator: " · ")
    }
}

// MARK: - Output helpers shared by the commands

/// Pretty JSON (sorted keys, ISO-8601 dates, unescaped slashes) on stdout.
func printJSONObject<T: Encodable>(_ value: T) {
    let encoder = SceneManifest.encoder()
    encoder.outputFormatting.insert(.withoutEscapingSlashes)
    if let data = try? encoder.encode(value) { print(String(decoding: data, as: UTF8.self)) }
}

/// Left-aligned columns separated by two spaces.
func printTable(header: [String], rows: [[String]]) {
    let all = [header] + rows
    let widths = header.indices.map { i in all.map { $0[i].count }.max() ?? 0 }
    for row in all {
        let cells = row.enumerated().map { i, cell in i == row.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
        var line = cells.joined(separator: "  ")
        while line.last == " " { line.removeLast() }
        print(line)
    }
}

/// Single-quotes a path for copy-and-paste into a shell when it needs it.
func shellQuoted(_ s: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./~@%+=:,")
    if !s.isEmpty, s.unicodeScalars.allSatisfy(safe.contains) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// A self-updating "importing… 42 %" line on stderr (only on a terminal; one final line otherwise).
final class ProgressLine: @unchecked Sendable {
    private let enabled: Bool
    private let label: String
    private let lock = NSLock()
    private var lastPercent = -1
    private let terminal = isatty(STDERR_FILENO) == 1

    init(enabled: Bool, label: String) { self.enabled = enabled; self.label = label }

    func update(_ fraction: Double) {
        guard enabled, terminal else { return }
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
        lock.lock(); defer { lock.unlock() }
        guard percent != lastPercent else { return }
        lastPercent = percent
        FileHandle.standardError.write(Data("\r  … \(label) \(percent) %".utf8))
    }

    func finish() {
        guard enabled else { return }
        FileHandle.standardError.write(Data((terminal ? "\r  … \(label) 100 %\n" : "  … \(label): done\n").utf8))
    }
}
