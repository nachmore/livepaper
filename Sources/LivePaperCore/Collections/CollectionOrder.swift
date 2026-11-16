// CollectionOrder — adding, removing and moving scene ids in an ordered list without repeats: the
// rules every collection edit follows (CollectionService, the app's drag and drop, the CLI).
// Pure functions over [String]; unknown ids are ignored, never an error.
import Foundation

/// Where scenes go in a collection.
public enum CollectionPlacement: Sendable, Equatable {
    case start
    case end
    /// 0-based position, in the resulting order, of the first scene placed (clamped).
    case index(Int)
    /// Right before / after this scene (the end when it isn't in the collection).
    case before(String)
    case after(String)
}

public enum CollectionOrder {
    /// `ids` without repeats, first occurrences kept.
    public static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Inserts the scenes `ids` doesn't have yet at `placement`, in the order given. Returns the new
    /// order and the scenes that were added.
    public static func adding(_ new: [String], to ids: [String], at placement: CollectionPlacement = .end) -> (ids: [String], added: [String]) {
        let present = Set(ids)
        let added = unique(new).filter { !present.contains($0) }
        guard !added.isEmpty else { return (ids, []) }
        var out = ids
        out.insert(contentsOf: added, at: insertionIndex(placement, in: ids))
        return (out, added)
    }

    /// Removes the given scenes. Returns the new order and the scenes that were removed.
    public static func removing(_ remove: [String], from ids: [String]) -> (ids: [String], removed: [String]) {
        let doomed = Set(remove)
        return (ids.filter { !doomed.contains($0) }, ids.filter(doomed.contains))
    }

    /// Moves the given scenes (those in `ids`, in their current relative order) to `placement` —
    /// measured against the other scenes, so `.index(0)` makes them the first and `.after(x)` puts
    /// them right after x. Placing scenes before or after one of themselves changes nothing.
    public static func moving(_ moving: [String], in ids: [String], to placement: CollectionPlacement) -> [String] {
        let movingSet = Set(moving)
        let moved = ids.filter(movingSet.contains)
        guard !moved.isEmpty else { return ids }
        switch placement {
        case .before(let target), .after(let target):
            if movingSet.contains(target) { return ids }
        default: break
        }
        var rest = ids.filter { !movingSet.contains($0) }
        rest.insert(contentsOf: moved, at: insertionIndex(placement, in: rest))
        return rest
    }

    /// Drag and drop in a grid: scenes dropped onto `target` take its place — after it when every
    /// dragged scene comes from before it (dragged forward), before it otherwise (dragged back, or
    /// coming from outside the collection). So dropping a card on its neighbour swaps the two.
    public static func dropPlacement(moving: [String], onto target: String, in ids: [String]) -> CollectionPlacement {
        guard let targetIndex = ids.firstIndex(of: target) else { return .end }
        let positions = moving.compactMap { ids.firstIndex(of: $0) }
        let forward = !positions.isEmpty && positions.count == Set(moving).count && positions.allSatisfy { $0 < targetIndex }
        return forward ? .after(target) : .before(target)
    }

    /// Where `placement` inserts into `ids`.
    static func insertionIndex(_ placement: CollectionPlacement, in ids: [String]) -> Int {
        switch placement {
        case .start: return 0
        case .end: return ids.count
        case .index(let i): return min(max(0, i), ids.count)
        case .before(let target): return ids.firstIndex(of: target) ?? ids.count
        case .after(let target): return ids.firstIndex(of: target).map { $0 + 1 } ?? ids.count
        }
    }
}
