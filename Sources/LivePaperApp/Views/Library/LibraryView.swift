// LibraryView — the scene grid: search, kind filter, hover previews and per-scene actions.
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
                        if let url = SystemActions.chooseScenePackage() { Task { await model.importPackage(at: url) } }
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
                ForEach(entries) { SceneCard(entry: $0, focus: $focusedCard, onMove: moveFocus) }
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
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @State private var showLive = false

    /// Hover must rest this long before a live preview starts, so sweeping the pointer across the
    /// grid doesn't spin up a web view per card.
    private static let hoverDelay: UInt64 = 450_000_000

    private var isFocused: Bool { focus.wrappedValue == entry.id }
    /// Hover and keyboard focus look the same.
    private var highlighted: Bool { hovering || isFocused }

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
        .onTapGesture(perform: open)
        .focusable()
        .focused(focus, equals: entry.id)
        .focusEffectDisabled()
        .onKeyPress(.space) { previewFullScreen(); return .handled }
        .onKeyPress(.return) { open(); return .handled }
        .onKeyPress(.leftArrow) { onMove(entry.id, -1); return .handled }
        .onKeyPress(.rightArrow) { onMove(entry.id, 1); return .handled }
        .focusedValue(\.fullScreenPreview, FullScreenPreviewAction { [model, id = entry.id] in
            FullScreenPreviewLauncher.previewScene(id, model: model)
        })
        .onHover { hovering = $0 }
        .task(id: hovering) {
            guard hovering else { showLive = false; return }
            try? await Task.sleep(nanoseconds: Self.hoverDelay)
            if !Task.isCancelled { withAnimation(.easeIn(duration: 0.25)) { showLive = true } }
        }
        .contextMenu { SceneMenuItems(entry: entry, includePreview: true) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.manifest.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Opens the scene. Space previews it full screen. More actions are in the context menu.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityAction(named: "Preview Full Screen", previewFullScreen)
    }

    private func open() { model.libraryPath.append(entry.id) }

    private func previewFullScreen() { FullScreenPreviewLauncher.previewScene(entry.id, model: model) }

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
            .overlay(alignment: .bottomTrailing) {
                // When every scene plays, a per-card marker would carry no information.
                if model.isInPlaylist(entry.id) && !PlaylistDraft(model.playlist).includesAllScenes {
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
                    .strokeBorder(highlighted ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: highlighted ? 2 : 1)
            }
            .shadow(color: .black.opacity(highlighted ? 0.25 : 0.12), radius: highlighted ? 12 : 5, y: highlighted ? 6 : 2)
            .scaleEffect(highlighted ? 1.015 : 1)
            .animation(.snappy(duration: 0.2), value: highlighted)
    }

    private var accessibilityValue: String {
        var parts = [entry.badge.label + " scene", entry.energy.label]
        if entry.item.isBuiltin { parts.append("Included with LivePaper") }
        if model.isInPlaylist(entry.id) { parts.append("In playlist") }
        return parts.joined(separator: ", ")
    }
}

/// The per-scene action menu, shared by the card context menu and the detail view's "More" menu.
struct SceneMenuItems: View {
    let entry: LibraryEntry
    var includePreview = false
    @Environment(AppModel.self) private var model

    var body: some View {
        if includePreview {
            Button("Preview") { model.showScene(entry.id) }
        }
        Button("Preview Full Screen") { FullScreenPreviewLauncher.previewScene(entry.id, model: model) }
        Divider()
        Button("Use as Screen Saver") { Task { await model.useAsScreenSaver(entry.id) } }
        Button("Add to Playlist") { Task { await model.addToPlaylist(entry.id) } }
            .disabled(model.isInPlaylist(entry.id) && model.playlist.mode != .single)
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
