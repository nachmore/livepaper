// CollectionDrag — what dragging scene cards inside LivePaper carries: the scenes' ids (every
// selected card when the dragged one is selected) and the collection they come from, if any. Drop
// targets: a sidebar collection (adds them), "New Collection…" (a new one with them), a card in a
// collection's grid (moves them there, CollectionOrder.dropPlacement) and the grid's empty space (the end).
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
    /// The collection whose grid they were dragged from (nil: the library).
    var sourceCollection: String?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .livePaperSceneReferences)
    }

    /// Every dropped payload's scenes, once each, in order.
    static func sceneIDs(_ payloads: [SceneDragPayload]) -> [String] {
        CollectionOrder.unique(payloads.flatMap(\.sceneIDs))
    }
}

/// Which grid a scene card is in: what a click opens into, what Space previews, what its menu offers.
enum SceneGrid: Equatable {
    case library
    case collection(String)

    var collectionID: String? {
        if case .collection(let id) = self { return id }
        return nil
    }
}
