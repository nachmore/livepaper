// LibrarySelection — choosing several scene cards in the Library to add them to a collection, move
// or remove them, or drag them together. Finder's rules, minus the parts a grid of previews doesn't
// need: ⌘-click adds or removes one card, ⇧-click adds the cards from the last one clicked to this one
// (in that section's order), a plain click opens the card (and ends the selection), Esc ends it.
// The selection is of scenes: a scene in several sections is selected in each. It remembers the
// section the cards were chosen in, so in a collection's section the selection bar can offer Move to
// and Remove.
// Foundation-only; also compiled into LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/.
import Foundation

struct LibrarySelection: Equatable, Sendable {
    /// What kind of click a card got (from the modifier keys held).
    enum Click: Equatable, Sendable {
        case plain
        /// ⌘-click.
        case toggle
        /// ⇧-click (⇧⌘-click too).
        case extend

        init(command: Bool, shift: Bool) {
            self = shift ? .extend : command ? .toggle : .plain
        }
    }

    enum Outcome: Equatable, Sendable {
        /// A plain click: open the card.
        case open(String)
        /// The selection changed (it may now be empty).
        case changed
    }

    private(set) var ids: Set<String> = []
    /// Where a ⇧-click range starts: the last card ⌘-clicked or ⇧-clicked.
    private(set) var anchor: String?
    /// The section the cards were chosen in (`LibrarySectionID.key`), unless they were chosen in several.
    private var chosenIn: String?
    private var mixed = false

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// The section every card was chosen in (a `LibrarySectionID.key`); nil when they were chosen in
    /// several sections, by Select All of the whole Library, or without saying where.
    var section: String? { mixed || ids.isEmpty ? nil : chosenIn }

    /// - Parameters:
    ///   - order: the cards as the grid (the card's section) shows them, for ranges.
    ///   - section: where the card was clicked (`LibrarySectionID.key`).
    mutating func click(_ id: String, _ click: Click, order: [String], section: String? = nil) -> Outcome {
        let wasEmpty = ids.isEmpty
        switch click {
        case .plain:
            clear()
            return .open(id)
        case .toggle:
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id
        case .extend:
            if let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
                ids.formUnion(order[min(from, to)...max(from, to)])
            } else {
                ids.insert(id)
                anchor = id
            }
        }
        if ids.isEmpty {
            clear()
        } else if wasEmpty {
            chosenIn = section; mixed = false
        } else if chosenIn != section {
            mixed = true
        }
        return .changed
    }

    mutating func clear() {
        ids = []
        anchor = nil
        chosenIn = nil
        mixed = false
    }

    /// - Parameter section: the section whose cards `order` is (nil: the whole Library).
    mutating func selectAll(_ order: [String], section: String? = nil) {
        ids = Set(order)
        anchor = order.last
        chosenIn = section
        mixed = section == nil
        if ids.isEmpty { clear() }
    }

    /// Keeps only cards that are still shown (deleted, filtered out, in a collapsed section).
    mutating func retain(_ shown: [String]) {
        let keep = Set(shown)
        guard !ids.isSubset(of: keep) || (anchor.map { !keep.contains($0) } ?? false) else { return }
        ids.formIntersection(keep)
        if let a = anchor, !keep.contains(a) { anchor = nil }
        if ids.isEmpty { clear() }
    }

    /// The selected cards in the grid's order.
    func ordered(_ order: [String]) -> [String] { order.filter(ids.contains) }

    /// What a drag of a card, or its context menu, acts on: every selected card (in the grid's
    /// order) when it is one of them, otherwise just that card.
    func targets(for id: String, order: [String]) -> [String] {
        ids.contains(id) && ids.count > 1 ? ordered(order) : [id]
    }
}
