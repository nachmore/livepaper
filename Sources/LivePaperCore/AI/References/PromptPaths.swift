// PromptPaths — file paths the user typed into a prompt ("animate ~/Desktop/heron.png").
//
// An agent works in a sandboxed workspace and can't open anything on the user's Mac, so a path in
// the prompt is useless to it unless LivePaper attaches a copy. `mentions` finds candidates by
// syntax alone (it never touches the file system: typing must not trigger a privacy prompt for
// ~/Desktop and friends); `resolve` checks one when the user (or the CLI's hint) asks; `rewrite`
// replaces the paths LivePaper attached with their workspace names (`references/ref-02.jpg`) and
// reports the rest, so TASK.md can say they weren't attached.
import Foundation
import UniformTypeIdentifiers

public struct PromptPathMention: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case image, folder }
    /// The path as typed (quotes removed, `\ ` escapes kept).
    public var text: String
    /// The whole mention in the prompt, quotes included (what `rewrite` replaces).
    public var range: Range<String.Index>
    /// Expanded (`~`, `file://`, escapes) and standardized.
    public var url: URL
    public var kind: Kind
    public init(text: String, range: Range<String.Index>, url: URL, kind: Kind) {
        self.text = text; self.range = range; self.url = url; self.kind = kind
    }
}

public enum PromptPaths {
    // Quoted spans that start like a path: '…', "…", `…`, “…”.
    private static let quoted = try! NSRegularExpression(
        pattern: #"'((?:~/|/|file://)[^'\n]+)'|"((?:~/|/|file://)[^"\n]+)"|`((?:~/|/|file://)[^`\n]+)`|“((?:~/|/|file://)[^”\n]+)”"#)
    // Unquoted tokens: a path start at a word boundary (not inside "and/or" or "https://…"), then
    // anything but whitespace and delimiters, with `\ ` allowed inside.
    private static let unquoted = try! NSRegularExpression(
        pattern: #"(?<![\w/:.~\\])(?:~/|/|file://)(?:\\ |[^\s"'`,;()<>\[\]“”])+"#)

    /// Candidate paths in `text`, in order. Syntax only: no file-system access.
    public static func mentions(in text: String, home: URL = LPPaths.home) -> [PromptPathMention] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var found: [PromptPathMention] = []
        var covered: [NSRange] = []
        for m in quoted.matches(in: text, range: all) {
            guard let group = (1...4).map({ m.range(at: $0) }).first(where: { $0.location != NSNotFound }),
                  let range = Range(m.range, in: text) else { continue }
            covered.append(m.range)
            if let mention = make(ns.substring(with: group), range: range, home: home, quoted: true) { found.append(mention) }
        }
        for m in unquoted.matches(in: text, range: all) where !covered.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            var token = ns.substring(with: m.range)
            var length = m.range.length
            // Sentence punctuation after a path isn't part of it.
            while let last = token.last, ".,;:!?)".contains(last), !token.hasSuffix("\\" + String(last)) {
                token.removeLast(); length -= (String(last) as NSString).length
            }
            guard let range = Range(NSRange(location: m.range.location, length: length), in: text) else { continue }
            if let mention = make(token, range: range, home: home, quoted: false) { found.append(mention) }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func make(_ typed: String, range: Range<String.Index>, home: URL, quoted: Bool) -> PromptPathMention? {
        var path = typed.trimmingCharacters(in: .whitespaces)
        if !quoted { path = path.replacingOccurrences(of: "\\ ", with: " ") }
        if path.hasPrefix("file://") {
            guard let url = URL(string: path), url.isFileURL else { return nil }
            path = url.path
        }
        let isFolderSyntax = path.hasSuffix("/")
        if path.hasPrefix("~/") { path = home.appendingPathComponent(String(path.dropFirst(2))).path }
        let fromHome = typed.hasPrefix("~/")
        guard path.hasPrefix("/"), path.count > 1, path != home.path else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let ext = url.pathExtension
        let kind: PromptPathMention.Kind
        if !isFolderSyntax, !ext.isEmpty {
            guard let type = UTType(filenameExtension: ext), type.conforms(to: .image), !type.conforms(to: .svg) else { return nil }
            kind = .image
        } else {
            // "/s" in "90°/s" isn't a folder anyone means: an absolute folder needs two components
            // (or a trailing slash, or to start at ~/).
            guard isFolderSyntax || fromHome || url.pathComponents.count >= 3 else { return nil }
            kind = .folder
        }
        return PromptPathMention(text: typed, range: range, url: url, kind: kind)
    }

    /// Folders macOS guards with a privacy prompt (or that may be offline): LivePaper doesn't look
    /// into them until the user asks.
    public static func isPrivacyProtected(_ url: URL, home: URL = LPPaths.home) -> Bool {
        let path = url.standardizedFileURL.path
        let roots = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"].map { home.appendingPathComponent($0).path } + ["/Volumes"]
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    public enum Resolution: Sendable, Equatable { case image(URL), folder(URL), missing, notAnImage }

    /// What a mention names on disk (touches the file system).
    public static func resolve(_ m: PromptPathMention) -> Resolution {
        guard let real = AISessionPolicy.realPath(m.url.path) else { return .missing }
        switch ReferenceFolders.fileType(real) {
        case S_IFDIR: return .folder(m.url)
        case S_IFREG: return ReferenceFolders.isImageFileName(real) || ReferenceFolders.isImageFileName(m.url.path) ? .image(m.url) : .notAnImage
        default: return .notAnImage
        }
    }

    /// `prompt` with every mention of an attached image (or of a folder they came from) replaced by
    /// its workspace name, plus the mentions that weren't attached. No file-system access: matches
    /// are by the paths the references were added with (as given, and real).
    public static func rewrite(_ prompt: String, attached: [PreparedReference], home: URL = LPPaths.home)
        -> (text: String, unattached: [PromptPathMention]) {
        let found = mentions(in: prompt, home: home)
        guard !found.isEmpty else { return (prompt, []) }
        let paths: [(index: Int, paths: [String], file: String)] = attached.enumerated().map { i, r in
            (i + 1, [r.requestedPath, r.originPath].compactMap { $0 }, ReferenceWorkspace.relativeImagePath(index: i + 1, format: r.vision.format))
        }
        // Replaced back to front through UTF-16 offsets taken before any change.
        let text = NSMutableString(string: prompt)
        var unattached: [PromptPathMention] = []
        for m in found.reversed() {
            let p = m.url.path
            let where_ = NSRange(m.range, in: prompt)
            if let hit = paths.first(where: { $0.paths.contains(p) }) {
                text.replaceCharacters(in: where_, with: "`\(hit.file)`")
                continue
            }
            let inside = paths.filter { $0.paths.contains { $0.hasPrefix(p + "/") } }.map(\.index)
            if !inside.isEmpty {
                text.replaceCharacters(in: where_, with: "`\(ReferenceWorkspace.directoryName)/` (\(indexList(inside)))")
                continue
            }
            unattached.insert(m, at: 0)
        }
        return (text as String, unattached)
    }

    /// "ref-03", "ref-01 … ref-04", "ref-01, ref-03".
    static func indexList(_ indexes: [Int]) -> String {
        let names = indexes.map { String(format: "ref-%02d", $0) }
        guard names.count > 1 else { return names.first ?? "" }
        let contiguous = zip(indexes, indexes.dropFirst()).allSatisfy { $1 == $0 + 1 }
        return contiguous && names.count > 2 ? "\(names[0]) \u{2026} \(names[names.count - 1])" : names.joined(separator: ", ")
    }
}
