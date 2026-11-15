// LibraryService — the user's scene library (LPPaths.library) plus the read-only built-in scenes
// shipped in the app (LPPaths.builtinScenesDir). See ARCHITECTURE §4.1–4.2.
//
// Invariants:
//   * A user scene lives in `<library>/<id>.lpscene`; the directory name is the authoritative id.
//   * Ids are unique across user AND built-in scenes (kebab-case, ≤ 64 chars, `-2`, `-3`… on clash).
//   * Every change is built in a hidden staging directory inside the library and moved into place
//     with one rename, so the library never shows a half-written scene (and the app and the CLI can
//     safely allocate ids at the same time: the final rename fails if the id was taken meanwhile).
import Foundation
import os

public final class LibraryService: LibraryServicing, @unchecked Sendable {
    public let libraryDirectory: URL
    public let builtinDirectory: URL
    /// The starter package copied by createWebScene (Runtime/templates/web).
    public let templateDirectory: URL

    /// Top-level package entries never copied when cloning, importing or exporting.
    static let transientEntries: Set<String> = [".check", ".DS_Store", "__MACOSX"]
    /// Entries that belong to the library's record of a scene rather than to its contents.
    static let historyEntries: Set<String> = [SceneHistory.directoryName, SceneHistory.fileName]

    private let lock = NSRecursiveLock()
    private let clock: @Sendable () -> Date
    private let runner: CommandRunning
    private let log = Logger(subsystem: LPPaths.bundleID, category: "library")
    private var prunedStaging = false

