// LibraryView — the scene grid: search, kind filter, hover previews and per-scene actions; ⌘-click
// and ⇧-click choose several cards (LibrarySelection) to add to a collection or drag together.
// SceneCard and SceneMenuItems are shared with a collection's grid (Views/Collections).
import AppKit
import LivePaperCore
import SwiftUI

/// The Library section: the grid with scene details pushed onto a navigation stack.
struct LibraryScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.libraryPath) {
            LibraryView()
                .navigationDestination(for: String.self) { id in
                    SceneDetailView(sceneID: id)
                }
        }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    /// The card with keyboard focus: Space shows it full screen (as in Quick Look), Return opens it.
    @FocusState private var focusedCard: String?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 20, alignment: .top)]

    var body: some View {
        @Bindable var model = model
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !model.selection.isEmpty { SelectionBar(grid: .library, order: model.visibleEntries.map(\.id)) }
            }
            .onExitCommand { model.selection.clear() }
            // Cards a search or filter hides leave the selection.
            .onChange(of: model.visibleEntries.map(\.id)) { _, shown in model.selection.retain(shown) }
            .navigationTitle("Library")
            .searchable(text: $model.query.text, placement: .toolbar, prompt: "Search scenes")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Picker("Show", selection: $model.query.kind) {
                        ForEach(LibraryKindFilter.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("Show only one kind of scene")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        // Like File › Import Scene…: a scene the library already has just opens.
                        if let url = SystemActions.chooseScenePackage() { Task { await model.openScenePackage(at: url) } }
                    } label: {
                        Label("Import Scene", systemImage: "square.and.arrow.down")
                    }
                    .help("Import a .lpscene package")
                    Button {
                        model.section = .create
                    } label: {
                        Label("New Scene", systemImage: "plus")
                    }
                    .help("Create a scene from a video or a description (\u{2318}N)")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        let visible = model.visibleEntries
        if model.entries.isEmpty && model.isLoadingLibrary {
            ProgressView("Loading scenes\u{2026}")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.entries.isEmpty {
            ContentUnavailableView {
                Label("No scenes yet", systemImage: "sparkles.rectangle.stack")
            } description: {
                Text(model.libraryLoadError ?? "Create one from a video or describe what you'd like to see.")
            } actions: {
                Button("Create a Scene") { model.section = .create }
                    .buttonStyle(.borderedProminent)
            }
        } else if visible.isEmpty {
            ContentUnavailableView.search(text: model.query.text)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if model.query.isActive {
                        section(title: "Results", entries: visible)
                    } else {
                        let mine = visible.filter { !$0.item.isBuiltin }
                        let builtin = visible.filter(\.item.isBuiltin)
                        if !mine.isEmpty { section(title: "Your Scenes", entries: mine) }
                        if !builtin.isEmpty { section(title: "Included with LivePaper", entries: builtin) }
                    }
                }
                .padding(24)
            }
        }
    }

    private func section(title: String, entries: [LibraryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.weight(.semibold))
                Text("\(entries.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                let order = model.visibleEntries.map(\.id)
                ForEach(entries) { SceneCard(entry: $0, focus: $focusedCard, onMove: moveFocus, grid: .library, order: order) }
            }
        }
    }

    /// ← → move the focus between cards in the grid's order (across both sections).
    private func moveFocus(from id: String, by delta: Int) {
        let ids = model.visibleEntries.map(\.id)
        guard let i = ids.firstIndex(of: id) else { return }
        let next = i + delta
        if ids.indices.contains(next) { focusedCard = ids[next] }
    }
}

// MARK: - Card

struct SceneCard: View {
    let entry: LibraryEntry
    /// The grid's focused card (Space previews it full screen, Return opens it, ← → move).
    var focus: FocusState<String?>.Binding
    var onMove: (String, Int) -> Void = { _, _ in }
    /// The library, or a collection: where a click opens it, the order Space steps through, the menu.
    var grid: SceneGrid = .library
    /// The grid's cards in order (⇧-click ranges, dragging the selection).
    var order: [String] = []
    /// A collection's grid: something is being dragged onto this card (it shows where it lands).
    var dropTargeted = false
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @State private var showLive = false

    /// Hover must rest this long before a live preview starts, so sweeping the pointer across the
    /// grid doesn't spin up a web view per card.
    private static let hoverDelay: UInt64 = 450_000_000

    private var isFocused: Bool { focus.wrappedValue == entry.id }
    private var isSelected: Bool { model.selection.contains(entry.id) }
    /// Hover and keyboard focus look the same.
    private var highlighted: Bool { hovering || isFocused || dropTargeted }
    /// What a drag of this card, or its menu's collection items, act on.
    private var targets: [String] { model.selection.targets(for: entry.id, order: order) }

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
        .draggable(SceneDragPayload(sceneIDs: targets, sourceCollection: grid.collectionID)) { dragPreview }
        .focusable()
        .focused(focus, equals: entry.id)
        .focusEffectDisabled()
        // Once per press: a held Space mustn't open the preview again the moment it closes.
        .onKeyPress(.space, phases: .down) { _ in previewFullScreen(); return .handled }
        .onKeyPress(.return) { open(); return .handled }
        .onKeyPress(.leftArrow) { onMove(entry.id, -1); return .handled }
        .onKeyPress(.rightArrow) { onMove(entry.id, 1); return .handled }
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
        .accessibilityAction(named: isSelected ? "Deselect" : "Select") { _ = model.selection.click(entry.id, .toggle, order: order) }
        .accessibilityAction(named: "Preview Full Screen", previewFullScreen)
    }

    /// A plain click opens the card; ⌘ and ⇧ choose cards (LibrarySelection).
    private func click() {
        let flags = NSEvent.modifierFlags
        let kind = LibrarySelection.Click(command: flags.contains(.command), shift: flags.contains(.shift))
        if case .open = model.selection.click(entry.id, kind, order: order) { open() }
    }

    private func open() {
        switch grid {
        case .library: model.libraryPath.append(entry.id)
        case .collection: model.collectionPath.append(entry.id)
        }
    }

    private func previewFullScreen() {
        switch grid {
        case .library: FullScreenPreviewLauncher.previewScene(entry.id, model: model)
        case .collection(let id): FullScreenPreviewLauncher.previewCollection(id, start: entry.id, model: model)
        }
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
                HStack {
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
            .overlay(alignment: .topLeading) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .shadow(radius: 2)
                        .padding(6)
                        .accessibilityHidden(true)
                }
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
/// In a collection's grid it also removes the scene from the collection or moves it to another;
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
            Button(ids.count > 1 ? "Remove \(ids.count) Scenes from \u{201C}\(c.name)\u{201D}" : "Remove from \u{201C}\(c.name)\u{201D}") {
                Task { await model.removeFromCollection(ids, id) }
            }
            MoveToCollectionMenu(sceneIDs: ids, from: id)
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
