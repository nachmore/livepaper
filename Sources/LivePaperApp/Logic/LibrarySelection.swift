// LibrarySelection — choosing several scene cards in a grid (the library, a collection) to add them
// to a collection, remove them from one or drag them together. Finder's rules, minus the parts a
// grid of previews doesn't need: ⌘-click adds or removes one card, ⇧-click adds the cards from the
// last one clicked to this one, a plain click opens the card (and ends the selection), Esc ends it.
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

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// `order`: the cards as the grid shows them (for ranges).
    mutating func click(_ id: String, _ click: Click, order: [String]) -> Outcome {
        switch click {
        case .plain:
            clear()
            return .open(id)
        case .toggle:
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id
            return .changed
        case .extend:
            guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
                ids.insert(id)
                anchor = id
                return .changed
            }
            ids.formUnion(order[min(from, to)...max(from, to)])
            return .changed
        }
    }

    mutating func clear() {
        ids = []
        anchor = nil
    }

    mutating func selectAll(_ order: [String]) {
        ids = Set(order)
        anchor = order.last
    }

    /// Keeps only cards that are still shown (deleted, filtered out, removed from the collection).
    mutating func retain(_ shown: [String]) {
        let keep = Set(shown)
        guard !ids.isSubset(of: keep) || (anchor.map { !keep.contains($0) } ?? false) else { return }
        ids.formIntersection(keep)
        if let a = anchor, !keep.contains(a) { anchor = nil }
    }

    /// The selected cards in the grid's order.
    func ordered(_ order: [String]) -> [String] { order.filter(ids.contains) }

    /// What a drag of a card, or its context menu, acts on: every selected card (in the grid's
    /// order) when it is one of them, otherwise just that card.
    func targets(for id: String, order: [String]) -> [String] {
        ids.contains(id) && ids.count > 1 ? ordered(order) : [id]
    }
}