    public init(libraryDirectory: URL = LPPaths.library,
                builtinDirectory: URL = LPPaths.builtinScenesDir,
                templateDirectory: URL = LPPaths.runtimeDir.appendingPathComponent("templates/web"),
                runner: CommandRunning = SystemCommandRunner(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.libraryDirectory = libraryDirectory
        self.builtinDirectory = builtinDirectory
        self.templateDirectory = templateDirectory
        self.runner = runner
        self.clock = now
    }

    // MARK: - Reading

    public func scenes() throws -> [SceneItem] {
        let user = packages(in: libraryDirectory, builtin: false)
        let userIDs = Set(user.map(\.id))
        // A built-in added by a newer app version may share an id with an older user scene; the
        // user's scene wins so ids stay unique (publish file names, UI identity).
        let builtins = packages(in: builtinDirectory, builtin: true).filter { !userIDs.contains($0.id) }
        return Self.sorted(user) + Self.sorted(builtins)
    }

    public func scene(id: String) throws -> SceneItem? {
        guard SceneManifest.isValidID(id) else { return nil }
        if let item = load(package: userPackage(id), builtin: false) { return item }
        return load(package: builtinDirectory.appendingPathComponent("\(id).\(SceneManifest.packageExtension)"), builtin: true)
    }

    // MARK: - Creating

    public func createWebScene(name: String, description: String) throws -> SceneItem {
        guard FileOps.isDirectory(templateDirectory) else {
            throw LibraryError.invalid("the web scene template is missing (\(templateDirectory.path)).")
        }
        let name = Self.displayName(name)
        return try withLock {
            let staging = try makeStaging()
            do {
                try FileOps.copyTree(from: templateDirectory, to: staging, excluding: Self.transientEntries.union(Self.historyEntries))
                var m = (try? SceneManifest.load(package: staging)) ?? SceneManifest(id: "scene", name: name, kind: .web)
                m.name = name
                m.description = description
                m.kind = .web
                m.runtime = m.runtime ?? 1
                m.video = nil
                m.parent = nil
                m.performance = nil
                m.created = now(); m.updated = m.created
                return try commit(staging: staging, manifest: m, preferredID: SceneManifest.slug(from: name))
            } catch { try? FileManager.default.removeItem(at: staging); throw error }
        }
    }

    public func importVideo(from url: URL, name: String, optimizeForBattery: Bool,
                            progress: @escaping @Sendable (Double) -> Void) async throws -> SceneItem {
        progress(0)
        let staging = try withLock { try makeStaging() }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            // 0…90 % for the media, the rest for poster + thumbnail.
            let file = try await VideoImporter.importVideo(from: url, into: staging, optimizeForBattery: optimizeForBattery) {
                progress(min(0.9, $0 * 0.9))
            }
            try await VideoImporter.writePosterAndThumbnail(for: staging.appendingPathComponent(file), in: staging)
            let date = now()
            let manifest = SceneManifest(id: "video", name: Self.displayName(name), kind: .video, runtime: nil,
                                         video: .init(file: file), created: date, updated: date)
            let item = try withLock { try commit(staging: staging, manifest: manifest, preferredID: SceneManifest.slug(from: manifest.name)) }
            progress(1)
            return item
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    public func clone(id: String, newName: String) throws -> SceneItem {
        try withLock {
            guard let source = try scene(id: id) else { throw LibraryError.notFound(id) }
            let name = Self.displayName(newName)
            let staging = try makeStaging()
            do {
                try FileOps.copyTree(from: source.packageURL, to: staging, excluding: Self.transientEntries)
                var m = source.manifest
                m.name = name
                m.parent = source.id
                m.created = now(); m.updated = m.created
                try SceneHistory.append(SceneHistoryEntry(date: now(), action: .clone, summary: "Cloned from \(source.id)"), to: staging)
                return try commit(staging: staging, manifest: m, preferredID: SceneManifest.slug(from: name))
            } catch { try? FileManager.default.removeItem(at: staging); throw error }
        }
    }

    // MARK: - Changing

    public func delete(id: String) throws {
        try withLock {
            let package = try existingUserPackage(id)
            // Rename first so the scene disappears atomically even if the recursive delete fails.
            let doomed = FileOps.stagingURL(in: libraryDirectory, tag: "deleted")
            try FileManager.default.moveItem(at: package, to: doomed)
            try FileManager.default.removeItem(at: doomed)
            log.info("deleted scene \(id, privacy: .public)")
        }
    }

    public func update(_ manifest: SceneManifest) throws {
        try withLock {
            let package = try existingUserPackage(manifest.id)
            var m = manifest
            m.schema = SceneManifest.currentSchema
            m.updated = now()
            try m.write(package: package)
        }
    }

    public func replaceContents(id: String, with package: URL) throws -> SceneItem {
        let candidate = try validatedPackage(at: package)
        return try withLock {
            let current = try existingUserPackage(id)
            let old = try SceneManifest.load(package: current)
            let staging = try makeStaging()
            do {
                // 1. The new contents (minus any history the candidate carries; merged below).
                try FileOps.copyTree(from: package, to: staging, excluding: Self.transientEntries.union(Self.historyEntries))
                // 2. Existing history, then the previous version as history/<timestamp>/.
                let fm = FileManager.default
                let historyDir = staging.appendingPathComponent(SceneHistory.directoryName)
                let oldHistoryDir = current.appendingPathComponent(SceneHistory.directoryName)
                if FileOps.isDirectory(oldHistoryDir) { try fm.copyItem(at: oldHistoryDir, to: historyDir) }
                try fm.createDirectory(at: historyDir, withIntermediateDirectories: true)
                let stamp = Self.uniqueChildName(in: historyDir, base: FileOps.timestamp(now()))
                try FileOps.copyTree(from: current, to: historyDir.appendingPathComponent(stamp),
                                     excluding: Self.transientEntries.union(Self.historyEntries))
                // 3. history.jsonl = old lines + the candidate's new lines (e.g. the AI "modify" entry) + this replace.
                let oldLog = current.appendingPathComponent(SceneHistory.fileName)
                if FileOps.isRegularFile(oldLog) { try fm.copyItem(at: oldLog, to: staging.appendingPathComponent(SceneHistory.fileName)) }
                let replace = SceneHistoryEntry(date: now(), action: .replace, summary: "Previous version kept in \(SceneHistory.directoryName)/\(stamp)",
                                                previous: "\(SceneHistory.directoryName)/\(stamp)")
                let known = SceneHistory.entries(in: current)
                let incoming = SceneHistory.entries(in: package).filter { !known.contains($0) }
                try SceneHistory.append(incoming + [replace], to: staging)
                // 4. Same identity, new content.
                var m = candidate
                m.id = id
                m.created = old.created
                m.parent = old.parent
                m.updated = now()
                try m.write(package: staging)
                try FileOps.installReplacing(current, with: staging)
                log.info("replaced contents of \(id, privacy: .public); previous version in history/\(stamp, privacy: .public)")
                return SceneItem(manifest: m, packageURL: current, isBuiltin: false)
            } catch { try? FileManager.default.removeItem(at: staging); throw error }
        }
    }

    // MARK: - Import / export

    public func importPackage(at url: URL) throws -> SceneItem {
        var extracted: URL?
        defer { if let extracted { try? FileManager.default.removeItem(at: extracted) } }
        var source = url
        if url.pathExtension.lowercased() == "zip" {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("livepaper-import-\(UUID().uuidString)")
            extracted = dir
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let result = try runner.run("/usr/bin/ditto", ["-x", "-k", url.path, dir.path], timeout: 300)
            guard result.succeeded else {
                throw LibraryError.invalid("\(url.lastPathComponent) could not be unzipped: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            source = try Self.locatePackage(in: dir, archiveName: url.lastPathComponent)
        }
        let manifest = try validatedPackage(at: source)
        return try withLock {
            let staging = try makeStaging()
            do {
                try FileOps.copyTree(from: source, to: staging, excluding: Self.transientEntries)
                var m = manifest
                m.schema = SceneManifest.currentSchema
                m.created = m.created ?? now()
                m.updated = now()
                let preferred = SceneManifest.isValidID(m.id) ? m.id : SceneManifest.slug(from: m.name)
                return try commit(staging: staging, manifest: m, preferredID: preferred)
            } catch { try? FileManager.default.removeItem(at: staging); throw error }
        }
    }

    public func existingScene(matching url: URL) throws -> SceneImportMatch? {
        let all = try scenes()
        // 1. The package itself is in the library or the app (opened from there in Finder).
        if let identity = Self.fileIdentity(url),
           let item = all.first(where: { Self.fileIdentity($0.packageURL).map { $0.isEqual(identity) } ?? false }) {
            return .same(item)
        }
        guard url.pathExtension.lowercased() == SceneManifest.packageExtension, let manifest = try? validatedPackage(at: url) else { return nil }
        // 2. A scene with the same contents; 3. another version of a user scene with that id.
        return ScenePackageComparison.match(url, manifest, in: all)
    }

    public func openPackage(at url: URL) throws -> SceneOpenResult {
        // One step under the lock: a second open of the same new package (a double-click while the
        // first copy is still running, two copies opened together) finds the first one's import.
        try withLock {
            if let match = try? existingScene(matching: url) { return .existing(match) }
            return .imported(try importPackage(at: url))
        }
    }

    /// The file system's identity for a file (same file ⇔ equal), whatever path or case was used.
    private static func fileIdentity(_ url: URL) -> NSObjectProtocol? {
        (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
    }

    public func exportPackage(id: String, to url: URL) throws {
        guard let item = try scene(id: id) else { throw LibraryError.notFound(id) }
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // Built next to the destination so the final step is a same-volume atomic rename.
        let staging = FileOps.stagingURL(in: parent, tag: "livepaper-export")
        defer { try? FileOps.removeIfPresent(staging) }
        if url.pathExtension.lowercased() == "zip" {
            let work = fm.temporaryDirectory.appendingPathComponent("livepaper-export-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: work) }
            let packageCopy = work.appendingPathComponent("\(item.id).\(SceneManifest.packageExtension)")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try FileOps.copyTree(from: item.packageURL, to: packageCopy, excluding: Self.transientEntries)
            let result = try runner.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", packageCopy.path, staging.path], timeout: 300)
            guard result.succeeded else {
                throw LibraryError.invalid("could not create \(url.lastPathComponent): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        } else {
            try FileOps.copyTree(from: item.packageURL, to: staging, excluding: Self.transientEntries)
        }
        try FileOps.installReplacing(url, with: staging)
    }

    // MARK: - Internals

    /// The current time in whole seconds: scene.json stores ISO 8601 without fractions, so this
    /// keeps the manifests this service returns equal to what a later read from disk gives.
    private func now() -> Date { Date(timeIntervalSince1970: clock().timeIntervalSince1970.rounded(.down)) }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func userPackage(_ id: String) -> URL {
        libraryDirectory.appendingPathComponent("\(id).\(SceneManifest.packageExtension)")
    }

    private func existingUserPackage(_ id: String) throws -> URL {
        guard SceneManifest.isValidID(id) else { throw LibraryError.notFound(id) }
        let package = userPackage(id)
        if FileOps.isDirectory(package) { return package }
        if try scene(id: id)?.isBuiltin == true { throw LibraryError.readOnly(id) }
        throw LibraryError.notFound(id)
    }

    /// A fresh hidden staging path inside the library (same volume as the final location).
    private func makeStaging() throws -> URL {
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        pruneAbandonedStaging()
        return FileOps.stagingURL(in: libraryDirectory, tag: "staging")
    }

    /// Removes staging/deleted directories left behind by a crash (older than a day, so a staging
    /// directory another process is still filling is never touched).
    private func pruneAbandonedStaging() {
        guard !prunedStaging else { return }
        prunedStaging = true
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: libraryDirectory.path) else { return }
        let cutoff = now().addingTimeInterval(-86_400)
        for name in names where name.hasPrefix(".staging-") || name.hasPrefix(".deleted-") {
            let url = libraryDirectory.appendingPathComponent(name)
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Writes the manifest with the first free id derived from `preferredID` and moves the staging
    /// directory into place. Retries with the next suffix if another process took the id meanwhile.
    private func commit(staging: URL, manifest: SceneManifest, preferredID: String) throws -> SceneItem {
        var m = manifest
        let base = SceneManifest.isValidID(preferredID) ? preferredID : SceneManifest.slug(from: preferredID)
        let builtinIDs = Set(packages(in: builtinDirectory, builtin: true).map(\.id))
        for attempt in 1...10_000 {
            let id = Self.candidateID(base: base, attempt: attempt)
            let destination = userPackage(id)
            if builtinIDs.contains(id) || FileOps.entryExists(destination) { continue }
            m.id = id
            try m.write(package: staging)
            do {
                try FileOps.moveExclusive(from: staging, to: destination)
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && (error.code == Int(EEXIST) || error.code == Int(ENOTEMPTY)) {
                continue   // lost a race for this id
            }
            log.info("added scene \(id, privacy: .public)")
            return SceneItem(manifest: m, packageURL: destination, isBuiltin: false)
        }
        throw LibraryError.exists(base)
    }

    /// `base`, then `base-2`, `base-3`… trimmed so the result stays a valid ≤ 64-char id.
    static func candidateID(base: String, attempt: Int) -> String {
        guard attempt > 1 else { return base }
        let suffix = "-\(attempt)"
        var stem = String(base.prefix(64 - suffix.count))
        while stem.hasSuffix("-") { stem.removeLast() }
        return (stem.isEmpty ? "scene" : stem) + suffix
    }

    private func packages(in directory: URL, builtin: Bool) -> [SceneItem] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles]) else { return [] }
        return urls.filter { $0.pathExtension == SceneManifest.packageExtension }.compactMap { load(package: $0, builtin: builtin) }
    }

    private func load(package url: URL, builtin: Bool) -> SceneItem? {
        guard FileOps.isDirectory(url) else { return nil }
        let id = url.deletingPathExtension().lastPathComponent
        guard SceneManifest.isValidID(id) else {
            log.error("ignoring \(url.lastPathComponent, privacy: .public): not a valid scene id")
            return nil
        }
        do {
            var m = try SceneManifest.load(package: url)
            // The directory name is authoritative (an agent may have edited "id" in scene.json).
            m.id = id
            return SceneItem(manifest: m, packageURL: url, isBuiltin: builtin)
        } catch {
            log.error("ignoring \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Validates a package directory from outside the library (import, AI candidate).
    private func validatedPackage(at url: URL) throws -> SceneManifest {
        guard FileOps.isDirectory(url) else { throw LibraryError.invalid("\(url.lastPathComponent) is not a scene package.") }
        let manifest: SceneManifest
        do { manifest = try SceneManifest.load(package: url) } catch {
            throw LibraryError.invalid("\(url.lastPathComponent) has no readable scene.json (\(error.localizedDescription)).")
        }
        if let link = FileOps.firstSymlink(in: url) {
            throw LibraryError.invalid("\(url.lastPathComponent) contains a symbolic link (\(link.lastPathComponent)); scenes must be self-contained.")
        }
        switch manifest.kind {
        case .web:
            guard FileOps.isRegularFile(url.appendingPathComponent("scene.js")) else {
                throw LibraryError.invalid("\(url.lastPathComponent) has no scene.js.")
            }
        case .video:
            guard let file = manifest.video?.file, Self.isPlainFileName(file),
                  FileOps.isRegularFile(url.appendingPathComponent(file)) else {
                throw LibraryError.invalid("\(url.lastPathComponent) is a video scene without its video file.")
            }
        }
        return manifest
    }

    /// The package inside an extracted archive: the archive root itself, or its only scene directory.
    static func locatePackage(in root: URL, archiveName: String) throws -> URL {
        if FileOps.isRegularFile(root.appendingPathComponent(SceneManifest.fileName)) { return root }
        let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let candidates = children.filter {
            $0.lastPathComponent != "__MACOSX" && FileOps.isRegularFile($0.appendingPathComponent(SceneManifest.fileName))
        }
        guard candidates.count == 1, let only = candidates.first else {
            throw LibraryError.invalid(candidates.isEmpty ? "\(archiveName) doesn't contain a LivePaper scene."
                                                          : "\(archiveName) contains more than one scene; import them one at a time.")
        }
        return only
    }

    /// A file name with no directory components (manifest values are untrusted input).
    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.hasPrefix(".")
    }

    static func uniqueChildName(in directory: URL, base: String) -> String {
        var name = base, n = 2
        while FileOps.entryExists(directory.appendingPathComponent(name)) { name = "\(base)-\(n)"; n += 1 }
        return name
    }

    static func displayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Scene" : trimmed
    }

    static func sorted(_ items: [SceneItem]) -> [SceneItem] {
        items.sorted {
            let order = $0.manifest.name.localizedStandardCompare($1.manifest.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
