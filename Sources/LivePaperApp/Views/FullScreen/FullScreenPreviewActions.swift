// FullScreenPreviewActions — the ways into the full-screen preview: a library scene (detail button,
// card context menu and hover button, Space on a focused card), the playlist (Screen Saver screen,
// menu-bar extra), and ⇧⌘F, which runs whatever the focused view publishes as its preview action.
import AppKit
import LivePaperCore
import SwiftUI

@MainActor
enum FullScreenPreviewLauncher {
    /// A library scene; ← → step through the library as the grid shows it.
    static func previewScene(_ id: String, model: AppModel) {
        guard let request = FullScreenPreviewRequest.library(start: id, visible: model.visibleEntries.map(\.id),
                                                             all: model.entries.map(\.id), playlist: model.playlist) else { return }
        FullScreenPreviewController.shared.present(request, model: model, origin: .window(currentWindowFrame))
    }

    /// The scenes a playlist plays, in its order: the Screen Saver screen's draft, or the saved
    /// playlist from the menu bar (then on the screen under the pointer).
    static func previewPlaylist(_ settings: PlaylistSettings, model: AppModel, start: String? = nil, fromMenuBar: Bool = false) {
        guard let request = FullScreenPreviewRequest.playlist(settings, available: model.availableSceneIDs, start: start) else { return }
        FullScreenPreviewController.shared.present(request, model: model, origin: fromMenuBar ? .pointer : .window(currentWindowFrame))
    }

    /// Whether a playlist has anything to preview.
    static func canPreview(_ settings: PlaylistSettings, model: AppModel) -> Bool {
        !PlaylistDraft(settings).effectiveSceneIDs(available: model.availableSceneIDs).isEmpty
    }

    /// The window the request came from (the main window: buttons, menus and keys act on the key window).
    private static var currentWindowFrame: CGRect? {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.frame
    }
}

/// "Preview Full Screen" for whatever has focus: a library card, the scene detail view, the Screen
/// Saver screen. The Scene menu's ⇧⌘F runs it.
struct FullScreenPreviewAction {
    let run: () -> Void
}

private struct FullScreenPreviewActionKey: FocusedValueKey {
    typealias Value = FullScreenPreviewAction
}

extension FocusedValues {
    var fullScreenPreview: FullScreenPreviewAction? {
        get { self[FullScreenPreviewActionKey.self] }
        set { self[FullScreenPreviewActionKey.self] = newValue }
    }
}

/// The full-screen symbol used by every entry point.
enum FullScreenPreviewSymbol {
    static let name = "arrow.up.left.and.arrow.down.right"
}
