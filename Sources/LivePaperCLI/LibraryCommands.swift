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
            CLICommand(name: "import", synopsis: "<video.mov|.mp4|.m4v | scene.lpscene | scene.zip | collection.lpcollection> [--name <name>] [--battery] [--json]",
                       summary: "add a video (as a video scene), a scene package or a collection file to the library", run: importItem),
            CLICommand(name: "publish",
                       synopsis: "[--scenes <id,id,…>|all | --collection <collection>|none] [--mode shuffle|sequence|single] [--cycle <minutes>] " +
                                 "[--performance automatic|best|balanced|battery] [--clock|--no-clock] " +
                                 "[--displays same|different|choose|span] [--display <display-uuid>=<scene-id>|playlist]… " +
                                 "[--battery-displays live|still|off] [--json]",
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
        let selection = services.publish.loadSettings().following(services.collections.collections()).sceneIDs
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
        if url.pathExtension.lowercased() == CollectionArchive.fileExtension {
            if args.flag("battery") || args.string("name") != nil { throw UsageError("--name and --battery don't apply to collections") }
            return try CollectionCommands.importFile([path] + (args.flag("json") ? ["--json"] : []))
        }
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
        struct Displays: Encodable {
            var mode: String
            var onBattery: String
            var assignments: [String: String]
        }
        var generation: Int
        var mode: String
        var cycleMinutes: Int
        var showClock: Bool
        var performance: String
        var scenes: [String]
        var skipped: [String: String]
        var saver: String
        /// The collection the playlist follows (its id and name), if any.
        var collection: String?
        var collectionName: String?
        /// Multiple displays as published (assignments only in "choose" mode, and only to published scenes).
        var displays: Displays
        /// Scenes published only for displays assigned to them.
        var displayScenes: [String]
        /// Scenes that stretch across displays in "span" mode (the others show on every display).
        var spanScenes: [String]
    }

    static let displaysUsage = "--displays must be same, different, choose or span"
    static let batteryDisplaysUsage = "--battery-displays must be live, still or off"
    static let displayUsage = "--display needs <display-uuid>=<scene-id> (or <display-uuid>=playlist, all=playlist)"

    static func publish(_ argv: [String]) async throws -> Int32 {
        let args = try Arguments(argv, flags: ["clock", "no-clock", "json"],
                                 options: ["scenes", "collection", "mode", "cycle", "performance", "displays", "display", "battery-displays"])
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
        if args.string("scenes") != nil && args.string("collection") != nil { throw UsageError("use either --scenes or --collection") }
        if let list = args.string("scenes") {
            settings.sceneIDs = try sceneSelection(list, library: services.library)
            settings.collectionID = nil
        }
        if let name = args.string("collection") {
            if name.lowercased() == "none" {
                // Stop following: the scenes it has now stay, as a list.
                settings = settings.following(services.collections.collections())
                settings.collectionID = nil
            } else {
                let c = try CollectionCommands.resolve(name)
                settings.collectionID = c.id
                settings.sceneIDs = c.sceneIDs
                if settings.mode == .single && c.sceneIDs.count > 1 { settings.mode = .sequence }
            }
        }
        if let mode = args.string("displays") {
            guard let m = LPDisplayMode(rawValue: mode) else { throw UsageError(displaysUsage) }
            settings.displays.mode = m
        }
        if let battery = args.string("battery-displays") {
            guard let b = LPBatteryDisplays(rawValue: battery) else { throw UsageError(batteryDisplaysUsage) }
            settings.displays.onBattery = b
        }
        let displayArguments = args.strings("display")
        if !displayArguments.isEmpty {
            settings.displays.assignments = try displayAssignments(displayArguments, current: settings.displays.assignments,
                                                                   library: services.library)
            // The app remembers names only for displays that have a scene.
            settings.displayNames = settings.displayNames.filter { settings.displays.assignments[$0.key] != nil }
        }
        if settings != before { try services.publish.saveSettings(settings) }
        if !settings.displays.assignments.isEmpty && settings.displays.mode != .choose && (!displayArguments.isEmpty || args.string("displays") != nil) {
            stderr("note: per-display scenes apply with --displays choose")
        }

        let playlist: LPPlaylist, skipped: [String: String]
        if let concrete = services.publish as? PublishService {
            let result = try concrete.publishReport()
            playlist = result.playlist; skipped = result.skipped
        } else {
            playlist = try services.publish.publish(); skipped = [:]
        }
        let followed = settings.collectionID.flatMap { services.collections.collection(id: $0) }
        if args.flag("json") {
            let d = playlist.displays
            printJSONObject(PublishSummary(generation: playlist.generation, mode: playlist.mode.rawValue, cycleMinutes: playlist.cycleMinutes,
                                           showClock: playlist.showClock, performance: playlist.performance.rawValue,
                                           scenes: playlist.scenes.map(\.id), skipped: skipped, saver: LPPaths.installedSaver.path,
                                           collection: followed?.id, collectionName: followed?.name,
                                           displays: .init(mode: d.mode.rawValue, onBattery: d.onBattery.rawValue, assignments: d.assignments),
                                           displayScenes: playlist.displayScenes.map(\.id),
                                           spanScenes: (playlist.scenes + playlist.displayScenes).filter { $0.span == true }.map(\.id)))
        } else {
            let n = playlist.scenes.count
            print("published \(n) scene\(n == 1 ? "" : "s") into \(displayPath(LPPaths.installedSaver)) (generation \(playlist.generation))")
            print("  \(describe(playlist))")
            if let followed {
                print("  plays the collection \u{201C}\(followed.name)\u{201D} (changes to it update the screen saver)" +
                      (followed.sceneIDs.isEmpty ? "; it's empty, so every scene plays" : ""))
            }
            print("  scenes: " + playlist.scenes.map(\.id).joined(separator: ", "))
            for (display, scene) in playlist.displays.assignments.sorted(by: { $0.key < $1.key }) {
                print("  display \(display): \(scene)")
            }
            if playlist.displays.mode == .span {
                let spanning = playlist.scenes.filter { $0.span == true }.map(\.id)
                print("  spanning displays: " + (spanning.isEmpty ? "none (every scene shows on every display)" : spanning.joined(separator: ", ")))
            }
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

    /// `--display` values applied to `current`: `<uuid>=<scene>` assigns, `<uuid>=playlist` removes,
    /// `all=playlist` clears. Display ids are UUIDs (as `livepaper doctor` and the app show them) or
    /// "display-<n>" for displays without one; scene ids must exist.
    static func displayAssignments(_ values: [String], current: [String: String], library: LibraryServicing) throws -> [String: String] {
        var assignments = current
        var known: Set<String>?
        for value in values {
            guard let eq = value.firstIndex(of: "=") else { throw UsageError(displayUsage) }
            let display = value[..<eq].trimmingCharacters(in: .whitespaces)
            let scene = value[value.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !display.isEmpty, !scene.isEmpty else { throw UsageError(displayUsage) }
            if display.lowercased() == "all" {
                guard scene == "playlist" else { throw UsageError(displayUsage) }
                assignments = [:]
                continue
            }
            let isFallback = display.lowercased().hasPrefix("display-") && Int(display.dropFirst(8)) != nil
            guard UUID(uuidString: display) != nil || isFallback else {
                throw UsageError("--display: \"\(display)\" is not a display UUID (like 37D8832A-2D66-02CA-B9F7-8F30A301B230). " + displayUsage)
            }
            let key = LPDisplay.normalizedID(display)
            if scene == "playlist" {
                assignments.removeValue(forKey: key)
                continue
            }
            if known == nil { known = Set(try library.scenes().map(\.id)) }
            guard known?.contains(scene) == true else { throw UsageError("unknown scene id: \(scene) (see `livepaper list`)") }
            assignments[key] = scene
        }
        return LPDisplaySettings.normalized(assignments)
    }

    /// "shuffle · a new scene every 5 min · clock on · automatic performance" (+ the display mode and
    /// the battery behaviour when they aren't the defaults).
    static func describe(_ p: LPPlaylist) -> String {
        let cycle = p.cycleMinutes == 0 ? "one scene per run" : "a new scene every \(p.cycleMinutes) min"
        var parts = [p.mode.rawValue, cycle, p.showClock ? "clock on" : "clock off", "\(p.performance.rawValue) performance"]
        switch p.displays.mode {
        case .same: break
        case .different: parts.append("different on each display")
        case .choose: parts.append("chosen per display")
        case .span: parts.append("spans displays")
        }
        switch p.displays.onBattery {
        case .live: break
        case .still: parts.append("other displays still on battery")
        case .off: parts.append("other displays off on battery")
        }
        return parts.joined(separator: " · ")
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
