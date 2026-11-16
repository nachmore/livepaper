// ReferenceFolders — dropped, picked or `--ref` folders expanded to the images inside them.
//
// Folders are walked a few levels deep (`ReferenceLimits.folderDepth`), hidden entries and package
// contents skipped, symlinked folders never followed (a link loop can't trap the walk), at most
// `folderScanLimit` entries looked at per folder. Images come out in Finder order (relative path,
// `localizedStandardCompare`: "img2" before "img10"), duplicates dropped, capped to the room left
// in the session; whatever was left out is counted so the UI can say so in one sentence.
import Darwin
import Foundation
import UniformTypeIdentifiers

public struct ReferenceExpansion: Sendable, Equatable {
    public struct LeftOut: Sendable, Equatable {
        /// Images beyond the session's capacity.
        public var overLimit = 0
        /// Files in folders that aren't images (by their extension).
        public var notImages = 0
        /// Folders deeper than `folderDepth` (not looked into).
        public var tooDeep = 0
        /// Entries that couldn't be read (missing, permissions).
        public var unreadable = 0
        /// Symbolic links to folders (never followed).
        public var linkedFolders = 0
        /// Images already attached, or given twice.
        public var duplicates = 0
        /// Folders whose walk stopped after `folderScanLimit` entries.
        public var truncatedFolders = 0
        public init() {}

        public var isEmpty: Bool { self == LeftOut() }

        /// "left out 27 more images (the limit is 10 per session) and 3 files that aren't images",
        /// or nil when nothing was left out.
        public func sentence(limit: Int = ReferenceLimits.maxImages) -> String? {
            func n(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }
            var parts: [String] = []
            if overLimit > 0 { parts.append(n(overLimit, "more image", "more images") + " (the limit is \(limit) per session)") }
            if notImages > 0 { parts.append(n(notImages, "file that isn't an image", "files that aren't images")) }
            if duplicates > 0 { parts.append(n(duplicates, "image that was already attached", "images that were already attached")) }
            if tooDeep > 0 {
                parts.append(n(tooDeep, "folder", "folders") + " nested more than \(ReferenceLimits.folderDepth) levels deep")
            }
            if linkedFolders > 0 { parts.append(n(linkedFolders, "linked folder", "linked folders") + " (links aren't followed)") }
            if unreadable > 0 { parts.append(n(unreadable, "item LivePaper couldn't read", "items LivePaper couldn't read")) }
            if truncatedFolders > 0 {
                parts.append("whatever comes after the first \(ReferenceLimits.folderScanLimit.formatted()) entries of " +
                             n(truncatedFolders, "folder", "folders"))
            }
            guard let last = parts.popLast() else { return nil }
            return "left out " + (parts.isEmpty ? last : parts.joined(separator: ", ") + " and " + last)
        }

        /// The sentence as a note of its own: "Left out 3 files that aren't images."
        public var note: String? { sentence().map { $0.prefix(1).uppercased() + $0.dropFirst() + "." } }
    }

    public var files: [URL]
    public var leftOut: LeftOut
    public init(files: [URL] = [], leftOut: LeftOut = LeftOut()) { self.files = files; self.leftOut = leftOut }
}

