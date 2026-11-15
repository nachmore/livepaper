// WallpaperStorePlanning — the pure logic of selecting LivePaper and undoing it: detection, the
// edit plans, the backup manifest, and the invariants every edited store must satisfy. No I/O
// beyond what callers pass in; WallpaperStoreApplier runs these against the live file.
//
// Rules (docs/RESEARCH.md §5, matching what System Settings does):
// * Select = SystemDefault.Idle plus every other Idle slot that holds an explicit choice (anything
//   but the `default` placeholder, which falls through to SystemDefault). Desktop slots, record
//   types, and placeholder Idle slots are never touched.
// * Restore = only Idle slots that *still* point at LivePaper get their recorded original back;
//   slots without a record (e.g. a display that appeared later, copied from SystemDefault) get the
//   placeholder. Slots the user changed since are left alone. The whole old file is never restored.
import Foundation

// MARK: - Detection

/// Which Idle slots of a store choose LivePaper.
public struct WallpaperSelection: Sendable, Equatable {
    /// Slots whose choice is the LivePaper saver.
    public var livePaper: [WallpaperRecordPath]
    /// Slots with an explicit choice of something else.
    public var other: [WallpaperRecordPath]
    /// Placeholder slots that use the next record up.
    public var inheriting: [WallpaperRecordPath]

    public init(livePaper: [WallpaperRecordPath] = [], other: [WallpaperRecordPath] = [], inheriting: [WallpaperRecordPath] = []) {
        self.livePaper = livePaper; self.other = other; self.inheriting = inheriting
    }

    /// LivePaper is chosen for at least one display or Space.
    public var isSelected: Bool { !livePaper.isEmpty }

    /// LivePaper is what every display and Space resolves to: SystemDefault chooses it and no
    /// explicit choice of anything else is left (the state both System Settings and
    /// `planSelect` produce).
    public var isSelectedEverywhere: Bool { livePaper.contains(.systemDefault) && other.isEmpty }
}

// MARK: - Plans

/// One Idle slot to replace.
public struct WallpaperSlotChange: Sendable, Equatable {
    public var path: WallpaperRecordPath
    public var before: PlistValue
    public var after: PlistValue
    /// `before` is the user's own choice, to be put back on uninstall (false when it already was
    /// LivePaper, e.g. at an old location).
    public var recordsOriginal: Bool

    public init(path: WallpaperRecordPath, before: PlistValue, after: PlistValue, recordsOriginal: Bool) {
        self.path = path; self.before = before; self.after = after; self.recordsOriginal = recordsOriginal
    }
}

/// A set of Idle-slot replacements, at most one per record.
public struct WallpaperStorePlan: Sendable, Equatable {
    public var changes: [WallpaperSlotChange]
    public init(changes: [WallpaperSlotChange] = []) { self.changes = changes }

    public var isEmpty: Bool { changes.isEmpty }
    public var paths: [WallpaperRecordPath] { changes.map(\.path) }
    public var replacements: [WallpaperRecordPath: PlistValue] {
        Dictionary(changes.map { ($0.path, $0.after) }, uniquingKeysWith: { _, last in last })
    }
}

extension WallpaperStoreDocument {
    /// Classifies every Idle slot.
    public func selection(of module: WallpaperSaverModule) -> WallpaperSelection {
        var result = WallpaperSelection()
        for record in records {
            guard let idle = record.idle else { continue }
            if module.isChosen(in: idle) { result.livePaper.append(record.path) }
            else if WallpaperSlot.isInherit(idle) { result.inheriting.append(record.path) }
            else { result.other.append(record.path) }
        }
        return result
    }

    /// Throws `.unsupportedShape` for layouts LivePaper doesn't edit: any `linked` record (Desktop
    /// and Idle share one slot) and a Desktop-only AllSpacesAndDisplays override (never observed).
    public func checkEditable() throws {
        for record in records {
            if record.type == "linked" { throw WallpaperStoreError.unsupportedShape("\(record.path) is a linked record") }
            if record.path == .allSpacesAndDisplays && record.idle == nil {
                throw WallpaperStoreError.unsupportedShape("AllSpacesAndDisplays has no Idle slot")
            }
        }
        if record(at: .systemDefault)?.idle == nil { throw WallpaperStoreError.unsupportedShape("SystemDefault has no Idle slot") }
    }

