// LibrarySections — the Library's sections (ARCHITECTURE §11): every collection, in the order the
// collections are listed (by name), then "Your Scenes" and "Included with LivePaper". Search and the
// kind filter apply inside each section; while they do, a section without matches isn't shown
// (collapsed or not). A scene can be in several sections — collections group scenes, Your Scenes lists
// everything you made — so a card is identified by its section and its scene (LibraryCardID).
//
// Also here: which sections are collapsed (remembered across launches in the PreferenceStore, per
// collection id so a rename keeps it; new collections start expanded) and what dropping scene cards
// on a collection does (CollectionDropPlan: a drag adds; only scenes dragged within their collection
// are reordered; "Move to ▸" moves).
//
// Foundation-only; also compiled into LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/.
import Foundation
import LivePaperCore

/// A Library section, and the key its collapsed state is remembered by.
enum LibrarySectionID: Hashable, Sendable {
    case collection(String)
    case yourScenes
    case builtin

    /// "collection:<id>", "your-scenes", "builtin".
    var key: String {
        switch self {
        case .collection(let id): return "collection:" + id
        case .yourScenes: return "your-scenes"
        case .builtin: return "builtin"
        }
    }

    init?(key: String) {
        switch key {
        case "your-scenes": self = .yourScenes
        case "builtin": self = .builtin
        default:
            guard key.hasPrefix("collection:"), key.count > "collection:".count else { return nil }
            self = .collection(String(key.dropFirst("collection:".count)))
        }
    }

    var collectionID: String? {
        if case .collection(let id) = self { return id }
        return nil
    }
}

struct LibrarySection: Identifiable, Equatable, Sendable {
    var id: LibrarySectionID
    var title: String
    /// What it shows, in its order (search and kind filter applied; also when collapsed).
    var entries: [LibraryEntry]
    /// How many of its scenes the library has, search and filter aside.
    var total: Int
    /// For a collection's section.
    var collection: SceneCollection?
    var isCollapsed: Bool

    /// Its cards' scene ids in order.
    var sceneIDs: [String] { entries.map(\.id) }

    /// "4", or "2 of 4" while a search or filter hides some.
    var countText: String { entries.count == total ? "\(total)" : "\(entries.count) of \(total)" }
}

/// One card in the Library: a scene in a section.
struct LibraryCardID: Hashable, Sendable {
    var section: LibrarySectionID
    var scene: String
}

/// What has the keyboard focus in the Library: a section's header or a card.
enum LibraryFocus: Hashable, Sendable {
    case header(LibrarySectionID)
    case card(LibraryCardID)
}

enum LibrarySections {
    static let yourScenesTitle = "Your Scenes"
    static let builtinTitle = "Included with LivePaper"

    /// - Parameter collections: in the order they are listed (AppModel.collections: by name).
    static func make(entries: [LibraryEntry], collections: [SceneCollection], query: LibraryQuery,
                     collapsed: Set<String>) -> [LibrarySection] {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var sections: [LibrarySection] = []
        func add(_ id: LibrarySectionID, _ title: String, _ all: [LibraryEntry], collection: SceneCollection? = nil, keepEmpty: Bool) {
            let shown = query.apply(all)
            // Searching: only sections with matches. Otherwise an empty collection still shows
            // (its drop hint); Your Scenes and Included only when they have scenes.
            if query.isActive ? shown.isEmpty : (all.isEmpty && !keepEmpty) { return }
            sections.append(LibrarySection(id: id, title: title, entries: shown, total: all.count, collection: collection,
                                           isCollapsed: collapsed.contains(id.key)))
        }
        for c in collections {
            let scenes = CollectionOrder.unique(c.sceneIDs).compactMap { byID[$0] }
            add(.collection(c.id), c.name, scenes, collection: c, keepEmpty: true)
        }
        add(.yourScenes, yourScenesTitle, entries.filter { !$0.item.isBuiltin }, keepEmpty: false)
        add(.builtin, builtinTitle, entries.filter(\.item.isBuiltin), keepEmpty: false)
        return sections
    }

