// WallpaperStorePlanning — the pure logic of selecting LivePaper and undoing it: detection, the
// edit plans, the backup manifest, and the invariants every edited store must satisfy. No I/O
// beyond what callers pass in; WallpaperStoreApplier runs these against the live file.
//
// Rules (docs/RESEARCH.md §5):
// * Select = SystemDefault.Idle plus every other Idle slot that holds an explicit choice (anything
//   but the `default` placeholder, which falls through to the next record up), as System Settings
//   does — plus the placeholder Idle slot of every display record: WallpaperAgent doesn't keep a
//   SystemDefault written into the file while the displays in use hold the placeholder (§5.5).
//   Desktop slots, record types and the placeholders of Space Defaults are never touched; every
//   original, placeholders included, goes into the backup manifest.
// * The quiet re-apply = only the placeholders of display records that fall back to macOS's default
//   screen saver (and SystemDefault's placeholder with them): never a slot with an explicit choice.
// * Selected = every display record resolves to LivePaper (Space and display, then Space, then
//   display, then SystemDefault).
// * Restore = only Idle slots that *still* point at LivePaper get their recorded original back;
//   slots without a record (e.g. a display that appeared later, copied from SystemDefault, or a
//   selection made by hand in System Settings) get the placeholder, and SystemDefault /
//   AllSpacesAndDisplays — which have nothing to inherit — the pre-LivePaper store's choice or a
//   built-in macOS saver (WallpaperRestoreFallback). Slots the user changed since are left alone.
//   The whole old file is never restored.
import Foundation

// MARK: - Detection

/// What a record shows when the Mac idles or locks: the first Idle slot along its fallback chain
/// (`WallpaperRecordPath.fallbackChain`) that isn't the placeholder.
public enum WallpaperResolution: Sendable, Equatable {
    /// LivePaper.saver, chosen in the Idle slot of `at`.
    case livePaper(at: WallpaperRecordPath)
    /// Something else chosen explicitly (another screen saver, an aerial, …) in the Idle slot of `at`.
    case other(at: WallpaperRecordPath)
    /// Nothing but placeholders up to SystemDefault: macOS's own default screen saver.
    case systemDefault

    public var isLivePaper: Bool { if case .livePaper = self { return true }; return false }
}

/// Which Idle slots of a store choose LivePaper, and what every display resolves to.
public struct WallpaperSelection: Sendable, Equatable {
    /// Slots whose choice is the LivePaper saver.
    public var livePaper: [WallpaperRecordPath]
    /// Slots with an explicit choice of something else.
    public var other: [WallpaperRecordPath]
    /// Placeholder slots that use the next record up.
    public var inheriting: [WallpaperRecordPath]
    /// What each display record (`Displays/*`, `Spaces/*/Displays/*`) resolves to.
    public var displays: [WallpaperRecordPath: WallpaperResolution]
    /// What each record displays fall back to — SystemDefault, every Space's Default and a set
    /// AllSpacesAndDisplays — resolves to. A display that appears later starts from a copy of
    /// SystemDefault (docs/RESEARCH.md §5.4).
    public var defaults: [WallpaperRecordPath: WallpaperResolution]
    /// Display records that show macOS's default screen saver only because their own Idle slot,
    /// and every slot they fall back to, holds the placeholder (no explicit choice anywhere on the
    /// way): what the quiet re-apply fills (`WallpaperSelectScope.placeholdersOnly`).
    public var displaysOnSystemDefault: [WallpaperRecordPath]

    public init(livePaper: [WallpaperRecordPath] = [], other: [WallpaperRecordPath] = [], inheriting: [WallpaperRecordPath] = [],
                displays: [WallpaperRecordPath: WallpaperResolution] = [:], defaults: [WallpaperRecordPath: WallpaperResolution] = [:],
                displaysOnSystemDefault: [WallpaperRecordPath] = []) {
        self.livePaper = livePaper; self.other = other; self.inheriting = inheriting
        self.displays = displays; self.defaults = defaults; self.displaysOnSystemDefault = displaysOnSystemDefault
    }

