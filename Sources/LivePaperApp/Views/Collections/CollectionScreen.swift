// CollectionScreen — one collection: the library's grid limited to its scenes, in its order. Drag a
// card onto another to move it there (CollectionOrder.dropPlacement), ⌘/⇧-click to choose several;
// remove or move scenes from the card menu or the selection bar. "Use as Screen Saver" makes the
// screen saver follow the collection (a live link: changes here update it), "Preview Full Screen"
// steps through it, "Export…" writes one .lpcollection file.
import LivePaperCore
import SwiftUI

struct CollectionScreen: View {
    let collectionID: String
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.collectionPath) {
            CollectionGridView(collectionID: collectionID)
                .navigationDestination(for: String.self) { id in
                    SceneDetailView(sceneID: id)
                }
        }
        .id(collectionID)
    }
}

struct CollectionGridView: View {
    let collectionID: String
    @Environment(AppModel.self) private var model
    @FocusState private var focusedCard: String?
    /// The card something is dragged onto, and whether it is the empty space after the cards.
    @State private var dropTarget: String?
    @State private var endTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 20, alignment: .top)]

    var body: some View {
        if let collection = model.collection(id: collectionID) {
            content(collection)
                .navigationTitle(collection.name)
                .toolbar { toolbar(collection) }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !model.selection.isEmpty { SelectionBar(grid: .collection(collectionID), order: order) }
                }
                .onExitCommand { model.selection.clear() }
                .focusedSceneValue(\.fullScreenPreview, canPreview ? FullScreenPreviewAction(run: preview) : nil)
        } else {
            ContentUnavailableView("Collection not found", systemImage: "rectangle.stack",
                                   description: Text("It may have been deleted."))
        }
    }

    private var entries: [LibraryEntry] { model.collectionEntries(collectionID) }
    private var order: [String] { entries.map(\.id) }
    private var canPreview: Bool { FullScreenPreviewLauncher.canPreviewCollection(collectionID, model: model) }
    private func preview() { FullScreenPreviewLauncher.previewCollection(collectionID, model: model) }

    @ToolbarContentBuilder
    private func toolbar(_ collection: SceneCollection) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: preview) {
                Label("Preview Full Screen", systemImage: FullScreenPreviewSymbol.name)
            }
            .help("Show the collection\u{2019}s scenes full screen, in order (\u{21E7}\u{2318}F); \u{2190} \u{2192} change the scene")
            .disabled(!canPreview)
            Menu {
                CollectionMenuItems(collection: collection, includeOpen: false)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More actions")
        }
    }

    @ViewBuilder
    private func content(_ collection: SceneCollection) -> some View {
        let entries = self.entries
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(collection, count: entries.count)
                if entries.isEmpty {
                    emptyState(collection)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(entries) { entry in
                            SceneCard(entry: entry, focus: $focusedCard, onMove: moveFocus, grid: .collection(collectionID), order: order,
                                      dropTargeted: dropTarget == entry.id)
                                .dropDestination(for: SceneDragPayload.self) { payloads, _ in
                                    drop(payloads, onto: entry.id)
                                } isTargeted: { targeted in
                                    if targeted { dropTarget = entry.id } else if dropTarget == entry.id { dropTarget = nil }
                                }
                        }
                    }
                    Text(entries.count > 1 ? "Drag a scene onto another to change the order. \u{2318}-click or \u{21E7}-click to choose several."
                                           : "\u{2318}-click or \u{21E7}-click to choose several scenes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The empty space after the cards: the end of the collection.
        .dropDestination(for: SceneDragPayload.self) { payloads, _ in
            drop(payloads, onto: nil)
        } isTargeted: { endTargeted = $0 }
    }

    private func header(_ collection: SceneCollection, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(collection.name).font(.largeTitle.weight(.semibold)).textSelection(.enabled)
                Text(CollectionText.sceneCount(count)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
            }
            HStack(spacing: 10) {
                if model.isFollowed(collectionID) {
                    Label("Plays in the screen saver", systemImage: "play.rectangle.fill")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.tint.opacity(0.15), in: Capsule())
                    Button("Screen Saver Settings\u{2026}") { model.section = .playlist }
                } else {
                    Button {
                        Task { await model.useCollectionAsScreenSaver(collectionID) }
                    } label: {
                        Label("Use as Screen Saver", systemImage: "play.rectangle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(count == 0 || model.isPublishing)
                    .help(count == 0 ? "Add scenes first" : "The screen saver plays this collection and follows its changes")
                }
                Button {
                    if let url = SystemActions.chooseCollectionExportDestination(for: collection) {
                        Task { await model.exportCollection(collectionID, to: url) }
                    }
                } label: {
                    Label("Export\u{2026}", systemImage: "square.and.arrow.up")
                }
                .help("Write the collection and your scenes in it to one .lpcollection file")
                if model.isPublishing { ProgressView().controlSize(.small) }
            }
            .controlSize(.large)
            if model.isFollowed(collectionID) {
                Text(CollectionText.followsNote(collection.name))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func emptyState(_ collection: SceneCollection) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No scenes yet").font(.title3.weight(.semibold))
            Text("Drag scenes from the Library onto \u{201C}\(collection.name)\u{201D} in the sidebar, or choose Add to Collection in a scene\u{2019}s menu.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button("Go to Library") { model.section = .library }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(endTargeted ? Color.accentColor : Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 2, dash: [6, 5])))
    }

    /// Scenes from this grid move; scenes from elsewhere are added there.
    private func drop(_ payloads: [SceneDragPayload], onto target: String?) -> Bool {
        let ids = SceneDragPayload.sceneIDs(payloads)
        guard !ids.isEmpty, let current = model.collection(id: collectionID)?.sceneIDs else { return false }
        dropTarget = nil
        let placement = target.map { CollectionOrder.dropPlacement(moving: ids, onto: $0, in: current) } ?? .end
        let fromHere = payloads.allSatisfy { $0.sourceCollection == collectionID }
        Task {
            if fromHere { await model.moveScenes(ids, in: collectionID, to: placement) }
            else { await model.addToCollection(ids, collectionID, at: placement) }
        }
        return true
    }

    private func moveFocus(from id: String, by delta: Int) {
        guard let i = order.firstIndex(of: id) else { return }
        let next = i + delta
        if order.indices.contains(next) { focusedCard = order[next] }
    }
}

/// A collection's actions (the sidebar's context menu, the collection screen's More menu).
struct CollectionMenuItems: View {
    let collection: SceneCollection
    var includeOpen = true
    @Environment(AppModel.self) private var model

    var body: some View {
        let id = collection.id
        if includeOpen { Button("Open") { model.showCollection(id) } }
        Button("Preview Full Screen") { FullScreenPreviewLauncher.previewCollection(id, model: model) }
            .disabled(!FullScreenPreviewLauncher.canPreviewCollection(id, model: model))
        Button(model.isFollowed(id) ? "Playing in the Screen Saver" : "Use as Screen Saver") {
            Task { await model.useCollectionAsScreenSaver(id) }
        }
        .disabled(model.isFollowed(id) || model.sceneCount(of: collection) == 0)
        Divider()
        Button("Export\u{2026}") {
            if let url = SystemActions.chooseCollectionExportDestination(for: collection) {
                Task { await model.exportCollection(id, to: url) }
            }
        }
        Divider()
        Button("Rename\u{2026}") { model.collectionAction = .rename(id) }
        Button("Delete Collection\u{2026}", role: .destructive) { model.collectionAction = .delete(id) }
    }
}
