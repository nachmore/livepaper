// SceneSourceScanner — static checks on scene sources before they are inlined. Owner: WS-runtime.
//
// Scenes run offline inside the (sandboxed) screen saver, and the compiled HTML also carries a CSP
// that blocks all network access at run time. This scanner exists to turn mistakes into clear,
// line-precise compile errors an AI agent can act on, instead of silent CSP failures. It is a small
// JavaScript tokenizer (comments, strings, template literals, regex literals) so URLs in comments are
// fine and `obj.fetch()` on the scene's own objects is not mistaken for the network API.
import Foundation

/// One problem found in a scene source file.
public struct SceneSourceIssue: Sendable, Equatable, CustomStringConvertible {
    public var file: String
    public var line: Int
    public var column: Int
    public var message: String
    public init(file: String, line: Int, column: Int, message: String) {
        self.file = file; self.line = line; self.column = column; self.message = message
    }
    public var description: String { "\(file):\(line):\(column): \(message)" }
}

public enum SceneSourceScanner {
    static let offlineHint = "Scenes must work offline: put files in assets/ and use LivePaper.asset(name), LivePaper.image(name) or LivePaper.text(name)."

    /// Network APIs that are never allowed (as globals or via window./self./globalThis.).
    static let networkGlobals: Set<String> = ["fetch", "XMLHttpRequest", "WebSocket", "EventSource", "importScripts",
                                              "WebTransport", "RTCPeerConnection"]
    /// Persistent storage: the screen saver loads scenes into a throwaway, opaque-origin page where
    /// these throw or forget everything, so a scene that relies on them breaks only on the lock screen.
    static let storageGlobals: Set<String> = ["localStorage", "sessionStorage", "indexedDB"]
    static let globalObjects: Set<String> = ["window", "self", "globalThis", "top", "parent", "frames"]
    /// XML namespace identifiers look like URLs but are never fetched.
    static let allowedURLPrefixes = ["http://www.w3.org/", "https://www.w3.org/"]

    /// Scans JavaScript for network access, external URLs and ES-module syntax.
    public static func scanJavaScript(_ source: String, file: String = "scene.js") -> [SceneSourceIssue] {
        let tokens = JSTokenizer.tokens(source)
        var issues: [SceneSourceIssue] = []
        // Names the scene declares itself (function fetch() {...}) are the scene's business.
        var declared = Set<String>()
        for (i, t) in tokens.enumerated() where t.kind == .identifier && i > 0 {
            let p = tokens[i - 1]
            if p.kind == .identifier, ["function", "let", "const", "var", "class"].contains(p.text) { declared.insert(t.text) }
        }
        func issue(_ t: JSToken, _ message: String) {
            issues.append(SceneSourceIssue(file: file, line: t.line, column: t.column, message: message))
        }
        for (i, t) in tokens.enumerated() {
            let prev = i > 0 ? tokens[i - 1] : nil
            let next = i + 1 < tokens.count ? tokens[i + 1] : nil
            switch t.kind {
            case .identifier:
                let isMember = prev?.kind == .punct && prev?.text == "."
                let memberOf = isMember && i > 1 && tokens[i - 2].kind == .identifier ? tokens[i - 2].text : nil
                let afterBraceOrComma = prev?.text == "{" || prev?.text == ","
                let isObjectKey = next?.text == ":" && afterBraceOrComma
                // `{ fetch() { … } }`: a method of the scene's own object or class, not a call.
                let isMethodDefinition = next?.text == "(" && (afterBraceOrComma || prev?.text == "}" || prev?.text == ";")
                    && tokenAfterParens(tokens, from: i + 1)?.text == "{"
                if isObjectKey || isMethodDefinition { continue }
                if networkGlobals.contains(t.text), !declared.contains(t.text),
                   !isMember || globalObjects.contains(memberOf ?? "") {
                    issue(t, "network access is not allowed (\(t.text)). \(offlineHint)")
                } else if storageGlobals.contains(t.text), !declared.contains(t.text),
                          !isMember || globalObjects.contains(memberOf ?? "") {
                    issue(t, "\(t.text) is not available to scenes (the screen saver keeps no storage). Derive state from lp.t and lp.rand instead.")
                } else if t.text == "cookie", memberOf == "document" {
                    issue(t, "document.cookie is not available to scenes (the screen saver keeps no storage).")
                } else if t.text == "sendBeacon", memberOf == "navigator" {
                    issue(t, "network access is not allowed (navigator.sendBeacon). \(offlineHint)")
                } else if t.text == "import", !isMember {
                    if next?.text == "(" {
                        issue(t, "dynamic import() is not allowed: put all code in scene.js.")
                    } else if next?.text == "." {
                        issue(t, "import.meta is not available: scene.js is a classic script, not a module.")
                    } else {
                        issue(t, "ES module syntax (import) is not supported: scene.js is a classic script. Put all code in scene.js; no other files are loaded.")
                    }
                } else if t.text == "export", !isMember, let n = next, n.kind == .identifier || ["{", "*"].contains(n.text) {
                    issue(t, "ES module syntax (export) is not supported: scene.js is a classic script that calls LivePaper.scene({...}).")
                }
            case .string:
                if let url = externalURL(in: t.text) {
                    issue(t, "external URL \"\(url)\" is not allowed. \(offlineHint)")
                }
            case .punct, .number, .regex:
                break
            }
        }
        return issues
    }

