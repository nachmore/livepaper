// CollectionStore — reads and writes collections.json (ARCHITECTURE §4.6).
//
// The app and the `livepaper` CLI may change collections at the same time, so every change is a
// read-modify-write under `collections.lock` (flock, like publish.lock) and the file is replaced
// atomically. Reads take no lock: they see the old file or the new one, never half of one.
//
// A file that can't be read at all (not JSON) reads as "no collections" — and before the next
// change replaces it, it is moved aside as `collections.unreadable-<time>.json`, so nothing anyone
// wrote is lost without a trace.
import Foundation
import os

public final class CollectionStore: @unchecked Sendable {
    /// Larger files are taken for something else than collections (and never read into memory).
    public static let maxFileBytes = 16 << 20

    public let fileURL: URL
    public let lockURL: URL
    private let lock = NSLock()
    private let log = Logger(subsystem: LPPaths.bundleID, category: "collections")

    public init(fileURL: URL = LPPaths.collectionsFile, lockURL: URL? = nil) {
        self.fileURL = fileURL
        self.lockURL = lockURL ?? fileURL.deletingLastPathComponent().appendingPathComponent("collections.lock")
    }

    /// Every collection as stored (in the file's order). Never throws: a missing file is no
    /// collections, an unreadable one too (see the file comment).
    public func load() -> CollectionsFile { read().file }

    /// Applies `body` to the current contents and writes the result if it changed, as one step
    /// against other writers in this process and in others.
    @discardableResult
    public func update<T>(_ body: (inout CollectionsFile) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        return try FileLock.withLock(at: lockURL) {
            let (current, unreadable) = read()
            var next = current
            let result = try body(&next)
            // An edit that changes nothing leaves the file alone (even an unreadable one).
            if next != current {
                if unreadable { setAsideUnreadable() }
                try FileOps.writeAtomically(try next.encoded(), to: fileURL)
            }
            return result
        }
    }

    private func read() -> (file: CollectionsFile, unreadable: Bool) {
        guard FileOps.entryExists(fileURL) else { return (CollectionsFile(), false) }
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= Self.maxFileBytes, let data = try? Data(contentsOf: fileURL) else {
            log.error("collections.json can't be read (\(size) bytes); treating it as empty")
            return (CollectionsFile(), true)
        }
        do {
            return (try CollectionsFile.decode(data), false)
        } catch {
            log.error("collections.json isn't readable JSON: \(error.localizedDescription, privacy: .public)")
            return (CollectionsFile(), true)
        }
    }

    private func setAsideUnreadable() {
        let stamp = FileOps.timestamp(Date())
        var aside = fileURL.deletingLastPathComponent().appendingPathComponent("collections.unreadable-\(stamp).json")
        var n = 2
        while FileOps.entryExists(aside) {
            aside = fileURL.deletingLastPathComponent().appendingPathComponent("collections.unreadable-\(stamp)-\(n).json")
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: aside)
            log.notice("moved the unreadable collections.json aside as \(aside.lastPathComponent, privacy: .public)")
        } catch {
            log.error("couldn't move the unreadable collections.json aside: \(error.localizedDescription, privacy: .public)")
        }
    }
}
