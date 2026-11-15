// RenderOutputPolicy — where the render server may write the files a request names (ARCHITECTURE §8).
//
// The render server runs outside any sandbox an AI agent works in (the app, or a LivePaperRenderd
// started before the agent), so a client must not be able to make it write wherever it likes: an
// agent confined to its workspace could otherwise overwrite any of the user's files with image data.
// A request's `out` must be
//
//   * still:     a .png in the `.check` folder that holds the request's html (where `livepaper
//                check`/`still` put them), in LivePaper's AI workspaces, or in a temporary directory;
//   * thumbnail: a .jpg/.jpeg in the scene package being rendered (or its .check), the AI
//                workspaces or a temporary directory.
//
// Symbolic links are resolved when the file is written, not before: the parent folder is opened,
// the opened folder's real path (F_GETPATH) is checked against the allowed roots, and the file is
// created and renamed relative to that descriptor, so swapping a folder for a link mid-request
// can't redirect the write. An existing destination must be a regular file (never a link or a
// folder). Foundation/Darwin only: the CLI links this too.
import Darwin
import Foundation

public struct RenderOutputError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct RenderOutputPolicy: Sendable {
    /// Explains the rule in refusals (clients show it to people and agents).
    public static let rule = "the render server only writes PNG stills into the scene's .check folder and JPEG thumbnails into the " +
        "scene package, LivePaper's AI workspaces or a temporary folder"

    public let supportRoot: URL
    public let temporaryDirectories: [URL]

    public init(supportRoot: URL = LPPaths.supportRoot,
                temporaryDirectories: [URL] = [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/tmp")]) {
        self.supportRoot = supportRoot
        self.temporaryDirectories = temporaryDirectories
    }

    /// File extensions `op` may write, or nil if it writes nothing.
    static func extensions(for op: RenderRequest.Op) -> Set<String>? {
        switch op {
        case .still: return ["png"]
        case .thumbnail: return ["jpg", "jpeg"]
        default: return nil
        }
    }

    /// Real paths of the folders (and everything below them) `request` may write into.
    public func allowedRoots(for request: RenderRequest) -> [String] {
        var roots = [supportRoot.appendingPathComponent("Workspaces")] + temporaryDirectories
        switch request.op {
        case .still:
            if let html = request.html, let real = Self.realPath(html) {
                let dir = URL(fileURLWithPath: real).deletingLastPathComponent()
                if dir.lastPathComponent == SceneChecker.checkDirectory { roots.append(dir) }
            }
        case .thumbnail:
            if let scene = request.scene, let real = Self.realPath(scene),
               FileOps.isRegularFile(URL(fileURLWithPath: real).appendingPathComponent(SceneManifest.fileName)) {
                roots.append(URL(fileURLWithPath: real))
            }
        default: break
        }
        return roots.compactMap { Self.realPath($0.path) }
    }

    /// Checks `request.out` without writing (so a refused request fails before any rendering).
    public func validate(_ request: RenderRequest) throws {
        _ = try plan(request)
    }

    /// Writes `data` to `request.out` (atomically: temp file + rename in the same folder) and
    /// returns the real path written.
    @discardableResult
    public func write(_ data: Data, for request: RenderRequest) throws -> URL {
        let (parent, name, roots) = try plan(request)
        let fd = try Self.openConfinedDirectory(parent, roots: roots, out: request.out ?? "")
        defer { close(fd) }
        var st = stat()
        if fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) != S_IFREG {
            throw RenderOutputError("refusing to write \(request.out ?? name): it exists and is not a regular file")
        }
        let tmp = ".\(name).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp"
        let out = openat(fd, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard out >= 0 else { throw RenderOutputError("cannot write \(request.out ?? name): \(String(cString: strerror(errno)))") }
        var ok = true
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(out, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; ok = false; return }
                offset += n
            }
        }
        close(out)
        guard ok, renameat(fd, tmp, fd, name) == 0 else {
            let e = errno
            unlinkat(fd, tmp, 0)
            throw RenderOutputError("cannot write \(request.out ?? name): \(String(cString: strerror(e)))")
        }
        return URL(fileURLWithPath: Self.descriptorPath(fd) ?? parent).appendingPathComponent(name)
    }

    // MARK: - Internals

    /// The (lexically normalised) parent folder and file name of `out`, after the checks that
    /// don't depend on the file system state at write time.
    private func plan(_ request: RenderRequest) throws -> (parent: String, name: String, roots: [String]) {
        guard let exts = Self.extensions(for: request.op) else {
            throw RenderOutputError("\(request.op.rawValue) requests don't write files")
        }
        guard let out = request.out, out.hasPrefix("/") else {
            throw RenderOutputError("\"out\" must be an absolute path (got \(request.out ?? "nothing"))")
        }
        guard !out.split(separator: "/").contains(where: { $0 == ".." }) else {
            throw RenderOutputError("\"out\" must not contain \"..\" (\(out))")
        }
        let url = URL(fileURLWithPath: out).standardizedFileURL
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/", exts.contains(url.pathExtension.lowercased()) else {
            throw RenderOutputError("refusing to write \(out): \(request.op.rawValue) output must be a \(exts.sorted().map { "." + $0 }.joined(separator: "/")) file")
        }
        let roots = allowedRoots(for: request)
        // Lexical pre-check (the real check happens on the opened folder): the nearest existing
        // ancestor must already lie inside a root, so no folder is ever created elsewhere.
        var ancestor = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" { ancestor = ancestor.deletingLastPathComponent() }
        guard let real = Self.realPath(ancestor.path), Self.isInside(real, roots) else {
            throw RenderOutputError("refusing to write \(out): \(Self.rule)")
        }
        return (url.deletingLastPathComponent().path, name, roots)
    }

    /// Creates the missing folders of `parent` (only below an ancestor inside a root, checked on each
    /// opened descriptor), opens `parent` and verifies its real location.
    private static func openConfinedDirectory(_ parent: String, roots: [String], out: String) throws -> Int32 {
        var existing = URL(fileURLWithPath: parent)
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var fd = open(existing.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw RenderOutputError("cannot open \(existing.path): \(String(cString: strerror(errno)))") }
        do {
            try verify(fd, roots: roots, out: out)
            for component in missing {
                if mkdirat(fd, component, 0o755) != 0, errno != EEXIST {
                    throw RenderOutputError("cannot create \(component) for \(out): \(String(cString: strerror(errno)))")
                }
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw RenderOutputError("refusing to write \(out): \(rule)") }
                close(fd)
                fd = next
                try verify(fd, roots: roots, out: out)
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func verify(_ fd: Int32, roots: [String], out: String) throws {
        guard let real = descriptorPath(fd), isInside(real, roots) else {
            throw RenderOutputError("refusing to write \(out): \(rule)")
        }
    }

    static func isInside(_ path: String, _ roots: [String]) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// realpath(3): symlinks resolved, nil if the path doesn't exist.
    static func realPath(_ path: String) -> String? {
        guard let p = Darwin.realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// The real path of an open descriptor (F_GETPATH).
    static func descriptorPath(_ fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }
}