    /// The edits that make `module` the screen saver everywhere. Empty when it already is.
    public func planSelect(_ module: WallpaperSaverModule, at date: Date) throws -> WallpaperStorePlan {
        try checkEditable()
        let slot = try module.slot(at: date)
        var changes: [WallpaperSlotChange] = []
        for record in records {
            guard let idle = record.idle else { continue }   // Desktop-only records inherit Idle
            let explicit = record.path == .systemDefault || !WallpaperSlot.isInherit(idle)
            guard explicit, !module.isCurrentChoice(in: idle) else { continue }
            changes.append(WallpaperSlotChange(path: record.path, before: idle, after: slot, recordsOriginal: !module.isChosen(in: idle)))
        }
        return WallpaperStorePlan(changes: changes)
    }

    /// The edits that undo LivePaper's selection using the recorded originals.
    ///
    /// - Parameter moduleExists: whether a screen-saver bundle still exists. A recorded original
    ///   that points at a deleted module is replaced by the placeholder (except at SystemDefault /
    ///   AllSpacesAndDisplays, which have nothing to fall back to: the original goes back as it was,
    ///   exactly as if LivePaper had never been installed).
    public func planRestore(_ manifest: WallpaperSelectionManifest, module: WallpaperSaverModule, at date: Date,
                            moduleExists: (URL) -> Bool) throws -> WallpaperStorePlan {
        try checkEditable()
        var changes: [WallpaperSlotChange] = []
        for record in records {
            guard let idle = record.idle, module.isChosen(in: idle) else { continue }   // changed since: leave it
            let replacement: PlistValue
            if let entry = manifest.entry(for: record.path) {
                let original = try entry.originalSlot()
                let missing = WallpaperSlot.moduleURLs(original).contains { !names(module, $0) && !moduleExists($0) }
                replacement = missing && !record.path.isRoot ? WallpaperChoicePayload.inheritSlot(at: date) : original
            } else if record.path.isRoot {
                continue   // no record of a previous choice: the user picked LivePaper here themselves
            } else {
                replacement = WallpaperChoicePayload.inheritSlot(at: date)
            }
            changes.append(WallpaperSlotChange(path: record.path, before: idle, after: replacement, recordsOriginal: false))
        }
        return WallpaperStorePlan(changes: changes)
    }

    /// The document with the plan's Idle slots replaced.
    public func applying(_ plan: WallpaperStorePlan) throws -> WallpaperStoreDocument {
        try replacingIdleSlots(plan.replacements)
    }

    private func names(_ module: WallpaperSaverModule, _ url: URL) -> Bool { module.names(url) }
}

// MARK: - Invariants

public enum WallpaperStoreVerifier {
    /// Checks bytes LivePaper is about to put in place, against the document they were made from:
    /// they decode with WallpaperAgent's model, they equal `original` with exactly the plan's Idle
    /// slots replaced, and every Desktop slot is identical. Throws `.verificationFailed`.
    public static func verify(edited data: Data, original: WallpaperStoreDocument, plan: WallpaperStorePlan) throws {
        do {
            try WallpaperStoreDocument.checkDecodable(data)
        } catch WallpaperStoreError.undecodable(let why) {
            throw WallpaperStoreError.verificationFailed("WallpaperAgent couldn't decode it: \(why)")
        }
        let edited: PlistValue
        do { edited = try PlistValue.parse(data) } catch {
            throw WallpaperStoreError.verificationFailed("not a property list")
        }
        let allowed = Set(plan.paths.map { $0.keyPath + ["Idle"] })
        let changed = original.root.differences(from: edited)
        if let stray = changed.first(where: { path in !allowed.contains(where: { path.starts(with: $0) }) }) {
            throw WallpaperStoreError.verificationFailed("unexpected change at \(stray.joined(separator: "/"))")
        }
        let editedDocument = WallpaperStoreDocument(root: edited)
        for record in original.records where record.desktop != nil {
            guard editedDocument.record(at: record.path)?.desktop == record.desktop else {
                throw WallpaperStoreError.verificationFailed("Desktop of \(record.path) changed")
            }
        }
        for change in plan.changes where editedDocument.idleSlot(at: change.path) != change.after {
            throw WallpaperStoreError.verificationFailed("Idle of \(change.path) isn't the planned value")
        }
    }

