// ReferenceTray — the reference images attached to a Describe-it card or a Modify sheet, before
// the session starts (ARCHITECTURE §11). Images are prepared (decoded, re-encoded, stripped) once,
// when added, off the main thread and one at a time; starting the session then only hands the
// prepared copies to AIServicing. Also: suggestions for image paths typed into the prompt, and
// the rules for what a paste or a drop contains.
// Foundation, Observation and UniformTypeIdentifiers only (compiled into LivePaperSelfTest too).
import Darwin
import Foundation
import LivePaperCore
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ReferenceTray {
    struct Item: Identifiable, Equatable {
        enum State: Equatable {
            case preparing
            case ready(PreparedReference)
            /// One sentence saying why (shown on the tile).
            case failed(String)
        }
        let id: UUID
        var displayName: String
        var role: AIReferenceRole
        var state: State
        /// The file's real path (nil for pasted or dropped data): duplicates are recognised by it.
        var originPath: String?
        /// The path as given, for matching paths typed into the prompt.
        var requestedPath: String?

        var isFailed: Bool { if case .failed = state { return true } else { return false } }
        var isPreparing: Bool { state == .preparing }
    }

    typealias Prepare = @Sendable (ReferenceInput) throws -> PreparedReference
    typealias Expand = @Sendable ([URL], Int, Set<String>) -> ReferenceExpansion

    /// Display names of pasted and dropped data, numbered by the tray.
    nonisolated static let pastedName = "Pasted image", droppedName = "Dropped image"

    private(set) var items: [Item] = []
    /// One-line notes (what was left out, what couldn't be attached), dismissible.
    private(set) var notes: [String] = []
    /// Image files and folders the prompt names that aren't attached yet.
    private(set) var suggestions: [PromptPathMention] = []

    private let prepare: Prepare
    private let expand: Expand
    private let resolve: @Sendable (PromptPathMention) -> PromptPaths.Resolution
    private let home: URL
    private var queue: Task<Void, Never>?
    private var dismissed: Set<String> = []
    private var dataCounters: [String: Int] = [:]
    private var suggestionGeneration = 0

    init(prepare: @escaping Prepare = { try ReferenceImporter.prepare($0) },
         expand: @escaping Expand = { ReferenceFolders.expand($0, capacity: $1, excluding: $2) },
         resolve: @escaping @Sendable (PromptPathMention) -> PromptPaths.Resolution = { PromptPaths.resolve($0) },
         home: URL = LPPaths.home) {
        self.prepare = prepare; self.expand = expand; self.resolve = resolve; self.home = home
    }

    // MARK: - State

    /// Items that count towards the limit (failed ones don't).
    var activeCount: Int { items.filter { !$0.isFailed }.count }
    var remainingCapacity: Int { max(0, ReferenceLimits.maxImages - activeCount) }
    var isPreparing: Bool { items.contains(where: \.isPreparing) }
    var isEmpty: Bool { items.isEmpty }

    /// The prepared images, in tray order, with the roles chosen in the tray.
    var references: [PreparedReference] {
        items.compactMap { item in
            guard case .ready(var r) = item.state else { return nil }
            r.role = item.role
            return r
        }
    }

    /// "3 images · 1 to animate", "1 image", "" when empty.
    var summaryText: String {
        let n = activeCount
        guard n > 0 else { return "" }
        let animate = items.filter { !$0.isFailed && $0.role == .animate }.count
        return "\(n) image\(n == 1 ? "" : "s")" + (animate > 0 ? " \u{00B7} \(animate) to animate" : "")
    }

    /// Waits until everything added so far is prepared (tests; the UI observes `isPreparing`).
    func settled() async {
        while let q = queue {
            await q.value
            if queue == nil || queue == q { break }
        }
    }

    // MARK: - Adding

    /// Adds images (files, folders, data). Folders are expanded and everything is prepared off the
    /// main thread, one image at a time; duplicates (same real path) are skipped and anything over
    /// the limit is left out with a note. `animate`: the first image added becomes the one to animate.
    func add(_ inputs: [ReferenceInput], animate: Bool = false) {
        guard !inputs.isEmpty else { return }
        enqueue { [self] in await self.process(inputs, animate: animate) }
    }

    func addFiles(_ urls: [URL]) { add(urls.map { ReferenceInput.file($0) }) }

    func addNotes(_ new: [String]) {
        for note in new where !note.isEmpty && !notes.contains(note) { notes.append(note) }
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    /// Choosing "Animate this image" for one item makes every other item a reference.
    func setRole(_ role: AIReferenceRole, for id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        for i in items.indices {
            if items[i].id == id { items[i].role = role } else if role == .animate, items[i].role == .animate { items[i].role = .reference }
        }
    }

    func clear() {
        items = []; notes = []; suggestions = []
    }

    func dismissNote(at index: Int) {
        guard notes.indices.contains(index) else { return }
        notes.remove(at: index)
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        queue = task
    }

    private func process(_ inputs: [ReferenceInput], animate: Bool) async {
        var leftOut = ReferenceExpansion.LeftOut()
        var accepted: [(ReferenceInput, origin: String?, requested: String?)] = []
        var room = remainingCapacity
        // Files and folders: expanded (and their real paths looked up) off the main thread.
        let fileInputs = inputs.compactMap { input -> (URL, AIReferenceRole)? in
            if case .file(let url) = input.source { return (url.standardizedFileURL, input.role) }
            return nil
        }
        if !fileInputs.isEmpty {
            let existing = Set(items.filter { !$0.isFailed }.compactMap(\.originPath))
            let expand = self.expand, urls = fileInputs.map(\.0), capacity = room
            let (expansion, origins) = await Task.detached { () -> (ReferenceExpansion, [String?]) in
                let e = expand(urls, capacity, existing)
                return (e, e.files.map { Self.realPath($0.path) })
            }.value
            leftOut = expansion.leftOut
            for (url, origin) in zip(expansion.files, origins) {
                let role = fileInputs.first { $0.0 == url.standardizedFileURL }?.1 ?? .reference
                accepted.append((.file(url, role: role), origin, url.standardizedFileURL.path))
            }
            room -= expansion.files.count
        }
        // Pasted or dropped data.
        for input in inputs {
            guard case .data = input.source else { continue }
            guard room > 0 else { leftOut.overLimit += 1; continue }
            var named = input
            if [Self.pastedName, Self.droppedName].contains(input.displayName) {
                dataCounters[input.displayName, default: 0] += 1
                named.displayName = "\(input.displayName) \(dataCounters[input.displayName]!)"
            }
            accepted.append((named, nil, nil))
            room -= 1
        }
        if let sentence = leftOut.sentence() { addNotes([sentence.prefix(1).uppercased() + sentence.dropFirst() + "."]) }

        var added: [(UUID, ReferenceInput)] = []
        for (i, (input, origin, requested)) in accepted.enumerated() {
            var role = input.role
            if animate && i == 0 { role = .animate }
            let item = Item(id: UUID(), displayName: input.displayName, role: .reference, state: .preparing, originPath: origin,
                            requestedPath: requested)
            items.append(item)
            if role == .animate { setRole(.animate, for: item.id) }
            added.append((item.id, input))
        }
        // One at a time: a photo takes a few hundred ms and up to ~100 MB while it is decoded.
        let prepare = self.prepare
        for (id, input) in added {
            guard items.contains(where: { $0.id == id }) else { continue }   // removed meanwhile
            let result = await Task.detached { Result { try prepare(input) } }.value
            guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
            switch result {
            case .success(let prepared): items[i].state = .ready(prepared)
            case .failure(let error): items[i].state = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated static func realPath(_ path: String) -> String? {
        guard let p = Darwin.realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    // MARK: - Paths typed into the prompt

    /// The image files and folders `prompt` names that aren't attached or dismissed. Paths in
    /// privacy-protected folders (Desktop, Documents, Downloads, iCloud Drive, volumes) are offered
    /// unverified, so typing never triggers a privacy prompt; others are checked off the main thread.
    func updateSuggestions(for prompt: String) async {
        suggestionGeneration += 1
        let generation = suggestionGeneration
        let attachedPaths = items.flatMap { [$0.originPath, $0.requestedPath].compactMap { $0 } }
        let candidates = PromptPaths.mentions(in: prompt, home: home).filter { m in
            let p = m.url.path
            guard !dismissed.contains(p) else { return false }
            return !attachedPaths.contains { $0 == p || $0.hasPrefix(p + "/") }
        }
        let home = self.home, resolve = self.resolve
        let kept = await Task.detached { () -> [PromptPathMention] in
            var out: [PromptPathMention] = []
            for m in candidates where !out.contains(where: { $0.url == m.url }) {
                if PromptPaths.isPrivacyProtected(m.url, home: home) { out.append(m); continue }
                switch resolve(m) {
                case .image: var x = m; x.kind = .image; out.append(x)
                case .folder: var x = m; x.kind = .folder; out.append(x)
                case .missing, .notAnImage: continue
                }
            }
            return out
        }.value
        guard generation == suggestionGeneration else { return }   // the prompt changed meanwhile
        suggestions = kept
    }

    /// Attaches what a suggestion names (looked up now, on the user's click).
    func attach(_ m: PromptPathMention, animate: Bool = false) {
        suggestions.removeAll { $0.url == m.url }
        let resolve = self.resolve
        enqueue { [self] in
            let found = await Task.detached { resolve(m) }.value
            let name = m.url.lastPathComponent
            switch found {
            case .image(let url): await self.process([.file(url, role: animate ? .animate : .reference)], animate: animate)
            case .folder(let url): await self.process([.file(url)], animate: false)
            case .missing: self.addNotes(["\u{201C}\(name)\u{201D} wasn't found; check the path in the prompt."])
            case .notAnImage: self.addNotes(["\u{201C}\(name)\u{201D} isn't an image or a folder."])
            }
        }
    }

    func dismiss(_ m: PromptPathMention) {
        dismissed.insert(m.url.path)
        suggestions.removeAll { $0.url == m.url }
    }
}

// MARK: - Paste and drop

/// What a paste holds, from the pasteboard's types and file URLs (the AppKit side reads those).
enum ReferencePasteRules {
    enum Kind: Equatable { case images, text }

    /// Images when the pasteboard holds file URLs of images or folders (a Finder copy) — file URLs
    /// of anything else are text (Finder also puts the file's icon on the pasteboard) — or, without
    /// file URLs, when the first item's first image type comes before any text type (a screenshot,
    /// Safari's Copy Image; rich text with an image in it stays text).
    static func classify(itemTypes: [[String]], fileURLs: [URL]) -> Kind {
        if !fileURLs.isEmpty {
            return fileURLs.contains { $0.hasDirectoryPath || ReferenceFolders.isImageFileName($0.lastPathComponent) } ? .images : .text
        }
        guard let first = itemTypes.first else { return .text }
        for id in first {
            guard let type = UTType(id) else { continue }
            if type.conforms(to: .image) { return .images }
            if type.conforms(to: .text) { return .text }
        }
        return .text
    }

    /// The first image type of a list (what to read the data as).
    static func imageType(in types: [String]) -> String? {
        types.first { UTType($0)?.conforms(to: .image) == true }
    }
}

/// Turns dropped items into inputs: file URLs (Finder, Photos) as files, image data (a browser, an
/// app) as data, and web URLs as a note — LivePaper never downloads anything.
enum ReferenceDropReader {
    static let acceptedTypes: [UTType] = [.fileURL, .image, .url]

    static let webNote = "LivePaper doesn't download images \u{2014} save it to your Mac first, then drop the file."

    static func inputs(from providers: [NSItemProvider]) async -> (inputs: [ReferenceInput], notes: [String]) {
        var inputs: [ReferenceInput] = [], notes: [String] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let url = await fileURL(provider) {
                inputs.append(.file(url))
            } else if let type = ReferencePasteRules.imageType(in: provider.registeredTypeIdentifiers) {
                switch await data(provider, type: type) {
                case .some(let d) where d.count <= ReferenceLimits.maxFileBytes:
                    inputs.append(ReferenceInput(source: .data(d, typeIdentifier: type), role: .reference, displayName: ReferenceTray.droppedName))
                case .some(let d):
                    notes.append(ReferenceError.tooLarge(name: ReferenceTray.droppedName.lowercased(), bytes: d.count).localizedDescription)
                case .none:
                    notes.append("A dropped image couldn't be read.")
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if !notes.contains(webNote) { notes.append(webNote) }
            }
        }
        return (inputs, notes)
    }

    private static func fileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url?.isFileURL == true ? url : nil) }
        }
    }

    private static func data(_ provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in done.resume(returning: data) }
        }
    }
}