    /// LivePaper is chosen in at least one Idle slot (what uninstall has to undo).
    public var isSelected: Bool { !livePaper.isEmpty }

    /// The displays the store has records for (sorted ids).
    public var displayIDs: [String] { Set(displays.keys.compactMap(\.displayID)).sorted() }

    /// Displays with a record that resolves to LivePaper (sorted ids).
    public var displaysWithLivePaper: [String] {
        Set(displays.filter { $0.value.isLivePaper }.keys.compactMap(\.displayID)).sorted()
    }

    /// Displays with a record (in some Space) that resolves to something else (sorted ids).
    public var displaysWithoutLivePaper: [String] {
        Set(displays.filter { !$0.value.isLivePaper }.keys.compactMap(\.displayID)).sorted()
    }

    /// LivePaper is what every display shows: every display record resolves to it — or, while the
    /// store has no display record yet, SystemDefault does. What "selected" means
    /// (InstallStatus.saverSelected).
    public var isSelectedOnEveryDisplay: Bool {
        guard !displays.isEmpty else { return defaults[.systemDefault]?.isLivePaper == true }
        return displays.values.allSatisfy(\.isLivePaper)
    }

    /// Every record resolves to LivePaper, SystemDefault and the Spaces' Defaults included: the
    /// store `planSelect` writes (WallpaperAgent may then write its own choice into those defaults,
    /// `WallpaperStoreVerifier.Confirmation.confirmedDefaultsRewritten`).
    public var isSelectedEverywhere: Bool {
        isSelectedOnEveryDisplay && defaults[.systemDefault]?.isLivePaper == true && defaults.values.allSatisfy(\.isLivePaper)
    }

    /// LivePaper is what some displays show, but not every display (InstallStatus's "partly").
    public var isPartlySelected: Bool { !displaysWithLivePaper.isEmpty && !isSelectedOnEveryDisplay }
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
    /// Restore only: root slots that get WallpaperRestoreFallback's built-in saver (no earlier choice
    /// was known), so the caller can tell the user.
    public var builtinSaverPaths: [WallpaperRecordPath]
    public init(changes: [WallpaperSlotChange] = [], builtinSaverPaths: [WallpaperRecordPath] = []) {
        self.changes = changes; self.builtinSaverPaths = builtinSaverPaths
    }

    public var isEmpty: Bool { changes.isEmpty }
    public var paths: [WallpaperRecordPath] { changes.map(\.path) }
    public var replacements: [WallpaperRecordPath: PlistValue] {
        Dictionary(changes.map { ($0.path, $0.after) }, uniquingKeysWith: { _, last in last })
    }
}

/// Which Idle slots a selection writes.
public enum WallpaperSelectScope: Sendable, Equatable {
    /// The user's "Make LivePaper my screen saver" and `livepaper select`: SystemDefault, every
    /// explicit Idle slot (another saver's too, as System Settings does), and the placeholder Idle
    /// slot of every display record. WallpaperAgent doesn't keep a SystemDefault written into the
    /// file while the displays in use hold the placeholder, but keeps display slots and copies them
    /// into SystemDefault and the Defaults of the Spaces in use itself (docs/RESEARCH.md §5.5, seen
    /// on macOS 26.7) — so the displays get LivePaper themselves. Space Defaults that hold the
    /// placeholder are left alone: a display record is tried before its Space's Default, and every
    /// display record gets LivePaper.
    case everyDisplay
    /// The app's quiet re-apply: only the placeholder Idle slots of display records that fall back
    /// to macOS's default screen saver (`WallpaperSelection.displaysOnSystemDefault`), plus
    /// SystemDefault while it holds the placeholder too. Never a slot with an explicit choice, so
    /// never a screen saver the user picked, nor what a display inherits from one. Empty while no
    /// display needs it.
    case placeholdersOnly
}

