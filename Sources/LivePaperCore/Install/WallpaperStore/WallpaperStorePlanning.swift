// WallpaperStorePlanning — the pure logic of selecting LivePaper and undoing it: detection, the
// edit plans, the backup manifest, and the invariants every edited store must satisfy. No I/O
// beyond what callers pass in; WallpaperStoreApplier runs these against the live file.
//
// Rules (docs/RESEARCH.md §5):
// * Select = SystemDefault.Idle plus every other Idle slot that holds an explicit choice (anything
//   but the `default` placeholder, which falls through to the next record up), as System Settings
//   does — plus the placeholder Idle slot of every display record: WallpaperAgent derives
//   SystemDefault and the Defaults of the Spaces in use from the slots of the displays it shows, so
//   only what the displays hold themselves lasts (§5.5). Desktop slots, record types and the
//   placeholders of Space Defaults are never touched; every original, placeholders included, goes
//   into the backup manifest (a placeholder never replaces an original recorded before).
// * The quiet re-apply = only while LivePaper is still chosen somewhere, only the placeholders of
//   display records that show macOS's default screen saver or inherit LivePaper from a record the
//   agent rewrites (and SystemDefault's placeholder with them): never a slot with an explicit
//   choice, nor one inheriting another screen saver.
// * Selected = every display record resolves to LivePaper (Space and display, then Space, then
//   display, then SystemDefault).
// * Restore = the Idle slots that are still LivePaper's — they name LivePaper.saver, or WallpaperAgent
//   wrote its own choice there in place of LivePaper's and nothing changed it since — get their
//   recorded original back; slots without a record (e.g. a display that appeared later, copied from
//   SystemDefault, or a selection made by hand in System Settings) get the placeholder, and
//   SystemDefault / AllSpacesAndDisplays — which have nothing to inherit — the pre-LivePaper store's
//   choice or a built-in macOS saver (WallpaperRestoreFallback). A display record that would then
//   hold the placeholder and inherit an explicit choice from SystemDefault or a Space's Default gets
//   that choice itself, for the same reason select fills the displays. Slots the user changed since
//   are left alone. The whole old file is never restored.
// * Confirm = the planned slots after WallpaperAgent restarted; a planned SystemDefault or Space
//   Default the agent rewrote counts only while every display record shows what the plan asked for.
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

    /// The record whose slot decides it (nil: macOS's default).
    public var source: WallpaperRecordPath? {
        switch self {
        case .livePaper(let at), .other(let at): return at
        case .systemDefault: return nil
        }
    }
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
    /// Display records whose own Idle slot holds the placeholder and that show macOS's default
    /// screen saver (placeholders all the way up), or inherit LivePaper from a record that isn't a
    /// display's (SystemDefault, a Space's Default — records WallpaperAgent derives from the slots of
    /// the displays it shows, §5.5, so LivePaper there doesn't last): what the quiet re-apply fills
    /// (`WallpaperSelectScope.placeholdersOnly`). Never a record inheriting another screen saver.
    public var placeholderDisplays: [WallpaperRecordPath]

    public init(livePaper: [WallpaperRecordPath] = [], other: [WallpaperRecordPath] = [], inheriting: [WallpaperRecordPath] = [],
                displays: [WallpaperRecordPath: WallpaperResolution] = [:], defaults: [WallpaperRecordPath: WallpaperResolution] = [:],
                placeholderDisplays: [WallpaperRecordPath] = []) {
        self.livePaper = livePaper; self.other = other; self.inheriting = inheriting
        self.displays = displays; self.defaults = defaults; self.placeholderDisplays = placeholderDisplays
    }

    /// LivePaper is chosen in at least one Idle slot (what uninstall has to undo; and the quiet
    /// re-apply runs only while it is).
    public var isSelected: Bool { !livePaper.isEmpty }

    /// The displays the store has records for (sorted ids).
    public var displayIDs: [String] { Set(displays.keys.compactMap(\.displayID)).sorted() }

    /// Displays every record of which (in every Space) resolves to LivePaper (sorted ids).
    public var displaysWithLivePaper: [String] {
        let without = Set(displaysWithoutLivePaper)
        return displayIDs.filter { !without.contains($0) }
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

    /// LivePaper is what some display records show, but not every one (InstallStatus's "partly").
    public var isPartlySelected: Bool { displays.values.contains(where: \.isLivePaper) && !isSelectedOnEveryDisplay }

    /// How many displays don't show LivePaper in every Space — of all the store has records for and,
    /// when `connected` (CoreGraphics' display UUIDs) names some of them, of the connected ones.
    public func displayCount(connected: Set<String>?) -> SaverSelection.DisplayCount {
        let ids = displayIDs, without = Set(displaysWithoutLivePaper)
        var count = SaverSelection.DisplayCount(displays: ids.count, missing: without.count)
        if let connected {
            let wanted = Set(connected.map { $0.uppercased() })
            let present = ids.filter { wanted.contains($0.uppercased()) }
            if !present.isEmpty {
                count.connected = present.count
                count.connectedMissing = present.filter(without.contains).count
            }
        }
        return count
    }
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
    /// The app's quiet re-apply: only while LivePaper is still chosen in some Idle slot, only the
    /// placeholder Idle slots of display records that show macOS's default screen saver or inherit
    /// LivePaper from SystemDefault or a Space's Default (`WallpaperSelection.placeholderDisplays`),
    /// plus SystemDefault while it holds the placeholder too. Never a slot with an explicit choice,
    /// so never a screen saver the user picked, nor what a display inherits from one. Empty while no
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
                // Its own slot is the placeholder whenever it resolves elsewhere (or to the default).
                let inheritsDefault = resolved == .systemDefault || (resolved.isLivePaper && resolved.source?.displayID == nil)
                if record.idle != nil, inheritsDefault { result.placeholderDisplays.append(record.path) }
            } else {
                result.defaults[record.path] = resolved
            }
        }
        return result
    }

    /// Every display record shows the installed `module` from a display's own record — its own Idle
    /// slot, or (a Space's record of it) the display's record — so a restarted WallpaperAgent keeps
    /// it (with no display record yet: SystemDefault does). What `selectSaver` takes as "nothing to
    /// change". A display record that only inherits LivePaper from SystemDefault or a Space's Default
    /// (System Settings' own selection) doesn't count: the agent derives those from the displays it
    /// shows, placeholders included, at its next launch (docs/RESEARCH.md §5.5). Nor does a choice of
    /// LivePaper.saver at another location (it gets rewritten).
    public func isCurrentChoiceOnEveryDisplay(_ module: WallpaperSaverModule) -> Bool {
        let displays = records.map(\.path).filter { $0.displayID != nil }
        guard !displays.isEmpty else { return idleSlot(at: .systemDefault).map(module.isCurrentChoice) == true }
        return displays.allSatisfy { path in
            guard let (at, slot) = resolvedSlot(of: path), at.displayID != nil else { return false }
            return module.isCurrentChoice(in: slot)
        }
    }

    /// The Idle slot the record at `path` shows and the record it is in: the first one along
    /// `path.fallbackChain` that isn't the placeholder (records that don't exist, or have no Idle
    /// slot, are passed over). nil: placeholders all the way up — macOS's default screen saver.
    public func resolvedSlot(of path: WallpaperRecordPath) -> (at: WallpaperRecordPath, slot: PlistValue)? {
        for link in path.fallbackChain {
            guard let record = record(at: link), let slot = record.idle ?? record.linked, !WallpaperSlot.isInherit(slot) else { continue }
            return (link, slot)
        }
        return nil
    }

    /// What the record at `path` shows when the Mac idles or locks (`resolvedSlot`).
    public func resolution(of path: WallpaperRecordPath, module: WallpaperSaverModule) -> WallpaperResolution {
        guard let (at, slot) = resolvedSlot(of: path) else { return .systemDefault }
        return module.isChosen(in: slot) ? .livePaper(at: at) : .other(at: at)
    }

    /// Every display record of `expected` shows the same choice here as there (`WallpaperSlot.sameChoices`
    /// of the resolved slots; macOS's default counts as one choice) — with no display record,
    /// SystemDefault does. How a restarted agent's store is judged when it rewrote a record displays
    /// only fall back to.
    public func showsTheSameOnEveryDisplay(as expected: WallpaperStoreDocument) -> Bool {
        let displays = expected.records.map(\.path).filter { $0.displayID != nil }
        return (displays.isEmpty ? [.systemDefault] : displays).allSatisfy { path in
            switch (expected.resolvedSlot(of: path), resolvedSlot(of: path)) {
            case (nil, nil): return true
            case let (wanted?, shown?): return WallpaperSlot.sameChoices(wanted.slot, shown.slot)
            default: return false
            }
        }
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
            let selection = selection(of: module)
            // Only while LivePaper is still chosen somewhere: a store without it (the user switched
            // to another screen saver, or something reset every slot) is the user's to change.
            guard selection.isSelected else { return WallpaperStorePlan() }
            let fill = Set(selection.placeholderDisplays)
            guard !fill.isEmpty else { return WallpaperStorePlan() }
            for record in records {
                guard let idle = record.idle, WallpaperSlot.isInherit(idle), fill.contains(record.path) || record.path == .systemDefault else { continue }
                changes.append(WallpaperSlotChange(path: record.path, before: idle, after: slot, recordsOriginal: true))
            }
        }
        return WallpaperStorePlan(changes: changes)
    }

    /// The edits that undo LivePaper's selection. Every Idle slot that is still LivePaper's — it
    /// names LivePaper.saver, or WallpaperAgent wrote its own choice there in place of LivePaper's
    /// (`WallpaperSelectionManifest.Entry.agentSlot`) and it still holds that — gets its recorded
    /// original back, or else the placeholder, or (SystemDefault / AllSpacesAndDisplays: nothing to
    /// inherit from) `fallback`'s choice. Then every display record that would hold the placeholder
    /// and inherit an explicit choice from a record that isn't a display's (SystemDefault, a Space's
    /// Default) — one this plan writes, or one inherited through a slot this plan writes — gets that
    /// choice itself: WallpaperAgent derives those records from the displays it shows (docs/RESEARCH.md
    /// §5.5), so only what the displays hold lasts. (A choice whose module is missing isn't copied.)
    /// Afterwards no slot names LivePaper except a recorded original that is LivePaper at another
    /// location that exists.
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
        var replacements: [WallpaperRecordPath: PlistValue] = [:]
        var builtin: [WallpaperRecordPath] = []
        for record in records {
            guard let idle = record.idle else { continue }
            let entry = manifest.entry(for: record.path)
            let namesLivePaper = module.isChosen(in: idle)
            // Not LivePaper's any more (changed since): leave it.
            guard namesLivePaper || entry?.agentReplaced(idle) == true else { continue }
            var replacement: PlistValue?
            if let entry {
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
            // What the agent wrote there doesn't point at LivePaper: only a usable original replaces it.
            if replacement == nil && !namesLivePaper { continue }
            if replacement == nil {
                if record.path.isRoot {
                    guard let (slot, isBuiltin) = try fallback.rootSlot(for: record.path, module: module, at: date, moduleExists: moduleExists) else {
                        throw WallpaperStoreError.noPreviousChoice(record.path.description)
                    }
                    replacement = slot
                    if isBuiltin { builtin.append(record.path) }
                } else {
                    replacement = WallpaperChoicePayload.inheritSlot(at: date)
                }
            }
            if replacement != idle { replacements[record.path] = replacement }
        }
        // The displays get what they would inherit from a record the agent rewrites.
        let restored = try replacingIdleSlots(replacements)
        for record in restored.records where record.path.displayID != nil {
            guard let idle = record.idle, WallpaperSlot.isInherit(idle), let (at, slot) = restored.resolvedSlot(of: record.path),
                  at.displayID == nil, replacements[record.path] != nil || replacements[at] != nil else { continue }
            let usable = WallpaperSlot.moduleURLs(slot).allSatisfy { url in
                moduleExists(url) && (!module.names(url) || module.isOtherExistingCopy(url, moduleExists: moduleExists))
            }
            if usable { replacements[record.path] = slot }
        }
        let changes = records.compactMap { record -> WallpaperSlotChange? in
            guard let idle = record.idle, let after = replacements[record.path] else { return nil }
            return WallpaperSlotChange(path: record.path, before: idle, after: after, recordsOriginal: false)
        }
        return WallpaperStorePlan(changes: changes, builtinSaverPaths: builtin)
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
        /// The plan's display slots were kept and every display record shows what the plan asked
        /// for, but the agent wrote its own choice into these planned records that displays only
        /// fall back to (SystemDefault, a Space's Default): it derives those from the displays it
        /// shows (docs/RESEARCH.md §5.5). What is shown is what was asked for: accepted.
        case confirmedDefaultsRewritten([WallpaperRecordPath])
        /// The agent's rewrite doesn't have these planned Idle slots (it wrote from memory between
        /// LivePaper's rename and the restart, or replaced a default the displays fall back to):
        /// worth retrying.
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
    /// - Parameter acceptingRewrittenDefaults: planned SystemDefault and Space Default slots the
    ///   agent replaced count as kept as long as every display record of `current` shows what it
    ///   does in `original` with the plan applied (`.confirmedDefaultsRewritten`) — select and
    ///   restore. false (rollback): every planned slot must be kept.
    public static func confirm(current: WallpaperStoreDocument, original: WallpaperStoreDocument, plan: WallpaperStorePlan,
                               acceptingRewrittenDefaults: Bool = false) -> Confirmation {
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
        if acceptingRewrittenDefaults, lost.allSatisfy({ $0.displayID == nil && $0 != .allSpacesAndDisplays }),
           let expected = try? original.applying(plan), current.showsTheSameOnEveryDisplay(as: expected) {
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
        /// Binary plist of the slot WallpaperAgent wrote here in place of LivePaper's choice, which
        /// the selection accepted (SystemDefault or a Space's Default, `WallpaperApplyReport.rewrittenByAgent`):
        /// while the record still holds it, it is LivePaper's to restore. nil: none (older manifests too).
        public var agentSlot: Data?

        public init(record: WallpaperRecordPath, provider: String?, configuration: Data?, slot: Data, recordedAt: Date, agentSlot: Data? = nil) {
            self.record = record; self.provider = provider; self.configuration = configuration; self.slot = slot; self.recordedAt = recordedAt
            self.agentSlot = agentSlot
        }

        public func originalSlot() throws -> PlistValue { try PlistValue.parse(slot) }

        /// `current` is the choice WallpaperAgent wrote in place of LivePaper's (`agentSlot`).
        public func agentReplaced(_ current: PlistValue) -> Bool {
            guard let agentSlot, let written = try? PlistValue.parse(agentSlot) else { return false }
            return WallpaperSlot.sameChoices(written, current)
        }
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
    /// when that is an explicit choice (the user's latest own one); a placeholder is only recorded
    /// where nothing is yet — a placeholder found later was left by a reset (another tool, the quiet
    /// re-apply's case), not chosen. Slots that were already LivePaper add nothing.
    public func recording(_ plan: WallpaperStorePlan, module: WallpaperSaverModule, at date: Date) throws -> WallpaperSelectionManifest {
        var copy = self
        copy.module = module.moduleURLString
        copy.updatedAt = date
        for change in plan.changes where change.recordsOriginal {
            let existing = copy.slots.firstIndex { $0.record == change.path }
            if existing != nil && WallpaperSlot.isInherit(change.before) { continue }
            let first = WallpaperSlot.choices(change.before)?.first
            let entry = Entry(record: change.path, provider: first?.provider, configuration: first?.configuration,
                              slot: try change.before.binaryData(), recordedAt: date)
            if let existing { copy.slots[existing] = entry } else { copy.slots.append(entry) }
        }
        copy.slots.sort { $0.record < $1.record }
        return copy
    }

    /// Notes what WallpaperAgent wrote into `paths` of `document` in place of LivePaper's choice (a
    /// selection it accepted, `WallpaperApplyReport.rewrittenByAgent`), for the entries recorded there.
    public func recordingAgentSlots(_ paths: [WallpaperRecordPath], in document: WallpaperStoreDocument, at date: Date) throws -> WallpaperSelectionManifest {
        var copy = self
        for path in paths {
            guard let index = copy.slots.firstIndex(where: { $0.record == path }), let slot = document.idleSlot(at: path) else { continue }
            copy.slots[index].agentSlot = try slot.binaryData()
            copy.updatedAt = date
        }
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
