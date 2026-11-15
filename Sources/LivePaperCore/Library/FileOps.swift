// FileOps — small crash-safe file-system primitives shared by the library, publisher and installer.
//
// Everything that replaces a directory the user (or the screen saver) can observe goes through
// `installReplacing(_:with:)`: the new content is fully built in a hidden staging directory next to
// the destination and then swapped in with one rename(2), so a crash leaves either the old or the
// new version — never a half-written one.
import Darwin
import Foundation

enum FileOps {
    private static var fm: FileManager { .default }

    /// True if anything (file, directory or symlink — even a dangling one) exists at `url`.
    static func entryExists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// True for a regular file that is not a symlink.
    static func isRegularFile(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    static func removeIfPresent(_ url: URL) throws {
        if entryExists(url) { try fm.removeItem(at: url) }
    }

    /// A hidden sibling path inside `directory` for building content before it is swapped in.
    /// Hidden names are skipped by every directory listing LivePaper (and the saver host) does.
    static func stagingURL(in directory: URL, tag: String) -> URL {
        directory.appendingPathComponent(".\(tag)-\(UUID().uuidString)")
    }

    /// rename(2) that fails with EEXIST instead of replacing an existing destination. This is what
    /// makes scene-id allocation race-free across processes (app + CLI).
    static func moveExclusive(from source: URL, to destination: URL) throws {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return }
        let err = errno
        guard err == ENOTSUP || err == EINVAL else { throw posixError(err, "move", source, destination) }
        // File system without RENAME_EXCL (e.g. some network volumes): best effort.
        guard !entryExists(destination) else { throw posixError(EEXIST, "move", source, destination) }
        if rename(source.path, destination.path) != 0 { throw posixError(errno, "move", source, destination) }
    }

    /// Atomically exchanges two existing paths (RENAME_SWAP), falling back to three renames on file
    /// systems that can't swap.
    static func swap(_ a: URL, _ b: URL) throws {
        if renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 { return }
        let err = errno
        guard err == ENOTSUP || err == EINVAL else { throw posixError(err, "swap", a, b) }
        let parked = stagingURL(in: b.deletingLastPathComponent(), tag: "swap")
        try fm.moveItem(at: b, to: parked)
        do { try fm.moveItem(at: a, to: b) } catch { try? fm.moveItem(at: parked, to: b); throw error }
        try fm.moveItem(at: parked, to: a)
    }

    /// Puts the fully built `staging` item at `destination` in one atomic step and deletes the
    /// previous version (if any). `staging` must be on the same volume as `destination`.
    static func installReplacing(_ destination: URL, with staging: URL) throws {
        if entryExists(destination) {
            try swap(staging, destination)
            // `staging` now holds the previous version; failing to delete it only wastes space.
            try? fm.removeItem(at: staging)
        } else {
            try moveExclusive(from: staging, to: destination)
        }
    }

    /// Copies a directory tree (APFS clones files, so this is cheap), skipping the given top-level
    /// entry names.
    static func copyTree(from source: URL, to destination: URL, excluding excluded: Set<String> = []) throws {
        guard !excluded.isEmpty else { try fm.copyItem(at: source, to: destination); return }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for child in try fm.contentsOfDirectory(atPath: source.path) where !excluded.contains(child) {
            try fm.copyItem(at: source.appendingPathComponent(child), to: destination.appendingPathComponent(child))
        }
    }

    /// Hard-links `source` to `destination` (no extra disk space for large videos), copying when the
    /// two are on different volumes or the file system doesn't support links.
    static func hardLinkOrCopy(from source: URL, to destination: URL) throws {
        do { try fm.linkItem(at: source, to: destination) } catch { try fm.copyItem(at: source, to: destination) }
    }

    /// The first symbolic link found inside `root` (packages must be self-contained: a link could
    /// smuggle arbitrary files into the published screen saver).
    static func firstSymlink(in root: URL) -> URL? {
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return nil }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            return url
        }
        return nil
    }

    /// Removes `com.apple.quarantine` from a tree. Files copied out of a downloaded app inherit the
    /// attribute, and the screen-saver host refuses to load quarantined bundles.
    static func stripQuarantine(_ root: URL) {
        var paths = [root.path]
        if let walker = fm.enumerator(atPath: root.path) {
            for case let rel as String in walker { paths.append(root.appendingPathComponent(rel).path) }
        }
        for p in paths { _ = removexattr(p, "com.apple.quarantine", XATTR_NOFOLLOW) }
    }

    /// Writes `data` atomically, creating the parent directory if needed.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// `20261113T175610Z` — a sortable, file-name-safe UTC timestamp.
    static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        return f.string(from: date)
    }

    /// `Info.plist` value of a bundle (nil if the bundle or key is missing).
    static func bundleInfo(_ bundle: URL, _ key: String) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return dict[key] as? String
    }

    private static func posixError(_ code: Int32, _ op: String, _ a: URL, _ b: URL) -> Error {
        let message = String(cString: strerror(code))
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSLocalizedDescriptionKey: "Could not \(op) \(a.lastPathComponent) → \(b.path): \(message)"])
    }
}

/// An advisory, cross-process lock (flock(2)) held for the duration of `body`. Used so the app and
/// the `livepaper` CLI never publish at the same time.
enum FileLock {
    static func withLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "Could not open lock file \(url.path)"])
        }
        defer { close(fd) }   // closing the descriptor also releases the lock
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSLocalizedDescriptionKey: "Could not lock \(url.path)"])
            }
        }
        return try body()
    }
}
