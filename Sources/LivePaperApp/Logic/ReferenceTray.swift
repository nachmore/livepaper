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
    /// An image still preparing that becomes the one to animate once it is ready.
    private var pendingAnimate: UUID?
    private var dataCounters: [String: Int] = [:]
    private var suggestionGeneration = 0
    /// Batches (adds, attaches) queued or running.
    private var pendingBatches = 0
    /// Called with the reasons when images of one batch couldn't be prepared (the Create card posts
    /// a banner; the tray itself marks the tiles and lists the reasons under them).
    @ObservationIgnored var onFailures: (@MainActor ([String]) -> Void)?

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
    var preparingCount: Int { items.filter(\.isPreparing).count }
    /// Anything added is still being looked at: folders expanded, a suggestion resolved, images
    /// prepared. Generate / Start wait for it (a folder's images only appear once it was expanded).
    var isBusy: Bool { pendingBatches > 0 || isPreparing }
    /// The reasons images couldn't be added, one per failed tile, in tray order.
    var failures: [(id: UUID, message: String)] {
        items.compactMap { item in
            if case .failed(let why) = item.state { return (item.id, why) }
            return nil
        }
    }
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

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        if pendingAnimate == id { pendingAnimate = nil }
    }

    /// Choosing "Animate this image" for one item makes every other item a reference. Only a
    /// ready image can be the one to animate (one still preparing gets it once it is ready, if the
    /// user didn't choose another meanwhile; one that failed never does).
    func setRole(_ role: AIReferenceRole, for id: UUID) {
        guard let target = items.first(where: { $0.id == id }) else { return }
        if role == .animate {
            switch target.state {
            case .ready: break
            case .preparing: pendingAnimate = id; return
            case .failed: return
            }
        }
        if pendingAnimate == id || role == .animate { pendingAnimate = nil }
        for i in items.indices {
            if items[i].id == id { items[i].role = role } else if role == .animate, items[i].role == .animate { items[i].role = .reference }
        }
    }

    func clear() {
        items = []; notes = []; suggestions = []; pendingAnimate = nil
    }

    func dismissNote(at index: Int) {
        guard notes.indices.contains(index) else { return }
        notes.remove(at: index)
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        pendingBatches += 1
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await work()
            self?.pendingBatches -= 1
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
            // Folders with nothing in them to attach (empty, hidden files only): say so.
            if expansion.files.isEmpty, expansion.leftOut.isEmpty {
                addNotes([ReferenceTrayText.nothingFound(in: fileInputs.map(\.0))])
            }
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
        if let note = leftOut.note { addNotes([note]) }

        var added: [(UUID, ReferenceInput)] = []
        for (i, (input, origin, requested)) in accepted.enumerated() {
            var role = input.role
            if animate && i == 0 { role = .animate }
            let item = Item(id: UUID(), displayName: input.displayName, role: .reference, state: .preparing, originPath: origin,
                            requestedPath: requested)
            items.append(item)
            // Promoted once it is ready: an image that fails must not cost the current one its role.
            if role == .animate { pendingAnimate = item.id }
            added.append((item.id, input))
        }
        // One at a time: a photo takes a few hundred ms and up to ~100 MB while it is decoded.
        let prepare = self.prepare
        var failed: [String] = []
        for (id, input) in added {
            guard items.contains(where: { $0.id == id }) else { continue }   // removed meanwhile
            let result = await Task.detached { Result { try prepare(input) } }.value
            guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
            switch result {
            case .success(let prepared):
                items[i].state = .ready(prepared)
                if pendingAnimate == id { setRole(.animate, for: id) }
            case .failure(let error):
                items[i].state = .failed(error.localizedDescription)
                failed.append(error.localizedDescription)
                if pendingAnimate == id { pendingAnimate = nil }
            }
        }
        if !failed.isEmpty { onFailures?(failed) }
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
                case .missing, .notAnImage, .notPermitted: continue
                }
            }
            return out
        }.value
        guard generation == suggestionGeneration else { return }   // the prompt changed meanwhile
        suggestions = kept
    }

    /// Attaches what a suggestion names (looked up now, on the user's click). Whatever came of it,
    /// the same path isn't suggested again (attached, or explained by a note).
    func attach(_ m: PromptPathMention, animate: Bool = false) {
        suggestions.removeAll { $0.url == m.url }
        dismissed.insert(m.url.path)
        let resolve = self.resolve
        enqueue { [self] in
            let found = await Task.detached { resolve(m) }.value
            let name = m.url.lastPathComponent
            switch found {
            case .image(let url): await self.process([.file(url, role: animate ? .animate : .reference)], animate: animate)
            case .folder(let url): await self.process([.file(url)], animate: false)
            case .missing: self.addNotes(["\u{201C}\(name)\u{201D} wasn't found; check the path in the prompt."])
            case .notAnImage: self.addNotes(["\u{201C}\(name)\u{201D} isn't an image or a folder."])
            case .notPermitted: self.addNotes([ReferenceTrayText.notPermitted(m.url, home: self.home)])
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

    /// File URLs of a paste or a drop split into what to attach (image files by name, and folders,
    /// which expand in the tray) and how many other files were left out (a Finder selection may hold
    /// documents too; they get one note instead of failed tiles).
    nonisolated static func imagesAndFolders(_ urls: [URL]) -> (kept: [URL], notImages: Int) {
        var kept: [URL] = [], left = 0
        for url in urls {
            var isDir: ObjCBool = false
            let folder = url.hasDirectoryPath || (FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue)
            if folder || ReferenceFolders.isImageFileName(url.lastPathComponent) { kept.append(url) } else { left += 1 }
        }
        return (kept, left)
    }

    /// "Left out 2 files that aren't images." for `n` files, or nil.
    nonisolated static func notImagesNote(_ n: Int) -> String? {
        var left = ReferenceExpansion.LeftOut()
        left.notImages = n
        return left.note
    }

    /// What to attach from a paste (or a drop onto the prompt) that `classify` calls images: the
    /// file URLs of images and folders (folders expand in the tray; other files are left out with a
    /// note), else the image data of each item, read through `data(item, type)` (the AppKit side
    /// reads the pasteboard). Data is checked against `maxBytes` once read; nothing is written anywhere.
    static func inputs(itemTypes: [[String]], fileURLs: [URL], data: (Int, String) -> Data?,
                       dataName: String = ReferenceTray.pastedName,
                       maxBytes: Int = ReferenceLimits.maxFileBytes) -> (inputs: [ReferenceInput], notes: [String]) {
        guard classify(itemTypes: itemTypes, fileURLs: fileURLs) == .images else { return ([], []) }
        if !fileURLs.isEmpty {
            let split = imagesAndFolders(fileURLs)
            return (split.kept.map { ReferenceInput.file($0) }, notImagesNote(split.notImages).map { [$0] } ?? [])
        }
        var inputs: [ReferenceInput] = [], notes: [String] = []
        for (i, types) in itemTypes.enumerated() {
            guard let type = imageType(in: types) else { continue }
            guard let d = data(i, type), !d.isEmpty else {
                notes.append("The \(dataName.lowercased()) couldn\u{2019}t be read."); continue
            }
            guard d.count <= maxBytes else {
                notes.append(ReferenceError.tooLarge(name: dataName.lowercased(), bytes: d.count).localizedDescription); continue
            }
            inputs.append(ReferenceInput(source: .data(d, typeIdentifier: type), role: .reference, displayName: dataName))
        }
        return (inputs, Array(Set(notes)).sorted())
    }
}

/// Turns dropped (or, with `dataName: pastedName`, pasted) items into inputs: file URLs (Finder)
/// as files, image data (Photos, a browser, an app) as data, and web URLs as a note — LivePaper
/// never downloads anything.
///
/// Image data is read through `loadFileRepresentation` where the provider offers it (Photos' file
/// promises, large images): macOS hands over its own temporary copy, which it deletes as soon as
/// the handler returns, so the size is checked before anything is read into memory and nothing is
/// left behind. LivePaper itself writes no temporary files.
enum ReferenceDropReader {
    static let acceptedTypes: [UTType] = [.fileURL, .image, .url]
    /// What ⌘V outside the prompt box accepts (a typed path pastes as text; web URLs aren't images).
    static let pasteTypes: [UTType] = [.fileURL, .image]

    static let webNote = "LivePaper doesn't download images \u{2014} save it to your Mac first, then drop the file."

    static func inputs(from providers: [NSItemProvider], dataName: String = ReferenceTray.droppedName,
                       maxBytes: Int = ReferenceLimits.maxFileBytes) async -> (inputs: [ReferenceInput], notes: [String]) {
        var inputs: [ReferenceInput] = [], notes: [String] = []
        var notImages = 0
        func note(_ text: String) { if !notes.contains(text) { notes.append(text) } }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let url = await fileURL(provider) {
                // Images and folders; other files (a Finder selection with documents in it) get one note.
                if ReferencePasteRules.imagesAndFolders([url]).kept.isEmpty { notImages += 1 } else { inputs.append(.file(url)) }
            } else if let type = ReferencePasteRules.imageType(in: provider.registeredTypeIdentifiers) {
                let name = provider.suggestedName.flatMap { $0.isEmpty ? nil : $0 } ?? dataName
                switch await load(provider, type: type, maxBytes: maxBytes) {
                case .data(let d):
                    inputs.append(ReferenceInput(source: .data(d, typeIdentifier: type), role: .reference, displayName: name))
                case .tooLarge(let bytes):
                    note(ReferenceError.tooLarge(name: name == dataName ? dataName.lowercased() : name, bytes: bytes).localizedDescription)
                case .unreadable:
                    note("A\(dataName == ReferenceTray.pastedName ? " pasted" : " dropped") image couldn\u{2019}t be read.")
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                note(webNote)
            }
        }
        if let left = ReferencePasteRules.notImagesNote(notImages) { note(left) }
        return (inputs, notes)
    }

    private enum Loaded { case data(Data), tooLarge(Int), unreadable }

    private static func fileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url?.isFileURL == true ? url : nil) }
        }
    }

    /// The image's bytes: from macOS's temporary file when there is one (size checked first), else
    /// as data (checked once loaded).
    private static func load(_ provider: NSItemProvider, type: String, maxBytes: Int) async -> Loaded {
        let viaFile = await withCheckedContinuation { (done: CheckedContinuation<Loaded?, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { done.resume(returning: nil); return }
                // Deleted by macOS when this handler returns: check the size, then read it whole (not mapped).
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])).flatMap { v in
                    v.isRegularFile == true ? v.fileSize : nil
                }
                guard let size else { done.resume(returning: nil); return }
                if size > maxBytes { done.resume(returning: .tooLarge(size)); return }
                let data = try? Data(contentsOf: url)
                done.resume(returning: data.flatMap { $0.isEmpty ? nil : .data($0) })
            }
        }
        if let viaFile { return viaFile }
        return await withCheckedContinuation { (done: CheckedContinuation<Loaded, Never>) in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                guard let data, !data.isEmpty else { done.resume(returning: .unreadable); return }
                done.resume(returning: data.count > maxBytes ? .tooLarge(data.count) : .data(data))
            }
        }
    }
}

