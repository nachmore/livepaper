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
// reads like one name, or a folder name ending in "/" (see `extend`), never by looking at the disk.
// Where the words don't say ("~/Desktop/Summer Trip for the palette", a folder Finder copies without
// a trailing slash), the mention keeps the shorter path and carries the longer readings as
// `alternatives`, which `resolveReadings` tries on disk when something may look (a click, the CLI).
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
    /// Other readings of an unquoted path, in the order to try them when this one names nothing on
    /// disk (`PromptPaths.resolveReadings`): for a path that was carried on across spaces, the token
    /// it started from first; then the token carried on word by word to the end of its clause
    /// ("~/Desktop/Summer" → "~/Desktop/Summer Trip", "~/Desktop/Summer Trip for", …). Syntax only;
    /// empty for quoted paths and for paths that end the clause.
    public var alternatives: [PromptPathMention]
    public init(text: String, range: Range<String.Index>, url: URL, kind: Kind, alternatives: [PromptPathMention] = []) {
        self.text = text; self.range = range; self.url = url; self.kind = kind; self.alternatives = alternatives
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
            // Sentence punctuation after a path isn't part of it, and the path ends there: it isn't
            // carried on into the next sentence ("…/refs. Then 3 shots like x.png").
            var endsClause = false
            while let last = token.last, trailing.contains(last), !token.hasSuffix("\\" + String(last)) {
                token.removeLast(); length -= (String(last) as NSString).length
                endsClause = true
            }
            let tokenEnd = m.range.location + length
            let words = endsClause ? [] : Self.words(in: ns, after: tokenEnd)
            var span = NSRange(location: m.range.location, length: length)
            var chosen = token
            if let longer = extend(token, words: words, in: ns, after: tokenEnd) {
                chosen = longer.text
                span = NSRange(location: m.range.location, length: longer.end - m.range.location)
                covered.append(span)   // later matches inside it are part of this path
            }
            guard let range = Range(span, in: text), var mention = make(chosen, range: range, home: home, quoted: false) else { continue }
            // The other readings, for a look on disk later: the token it started from, then longer ones.
            var others = chosen == token ? [] : [(text: token, end: tokenEnd)]
            others += readings(token, words: words, in: ns, after: tokenEnd).filter { $0.text != chosen }
            for reading in others {
                guard let r = Range(NSRange(location: m.range.location, length: reading.end - m.range.location), in: text),
                      let other = make(reading.text, range: r, home: home, quoted: false),
                      other.url != mention.url, !mention.alternatives.contains(where: { $0.url == other.url }) else { continue }
                mention.alternatives.append(other)
            }
            found.append(mention)
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// A word after an unquoted path on its line: as typed, without the sentence punctuation after
    /// it, and where that ends (UTF-16 offset).
    struct Word: Equatable {
        var text: String
        var trimmed: String
        var end: Int
        /// Sentence punctuation follows it: the clause (and so the path) ends there.
        var endsClause: Bool { trimmed != text }
    }

    /// The words after `end` on the same line that may still belong to an unquoted path
    /// (≤ `maxExtraWords`, ≤ `maxExtraLength`), stopping at a delimiter or a word that starts
    /// another path.
    static func words(in text: NSString, after end: Int) -> [Word] {
        var words: [Word] = []
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
            var trimmed = word, wordEnd = k
            while let last = trimmed.last, trailing.contains(last) {
                trimmed.removeLast(); wordEnd -= (String(last) as NSString).length
            }
            words.append(Word(text: word, trimmed: trimmed, end: wordEnd))
            i = k
        }
        return words
    }

    /// `token` (ending at UTF-16 offset `end` of `text`) carried on across `words`, one more word
    /// each, shortest first, to the end of its clause: after a word with sentence punctuation, a
    /// reading that ends in "/" or an image file name, nothing more belongs to it.
    static func readings(_ token: String, words: [Word], in text: NSString, after end: Int) -> [(text: String, end: Int)] {
        guard !token.hasSuffix("/"), !ReferenceFolders.isImageFileName(token) else { return [] }
        var out: [(text: String, end: Int)] = []
        for w in words {
            guard !w.trimmed.isEmpty else { break }
            let candidate = token + text.substring(with: NSRange(location: end, length: w.end - end))
            out.append((candidate, w.end))
            if w.endsClause || candidate.hasSuffix("/") || ReferenceFolders.isImageFileName(candidate) { break }
        }
        return out
    }

    /// The reading of an unquoted `token` that is the path when the words say so (nil: the token as
    /// it is) — carried on across spaces and parentheses within its clause (`words`). It is carried on
    /// to the first word that ends in an image file name when that reads like one name — a single
    /// word ("old photo.jpg", "photo (1).png"), a folder name with a slash ("My Old Refs/heron.png"),
    /// a parenthesis that opens right after the token and closes in the file name ("photo (copy
    /// 2).png", not "refs (the folder) and x.png"), a word before it that looks like a date, a time
    /// or a year ("Screenshot 2026-11-15 at 10.41.23.png"; a count such as "3" doesn't), only
    /// capitalised words before it ("My Holiday Photo.png"), or Finder's "copy" ("heron copy
    /// 2.png") — and not otherwise ("refs and sunset.png", "refs for 3 more like x.png" stay the
    /// folder refs); or to a word within two words that ends a folder name in "/" ("My Refs/", not the
    /// shorthand "w/"). Anything else stays the token, with the longer readings as alternatives.
    static func extend(_ token: String, words: [Word], in text: NSString, after end: Int) -> (text: String, end: Int)? {
        guard !token.hasSuffix("/"), !ReferenceFolders.isImageFileName(token) else { return nil }
        for (n, w) in words.enumerated() {
            guard !w.trimmed.isEmpty else { break }
            let candidate = token + text.substring(with: NSRange(location: end, length: w.end - end))
            if ReferenceFolders.isImageFileName(candidate) {
                let extra = words[0...n].map(\.text)
                let before = extra.dropLast()
                let parenthesised = extra[0].hasPrefix("(") && !before.contains { $0.contains(")") }
                let reads = n == 0 || hasFolderPart(w.trimmed) || parenthesised || before.contains(where: looksLikeDateOrTime)
                    || before.allSatisfy { $0.first?.isUppercase == true } || before.allSatisfy { $0.lowercased() == "copy" }
                return reads ? (candidate, w.end) : nil
            }
            if n < 2, endsFolderName(w.trimmed) { return (candidate, w.end) }
            if w.endsClause { break }
        }
        return nil
    }

    /// "Refs/" ends a folder name; "w/" (shorthand for "with") and "/" alone don't.
    static func endsFolderName(_ word: String) -> Bool {
        guard word.hasSuffix("/") else { return false }
        return (word.dropLast().split(separator: "/").last?.count ?? 0) >= 2
    }

    /// "Refs/heron.png": a folder name (two characters or more) before the file name.
    static func hasFolderPart(_ word: String) -> Bool {
        let parts = word.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.dropLast().allSatisfy { $0.count >= 2 }
    }

    /// "2026-11-15", "10.41.23", "12:30", "2024": a date, a time or a year in a file name — not a
    /// count in a sentence ("3", "12", "100").
    static func looksLikeDateOrTime(_ word: String) -> Bool {
        let c = Array(word)
        if c.filter(\.isNumber).count >= 4 { return true }
        guard c.count >= 3 else { return false }
        return (1..<(c.count - 1)).contains { ".:-_".contains(c[$0]) && c[$0 - 1].isNumber && c[$0 + 1].isNumber }
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

    /// `m`, or the first of its other readings (`alternatives`) that names something, with what it
    /// names: `resolve` (the file system, or a test's stand-in) is asked about `m` first and about
    /// the others in order while the answer is `.missing` — so "~/Desktop/Summer Trip for the
    /// palette" finds the folder "Summer Trip", and a longer reading that isn't there falls back to the
    /// shorter one. `m` and `.missing` when none of them is there. Touches the file system: only when
    /// LivePaper may look (a click on a suggestion, paths outside the privacy-protected folders).
    public static func resolveReadings(_ m: PromptPathMention, using resolve: (PromptPathMention) -> Resolution = { PromptPaths.resolve($0) })
        -> (mention: PromptPathMention, resolution: Resolution) {
        let first = resolve(m)
        guard first == .missing else { return (m, first) }
        for other in m.alternatives {
            let found = resolve(other)
            if found != .missing { return (other, found) }
        }
        return (m, .missing)
    }

    /// `prompt` with every mention of an attached image (or of a folder they came from) replaced by
    /// its workspace name, plus the mentions that weren't attached. No file-system access: matches
    /// are by the paths the references were added with (as given, and real). The attached files'
    /// paths, and the folders they came from (below the home folder and /), are also replaced
    /// wherever they appear literally (as given, real, `~/…`, with `\ ` escapes, as a file URL; a
    /// folder with or without its trailing "/"), so an attached path never survives into TASK.md or
    /// the history, however `mentions` read it ("use ~/Desktop/Summer Trip for the palette").
    public static func rewrite(_ prompt: String, attached: [PreparedReference], home: URL = LPPaths.home)
        -> (text: String, unattached: [PromptPathMention]) {
        let ns = prompt as NSString
        let paths: [(index: Int, paths: [String], file: String)] = attached.enumerated().map { i, r in
            (i + 1, [r.requestedPath, r.originPath].compactMap { $0 }, ReferenceWorkspace.relativeImagePath(index: i + 1, format: r.vision.format))
        }
        var edits: [(range: NSRange, with: String)] = []
        func free(_ r: NSRange) -> Bool { !edits.contains { NSIntersectionRange($0.range, r).length > 0 } }
        func folderName(_ indexes: [Int]) -> String { "`\(ReferenceWorkspace.directoryName)/` (\(indexList(indexes)))" }

        // 1. Literal occurrences of the attached files' paths and of the folders they came from, longest first.
        var forms: [(text: String, with: String)] = []
        func add(_ form: String, _ with: String) { if !forms.contains(where: { $0.text == form }) { forms.append((form, with)) } }
        for p in paths {
            for path in p.paths { for form in Self.forms(of: path, home: home) { add(form, "`\(p.file)`") } }
        }
        for folder in sourceFolders(paths.map { ($0.index, $0.paths) }, home: home) {
            for form in Self.forms(of: folder.path, home: home, folder: true) { add(form, folderName(folder.indexes)) }
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
                if free(widened) { edits.append((widened, form.with)) }
            }
        }

        // 2. Mentions — or one of their other readings: an attached image, a folder attached images
        //    came from, or not attached.
        var unattached: [PromptPathMention] = []
        mentions: for m in mentions(in: prompt, home: home) {
            guard free(NSRange(m.range, in: prompt)) else { continue }
            for reading in [m] + m.alternatives {
                let p = reading.url.path
                let where_ = NSRange(reading.range, in: prompt)
                guard free(where_) else { continue }
                if let hit = paths.first(where: { $0.paths.contains(p) }) {
                    edits.append((where_, "`\(hit.file)`"))
                    continue mentions
                }
                let inside = paths.filter { $0.paths.contains { $0.hasPrefix(p + "/") } }.map(\.index)
                if !inside.isEmpty {
                    edits.append((where_, folderName(inside)))
                    continue mentions
                }
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

    /// The ways a path may have been typed: as is, `~/…`, with `\ ` escapes, as a file URL (for a
    /// folder each with and without a trailing "/"). No file-system access.
    static func forms(of path: String, home: URL, folder: Bool = false) -> [String] {
        var out = [path]
        let homePath = home.standardizedFileURL.path
        if path.hasPrefix(homePath + "/") { out.append("~/" + path.dropFirst(homePath.count + 1)) }
        for p in out where p.contains(" ") { out.append(p.replacingOccurrences(of: " ", with: "\\ ")) }
        if folder { out += out.map { $0 + "/" } }
        let url = URL(fileURLWithPath: path, isDirectory: folder).absoluteString
        out.append(url)
        if folder, url.hasSuffix("/") { out.append(String(url.dropLast())) }
        return out
    }

    /// The folders attached files came from, each with the files (their indexes) inside it: every
    /// folder a file is in, up to the home folder (or, outside it, folders with at least two
    /// components, as `mentions` reads them) — never the home folder, a folder that holds it, or /.
    static func sourceFolders(_ files: [(index: Int, paths: [String])], home: URL) -> [(path: String, indexes: [Int])] {
        let homePath = home.standardizedFileURL.path
        var out: [(path: String, indexes: [Int])] = []
        for file in files {
            for path in file.paths {
                var folder = (path as NSString).deletingLastPathComponent
                while folder != homePath, !homePath.hasPrefix(folder + "/"), (folder as NSString).pathComponents.count >= 3 {
                    if let i = out.firstIndex(where: { $0.path == folder }) {
                        if !out[i].indexes.contains(file.index) { out[i].indexes.append(file.index) }
                    } else {
                        out.append((folder, [file.index]))
                    }
                    folder = (folder as NSString).deletingLastPathComponent
                }
            }
        }
        return out.map { ($0.path, $0.indexes.sorted()) }
    }

    /// No path character right before `i` (the match isn't the tail of a longer path).
    private static func isBoundary(_ s: NSString, before i: Int) -> Bool {
        guard i > 0, let c = Unicode.Scalar(s.character(at: i - 1)) else { return true }
        return !(CharacterSet.alphanumerics.contains(c) || "/._-~\\".unicodeScalars.contains(c))
    }

    /// No path character right after `i` (the match isn't the head of a longer name or path: a
    /// full stop ends a sentence, but not in "x.png.bak" or "~/Desktop/./more").
    private static func isBoundary(_ s: NSString, after i: Int) -> Bool {
        guard i < s.length, let c = Unicode.Scalar(s.character(at: i)) else { return true }
        if CharacterSet.alphanumerics.contains(c) || "/_-~".unicodeScalars.contains(c) { return false }
        if c == ".", i + 1 < s.length, let d = Unicode.Scalar(s.character(at: i + 1)),
           CharacterSet.alphanumerics.contains(d) || "/.".unicodeScalars.contains(d) { return false }
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