    /// The cards as the Library shows them, top to bottom (a collapsed section's aren't shown): the
    /// order ← → move the keyboard focus in.
    static func cards(_ sections: [LibrarySection]) -> [LibraryCardID] {
        sections.filter { !$0.isCollapsed }.flatMap { s in s.entries.map { LibraryCardID(section: s.id, scene: $0.id) } }
    }

    /// The shown scenes in that order, each once: the selection's order (the selection bar, a drag
    /// of selected cards, Select All).
    static func sceneOrder(_ sections: [LibrarySection]) -> [String] {
        CollectionOrder.unique(cards(sections).map(\.scene))
    }

    /// The card `delta` steps from `card` (nil at either end).
    static func card(_ card: LibraryCardID, movedBy delta: Int, in sections: [LibrarySection]) -> LibraryCardID? {
        let all = cards(sections)
        guard let i = all.firstIndex(of: card), all.indices.contains(i + delta) else { return nil }
        return all[i + delta]
    }

    /// Where the keyboard focus goes when its card is hidden by collapsing `section`: the header.
    static func focusAfterCollapsing(_ section: LibrarySectionID, focus: LibraryFocus?) -> LibraryFocus? {
        if case .card(let card)? = focus, card.section == section { return .header(section) }
        return focus
    }

    /// Whether the search or filter hides the collection's section (revealing it clears them).
    static func hides(_ collectionID: String, entries: [LibraryEntry], collections: [SceneCollection], query: LibraryQuery) -> Bool {
        guard query.isActive else { return false }
        return !make(entries: entries, collections: collections, query: query, collapsed: [])
            .contains { $0.id == .collection(collectionID) }
    }
}

/// The Library's collapsed sections, remembered across launches (`LibrarySectionID.key`s, a JSON
/// array in the PreferenceStore).
enum LibraryCollapsedSections {
    static let preferenceKey = "libraryCollapsedSections"

    static func load(_ store: PreferenceStore) -> Set<String> {
        guard let data = store.data(forKey: preferenceKey),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(keys.filter { LibrarySectionID(key: $0) != nil })
    }

    static func save(_ keys: Set<String>, to store: PreferenceStore) {
        if keys.isEmpty { store.removeObject(forKey: preferenceKey); return }
        if let data = try? JSONEncoder().encode(keys.sorted()) { store.set(data, forKey: preferenceKey) }
    }
}

/// What dropping scene cards on a collection's section does. A drag adds (copies): the scenes stay
/// wherever else they are. Scenes dragged within their own collection, and all of them already in
/// it, are reordered instead. Moving to another collection is "Move to ▸" (card menu, selection bar).
enum CollectionDropPlan: Equatable, Sendable {
    case none
    /// Add the scenes the collection lacks at `placement`. `copiedFrom`: the collection they were
    /// dragged from (they stay there too; the banner says how to move instead).
    case add([String], CollectionPlacement, copiedFrom: String?)
    case reorder([String], CollectionPlacement)

    /// - Parameters:
    ///   - source: the collection the cards were dragged from (nil: Your Scenes, Included).
    ///   - card: the card they were dropped on; nil for the header or the empty space.
    ///   - onHeader: dropped on the header (scenes from this collection: nothing to do).
    static func plan(sceneIDs: [String], source: String?, onto collection: SceneCollection, card: String?,
                     onHeader: Bool = false) -> CollectionDropPlan {
        let ids = CollectionOrder.unique(sceneIDs)
        guard !ids.isEmpty else { return .none }
        let have = Set(collection.sceneIDs)
        let placement = card.map { CollectionOrder.dropPlacement(moving: ids, onto: $0, in: collection.sceneIDs) } ?? .end
        if source == collection.id && ids.allSatisfy(have.contains) {
            if onHeader { return .none }
            if let card, ids.contains(card) { return .none }   // dropped onto itself
            return .reorder(ids, placement)
        }
        return .add(ids, placement, copiedFrom: source == collection.id ? nil : source)
    }
}

/// Scene cards being dragged in the Library: the scenes (the selection, when the dragged card is
/// selected) and the collection whose section they came from (nil: Your Scenes, Included).
struct LibraryDrag: Equatable, Sendable {
    var sceneIDs: [String]
    var sourceCollection: String?
}
