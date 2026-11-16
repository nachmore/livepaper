// LibraryView — the Library: search and kind filter, then its sections (LibrarySections): every
// collection, "Your Scenes" and "Included with LivePaper", each collapsible (remembered across
// launches). Organising happens here: drag cards onto a collection's section to add them (they stay
// where they are; dragged within their collection they are reordered), "Move to ▸" in a card's menu
// or the selection bar moves them, drop cards on "New Collection" (toolbar or the row after the
// collections) to make one with them; ⌘-click and ⇧-click choose several (LibrarySelection).
// .lpcollection and .lpscene files dropped on the Library are imported. Cards: SceneCard.swift;
// headers, drop hint and the New Collection row: LibrarySectionViews.swift.
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
    /// A card (Space shows it full screen, as in Quick Look; Return opens it) or a section header
    /// (← → collapse and expand, Space toggles).
    @FocusState private var focus: LibraryFocus?
    /// What scene cards are dragged over.
    @State private var dropTarget: DropTarget?
    @State private var filesTargeted = false

    enum DropTarget: Equatable {
        case header(LibrarySectionID)
        /// The section's empty space, or an empty collection's drop hint: the end.
        case body(LibrarySectionID)
        case card(LibraryCardID)
        case newCollection
        case toolbarNewCollection

        var section: LibrarySectionID? {
            switch self {
            case .header(let s), .body(let s): return s
            case .card(let c): return c.section
            case .newCollection, .toolbarNewCollection: return nil
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 20, alignment: .top)]

    var body: some View {
        @Bindable var model = model
        let sections = model.librarySections
        content(sections)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !model.selection.isEmpty { SelectionBar(sections: sections) }
            }
            .onExitCommand { model.selection.clear() }
            // Cards a search, a filter or a collapsed section hides leave the selection.
            .onChange(of: LibrarySections.sceneOrder(sections)) { _, shown in model.selection.retain(shown) }
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
                        model.collectionAction = .new(sceneIDs: [])
                    } label: {
                        Label("New Collection", systemImage: dropTarget == .toolbarNewCollection ? "rectangle.stack.fill.badge.plus"
                                                                                                    : "rectangle.stack.badge.plus")
                    }
                    .help("A new collection (\u{2325}\u{2318}N). Drop scenes here to make one with them.")
                    .dropDestination(for: SceneDragPayload.self) { payloads, _ in
                        newCollection(with: payloads)
                    } isTargeted: { track(.toolbarNewCollection, $0) }
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
    private func content(_ sections: [LibrarySection]) -> some View {
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
        } else if sections.isEmpty {
            ContentUnavailableView.search(text: model.query.text)
        } else {
            let collections = sections.filter { $0.collection != nil }
            let others = sections.filter { $0.collection == nil }
            let order = LibrarySections.sceneOrder(sections)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(collections) { sectionView($0, in: sections, order: order) }
                        // Searching is about finding: the row comes back with the full Library.
                        if !model.query.isActive {
                            NewCollectionRow(targeted: dropTarget == .newCollection) { model.collectionAction = .new(sceneIDs: []) }
                                .dropDestination(for: SceneDragPayload.self) { payloads, _ in
                                    newCollection(with: payloads)
                                } isTargeted: { track(.newCollection, $0) }
                                .padding(.top, collections.isEmpty ? 0 : -8)
                        }
                        ForEach(others) { sectionView($0, in: sections, order: order) }
                    }
                    .padding(24)
                }
                .onChange(of: model.libraryReveal) { reveal(proxy) }
                .onAppear { reveal(proxy) }
            }
            // .lpcollection and .lpscene files from Finder are imported (ones the library has just open).
            .dropDestination(for: URL.self) { urls, _ in
                importFiles(urls)
            } isTargeted: { filesTargeted = $0 }
            .overlay {
                if filesTargeted {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 3).padding(6).allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - A section

    /// - Parameter order: every shown scene, once each (LibrarySections.sceneOrder): the selection's order.
    @ViewBuilder
    private func sectionView(_ section: LibrarySection, in sections: [LibrarySection], order: [String]) -> some View {
        let bodyTargeted = section.collection != nil && dropTarget == .body(section.id) && !section.entries.isEmpty
        let stack = VStack(alignment: .leading, spacing: 12) {
            LibrarySectionHeader(section: section, focus: $focus, dropLabel: dropLabel(for: section),
                                 targeted: dropTarget == .header(section.id)) { collapse in
                setCollapsed(section, collapse)
            }
            .modifier(SceneDrop(enabled: section.collection != nil) { payloads in
                drop(payloads, on: .header(section.id), section: section)
            } isTargeted: { track(.header(section.id), $0) })
            if !section.isCollapsed {
                if section.entries.isEmpty {
                    CollectionDropHint(targeted: dropTarget == .body(section.id))
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(section.entries) { entry in
                            let card = LibraryCardID(section: section.id, scene: entry.id)
                            SceneCard(entry: entry, section: section.id, focus: $focus, onMove: { moveFocus(from: $0, by: $1, in: sections) },
                                      sectionOrder: section.sceneIDs, selectionOrder: order, dropTargeted: dropTarget == .card(card))
                                .modifier(SceneDrop(enabled: section.collection != nil) { payloads in
                                    drop(payloads, on: .card(card), section: section)
                                } isTargeted: { track(.card(card), $0) })
                        }
                    }
                }
            }
        }
        stack
            // Drawn outside the section, so nothing moves under the pointer while dragging.
            .background {
                if bodyTargeted {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.07))
                        RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                    }
                    .padding(-10)
                }
            }
            // The section's empty space (and an empty collection's hint): the end of the collection.
            .modifier(SceneDrop(enabled: section.collection != nil) { payloads in
                drop(payloads, on: .body(section.id), section: section)
            } isTargeted: { track(.body(section.id), $0) })
            .id(section.id)
    }

    private func setCollapsed(_ section: LibrarySection, _ collapsed: Bool) {
        guard section.isCollapsed != collapsed else { return }
        withAnimation(.snappy(duration: 0.25)) { model.setCollapsed(section.id, collapsed) }
        if collapsed { focus = LibrarySections.focusAfterCollapsing(section.id, focus: focus) }
    }

    /// ← → move the focus between cards in the order the Library shows them (across sections).
    private func moveFocus(from card: LibraryCardID, by delta: Int, in sections: [LibrarySection]) {
        if let next = LibrarySections.card(card, movedBy: delta, in: sections) { focus = .card(next) }
    }

    /// revealCollection: scroll to the section and focus its header.
    private func reveal(_ proxy: ScrollViewProxy) {
        guard let id = model.libraryReveal else { return }
        model.libraryReveal = nil
        withAnimation(.snappy) { proxy.scrollTo(id, anchor: .top) }
        focus = .header(id)
    }

    // MARK: - Drops

    private func track(_ target: DropTarget, _ targeted: Bool) {
        if targeted { dropTarget = target } else if dropTarget == target { dropTarget = nil }
    }

    /// What dropping here would do, while scene cards are dragged over the section.
    private func dropLabel(for section: LibrarySection) -> String? {
        guard let c = section.collection, let target = dropTarget, target.section == section.id else { return nil }
        guard let drag = model.libraryDrag else { return "Add to \(CollectionText.quoted(c.name))" }
        var card: String?
        if case .card(let id) = target { card = id.scene }
        if case .header = target, model.dropPlan(drag.sceneIDs, from: drag.sourceCollection, onto: c.id, card: nil, onHeader: true) == .none {
            return "Already here"
        }
        let plan = model.dropPlan(drag.sceneIDs, from: drag.sourceCollection, onto: c.id, card: card, onHeader: false)
        return CollectionText.dropLabel(plan, collection: c.name)
    }

    private func drop(_ payloads: [SceneDragPayload], on target: DropTarget, section: LibrarySection) -> Bool {
        dropTarget = nil
        guard let c = section.collection else { return false }
        let ids = SceneDragPayload.sceneIDs(payloads)
        let sources = Set(payloads.map(\.sourceCollection))
        var card: String?, onHeader = false
        switch target {
        case .card(let id): card = id.scene
        case .header: onHeader = true
        default: break
        }
        let plan = model.dropPlan(ids, from: sources.count == 1 ? sources.first ?? nil : nil, onto: c.id, card: card, onHeader: onHeader)
        guard plan != .none else { model.libraryDrag = nil; return false }
        Task { await model.performDrop(plan, onto: c.id) }
        return true
    }

    private func newCollection(with payloads: [SceneDragPayload]) -> Bool {
        dropTarget = nil
        model.libraryDrag = nil
        let ids = SceneDragPayload.sceneIDs(payloads)
        guard !ids.isEmpty else { return false }
        model.collectionAction = .new(sceneIDs: ids)
        return true
    }

    private func importFiles(_ urls: [URL]) -> Bool {
        let files = urls.filter { [CollectionArchive.fileExtension, SceneManifest.packageExtension].contains($0.pathExtension.lowercased()) }
        for url in files {
            Task {
                if url.pathExtension.lowercased() == CollectionArchive.fileExtension { await model.importCollection(at: url) }
                else { await model.openScenePackage(at: url) }
            }
        }
        return !files.isEmpty
    }
}

/// A drop destination for scene cards, only where there is a collection to drop on.
private struct SceneDrop: ViewModifier {
    let enabled: Bool
    let action: ([SceneDragPayload]) -> Bool
    let isTargeted: (Bool) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: SceneDragPayload.self) { payloads, _ in action(payloads) } isTargeted: { isTargeted($0) }
        } else {
            content
        }
    }
}
