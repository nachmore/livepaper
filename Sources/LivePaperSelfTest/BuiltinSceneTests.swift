// Self tests for the built-in example scenes in Scenes/ (shipped in LivePaper.app/Contents/Resources/Scenes).
//
// These are static checks of the packages as committed: manifest, compile (runtime inlined, source
// scan), thumbnail, provenance and hygiene. Rendering budgets are `livepaper check`'s job and need
// the render server, which tests never start; the numbers it measured are required to be recorded
// in each scene.json instead. See docs/SCENES.md.
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
    ] }
}

private enum BuiltinScenes {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let directory = repo.appendingPathComponent("Scenes")
    static let minimumCount = 5
    static let allowedEntries: Set<String> = ["scene.json", "scene.js", "thumbnail.jpg", "history.jsonl", "assets"]

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