extension WallpaperStoreDocument {
    /// Classifies every Idle slot, and resolves every display record and every record displays fall
    /// back to.
    public func selection(of module: WallpaperSaverModule) -> WallpaperSelection {
        var result = WallpaperSelection()
        for record in records {
            if let idle = record.idle {
                if module.isChosen(in: idle) { result.livePaper.append(record.path) }
                else if WallpaperSlot.isInherit(idle) { result.inheriting.append(record.path) }
                else { result.other.append(record.path) }
            }
            let resolved = resolution(of: record.path, module: module)
            if record.path.displayID != nil {
                result.displays[record.path] = resolved
                if resolved == .systemDefault, record.idle != nil { result.displaysOnSystemDefault.append(record.path) }
            } else {
                result.defaults[record.path] = resolved
            }
        }
        return result
    }

    /// Every display record resolves to `module` at its own location (with no display record yet:
    /// SystemDefault does) — System Settings' own selection, say, or one whose SystemDefault the agent
    /// kept: a user's selection has nothing to change then. A choice of LivePaper.saver elsewhere
    /// doesn't count (it gets rewritten).
    public func isCurrentChoiceOnEveryDisplay(_ module: WallpaperSaverModule) -> Bool {
        let displays = records.map(\.path).filter { $0.displayID != nil }
        return (displays.isEmpty ? [.systemDefault] : displays).allSatisfy { path in
            guard case .livePaper(let at) = resolution(of: path, module: module),
                  let slot = record(at: at).flatMap({ $0.idle ?? $0.linked }) else { return false }
            return module.isCurrentChoice(in: slot)
        }
    }

