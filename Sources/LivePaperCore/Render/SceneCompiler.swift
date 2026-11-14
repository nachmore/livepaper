// SceneCompiler — web scene package → one self-contained HTML file (runtime + scene.js + assets
// inlined). The same HTML is what the render server checks and what the saver publishes, so a scene
// that passes `livepaper check` runs identically on the lock screen. Owner: WS-runtime.
import Foundation

/// Placeholder error for APIs that other workstreams have not implemented yet.
public struct NotImplemented: Error, LocalizedError {
    public let what: String
    public init(_ w: String) { what = w }
    public var errorDescription: String? { "\(what) is not implemented yet" }
}

/// Why a scene could not be compiled. Each issue is one actionable sentence with a file location.
public struct SceneCompileError: Error, LocalizedError, Sendable, Equatable {
    public var issues: [SceneSourceIssue]
    public init(_ issues: [SceneSourceIssue]) { self.issues = issues }
    public init(file: String, line: Int = 0, column: Int = 0, _ message: String) {
        issues = [SceneSourceIssue(file: file, line: line, column: column, message: message)]
    }
    /// Issue texts without the `file:0:0:` prefix for package-level problems.
    public var messages: [String] {
        issues.map { $0.line > 0 ? $0.description : "\($0.file): \($0.message)" }
    }
    public var errorDescription: String? { messages.joined(separator: "\n") }
}

/// The result of compiling a package in memory.
public struct CompiledScene: Sendable {
    public var html: String
    public var manifest: SceneManifest
    /// Total bytes of inlined assets (before base64).
    public var assetBytes: Int
}

public final class SceneCompiler: SceneCompiling, @unchecked Sendable {
    /// Runtime API major version this compiler inlines.
    public static let supportedRuntime = 1
    public static let sceneFile = "scene.js"
    public static let assetsDirectory = "assets"
    public static let maxSceneBytes = 4 << 20
    public static let maxAssetFileBytes = 4 << 20
    public static let maxAssetTotalBytes = 8 << 20

