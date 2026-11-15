// ScenePackageComparison — whether two scene packages show the same scene, so opening a package
// that is already in the library (double-clicking it in Finder, File › Import Scene…) opens that
// scene instead of importing a duplicate. See ARCHITECTURE §4.2.
//
// "The same scene" means the same files the scene is made of (scene.js, assets, the video), byte
// for byte, and the same manifest fields that change how it renders (kind, runtime version, clock,
// video settings). The library's own records don't count: scene.json's metadata (id, name,
// description, tags, dates, measured performance), the thumbnail, history and check results all
// change in the library copy without the scene being any different.
import Foundation

public enum ScenePackageComparison {
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

    /// Byte-for-byte equality, 1 MB at a time (video files can be large).
    static func sameBytes(_ a: URL, _ b: URL) -> Bool {
        guard let fa = try? FileHandle(forReadingFrom: a), let fb = try? FileHandle(forReadingFrom: b) else { return false }
        defer { try? fa.close(); try? fb.close() }
        while true {
            let (da, db): (Data?, Data?)
            do { da = try fa.read(upToCount: 1 << 20); db = try fb.read(upToCount: 1 << 20) } catch { return false }
            if da != db { return false }
            if (da?.isEmpty ?? true) { return true }
        }
    }
}
