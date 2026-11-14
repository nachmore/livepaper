// PlaylistView — what the screen saver plays: which scenes, in what order, how often it changes,
// the clock and the performance profile. Edits are a draft until "Save & Publish".
import LivePaperCore
import SwiftUI

struct PlaylistView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = PlaylistDraft(PlaylistSettings())
    @State private var loaded = false

    private var hasChanges: Bool { loaded && draft.settings != model.playlist }

    var body: some View {
        Form {
            scenesSection
            playbackSection
            performanceSection
        }
        .formStyle(.grouped)
        .navigationTitle("Screen Saver")
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

    // MARK: scenes

    private var scenesSection: some View {
        Section {
            Toggle(isOn: Binding(get: { draft.includesAllScenes },
                                 set: { draft.setIncludesAllScenes($0, available: available) })) {
                Text("Play all scenes")
                Text("New scenes join automatically.")
            }
            if draft.includesAllScenes {
                ForEach(model.entries) { entry in
                    PlaylistSceneRow(entry: entry)
                }
            } else {
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
            if !draft.includesAllScenes && draft.settings.sceneIDs.count > 1 {
                Text("Drag to change the order, or use the context menu.")
                    .font(.callout).foregroundStyle(.secondary)
            }
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
            .disabled(!hasChanges || model.isPublishing || draft.effectiveSceneIDs(available: available).isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var statusText: String {
        if hasChanges { return "Unsaved changes \u{2014} " + PlaylistDraft.summary(draft.settings, available: available, names: model.sceneNames) }
        if let published = model.lastPublished {
            return "Published \u{00B7} " + (published.scenes.count == 1 ? "1 scene" : "\(published.scenes.count) scenes")
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