    /// The token following the parenthesised group that opens at `open`, if any.
    private static func tokenAfterParens(_ tokens: [JSToken], from open: Int) -> JSToken? {
        var depth = 0, j = open
        while j < tokens.count {
            let t = tokens[j]
            if t.kind == .punct, t.text == "(" { depth += 1 }
            if t.kind == .punct, t.text == ")" { depth -= 1; if depth == 0 { return j + 1 < tokens.count ? tokens[j + 1] : nil } }
            j += 1
        }
        return nil
    }

    /// Scans a text asset (SVG, JSON, shader…) for external URLs.
    public static func scanText(_ text: String, file: String) -> [SceneSourceIssue] {
        var issues: [SceneSourceIssue] = []
        var line = 1
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let url = externalURL(in: String(rawLine)) {
                let col = (rawLine.range(of: url).map { rawLine.distance(from: rawLine.startIndex, to: $0.lowerBound) } ?? 0) + 1
                issues.append(SceneSourceIssue(file: file, line: line, column: col,
                                               message: "external URL \"\(url)\" is not allowed. \(offlineHint)"))
            }
            line += 1
        }
        return issues
    }

    private static let urlPattern = try! NSRegularExpression(
        pattern: #"(?i)(?:\b(?:https?|wss?|ftp)://[^\s"'`<>()]*|^//[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}(?:[/:?#][^\s"'`<>()]*)?$)"#)

    /// The first URL in `text` that would be fetched from the network, if any.
    static func externalURL(in text: String) -> String? {
        let unescaped = text.replacingOccurrences(of: "\\/", with: "/")
        let ns = unescaped as NSString
        for m in urlPattern.matches(in: unescaped, range: NSRange(location: 0, length: ns.length)) {
            let url = ns.substring(with: m.range)
            if allowedURLPrefixes.contains(where: { url.lowercased().hasPrefix($0) }) { continue }
            return url.count > 100 ? String(url.prefix(100)) + "…" : url
        }
        return nil
    }
}

// MARK: - Tokenizer

struct JSToken {
    enum Kind { case identifier, string, punct, number, regex }
    var kind: Kind
    /// Identifier name, string/template-chunk contents (escapes left as written), or the punctuator.
    var text: String
    var line: Int
    var column: Int
}

/// A forgiving JavaScript tokenizer: good enough to separate code from comments, strings, template
/// literals and regular expressions. It never throws; malformed input just yields fewer tokens.
struct JSTokenizer {
    private let b: [UInt8]
    private var i = 0
    private var line = 1
    private var lineStart = 0
    private var tokens: [JSToken] = []
    /// Whether a `/` at this point starts a regular expression (vs. division).
    private var regexAllowed = true
    private var braceDepth = 0
    /// Brace depth at which each open template literal's `${` started.
    private var templateStack: [Int] = []

    /// Keywords after which an expression (and therefore a regex literal) may start.
    private static let regexKeywords: Set<String> = ["return", "typeof", "instanceof", "in", "of", "new", "delete", "void",
                                                     "throw", "case", "do", "else", "yield", "await"]

    init(_ source: String) { b = Array(source.utf8) }

    static func tokens(_ source: String) -> [JSToken] {
        var tokenizer = JSTokenizer(source)
        return tokenizer.tokenize()
    }

    mutating func tokenize() -> [JSToken] {
        while i < b.count {
            let c = b[i]
            switch c {
            case 0x0A: newline(at: i); i += 1
            case 0x20, 0x09, 0x0D, 0x0B, 0x0C: i += 1
            case UInt8(ascii: "/"):
                let n = peek(1)
                if n == UInt8(ascii: "/") { skipLineComment() }
                else if n == UInt8(ascii: "*") { skipBlockComment() }
                else if regexAllowed { scanRegex() }
                else { push(.punct, "/", at: i); i += 1; regexAllowed = true }
            case UInt8(ascii: "\""), UInt8(ascii: "'"): scanString(quote: c)
            case UInt8(ascii: "`"):
                i += 1
                scanTemplateChunk(startedAt: i - 1)
            case UInt8(ascii: "{"):
                braceDepth += 1; push(.punct, "{", at: i); i += 1; regexAllowed = true
            case UInt8(ascii: "}"):
                if let top = templateStack.last, braceDepth - 1 == top {
                    templateStack.removeLast()
                    braceDepth -= 1
                    i += 1
                    scanTemplateChunk(startedAt: i - 1)
                } else {
                    braceDepth = max(0, braceDepth - 1); push(.punct, "}", at: i); i += 1
                    regexAllowed = true // a block usually ends here; `} / x` is far rarer than `}\n/re/`
                }
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                scanNumber()
            case UInt8(ascii: "."):
                if let n = peek(1), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(n) { scanNumber() }
                else { push(.punct, ".", at: i); i += 1; regexAllowed = true }
            default:
                if JSTokenizer.isIdentStart(c) { scanIdentifier() }
                else {
                    push(.punct, String(UnicodeScalar(c)), at: i)
                    i += 1
                    regexAllowed = !(c == UInt8(ascii: ")") || c == UInt8(ascii: "]"))
                }
            }
        }
        return tokens
    }

