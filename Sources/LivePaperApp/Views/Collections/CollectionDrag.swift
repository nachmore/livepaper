// CollectionDrag — what dragging scene cards in the Library carries: the scenes' ids (every selected
// card when the dragged one is selected) and the collection whose section they come from, if any.
// Drop targets (LibraryView, CollectionDropPlan): a collection's section — its header and empty space
// (the end) or one of its cards (that place, CollectionOrder.dropPlacement); dragged from elsewhere
// the scenes are added, dragged within their collection they are reordered — and "New Collection" (the
// toolbar button, the row after the collections) makes a collection with them.
import CoreTransferable
import LivePaperCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist; never written to disk.
    static let livePaperSceneReferences = UTType(exportedAs: "com.nachmore.livepaper.scene-references", conformingTo: .data)
}

struct SceneDragPayload: Codable, Transferable, Equatable {
    var sceneIDs: [String]
    /// The collection whose section they were dragged from (nil: Your Scenes, Included).
    var sourceCollection: String?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .livePaperSceneReferences)
    }

    /// Every dropped payload's scenes, once each, in order.
    static func sceneIDs(_ payloads: [SceneDragPayload]) -> [String] {
        CollectionOrder.unique(payloads.flatMap(\.sceneIDs))
    }
}

/// Which kind of section a scene card is in: what Space previews (the library, or the collection in
/// its order) and what its menu offers.
enum SceneGrid: Equatable {
    case library
    case collection(String)

    var collectionID: String? {
        if case .collection(let id) = self { return id }
        return nil
    }
}