    /// What the record at `path` shows when the Mac idles or locks: the first Idle slot along
    /// `path.fallbackChain` that isn't the placeholder (records that don't exist, or have no Idle
    /// slot, are passed over).
    public func resolution(of path: WallpaperRecordPath, module: WallpaperSaverModule) -> WallpaperResolution {
        for link in path.fallbackChain {
            guard let record = record(at: link), let slot = record.idle ?? record.linked, !WallpaperSlot.isInherit(slot) else { continue }
            return module.isChosen(in: slot) ? .livePaper(at: link) : .other(at: link)
        }
        return .systemDefault
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

    /// The edits that make `module` the screen saver of every display (`scope`). Empty when there is
    /// nothing to change.
    ///
    /// - Parameter moduleExists: whether a screen-saver bundle exists. A choice of LivePaper.saver at
    ///   another location that exists (e.g. /Library/Screen Savers) is recorded as the original, so
    ///   uninstall puts that location back; one at a location that no longer exists is not.
    public func planSelect(_ module: WallpaperSaverModule, at date: Date, scope: WallpaperSelectScope = .everyDisplay,
                           moduleExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) throws -> WallpaperStorePlan {
        try checkEditable()
        let slot = try module.slot(at: date)
        var changes: [WallpaperSlotChange] = []
        switch scope {
        case .everyDisplay:
            for record in records {
                guard let idle = record.idle else { continue }   // Desktop-only records inherit Idle
                let wanted = record.path == .systemDefault || record.path.displayID != nil || !WallpaperSlot.isInherit(idle)
                guard wanted, !module.isCurrentChoice(in: idle) else { continue }
                // A placeholder is recorded too: uninstall puts exactly it back.
                let original = !module.isChosen(in: idle)
                    || WallpaperSlot.moduleURLs(idle).contains { module.isOtherExistingCopy($0, moduleExists: moduleExists) }
                changes.append(WallpaperSlotChange(path: record.path, before: idle, after: slot, recordsOriginal: original))
            }
        case .placeholdersOnly:
            let fill = Set(selection(of: module).displaysOnSystemDefault)
            guard !fill.isEmpty else { return WallpaperStorePlan() }
            for record in records {
                guard let idle = record.idle, WallpaperSlot.isInherit(idle), fill.contains(record.path) || record.path == .systemDefault else { continue }
                changes.append(WallpaperSlotChange(path: record.path, before: idle, after: slot, recordsOriginal: true))
            }
        }
        return WallpaperStorePlan(changes: changes)
    }

    /// The edits that undo LivePaper's selection: every Idle slot that still names LivePaper.saver
    /// gets its recorded original back, or else the placeholder — or, at SystemDefault /
    /// AllSpacesAndDisplays (nothing to inherit from), `fallback`'s choice. Afterwards no slot names
    /// LivePaper except a recorded original that is LivePaper at another location that exists.
    ///
    /// - Parameters:
    ///   - manifest: the recorded originals (empty when LivePaper never changed the store itself, e.g.
    ///     it was picked by hand in System Settings).
    ///   - moduleExists: whether a screen-saver bundle still exists. A recorded original that points
    ///     at a deleted module is replaced by the placeholder (except at the root records, where the
    ///     original goes back as it was, exactly as if LivePaper had never been installed). A
    ///     recorded LivePaper original only counts while that copy exists and isn't `module` itself.
    /// - Throws: `.noPreviousChoice` when a root slot has nothing LivePaper may put there.
    public func planRestore(_ manifest: WallpaperSelectionManifest, module: WallpaperSaverModule, at date: Date,
                            fallback: WallpaperRestoreFallback = WallpaperRestoreFallback(),
                            moduleExists: (URL) -> Bool) throws -> WallpaperStorePlan {
        try checkEditable()
        var plan = WallpaperStorePlan()
        for record in records {
            guard let idle = record.idle, module.isChosen(in: idle) else { continue }   // changed since: leave it
            var replacement: PlistValue?
            if let entry = manifest.entry(for: record.path) {
                let original = try entry.originalSlot()
                let urls = WallpaperSlot.moduleURLs(original)
                let livePaperOriginal = module.isChosen(in: original)
                if livePaperOriginal && !urls.contains(where: { module.isOtherExistingCopy($0, moduleExists: moduleExists) }) {
                    replacement = nil   // LivePaper at a location that is gone (or this one): no use putting it back
                } else {
                    let missing = urls.contains { !names(module, $0) && !moduleExists($0) }
                    replacement = missing && !record.path.isRoot ? WallpaperChoicePayload.inheritSlot(at: date) : original
                }
            }
            if replacement == nil {
                if record.path.isRoot {
                    guard let (slot, builtin) = try fallback.rootSlot(for: record.path, module: module, at: date, moduleExists: moduleExists) else {
                        throw WallpaperStoreError.noPreviousChoice(record.path.description)
                    }
                    replacement = slot
                    if builtin { plan.builtinSaverPaths.append(record.path) }
                } else {
                    replacement = WallpaperChoicePayload.inheritSlot(at: date)
                }
            }
            plan.changes.append(WallpaperSlotChange(path: record.path, before: idle, after: replacement!, recordsOriginal: false))
        }
        return plan
    }

    /// The document with the plan's Idle slots replaced.
    public func applying(_ plan: WallpaperStorePlan) throws -> WallpaperStoreDocument {
        try replacingIdleSlots(plan.replacements)
    }

    private func names(_ module: WallpaperSaverModule, _ url: URL) -> Bool { module.names(url) }
}

/// What uninstall puts in a root Idle slot (SystemDefault, AllSpacesAndDisplays) that still names
/// LivePaper but has no usable recorded original — say LivePaper was picked by hand in System
/// Settings, or was already chosen when LivePaper first changed the store. The slot can't inherit,
/// and the store must never be left pointing at the LivePaper.saver uninstall is about to delete.
public struct WallpaperRestoreFallback: Sendable, Equatable {
    /// The store as it was before LivePaper's first selection (the raw backup), when readable.
    public var previousStore: WallpaperStoreDocument?
    /// A screen saver that ships with macOS, used when the previous store has nothing better.
    public var builtinSaver: WallpaperSaverModule?

