// PlaylistView — what the screen saver plays: which scenes (every scene, the ones chosen here, or a
// collection, followed as it changes), in what order, how often it changes, the clock, multiple
// displays (DisplaysSection) and the performance profile. Edits are a draft until "Save & Publish".
import LivePaperCore
import SwiftUI

struct PlaylistView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = PlaylistDraft(PlaylistSettings())
    @State private var loaded = false

    private var hasChanges: Bool { loaded && draft.settings != model.playlist }

    var body: some View {
        Form {
            skippedSection
            scenesSection
            playbackSection
            DisplaysSection(draft: $draft)
            performanceSection
        }
        .formStyle(.grouped)
        .navigationTitle("Screen Saver")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: previewPlaylist) {
                    Label("Preview Playlist", systemImage: FullScreenPreviewSymbol.name)
                        .labelStyle(.titleAndIcon)
                }
                .help("Show these scenes full screen in order, as the screen saver will (\u{21E7}\u{2318}F); \u{2190} \u{2192} change the scene")
                .disabled(!canPreview)
            }
        }
        .focusedSceneValue(\.fullScreenPreview, canPreview ? FullScreenPreviewAction(run: previewPlaylist) : nil)
        .safeAreaInset(edge: .bottom, spacing: 0) { publishBar }
        .onAppear(perform: syncFromModel)
        .onChange(of: model.playlist) { old, new in
            // Changes made elsewhere (menu bar, scene actions) replace an untouched draft.
            if draft.settings == old { draft = PlaylistDraft(new) }
        }
    }

    private func syncFromModel() {
        draft = PlaylistDraft(model.playlist)
        loaded = true
    }

    private var available: [String] { model.availableSceneIDs }

    /// The draft as it plays (unsaved changes included, a followed collection as it is now).
    private var playing: PlaylistDraft { PlaylistDraft(draft.settings.following(model.collections)) }
    private var followed: SceneCollection? { draft.settings.collectionID.flatMap { model.collection(id: $0) } }

    /// The draft as it stands (unsaved changes included): its scenes, order, clock and profile.
    private var canPreview: Bool { !playing.effectiveSceneIDs(available: available).isEmpty }

    private func previewPlaylist() { FullScreenPreviewLauncher.previewPlaylist(playing.settings, model: model) }

    // MARK: skipped scenes

    /// Scenes the last publish had to leave out (PublishResult.skipped): the saver plays the rest.
    @ViewBuilder
    private var skippedSection: some View {
        if let result = model.lastPublishResult, !result.skipped.isEmpty {
            Section {
                ForEach(result.skippedScenes) { skipped in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.sceneNames[skipped.id] ?? skipped.id)
                            Text(skipped.reason)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if model.entry(id: skipped.id) != nil {
                            Button("Show") { model.showScene(skipped.id) }
                                .controlSize(.small)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Left out of the screen saver")
            } footer: {
                Text("The screen saver plays the other scenes. Fix these scenes, then publish again.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: scenes

    private var scenesSection: some View {
        Section {
            Picker("Play", selection: Binding(get: { draft.source },
                                              set: { draft.setSource($0, available: available, collections: model.collections) })) {
                Text("All scenes").tag(PlaylistSource.all)
                Text("Scenes you choose").tag(PlaylistSource.chosen)
                if !model.collections.isEmpty {
                    Section("Collections") {
                        ForEach(model.collections) { c in
                            Text(c.name).tag(PlaylistSource.collection(c.id))
                        }
                    }
                }
                if case .collection(let id) = draft.source, model.collection(id: id) == nil {
                    Text("A deleted collection").tag(draft.source)
                }
            }
            switch draft.source {
            case .all:
                Text("New scenes join automatically.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(model.entries) { entry in
                    PlaylistSceneRow(entry: entry)
                }
            case .collection:
                collectionRows
            case .chosen:
                ForEach(draft.settings.sceneIDs, id: \.self) { id in
                    if let entry = model.entry(id: id) {
                        PlaylistSceneRow(entry: entry) {
                            Button {
                                draft.setIncluded(id, false, available: available)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(entry.manifest.name)")
                        }
                        .contextMenu { moveMenu(for: id) }
                    }
                }
                .onMove { draft.move(fromOffsets: $0, toOffset: $1) }
                let missing = model.entries.filter { !draft.settings.sceneIDs.contains($0.id) }
                if !missing.isEmpty {
                    Menu {
                        ForEach(missing) { entry in
                            Button(entry.manifest.name) { draft.setIncluded(entry.id, true, available: available) }
                        }
                    } label: {
                        Label("Add Scene", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        } header: {
            Text("Scenes")
        } footer: {
            if draft.source == .chosen && draft.settings.sceneIDs.count > 1 {
                Text("Drag to change the order, or use the context menu.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// The followed collection's scenes, in its order (edited in its Library section).
    @ViewBuilder
    private var collectionRows: some View {
        if let c = followed {
            HStack(alignment: .firstTextBaseline) {
                Label(CollectionText.followsNote(c.name), systemImage: "link")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Edit in Library") { model.revealCollection(c.id) }
                    .help("Its section in the Library: add, reorder, move or remove its scenes")
            }
            let entries = model.collectionEntries(c.id)
            if entries.isEmpty {
                Text("\u{201C}\(c.name)\u{201D} is empty, so the screen saver plays every scene.")
                    .font(.callout).foregroundStyle(.orange)
            }
            ForEach(entries) { entry in
                PlaylistSceneRow(entry: entry)
            }
        } else {
            Text("The collection was deleted. The screen saver plays the scenes it had: choose what to play instead.")
                .font(.callout).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func moveMenu(for id: String) -> some View {
        let ids = draft.settings.sceneIDs
        if let i = ids.firstIndex(of: id) {
            Button("Move Up") { draft.move(fromOffsets: [i], toOffset: i - 1) }.disabled(i == 0)
            Button("Move Down") { draft.move(fromOffsets: [i], toOffset: i + 2) }.disabled(i == ids.count - 1)
            Divider()
            Button("Remove from Playlist", role: .destructive) { draft.setIncluded(id, false, available: available) }
        }
    }

    // MARK: playback

    private var playbackSection: some View {
        Section("Playback") {
            Picker("Order", selection: $draft.settings.mode) {
                ForEach(LPPlaylistMode.allCases, id: \.self) { Text($0.uiTitle).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Change scene", selection: $draft.settings.cycleMinutes) {
                ForEach(PlaylistDraft.cycleChoices, id: \.self) { Text(LPFormat.cycle(minutes: $0)).tag($0) }
            }
            .disabled(draft.settings.mode == .single)
            Toggle(isOn: $draft.settings.showClock) {
                Text("Show the clock")
                Text("Fades out when the lock screen shows its own clock.")
            }
        }
    }

    private var performanceSection: some View {
        Section("Performance") {
            Picker("Profile", selection: $draft.settings.performance) {
                ForEach(LPPerformanceProfile.allCases, id: \.self) { Text($0.uiTitle).tag($0) }
            }
            Text(draft.settings.performance.uiExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: publish

    private var publishBar: some View {
        HStack(spacing: 12) {
            Image(systemName: hasChanges ? "pencil.circle" : "checkmark.circle")
                .foregroundStyle(hasChanges ? Color.orange : Color.green)
            Text(statusText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if model.isPublishing { ProgressView().controlSize(.small) }
            Button("Revert") { syncFromModel() }
                .disabled(!hasChanges || model.isPublishing)
            Button("Save & Publish") {
                let settings = draft.settings
                Task { await model.savePlaylist(settings) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s")
            .disabled(!hasChanges || model.isPublishing || playing.effectiveSceneIDs(available: available).isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var statusText: String {
        if hasChanges { return "Unsaved changes \u{2014} " + PlaylistDraft.summary(playing.settings, available: available, names: model.sceneNames,
                                                                                   displays: model.displays, collection: followed) }
        if let result = model.lastPublishResult {
            let n = result.playlist.scenes.count + result.playlist.displayScenes.count
            let left = result.skipped.count
            return "Published \u{00B7} " + (n == 1 ? "1 scene" : "\(n) scenes") + (left > 0 ? " \u{00B7} \(left) left out" : "")
        }
        return model.playlistSummary
    }
}

/// A scene row: thumbnail, name, kind and energy; `trailing` adds controls.
private struct PlaylistSceneRow<Trailing: View>: View {
    let entry: LibraryEntry
    @ViewBuilder var trailing: Trailing
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailImage(url: entry.thumbnail, revision: model.thumbnailRevision[entry.id] ?? 0, maxPixel: 160,
                           placeholderSymbol: entry.badge.symbolName)
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.manifest.name)
                HStack(spacing: 8) {
                    Label(entry.badge.label, systemImage: entry.badge.symbolName)
                    if entry.energy != .unmeasured {
                        Label(entry.energy.shortLabel, systemImage: entry.energy.symbolName).foregroundStyle(entry.energy.tint)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .accessibilityElement(children: .contain)
    }
}

extension PlaylistSceneRow where Trailing == EmptyView {
    init(entry: LibraryEntry) {
        self.entry = entry
        self.trailing = EmptyView()
    }
}
