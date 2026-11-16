// PromptPaths — file paths the user typed into a prompt ("animate ~/Desktop/heron.png").
//
// An agent works in a sandboxed workspace and can't open anything on the user's Mac, so a path in
// the prompt is useless to it unless LivePaper attaches a copy. `mentions` finds candidates by
// syntax alone (it never touches the file system: typing must not trigger a privacy prompt for
// ~/Desktop and friends); `resolve` checks one when the user (or the CLI's hint) asks; `rewrite`
// replaces the paths LivePaper attached with their workspace names (`references/ref-02.jpg`) and
// reports the rest, so TASK.md can say they weren't attached.
//
// Paths are often pasted unquoted with plain spaces (Finder's Copy as Pathname, macOS screenshot
// names like "Screenshot 2026-11-15 at 10.41.23.png"): an unquoted path that stops at a space or a
// parenthesis is carried on across a few words when that reaches an image file name in a way that
// reads like one name (see `extend`), never by looking at the disk.
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
    // Quoted spans that start like a path: '…', "…", `…`, “…”, ‘…’.
    private static let quoted = try! NSRegularExpression(
        pattern: #"'((?:~/|/|file://)[^'\n]+)'|"((?:~/|/|file://)[^"\n]+)"|`((?:~/|/|file://)[^`\n]+)`|“((?:~/|/|file://)[^”\n]+)”|‘((?:~/|/|file://)[^’\n]+)’"#)
    // Unquoted tokens: a path start at a word boundary (not inside "and/or" or "https://…"), then
    // anything but whitespace and delimiters, with `\ ` allowed inside.
    private static let unquoted = try! NSRegularExpression(
        pattern: #"(?<![\w/:.~\\])(?:~/|/|file://)(?:\\ |[^\s"'`,;()<>\[\]“”‘’])+"#)
    /// Characters after a path that belong to the sentence, not to it.
    private static let trailing = ".,;:!?)\u{2026}*\u{2019}\u{201D}"
    /// How far an unquoted path may be carried on across spaces.
    static let maxExtraWords = 6
    static let maxExtraLength = 160

    /// Candidate paths in `text`, in order. Syntax only: no file-system access.
    public static func mentions(in text: String, home: URL = LPPaths.home) -> [PromptPathMention] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var found: [PromptPathMention] = []
        var covered: [NSRange] = []
        for m in quoted.matches(in: text, range: all) {
            guard let group = (1...5).map({ m.range(at: $0) }).first(where: { $0.location != NSNotFound }),
                  let range = Range(m.range, in: text) else { continue }
            covered.append(m.range)
            if let mention = make(ns.substring(with: group), range: range, home: home, quoted: true) { found.append(mention) }
        }
        for m in unquoted.matches(in: text, range: all) {
            guard !covered.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) else { continue }
            var token = ns.substring(with: m.range)
            var length = m.range.length
            // Sentence punctuation after a path isn't part of it.
            while let last = token.last, trailing.contains(last), !token.hasSuffix("\\" + String(last)) {
                token.removeLast(); length -= (String(last) as NSString).length
            }
            var span = NSRange(location: m.range.location, length: length)
            switch extend(token, in: ns, after: m.range.location + m.range.length) {
            case .extended(let longer, let end):
                token = longer
                span = NSRange(location: m.range.location, length: end - m.range.location)
                covered.append(span)   // later matches inside it are part of this path
            case .fragment: continue   // the start of a longer path that can't be read: no bogus folder
            case .none: break
            }
            guard let range = Range(span, in: text) else { continue }
            if let mention = make(token, range: range, home: home, quoted: false) { found.append(mention) }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    enum Extension: Equatable { case none, extended(String, end: Int), fragment }

    /// Carries an unquoted `token` (ending at UTF-16 offset `end` of `text`) on across spaces and
    /// parentheses, word by word on the same line (≤ `maxExtraWords`, ≤ `maxExtraLength`), stopping
    /// at a word that starts another path. It is carried on to the first word that ends in an image
    /// file name when that reads like one name — a single word ("old photo.jpg", "photo (1).png"),
    /// a folder name with a slash ("My Refs/heron.png"), a parenthesis, or a word with a digit before
    /// the last ("Screenshot 2026-11-15 at 10.41.23.png") — and not otherwise ("refs and sunset.png"
    /// stays the folder refs); or to a word ending in "/" within two words ("My Refs/"). A token
    /// directly followed by a word with a slash inside that leads nowhere is a `fragment`.
    static func extend(_ token: String, in text: NSString, after end: Int) -> Extension {
        guard !token.hasSuffix("/"), !ReferenceFolders.isImageFileName(token) else { return .none }
        var words: [(text: String, start: Int, end: Int)] = []
        var i = end
        let limit = min(text.length, end + maxExtraLength)
        func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0xA0 || c == 0x202F || c == 0x2009 }
        func isBreak(_ c: unichar) -> Bool {
            isSpace(c) || c == 0x0A || c == 0x0D || "\"'`,;<>[]\u{201C}\u{201D}\u{2018}".utf16.contains(c)
        }
        while words.count < maxExtraWords, i < limit {
            var j = i
            while j < limit, isSpace(text.character(at: j)) { j += 1 }
            guard j < limit, !isBreak(text.character(at: j)) else { break }
            var k = j
            while k < limit, !isBreak(text.character(at: k)) { k += 1 }
            let word = text.substring(with: NSRange(location: j, length: k - j))
            if word.hasPrefix("/") || word.hasPrefix("~/") || word.hasPrefix("file://") { break }
            words.append((word, j, k))
            i = k
        }
        guard !words.isEmpty else { return .none }
        for (n, w) in words.enumerated() {
            var trimmed = w.text, wordEnd = w.end
            while let last = trimmed.last, trailing.contains(last) {
                trimmed.removeLast(); wordEnd -= (String(last) as NSString).length
            }
            guard !trimmed.isEmpty else { break }
            let candidate = token + text.substring(with: NSRange(location: end, length: wordEnd - end))
            if ReferenceFolders.isImageFileName(candidate) {
                let extra = words[0...n].map(\.text)
                let reads = n == 0 || extra.contains { $0.contains("/") } || words[0].text.hasPrefix("(")
                    || extra.dropLast().contains { $0.contains(where: \.isNumber) }
                return reads ? .extended(candidate, end: wordEnd) : .none
            }
            if n < 2, w.text.hasSuffix("/") || trimmed.hasSuffix("/") {
                return .extended(candidate, end: wordEnd)
            }
        }
        let first = words[0].text
        if first.dropLast().contains("/") { return .fragment }
        return .none
    }

    private static func make(_ typed: String, range: Range<String.Index>, home: URL, quoted: Bool) -> PromptPathMention? {
        var path = typed.trimmingCharacters(in: .whitespaces)
        if !quoted { path = path.replacingOccurrences(of: "\\ ", with: " ") }
        if path.hasPrefix("file://") {
            guard let url = URL(string: path), url.isFileURL else { return nil }
            path = url.path
        }
        // Globs ("~/Desktop/*.png") aren't paths.
        guard !path.contains("*") else { return nil }
        let isFolderSyntax = path.hasSuffix("/")
        if path.hasPrefix("~/") { path = home.appendingPathComponent(String(path.dropFirst(2))).path }
        let fromHome = typed.hasPrefix("~/")
        guard path.hasPrefix("/"), path.count > 1, path != home.path else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let ext = url.pathExtension
        let kind: PromptPathMention.Kind
        if !isFolderSyntax, !ext.isEmpty, let type = UTType(filenameExtension: ext), type.conforms(to: .image), !type.conforms(to: .svg) {
            kind = .image
        } else {
            // A known kind of document (notes.txt, a scene package) isn't a folder of images; an
            // unknown "extension" is part of a folder's name ("refs.old", "v1.2").
            if !isFolderSyntax, !ext.isEmpty {
                guard ext.lowercased() != SceneManifest.packageExtension,
                      UTType(filenameExtension: ext).map({ $0.isDynamic }) ?? true else { return nil }
            }
            // "/s" in "90°/s" isn't a folder anyone means: an absolute folder needs two components
            // (or a trailing slash, or to start at ~/).
            guard isFolderSyntax || fromHome || url.pathComponents.count >= 3 else { return nil }
            kind = .folder
        }
        return PromptPathMention(text: typed, range: range, url: url, kind: kind)
    }

    /// Folders macOS guards with a privacy prompt (or that may be offline): LivePaper doesn't look
    /// into them until the user asks. Case-insensitive, as the volume is (`~/desktop/x` is the Desktop).
    public static func isPrivacyProtected(_ url: URL, home: URL = LPPaths.home) -> Bool {
        let path = url.standardizedFileURL.path.lowercased()
        let roots = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
            .map { home.appendingPathComponent($0).path.lowercased() } + ["/volumes"]
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// `notPermitted`: macOS refused to let this process look (a privacy-protected folder it has no
    /// access to), which isn't the same as the path not existing.
    public enum Resolution: Sendable, Equatable { case image(URL), folder(URL), missing, notAnImage, notPermitted }

    /// What a mention names on disk (touches the file system).
    public static func resolve(_ m: PromptPathMention) -> Resolution {
        let found = AISessionPolicy.lookUp(m.url.path)
        guard let real = found.real else { return found.denied ? .notPermitted : .missing }
        switch ReferenceFolders.fileType(real) {
        case S_IFDIR: return .folder(m.url)
        case S_IFREG: return ReferenceFolders.isImageFileName(real) || ReferenceFolders.isImageFileName(m.url.path) ? .image(m.url) : .notAnImage
        default: return .notAnImage
        }
    }

    /// `prompt` with every mention of an attached image (or of a folder they came from) replaced by
    /// its workspace name, plus the mentions that weren't attached. No file-system access: matches
    /// are by the paths the references were added with (as given, and real). The attached files'
    /// paths are also replaced wherever they appear literally (as given, real, `~/…`, with `\ `
    /// escapes, as a file URL), so an attached path never survives into TASK.md or the history,
    /// however `mentions` read it.
    public static func rewrite(_ prompt: String, attached: [PreparedReference], home: URL = LPPaths.home)
        -> (text: String, unattached: [PromptPathMention]) {
        let ns = prompt as NSString
        let paths: [(index: Int, paths: [String], file: String)] = attached.enumerated().map { i, r in
            (i + 1, [r.requestedPath, r.originPath].compactMap { $0 }, ReferenceWorkspace.relativeImagePath(index: i + 1, format: r.vision.format))
        }
        var edits: [(range: NSRange, with: String)] = []
        func free(_ r: NSRange) -> Bool { !edits.contains { NSIntersectionRange($0.range, r).length > 0 } }

        // 1. Literal occurrences of the attached files' paths, longest first.
        var forms: [(text: String, file: String)] = []
        for p in paths {
            for path in p.paths {
                for form in Self.forms(of: path, home: home) where !forms.contains(where: { $0.text == form }) { forms.append((form, p.file)) }
            }
        }
        forms.sort { ($0.text as NSString).length > ($1.text as NSString).length }
        for form in forms {
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let r = ns.range(of: form.text, options: [], range: search)
                guard r.location != NSNotFound else { break }
                search = NSRange(location: r.location + r.length, length: ns.length - r.location - r.length)
                guard isBoundary(ns, before: r.location), isBoundary(ns, after: r.location + r.length) else { continue }
                let widened = widenToQuotes(r, in: ns)
                if free(widened) { edits.append((widened, "`\(form.file)`")) }
            }
        }

        // 2. Mentions: an attached image, a folder attached images came from, or not attached.
        var unattached: [PromptPathMention] = []
        for m in mentions(in: prompt, home: home) {
            let p = m.url.path
            let where_ = NSRange(m.range, in: prompt)
            guard free(where_) else { continue }
            if let hit = paths.first(where: { $0.paths.contains(p) }) {
                edits.append((where_, "`\(hit.file)`"))
                continue
            }
            let inside = paths.filter { $0.paths.contains { $0.hasPrefix(p + "/") } }.map(\.index)
            if !inside.isEmpty {
                edits.append((where_, "`\(ReferenceWorkspace.directoryName)/` (\(indexList(inside)))"))
                continue
            }
            unattached.append(m)
        }
        // Replaced back to front through UTF-16 offsets taken before any change.
        let text = NSMutableString(string: prompt)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            text.replaceCharacters(in: edit.range, with: edit.with)
        }
        return (text as String, unattached)
    }

    /// The ways a path may have been typed: as is, `~/…`, with `\ ` escapes, as a file URL.
    static func forms(of path: String, home: URL) -> [String] {
        var out = [path]
        let homePath = home.standardizedFileURL.path
        if path.hasPrefix(homePath + "/") { out.append("~/" + path.dropFirst(homePath.count + 1)) }
        for p in out where p.contains(" ") { out.append(p.replacingOccurrences(of: " ", with: "\\ ")) }
        out.append(URL(fileURLWithPath: path).absoluteString)
        return out
    }

    /// No path character right before `i` (the match isn't the tail of a longer path).
    private static func isBoundary(_ s: NSString, before i: Int) -> Bool {
        guard i > 0, let c = Unicode.Scalar(s.character(at: i - 1)) else { return true }
        return !(CharacterSet.alphanumerics.contains(c) || "/._-~\\".unicodeScalars.contains(c))
    }

    /// No path character right after `i` (the match isn't the head of a longer name).
    private static func isBoundary(_ s: NSString, after i: Int) -> Bool {
        guard i < s.length, let c = Unicode.Scalar(s.character(at: i)) else { return true }
        if CharacterSet.alphanumerics.contains(c) || "/_-~".unicodeScalars.contains(c) { return false }
        if c == ".", i + 1 < s.length, let d = Unicode.Scalar(s.character(at: i + 1)), CharacterSet.alphanumerics.contains(d) { return false }
        return true
    }

    /// `r` with the quotes around it, when it is quoted ('…', "…", `…`, “…”, ‘…’).
    private static func widenToQuotes(_ r: NSRange, in s: NSString) -> NSRange {
        guard r.location > 0, r.location + r.length < s.length else { return r }
        let open = s.character(at: r.location - 1), close = s.character(at: r.location + r.length)
        let pairs: [(unichar, unichar)] = [(0x27, 0x27), (0x22, 0x22), (0x60, 0x60), (0x201C, 0x201D), (0x2018, 0x2019)]
        return pairs.contains { $0.0 == open && $0.1 == close } ? NSRange(location: r.location - 1, length: r.length + 2) : r
    }

    /// "ref-03", "ref-01 … ref-04", "ref-01, ref-03".
    static func indexList(_ indexes: [Int]) -> String {
        let names = indexes.map { String(format: "ref-%02d", $0) }
        guard names.count > 1 else { return names.first ?? "" }
        let contiguous = zip(indexes, indexes.dropFirst()).allSatisfy { $1 == $0 + 1 }
        return contiguous && names.count > 2 ? "\(names[0]) \u{2026} \(names[names.count - 1])" : names.joined(separator: ", ")
    }
}