// MARK: - Wording

/// Sentences and labels of the tray, the tiles and the suggestion chips (kept here so they're tested).
enum ReferenceTrayText {
    /// "Reference image 2 of 4, sunset.heic, animate".
    static func tileLabel(_ item: ReferenceTray.Item, index: Int, count: Int) -> String {
        var parts = ["Reference image \(index + 1) of \(count)", item.displayName]
        switch item.state {
        case .preparing: parts.append("preparing")
        case .failed(let why): parts.append("couldn\u{2019}t be added: \(why)")
        case .ready: parts.append(item.role == .animate ? "animate" : "reference")
        }
        return parts.joined(separator: ", ")
    }

    static let referenceChoice = "Reference \u{2014} inspiration for style, colours and composition"
    static let animateChoice = "Animate this image \u{2014} the scene shows this exact picture, brought to life"

    /// The card's footer while images are being prepared ("Preparing 2 images…"; "Preparing
    /// images…" while a folder is still being looked through), else nil.
    static func preparing(_ n: Int, busy: Bool = false) -> String? {
        if n > 0 { return "Preparing \(n == 1 ? "1 image" : "\(n) images")\u{2026}" }
        return busy ? "Preparing images\u{2026}" : nil
    }

    /// " on your Desktop", " in Downloads", " in iCloud Drive", " on “Backup”", or "" — where a
    /// mentioned path lives, for the suggestion chips (case-insensitive, like the volume).
    static func location(of url: URL, home: URL = LPPaths.home) -> String {
        let path = url.deletingLastPathComponent().standardizedFileURL.path.lowercased()
        func under(_ rel: String) -> Bool {
            let root = home.appendingPathComponent(rel).path.lowercased()
            return path == root || path.hasPrefix(root + "/")
        }
        if under("Desktop") { return " on your Desktop" }
        if under("Documents") { return " in Documents" }
        if under("Downloads") { return " in Downloads" }
        if under("Library/Mobile Documents") { return " in iCloud Drive" }
        if under("Library/CloudStorage") { return " in cloud storage" }
        let parts = url.standardizedFileURL.pathComponents
        if parts.count > 2, parts[1].lowercased() == "volumes" { return " on \u{201C}\(parts[2])\u{201D}" }
        return ""
    }