    /// The outcome of re-reading the store after WallpaperAgent restarted.
    public enum Confirmation: Sendable, Equatable {
        case confirmed
        /// The agent's rewrite doesn't have these planned Idle slots (it wrote from memory between
        /// LivePaper's rename and the restart): worth retrying.
        case changeLost([WallpaperRecordPath])
        /// Desktop slots differ from before the edit (or records vanished, as when the agent fell
        /// back to a default store): roll back.
        case desktopChanged([WallpaperRecordPath])
    }

    /// Compares the restarted agent's store with the plan. `LastUse` is ignored throughout: the
    /// agent bumps it whenever a slot is shown.
    public static func confirm(current: WallpaperStoreDocument, original: WallpaperStoreDocument, plan: WallpaperStorePlan) -> Confirmation {
        var desktop: [WallpaperRecordPath] = []
        for record in original.records {
            guard let before = record.desktop else { continue }
            guard let after = current.record(at: record.path)?.desktop,
                  WallpaperSlot.identity(after) == WallpaperSlot.identity(before) else { desktop.append(record.path); continue }
        }
        if !desktop.isEmpty { return .desktopChanged(desktop) }
        let lost = plan.changes.filter { change in
            current.idleSlot(at: change.path).map(WallpaperSlot.identity) != WallpaperSlot.identity(change.after)
        }.map(\.path)
        return lost.isEmpty ? .confirmed : .changeLost(lost)
    }
}

// MARK: - Backup manifest

/// What LivePaper changed in the store (`backups/wallpaper-selection.json`): for each Idle slot, the
/// user's choice before LivePaper replaced it. Uninstall restores from this — never from a copy of
/// the whole file, which would undo later Desktop changes and drop new displays and Spaces.
public struct WallpaperSelectionManifest: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public struct Entry: Codable, Sendable, Equatable {
        public var record: WallpaperRecordPath
        /// The original first choice's provider and configuration (for people reading the file).
        public var provider: String?
        public var configuration: Data?
        /// Binary plist of the whole original Idle slot — what restore puts back.
        public var slot: Data
        public var recordedAt: Date

        public init(record: WallpaperRecordPath, provider: String?, configuration: Data?, slot: Data, recordedAt: Date) {
            self.record = record; self.provider = provider; self.configuration = configuration; self.slot = slot; self.recordedAt = recordedAt
        }

        public func originalSlot() throws -> PlistValue { try PlistValue.parse(slot) }
    }

    public var version: Int
    /// The module URL LivePaper selected (moduleURLString).
    public var module: String
    public var createdAt: Date
    public var updatedAt: Date
    public var slots: [Entry]

    public init(module: String, createdAt: Date, slots: [Entry] = []) {
        version = Self.currentVersion; self.module = module; self.createdAt = createdAt; updatedAt = createdAt; self.slots = slots
    }

    public func entry(for path: WallpaperRecordPath) -> Entry? { slots.first { $0.record == path } }

    /// Adds the originals of a select plan. A slot LivePaper replaces again keeps the newer original
    /// (the user's latest own choice); slots that were already LivePaper add nothing.
    public func recording(_ plan: WallpaperStorePlan, module: WallpaperSaverModule, at date: Date) throws -> WallpaperSelectionManifest {
        var copy = self
        copy.module = module.moduleURLString
        copy.updatedAt = date
        for change in plan.changes where change.recordsOriginal {
            let first = WallpaperSlot.choices(change.before)?.first
            let entry = Entry(record: change.path, provider: first?.provider, configuration: first?.configuration,
                              slot: try change.before.binaryData(), recordedAt: date)
            if let index = copy.slots.firstIndex(where: { $0.record == change.path }) { copy.slots[index] = entry } else { copy.slots.append(entry) }
        }
        copy.slots.sort { $0.record < $1.record }
        return copy
    }

    /// nil when there is no manifest.
    public static func load(from url: URL) throws -> WallpaperSelectionManifest? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WallpaperSelectionManifest.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileOps.writeAtomically(try encoder.encode(self), to: url)
    }
}