    public init(previousStore: WallpaperStoreDocument? = nil, builtinSaver: WallpaperSaverModule? = nil) {
        self.previousStore = previousStore; self.builtinSaver = builtinSaver
    }

    /// macOS's Message saver ("FloatingMessage.saver"), on the read-only system volume of every
    /// macOS 26 Mac. Its choice is the same legacy `.saver` payload System Settings writes for any
    /// other saver (docs/RESEARCH.md §5.3), so nothing about it is guessed.
    public static let systemSaverURL = URL(fileURLWithPath: "/System/Library/Screen Savers/FloatingMessage.saver")

    /// The slot for `path`, and whether it is the built-in saver; nil when there is none.
    /// Prefers the previous store's own slot at `path`, then its SystemDefault, as long as it
    /// doesn't name LivePaper; then the built-in saver if it exists.
    func rootSlot(for path: WallpaperRecordPath, module: WallpaperSaverModule, at date: Date,
                  moduleExists: (URL) -> Bool) throws -> (PlistValue, Bool)? {
        for candidate in [path, .systemDefault] {
            if let slot = previousStore?.idleSlot(at: candidate), WallpaperSlot.choices(slot)?.isEmpty == false, !module.isChosen(in: slot) {
                return (slot, false)
            }
        }
        if let builtinSaver, !module.names(builtinSaver.url), moduleExists(builtinSaver.url) { return (try builtinSaver.slot(at: date), true) }
        return nil
    }
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
        /// A select plan's display slots were kept and every display record resolves to the selected
        /// module, but the agent wrote its own choice into these planned records that displays only
        /// fall back to (SystemDefault, a Space's Default): it derives those from the displays it
        /// shows (docs/RESEARCH.md §5.5). What is shown is what was asked for: accepted.
        case confirmedDefaultsRewritten([WallpaperRecordPath])
        /// The agent's rewrite doesn't have these planned Idle slots (it wrote from memory between
        /// LivePaper's rename and the restart): worth retrying.
        case changeLost([WallpaperRecordPath])
        /// Desktop slots differ from before the edit (or records vanished, as when the agent fell
        /// back to a default store): roll back.
        case desktopChanged([WallpaperRecordPath])
    }

    /// Compares the restarted agent's store with the plan. Desktop slots must be unchanged apart
    /// from `LastUse` (the agent bumps it whenever a slot is shown). A planned Idle slot counts as
    /// kept when it makes the planned choice (`WallpaperSlot.sameChoices`): the agent may normalise
    /// option values or timestamps of a slot it loaded, which changes nothing that is shown. An
    /// empty plan checks only the Desktop slots.
    ///
    /// - Parameter selecting: the module a select plan chooses. Planned SystemDefault and Space
    ///   Default slots the agent replaced then count as kept as long as every display record of
    ///   `current` resolves to it (`.confirmedDefaultsRewritten`). nil (restore, rollback): every
    ///   planned slot must be kept.
    public static func confirm(current: WallpaperStoreDocument, original: WallpaperStoreDocument, plan: WallpaperStorePlan,
                               selecting module: WallpaperSaverModule? = nil) -> Confirmation {
        var desktop: [WallpaperRecordPath] = []
        for record in original.records {
            guard let before = record.desktop else { continue }
            guard let after = current.record(at: record.path)?.desktop,
                  WallpaperSlot.identity(after) == WallpaperSlot.identity(before) else { desktop.append(record.path); continue }
        }
        if !desktop.isEmpty { return .desktopChanged(desktop) }
        let lost = plan.changes.filter { change in
            guard let slot = current.idleSlot(at: change.path) else { return true }
            return !WallpaperSlot.sameChoices(slot, change.after)
        }.map(\.path)
        if lost.isEmpty { return .confirmed }
        if let module, lost.allSatisfy({ $0.displayID == nil && $0 != .allSpacesAndDisplays }),
           current.selection(of: module).isSelectedOnEveryDisplay {
            return .confirmedDefaultsRewritten(lost)
        }
        return .changeLost(lost)
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