public enum ReferenceFolders {
    /// Whether a file name's extension is an image type macOS knows (folders are filtered by name;
    /// explicitly chosen files are checked by decoding).
    public static func isImageFileName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .svg)
    }

    /// Files and folders → image files, at most `capacity`, skipping real paths in `existing`.
    /// Explicit files are kept whatever their name (the importer says why one isn't an image);
    /// files found in folders must have an image extension.
    public static func expand(_ urls: [URL], capacity: Int, excluding existing: Set<String> = [],
                              depth: Int = ReferenceLimits.folderDepth) -> ReferenceExpansion {
        var out = ReferenceExpansion()
        var seen = existing
        var found: [URL] = []
        func add(_ url: URL, real: String) {
            guard seen.insert(real).inserted else { out.leftOut.duplicates += 1; return }
            found.append(url)
        }
        for url in urls {
            let given = url.standardizedFileURL
            guard let real = AISessionPolicy.realPath(given.path) else { out.leftOut.unreadable += 1; continue }
            switch fileType(real) {
            case S_IFREG: add(given, real: real)
            case S_IFDIR:
                for file in walk(folder: given, real: URL(fileURLWithPath: real), depth: depth, leftOut: &out.leftOut) {
                    guard let r = AISessionPolicy.realPath(file.path) else { out.leftOut.unreadable += 1; continue }
                    add(file, real: r)
                }
            default: out.leftOut.unreadable += 1
            }
        }
        let room = max(0, capacity)
        out.files = Array(found.prefix(room))
        out.leftOut.overLimit += max(0, found.count - room)
        return out
    }

    /// The images in one folder, in Finder order, as paths under `folder` as given (so they match
    /// what the user typed), found by walking its real path.
    static func walk(folder: URL, real: URL, depth: Int, leftOut: inout ReferenceExpansion.LeftOut) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]
        var errors = 0
        guard let walker = FileManager.default.enumerator(at: real, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                          errorHandler: { _, _ in errors += 1; return true }) else {
            leftOut.unreadable += 1
            return []
        }
        let root = real.standardizedFileURL.path
        var images: [String] = [], looked = 0
        for case let url as URL in walker {
            looked += 1
            if looked > ReferenceLimits.folderScanLimit { leftOut.truncatedFolders += 1; break }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            let rel = String(path.dropFirst(root.count + 1))
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                // Links to files are fine (resolved later, must be regular files); links to folders aren't followed.
                guard let target = AISessionPolicy.realPath(path) else { leftOut.unreadable += 1; continue }
                switch fileType(target) {
                case S_IFDIR: leftOut.linkedFolders += 1
                case S_IFREG: if isImageFileName(url.lastPathComponent) { images.append(rel) } else { leftOut.notImages += 1 }
                default: leftOut.unreadable += 1
                }
                continue
            }
            if values?.isDirectory == true {
                if values?.isPackage == true { leftOut.notImages += 1; walker.skipDescendants(); continue }
                if walker.level >= depth { leftOut.tooDeep += 1; walker.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if isImageFileName(url.lastPathComponent) { images.append(rel) } else { leftOut.notImages += 1 }
        }
        leftOut.unreadable += errors
        return images.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { folder.appendingPathComponent($0, isDirectory: false) }
    }

    /// The real path of a file the user named, or `notFound` / `notPermitted` (a privacy-protected
    /// folder this process may not read, e.g. the terminal without Files and Folders access).
    static func lookUp(_ url: URL) throws -> String {
        let found = AISessionPolicy.lookUp(url.path)
        guard let real = found.real else {
            throw found.denied ? ReferenceError.notPermitted(name: url.lastPathComponent) : ReferenceError.notFound(name: url.lastPathComponent)
        }
        return real
    }

    static func fileType(_ path: String) -> mode_t {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_mode & S_IFMT : 0
    }

    /// The CLI's `--ref` (files or folders, repeatable) and `--animate` (one file): inputs in the
    /// order they'll be numbered — the picture to animate first. More than `maxImages` explicit files
    /// throws `tooMany`; folders fill whatever room is left; a file given both ways is kept once,
    /// as the one to animate.
    public static func collect(references: [URL], animate: URL?) throws -> (inputs: [ReferenceInput], leftOut: ReferenceExpansion.LeftOut) {
        var leftOut = ReferenceExpansion.LeftOut()
        var inputs: [ReferenceInput] = []
        var taken = Set<String>()
        if let animate {
            let url = animate.standardizedFileURL
            let real = try lookUp(url)
            guard fileType(real) != S_IFDIR else { throw ReferenceError.animateNeedsFile(name: url.lastPathComponent) }
            inputs.append(.file(url, role: .animate))
            taken.insert(real)
        }
        var files: [(URL, String)] = [], folders: [URL] = []
        for given in references {
            let url = given.standardizedFileURL
            let real = try lookUp(url)
            if fileType(real) == S_IFDIR { folders.append(url) } else { files.append((url, real)) }
        }
        for (url, real) in files {
            guard taken.insert(real).inserted else { continue }   // the same file twice, or also --animate
            inputs.append(.file(url))
        }
        guard inputs.count <= ReferenceLimits.maxImages else { throw ReferenceError.tooMany(count: inputs.count) }
        if !folders.isEmpty {
            let expansion = expand(folders, capacity: ReferenceLimits.maxImages - inputs.count, excluding: taken)
            inputs += expansion.files.map { ReferenceInput.file($0) }
            leftOut = expansion.leftOut
        }
        return (inputs, leftOut)
    }
}
