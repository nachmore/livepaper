// SceneCard — one scene in a Library section: thumbnail (hover = live preview), badges, the
// full-screen button, ⌘/⇧-click selection, drag (the selection when the card is selected), keyboard
// focus (Space previews full screen, Return opens, ← → move across sections) and the context menu.
// A scene can be in several sections; a card in a collection's section previews through that
// collection and its menu can remove it or move it to another collection.
import AppKit
import LivePaperCore
import SwiftUI

struct SceneCard: View {
    let entry: LibraryEntry
    /// The section it is shown in.
    let section: LibrarySectionID
    /// The Library's keyboard focus (Space previews full screen, Return opens, ← → move).
    var focus: FocusState<LibraryFocus?>.Binding
    var onMove: (LibraryCardID, Int) -> Void = { _, _ in }
    /// Its section's cards in order (⇧-click ranges).
    var sectionOrder: [String] = []
    /// Every shown scene in the Library's order, once each: what a drag or the menu of a selected
    /// card acts on.
    var selectionOrder: [String] = []
    /// Scene cards are dragged onto this one (a collection's section: they land here).
    var dropTargeted = false
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @State private var showLive = false

    /// Hover must rest this long before a live preview starts, so sweeping the pointer across the
    /// grid doesn't spin up a web view per card.
    private static let hoverDelay: UInt64 = 450_000_000

    private var cardID: LibraryCardID { LibraryCardID(section: section, scene: entry.id) }
    private var grid: SceneGrid { section.collectionID.map(SceneGrid.collection) ?? .library }
    private var isFocused: Bool { focus.wrappedValue == .card(cardID) }
    private var isSelected: Bool { model.selection.contains(entry.id) }
    /// Hover and keyboard focus look the same.
    private var highlighted: Bool { hovering || isFocused || dropTargeted }
    /// What a drag of this card, or its menu's collection items, act on.
    private var targets: [String] { model.selection.targets(for: entry.id, order: selectionOrder) }

    // Not a Button: the card holds its own full-screen button, and a click anywhere else opens it.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.manifest.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(entry.manifest.description.isEmpty ? " " : entry.manifest.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: click)
        // The payload is made when the drag starts: the drop targets read what is dragged from where.
        .draggable(beginDrag()) { dragPreview }
        .focusable()
        .focused(focus, equals: .card(cardID))
        .focusEffectDisabled()
        // Once per press: a held Space mustn't open the preview again the moment it closes.
        .onKeyPress(.space, phases: .down) { _ in previewFullScreen(); return .handled }
        .onKeyPress(.return) { open(); return .handled }
        .onKeyPress(.leftArrow) { onMove(cardID, -1); return .handled }
        .onKeyPress(.rightArrow) { onMove(cardID, 1); return .handled }
        .focusedValue(\.fullScreenPreview, FullScreenPreviewAction(run: previewFullScreen))
        .onHover { hovering = $0 }
        .task(id: hovering) {
            guard hovering else { showLive = false; return }
            try? await Task.sleep(nanoseconds: Self.hoverDelay)
            if !Task.isCancelled { withAnimation(.easeIn(duration: 0.25)) { showLive = true } }
        }
        .contextMenu { SceneMenuItems(entry: entry, includePreview: true, grid: grid, targets: targets) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.manifest.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Opens the scene. Space previews it full screen. Command-click selects it. More actions are in the context menu.")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, open)
        .accessibilityAction(named: isSelected ? "Deselect" : "Select") {
            _ = model.selection.click(entry.id, .toggle, order: sectionOrder, section: section.key)
        }
        .accessibilityAction(named: "Preview Full Screen", previewFullScreen)
    }

    /// A plain click opens the card; ⌘ and ⇧ choose cards (LibrarySelection).
    private func click() {
        let flags = NSEvent.modifierFlags
        let kind = LibrarySelection.Click(command: flags.contains(.command), shift: flags.contains(.shift))
        if case .open = model.selection.click(entry.id, kind, order: sectionOrder, section: section.key) { open() }
    }

    private func open() { model.libraryPath.append(entry.id) }

    private func previewFullScreen() {
        switch grid {
        case .library: FullScreenPreviewLauncher.previewScene(entry.id, model: model)
        case .collection(let id): FullScreenPreviewLauncher.previewCollection(id, start: entry.id, model: model)
        }
    }

    private func beginDrag() -> SceneDragPayload {
        let payload = SceneDragPayload(sceneIDs: targets, sourceCollection: section.collectionID)
        model.libraryDrag = LibraryDrag(sceneIDs: payload.sceneIDs, sourceCollection: payload.sourceCollection)
        return payload
    }