    private static func isIdentStart(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == UInt8(ascii: "_") || c == UInt8(ascii: "$")
            || c == UInt8(ascii: "#") || c == UInt8(ascii: "\\") || c >= 0x80
    }
    private static func isIdentPart(_ c: UInt8) -> Bool { isIdentStart(c) || (c >= 0x30 && c <= 0x39) }

    private func peek(_ k: Int) -> UInt8? { i + k < b.count ? b[i + k] : nil }
    private mutating func newline(at index: Int) { line += 1; lineStart = index + 1 }
    private mutating func push(_ kind: JSToken.Kind, _ text: String, at start: Int) {
        tokens.append(JSToken(kind: kind, text: text, line: line, column: start - lineStart + 1))
    }
    private func text(_ from: Int, _ to: Int) -> String { String(decoding: b[from..<to], as: UTF8.self) }

    private mutating func skipLineComment() {
        while i < b.count, b[i] != 0x0A { i += 1 }
    }
    private mutating func skipBlockComment() {
        i += 2
        while i < b.count {
            if b[i] == UInt8(ascii: "*"), peek(1) == UInt8(ascii: "/") { i += 2; return }
            if b[i] == 0x0A { newline(at: i) }
            i += 1
        }
    }
    private mutating func scanIdentifier() {
        let start = i
        while i < b.count, JSTokenizer.isIdentPart(b[i]) { i += 1 }
        let name = text(start, i)
        push(.identifier, name, at: start)
        regexAllowed = JSTokenizer.regexKeywords.contains(name)
    }
    private mutating func scanNumber() {
        let start = i
        while i < b.count, JSTokenizer.isIdentPart(b[i]) || b[i] == UInt8(ascii: ".") { i += 1 }
        push(.number, text(start, i), at: start)
        regexAllowed = false
    }
    private mutating func scanString(quote: UInt8) {
        let start = i, startLine = line, startCol = i - lineStart + 1
        i += 1
        while i < b.count, b[i] != quote {
            if b[i] == UInt8(ascii: "\\") {
                if peek(1) == 0x0A { newline(at: i + 1) }
                i += 2; continue
            }
            if b[i] == 0x0A { break } // unterminated: stop at end of line
            i += 1
        }
        let end = min(i, b.count)
        tokens.append(JSToken(kind: .string, text: text(start + 1, end), line: startLine, column: startCol))
        if i < b.count, b[i] == quote { i += 1 }
        regexAllowed = false
    }
    /// Scans template-literal text from `i` up to the closing backtick or the next `${`.
    private mutating func scanTemplateChunk(startedAt start: Int) {
        let startLine = line, startCol = start - lineStart + 1
        let chunkStart = i
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\\") { i += 2; continue }
            if c == 0x0A { newline(at: i) }
            if c == UInt8(ascii: "`") {
                tokens.append(JSToken(kind: .string, text: text(chunkStart, i), line: startLine, column: startCol))
                i += 1
                regexAllowed = false
                return
            }
            if c == UInt8(ascii: "$"), peek(1) == UInt8(ascii: "{") {
                tokens.append(JSToken(kind: .string, text: text(chunkStart, i), line: startLine, column: startCol))
                templateStack.append(braceDepth)
                braceDepth += 1
                i += 2
                regexAllowed = true
                return
            }
            i += 1
        }
        tokens.append(JSToken(kind: .string, text: text(chunkStart, min(i, b.count)), line: startLine, column: startCol))
    }
    private mutating func scanRegex() {
        let start = i
        i += 1
        var inClass = false
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\\") { i += 2; continue }
            if c == 0x0A { break }
            if inClass { if c == UInt8(ascii: "]") { inClass = false } }
            else if c == UInt8(ascii: "[") { inClass = true }
            else if c == UInt8(ascii: "/") { i += 1; break }
            i += 1
        }
        while i < b.count, JSTokenizer.isIdentPart(b[i]) { i += 1 } // flags
        push(.regex, text(start, min(i, b.count)), at: start)
        regexAllowed = false
    }
}
