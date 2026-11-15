// ScenePackageComparison — whether two scene packages show the same scene, so opening a package
// that is already in the library (double-clicking it in Finder, File › Import Scene…) opens that
// scene instead of importing a duplicate. See ARCHITECTURE §4.2.
//
// "The same scene" means the same files the scene is made of (scene.js, assets, the video), byte
// for byte, and the same manifest fields that change how it renders (kind, runtime version, clock,
// video settings). The library's own records don't count: scene.json's metadata (id, name,
// description, tags, dates, measured performance), the thumbnail, history and check results all
// change in the library copy without the scene being any different.
//
// "A different version of a scene" needs more than a shared id: ids are slugs of names, so
// unrelated scenes share them all the time ("aurora-lake-copy" from two people's AI-modified
// Aurora Lake, "untitled-scene", a video's "img-1234"). It needs the same `created` (sameLineage).
import Foundation

public enum ScenePackageComparison {
    /// What a library (`scenes`, as `LibraryServicing.scenes()` lists them) has for a scene package
    /// that isn't itself one of them: a scene with the same contents (`.same`), else a user scene
    /// that is another version of it (`.otherVersion`), else nil (import it).
    public static func match(_ package: URL, _ manifest: SceneManifest, in scenes: [SceneItem]) -> SceneImportMatch? {
        let preferred = SceneManifest.isValidID(manifest.id) ? manifest.id : SceneManifest.slug(from: manifest.name)
        // The scene with the package's id first, then the ids an earlier import of it would have
        // got (`id-2`, …), then any other; user scenes before built-ins (the order of `scenes`).
        func rank(_ item: SceneItem) -> Int { item.id == preferred ? 0 : item.id.hasPrefix(preferred + "-") ? 1 : 2 }
        let ordered = scenes.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        if let item = ordered.first(where: { sameScene($0.packageURL, $0.manifest, package, manifest) }) { return .same(item) }
        // Built-ins are never replaced; an unrelated scene that only shares the id is imported.
        if let item = ordered.first(where: { rank($0) < 2 && !$0.isBuiltin && sameLineage($0.manifest, manifest) }) {
            return .otherVersion(item)
        }
        return nil
    }

    /// Whether two manifests describe versions of one scene: the same `created`, which exporting,
    /// importing, AI "modify" and Replace keep, while creating, cloning and importing a video set a
    /// new one. (Shared history lines are no evidence: every clone of a built-in copies its history.)
    public static func sameLineage(_ a: SceneManifest, _ b: SceneManifest) -> Bool {
        guard let ca = a.created, let cb = b.created else { return false }
        // scene.json stores whole seconds.
        return ca.timeIntervalSince1970.rounded(.down) == cb.timeIntervalSince1970.rounded(.down)
    }

    /// Top-level entries that are records about the scene rather than the scene itself.
    static let recordEntries: Set<String> = LibraryService.transientEntries
        .union(LibraryService.historyEntries)
        .union([SceneManifest.fileName, "thumbnail.jpg"])
    /// Finder and archive clutter, ignored at any depth.
    static let clutter: Set<String> = [".DS_Store", "__MACOSX"]

    /// Same rendering fields and same content files (see the file comment).
    public static func sameScene(_ a: URL, _ aManifest: SceneManifest, _ b: URL, _ bManifest: SceneManifest) -> Bool {
        sameRendering(aManifest, bManifest) && sameContents(a, b)
    }

    /// The manifest fields that change what the scene shows.
    public static func sameRendering(_ a: SceneManifest, _ b: SceneManifest) -> Bool {
        a.kind == b.kind && (a.runtime ?? 1) == (b.runtime ?? 1) && a.clock == b.clock && a.video == b.video
    }

    /// The same content files (relative path → bytes). Sizes are compared first, so packages that
    /// differ are usually told apart without reading any file.
    public static func sameContents(_ a: URL, _ b: URL) -> Bool {
        guard let left = contentFiles(a), let right = contentFiles(b), left == right else { return false }
        return left.keys.sorted().allSatisfy { sameBytes(a.appendingPathComponent($0), b.appendingPathComponent($0)) }
    }

    /// Relative path → size of every regular file that makes up the scene; nil when the package
    /// can't be read or contains anything other than plain files and directories.
    static func contentFiles(_ root: URL) -> [String: Int]? {
        guard FileOps.isRealDirectory(root), let walker = FileManager.default.enumerator(atPath: root.path) else { return nil }
        var files: [String: Int] = [:]
        while let relative = walker.nextObject() as? String {
            var st = stat()
            guard lstat(root.appendingPathComponent(relative).path, &st) == 0 else { return nil }
            let type = st.st_mode & S_IFMT
            let parts = relative.split(separator: "/").map(String.init)
            guard let name = parts.last else { continue }
            if clutter.contains(name) || (parts.count == 1 && recordEntries.contains(name)) {
                // Only for a directory: on a file, skipDescendants() would skip the rest of its parent.
                if type == S_IFDIR { walker.skipDescendants() }
                continue
            }
            switch type {
            case S_IFDIR: continue
            case S_IFREG: files[relative] = Int(st.st_size)
            default: return nil   // a symbolic link, socket, …: not a self-contained package
            }
        }
        return files
    }

    /// Byte-for-byte equality, 1 MB at a time into two buffers reused for the whole file: video
    /// files can be GBs, and FileHandle's reads return autoreleased chunks that a background job
    /// would keep until it ends (twice the file size in memory).
    static func sameBytes(_ a: URL, _ b: URL) -> Bool {
        let fa = open(a.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC), fb = open(b.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        defer {
            if fa >= 0 { close(fa) }
            if fb >= 0 { close(fb) }
        }
        guard fa >= 0, fb >= 0 else { return false }
        let size = 1 << 20
        let bufferA = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        let bufferB = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { bufferA.deallocate(); bufferB.deallocate() }
        while true {
            let na = readFully(fa, into: bufferA, count: size), nb = readFully(fb, into: bufferB, count: size)
            guard na >= 0, na == nb else { return false }
            if na == 0 { return true }
            if memcmp(bufferA, bufferB, na) != 0 { return false }
        }
    }

    /// Reads until `count` bytes or the end of the file; the number read, or -1 on an error.
    private static func readFully(_ fd: Int32, into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        var total = 0
        while total < count {
            let n = read(fd, buffer + total, count - total)
            if n > 0 { total += n } else if n == 0 { break } else if errno != EINTR { return -1 }
        }
        return total
    }
}