    /// The thumbnail, small, with how many scenes come along.
    private var dragPreview: some View {
        ThumbnailImage(url: entry.thumbnail, revision: model.thumbnailRevision[entry.id] ?? 0, maxPixel: 320,
                       placeholderSymbol: entry.badge.symbolName)
            .frame(width: 128, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if targets.count > 1 {
                    Text("\(targets.count)")
                        .font(.caption.weight(.bold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .padding(4)
                }
            }
    }

    /// Shown while the card is hovered or focused.
    private var fullScreenButton: some View {
        Button(action: previewFullScreen) {
            Image(systemName: FullScreenPreviewSymbol.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.black.opacity(0.5), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Preview Full Screen (Space)")
        .accessibilityLabel("Preview Full Screen")
        .padding(8)
        .transition(.opacity)
    }

    private var artwork: some View {
        Color.black
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay {
                ZStack {
                    ThumbnailImage(url: entry.thumbnail, revision: model.thumbnailRevision[entry.id] ?? 0,
                                   placeholderSymbol: entry.badge.symbolName)
                    if showLive {
                        ScenePreview(item: entry.item, quality: .hover, showClock: false, cornerRadius: 12)
                            .transition(.opacity)
                    }
                }
            }
            .overlay(alignment: .top) {
                HStack(spacing: 6) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .shadow(radius: 2)
                            .accessibilityHidden(true)
                    }
                    OverlayBadge(title: entry.badge.label, symbol: entry.badge.symbolName, tint: entry.badge.tint)
                    Spacer()
                    if entry.energy != .unmeasured {
                        OverlayBadge(title: entry.energy.shortLabel, symbol: entry.energy.symbolName, tint: entry.energy.overlayTint)
                            .help(entry.energy.label + ". " + entry.energy.explanation)
                    }
                }
                .padding(8)
            }
            .overlay(alignment: .bottomLeading) {
                if highlighted { fullScreenButton }
            }
            .overlay(alignment: .bottomTrailing) {
                // When every scene plays, a per-card marker would carry no information.
                if model.isInPlaylist(entry.id) && !PlaylistDraft(model.effectivePlaylist).includesAllScenes {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .padding(8)
                        .help("In the screen saver playlist")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(highlighted || isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                                  lineWidth: isSelected ? 3 : highlighted ? 2 : 1)
            }
            .shadow(color: .black.opacity(highlighted ? 0.25 : 0.12), radius: highlighted ? 12 : 5, y: highlighted ? 6 : 2)
            .scaleEffect(highlighted ? 1.015 : 1)
            .animation(.snappy(duration: 0.2), value: highlighted)
    }

    private var accessibilityValue: String {
        var parts = [entry.badge.label + " scene", entry.energy.label]
        if entry.item.isBuiltin { parts.append("Included with LivePaper") }
        if model.isInPlaylist(entry.id) { parts.append("In playlist") }
        if isSelected { parts.append("Selected") }
        return parts.joined(separator: ", ")
    }
}

/// The per-scene action menu, shared by the card context menu and the detail view's "More" menu.
/// In a collection's section it also removes the scene from the collection or moves it to another;
/// the collection items act on every selected card when this one is selected (`targets`).
struct SceneMenuItems: View {
    let entry: LibraryEntry
    var includePreview = false
    var grid: SceneGrid = .library
    /// The scenes "Add to Collection" and the collection items act on (default: this one).
    var targets: [String]? = nil
    @Environment(AppModel.self) private var model

    var body: some View {
        let ids = targets ?? [entry.id]
        if includePreview {
            Button("Preview") { model.showScene(entry.id) }
        }
        Button("Preview Full Screen") {
            if let id = grid.collectionID { FullScreenPreviewLauncher.previewCollection(id, start: entry.id, model: model) }
            else { FullScreenPreviewLauncher.previewScene(entry.id, model: model) }
        }
        Divider()
        Button("Use as Screen Saver") { Task { await model.useAsScreenSaver(entry.id) } }
        Button(model.followedCollection.map { "Add to Playlist (\u{201C}\($0.name)\u{201D})" } ?? "Add to Playlist") {
            Task { await model.addToPlaylist(entry.id) }
        }
        .disabled(model.isInPlaylist(entry.id) && model.playlist.mode != .single)
        .help(model.followedCollection.map { "The screen saver plays \u{201C}\($0.name)\u{201D}, so the scene is added to that collection." } ?? "")
        AddToCollectionMenu(sceneIDs: ids)
        if let id = grid.collectionID, let c = model.collection(id: id) {
            // Of the chosen scenes, those in this collection.
            let inIt = ids.filter(c.sceneIDs.contains)
            let these = inIt.isEmpty ? [entry.id] : inIt
            MoveToCollectionMenu(sceneIDs: these, from: id)
            Button(these.count > 1 ? "Remove \(these.count) Scenes from \u{201C}\(c.name)\u{201D}" : "Remove from \u{201C}\(c.name)\u{201D}") {
                Task { await model.removeFromCollection(these, id) }
            }
        }
        Divider()
        Button("Clone\u{2026}") { model.sceneAction = .clone(entry.id) }
        Button("Modify with AI\u{2026}") { model.sceneAction = .modify(entry.id) }
            .disabled(entry.manifest.kind == .video)
        Divider()
        Button("Export\u{2026}") {
            if let url = SystemActions.chooseExportDestination(for: entry) { Task { await model.export(entry.id, to: url) } }
        }
        Button("Reveal in Finder") { SystemActions.revealInFinder(entry.item.packageURL) }
        Divider()
        Button("Delete\u{2026}", role: .destructive) { model.sceneAction = .delete(entry.id) }
            .disabled(entry.item.isBuiltin)
    }
}