    /// A suggestion LivePaper wasn't allowed to look up (the user declined, or never gave, access
    /// to that folder): what works instead.
    static func notPermitted(_ url: URL, home: URL = LPPaths.home) -> String {
        let place = location(of: url, home: home)
        return "LivePaper isn\u{2019}t allowed to open \u{201C}\(url.lastPathComponent)\u{201D}\(place.isEmpty ? "" : " (\(place.dropFirst()))"). " +
            "Drag it onto the card or use Add Images\u{2026}, or allow access in System Settings \u{203A} Privacy & Security \u{203A} Files and Folders."
    }

    /// Folders that held nothing to attach: "“refs” has no images in it (LivePaper looks 3 folders deep)."
    static func nothingFound(in urls: [URL]) -> String {
        if urls.count == 1, let url = urls.first {
            return "\u{201C}\(url.lastPathComponent)\u{201D} has no images in it (LivePaper looks \(ReferenceLimits.folderDepth) folders deep)."
        }
        return "No images were found in what you added (LivePaper looks \(ReferenceLimits.folderDepth) folders deep)."
    }

    /// "The agent can't open “refs” on your Desktop. Attach copies of its images?"
    static func suggestion(_ m: PromptPathMention, home: URL = LPPaths.home) -> String {
        let name = m.url.lastPathComponent
        switch m.kind {
        case .folder: return "The agent can\u{2019}t open \u{201C}\(name)\u{201D}\(location(of: m.url, home: home)). Attach copies of its images?"
        case .image: return "The agent can\u{2019}t open \u{201C}\(name)\u{201D}\(location(of: m.url, home: home)). Attach a copy?"
        }
    }

    /// Under a session's references: what the agent does with them, and that trying again keeps them.
    static func sessionCaption(roles: [AIReferenceRole]) -> String {
        let animates = roles.contains(.animate)
        switch (animates, roles.count) {
        case (true, 1): return "The scene shows this picture, brought to life. Trying again keeps it."
        case (true, _): return "The scene shows the picture marked Animate; the others are inspiration. Trying again keeps them."
        case (false, 1): return "Inspiration for the scene. Trying again keeps it."
        default: return "Inspiration for the scene. Trying again keeps them."
        }
    }

    /// The Create card's banner for images that couldn't be added.
    static func failureBanner(_ messages: [String]) -> (title: String, message: String)? {
        guard let first = messages.first else { return nil }
        if messages.count == 1 { return ("An image couldn\u{2019}t be added", first) }
        return ("\(messages.count) images couldn\u{2019}t be added", first + " The others are listed under the images.")
    }
}