    /// Asset types that may be inlined, by lowercase extension.
    public static let assetTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp", "gif": "image/gif",
        "avif": "image/avif", "svg": "image/svg+xml",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "json": "application/json", "txt": "text/plain", "csv": "text/csv",
        "glsl": "text/plain", "vert": "text/plain", "frag": "text/plain", "bin": "application/octet-stream",
    ]
    static let textAssetExtensions: Set<String> = ["svg", "json", "txt", "csv", "glsl", "vert", "frag"]

    /// Enforced at run time on top of the compile-time scan: no network, no external anything.
    /// (WKUserScripts and the host's evaluateJavaScript are not subject to page CSP.)
    public static let contentSecurityPolicy =
        "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; " +
        "font-src data:; media-src 'none'; connect-src 'none'; worker-src blob:; child-src blob:; " +
        "frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"

    public let runtimeDir: URL

    public init(runtimeDir: URL = SceneCompiler.defaultRuntimeDir) { self.runtimeDir = runtimeDir }

    /// The bundled Runtime/ directory, or — for `swift run` / `.build` executables during development —
    /// the repository's Runtime/ found by walking up from the executable.
    public static var defaultRuntimeDir: URL {
        let fm = FileManager.default
        let bundled = LPPaths.runtimeDir
        if fm.fileExists(atPath: bundled.appendingPathComponent("runtime.js").path) { return bundled }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Runtime")
            if fm.fileExists(atPath: candidate.appendingPathComponent("runtime.js").path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return bundled
    }

    public func compile(package: URL, to output: URL) throws {
        let compiled = try build(package: package)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(compiled.html.utf8).write(to: output, options: .atomic)
    }

    /// Compiles a web scene package in memory.
    public func build(package: URL) throws -> CompiledScene {
        let pkg = package.standardizedFileURL.resolvingSymlinksInPath()
        let manifest = try Self.loadManifest(pkg)
        guard manifest.kind == .web else {
            throw SceneCompileError(file: SceneManifest.fileName, "kind is \"\(manifest.kind.rawValue)\"; only web scenes are compiled to HTML.")
        }
        let runtimeVersion = manifest.runtime ?? Self.supportedRuntime
        guard runtimeVersion == Self.supportedRuntime else {
            throw SceneCompileError(file: SceneManifest.fileName,
                                    "\"runtime\": \(runtimeVersion) is not supported; this LivePaper provides runtime \(Self.supportedRuntime).")
        }
        let sceneJS = try Self.readSceneJS(pkg)
        var issues = SceneSourceScanner.scanJavaScript(sceneJS, file: Self.sceneFile)
        if !SceneSourceScanner.mentionsLivePaper(sceneJS) {
            issues.append(SceneSourceIssue(file: Self.sceneFile, line: 0, column: 0,
                                           message: "never calls LivePaper.scene({...}); every scene must register exactly once."))
        }
        let (assets, assetBytes, assetIssues) = Self.collectAssets(pkg)
        issues += assetIssues
        guard issues.isEmpty else { throw SceneCompileError(issues) }

        let runtimeURL = runtimeDir.appendingPathComponent("runtime.js")
        guard let runtime = try? String(contentsOf: runtimeURL, encoding: .utf8) else {
            throw SceneCompileError(file: "runtime.js", "LivePaper's runtime was not found at \(runtimeURL.path) (installation problem, not a scene problem).")
        }
        let html = Self.assemble(manifest: manifest, runtime: runtime, sceneJS: sceneJS, assets: assets)
        return CompiledScene(html: html, manifest: manifest, assetBytes: assetBytes)
    }

    // MARK: - Assembly

    /// Builds the HTML document. `assets` maps asset names to data: URLs.
    static func assemble(manifest: SceneManifest, runtime: String, sceneJS: String, assets: [String: String]) -> String {
        let assetsJSON = jsonForScript(assets)
        var head = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="LivePaper runtime \(supportedRuntime)">
        <title>\(escapeHTML(manifest.name))</title>

        """
        // The scene's first line number in this document lets the runtime map error positions back
        // to scene.js when the engine ignores //# sourceURL. It is computed after the prefix is built.
        let runtimeBlock = "<script>\n\(escapeForInlineScript(runtime))\n</script>\n</head>\n<body>\n<script>\n"
        func metaBlock(line: Int) -> String {
            let meta: [String: Any] = ["id": manifest.id, "name": manifest.name, "clock": manifest.clock.position.rawValue,
                                       "runtime": manifest.runtime ?? supportedRuntime, "line": line]
            return "<script>window.LIVEPAPER_SCENE = \(jsonForScript(meta));\nwindow.LIVEPAPER_ASSETS = \(assetsJSON);</script>\n"
        }
        let probe = head + metaBlock(line: 0) + runtimeBlock
        let sceneLine = probe.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        head += metaBlock(line: sceneLine) + runtimeBlock
        return head + escapeForInlineScript(sceneJS) + "\n//# sourceURL=scene.js\n</script>\n</body>\n</html>\n"
    }

    /// Makes JavaScript safe inside `<script>…</script>`: the HTML parser ends the element at the first
    /// `</script` and enters a special state at `<!--`. `\x3C` is `<` in strings, template literals and
    /// regular expressions (including /u), and those sequences cannot appear in code positions anyway.
    public static func escapeForInlineScript(_ js: String) -> String {
        var out = js.replacingOccurrences(of: "<!--", with: "\\x3C!--")
        out = out.replacingOccurrences(of: "</script", with: "\\x3C/script", options: .caseInsensitive)
        return out
    }

    /// JSON that can be embedded in a script element (no `<`, no raw line separators).
    static func jsonForScript(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Package reading

    static func loadManifest(_ pkg: URL) throws -> SceneManifest {
        let url = pkg.appendingPathComponent(SceneManifest.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SceneCompileError(file: SceneManifest.fileName, "is missing; a scene package needs scene.json next to scene.js.")
        }
        do {
            return try SceneManifest.load(package: pkg)
        } catch let DecodingError.dataCorrupted(ctx) where !ctx.codingPath.isEmpty {
            // Valid JSON, invalid value (e.g. an unknown clock position or kind).
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            throw SceneCompileError(file: SceneManifest.fileName, "field \"\(path)\" has an invalid value (\(ctx.debugDescription))\(Self.allowedValues(path)).")
        } catch let DecodingError.dataCorrupted(ctx) {
            throw SceneCompileError(file: SceneManifest.fileName, "is not valid JSON (\(Self.underlyingMessage(ctx))).")
        } catch let DecodingError.keyNotFound(key, _) {
            throw SceneCompileError(file: SceneManifest.fileName, "is missing the required \"\(key.stringValue)\" field.")
        } catch let DecodingError.typeMismatch(_, ctx), let DecodingError.valueNotFound(_, ctx) {
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            throw SceneCompileError(file: SceneManifest.fileName, "field \"\(path)\" has the wrong type (\(ctx.debugDescription)).")
        } catch {
            throw SceneCompileError(file: SceneManifest.fileName, "could not be read: \(error.localizedDescription)")
        }
    }

    private static func underlyingMessage(_ ctx: DecodingError.Context) -> String {
        if let e = ctx.underlyingError as NSError?, let d = e.userInfo[NSDebugDescriptionErrorKey] as? String { return d }
        return ctx.debugDescription
    }

    private static func allowedValues(_ path: String) -> String {
        switch path {
        case "clock.position": return "; use one of: " + LPClockPosition.allCases.map(\.rawValue).joined(separator: ", ")
        case "kind": return "; use \"web\" or \"video\""
        default: return ""
        }
    }

    static func readSceneJS(_ pkg: URL) throws -> String {
        let url = pkg.appendingPathComponent(sceneFile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SceneCompileError(file: sceneFile, "is missing; web scenes keep all their code in scene.js.")
        }
        try ensureInside(pkg, url, name: sceneFile)
        let data = try Data(contentsOf: url)
        guard data.count <= maxSceneBytes else {
            throw SceneCompileError(file: sceneFile, "is \(data.count / 1024) KB; the limit is \(maxSceneBytes / 1024) KB.")
        }
        guard let js = String(data: data, encoding: .utf8) else {
            throw SceneCompileError(file: sceneFile, "is not valid UTF-8 text.")
        }
        guard !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SceneCompileError(file: sceneFile, "is empty.")
        }
        return js
    }

    /// Symlinks must not smuggle files from outside the package into published HTML.
    static func ensureInside(_ pkg: URL, _ url: URL, name: String) throws {
        let resolved = url.resolvingSymlinksInPath().path
        let root = pkg.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(root + "/") else {
            throw SceneCompileError(file: name, "points outside the scene package (symlink); copy the file into the package instead.")
        }
    }

    /// Reads assets/ (recursively, skipping hidden files) into data: URLs.
    static func collectAssets(_ pkg: URL) -> ([String: String], Int, [SceneSourceIssue]) {
        let fm = FileManager.default
        let dir = pkg.appendingPathComponent(assetsDirectory)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return ([:], 0, []) }
        var assets: [String: String] = [:], total = 0, issues: [SceneSourceIssue] = []
        func problem(_ file: String, _ message: String, line: Int = 0) {
            issues.append(SceneSourceIssue(file: file, line: line, column: 0, message: message))
        }
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                         options: [.skipsHiddenFiles]) else { return ([:], 0, []) }
        let rootPath = dir.standardizedFileURL.path
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let resolved = url.resolvingSymlinksInPath()
            let path = url.standardizedFileURL.path
            let name = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : url.lastPathComponent
            let display = "assets/" + name
            if values?.isSymbolicLink == true, !resolved.path.hasPrefix(pkg.resolvingSymlinksInPath().path + "/") {
                problem(display, "points outside the scene package (symlink); copy the file into assets/ instead.")
                continue
            }
            guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let ext = resolved.pathExtension.lowercased()
            guard let mime = assetTypes[ext] else {
                problem(display, "has an unsupported type (.\(ext)). Allowed: \(assetTypes.keys.sorted().joined(separator: ", ")).")
                continue
            }
            guard let data = try? Data(contentsOf: resolved) else { problem(display, "could not be read."); continue }
            if data.count > maxAssetFileBytes {
                problem(display, "is \(data.count / 1024) KB; each asset must be at most \(maxAssetFileBytes / 1024) KB.")
                continue
            }
            total += data.count
            if textAssetExtensions.contains(ext) {
                guard let text = String(data: data, encoding: .utf8) else { problem(display, "is not valid UTF-8 text."); continue }
                issues += SceneSourceScanner.scanText(text, file: display)
            }
            assets[name] = "data:\(mime);base64,\(data.base64EncodedString())"
        }
        if total > maxAssetTotalBytes {
            problem("assets/", "total \(total / 1024) KB; all assets together must be at most \(maxAssetTotalBytes / 1024) KB. Shrink or drop images (draw procedurally where you can).")
        }
        return (assets, total, issues)
    }
}

extension SceneSourceScanner {
    /// True if the code (not just a comment) references the LivePaper namespace.
    static func mentionsLivePaper(_ source: String) -> Bool {
        JSTokenizer.tokens(source).contains { $0.kind == .identifier && $0.text == "LivePaper" }
    }
}
