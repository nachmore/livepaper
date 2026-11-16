// CollectionMenus — a collection's actions (its Library section's "…" menu and context menu), "Add to
// Collection ▸" (with checkmarks), "Move to Collection ▸", and the bar that appears while cards are
// selected in the Library.
import LivePaperCore
import SwiftUI

/// Every collection with a checkmark when it has all of `sceneIDs` (choosing it then takes them
/// out; otherwise it adds the ones it lacks), then "New Collection…" with them.
struct AddToCollectionMenu: View {
    let sceneIDs: [String]
    var title: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu(title ?? (sceneIDs.count > 1 ? "Add \(sceneIDs.count) Scenes to Collection" : "Add to Collection")) {
            AddToCollectionItems(sceneIDs: sceneIDs)
        }
    }
}

/// The items of "Add to Collection" (also used where the menu has its own label).
struct AddToCollectionItems: View {
    let sceneIDs: [String]
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(model.collections) { c in
            let state = CollectionMembership(sceneIDs, in: c)
            Toggle(isOn: Binding(get: { state == .all }, set: { _ in Task { await model.toggleCollection(sceneIDs, c.id) } })) {
                if state == .some {
                    let n = sceneIDs.filter(c.sceneIDs.contains).count
                    Text("\(c.name) (\(n) of \(sceneIDs.count))")
                } else {
                    Text(c.name)
                }
            }
        }
        if !model.collections.isEmpty { Divider() }
        Button(sceneIDs.count > 1 ? "New Collection with \(sceneIDs.count) Scenes\u{2026}" : "New Collection\u{2026}") {
            model.collectionAction = .new(sceneIDs: sceneIDs)
        }
    }
}

/// "Move to Collection ▸": into another collection and out of `from`.
struct MoveToCollectionMenu: View {
    let sceneIDs: [String]
    let from: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let others = model.collections.filter { $0.id != from }
        Menu(sceneIDs.count > 1 ? "Move \(sceneIDs.count) Scenes to Collection" : "Move to Collection") {
            ForEach(others) { c in
                Button(c.name) { Task { await model.moveToCollection(sceneIDs, from: from, to: c.id) } }
            }
        }
        .disabled(others.isEmpty)
    }
}

/// A collection's actions: its Library section's "…" menu and context menu.
struct CollectionMenuItems: View {
    let collection: SceneCollection
    @Environment(AppModel.self) private var model

    var body: some View {
        let id = collection.id
        let empty = model.sceneCount(of: collection) == 0
        if model.isFollowed(id) {
            Button("Playing in the Screen Saver") {}
                .disabled(true)
            Button("Screen Saver Settings\u{2026}") { model.section = .playlist }
        } else {
            Button("Play as Screen Saver") { Task { await model.useCollectionAsScreenSaver(id) } }
                .disabled(empty || model.isPublishing)
                .help(empty ? "Add scenes first" : "The screen saver plays this collection and follows its changes")
        }
        Button("Preview Full Screen") { FullScreenPreviewLauncher.previewCollection(id, model: model) }
            .disabled(!FullScreenPreviewLauncher.canPreviewCollection(id, model: model))
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

/// While cards are selected (⌘-click, ⇧-click): how many, what can be done with them, and Done. Chosen
/// in a collection's section, it also moves them to another collection or removes them from this one.
struct SelectionBar: View {
    let sections: [LibrarySection]
    @Environment(AppModel.self) private var model

    var body: some View {
        let order = LibrarySections.sceneOrder(sections)
        let ids = model.selection.ordered(order)
        let chosenIn = model.selection.section.flatMap(LibrarySectionID.init(key:))
        let scope = chosenIn.flatMap { id in sections.first { $0.id == id } }
        let source = chosenIn?.collectionID.flatMap { model.collection(id: $0) }
        let inSource = source.map { c in ids.filter(c.sceneIDs.contains) } ?? []
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            Text(ids.count == 1 ? "1 scene selected" : "\(ids.count) scenes selected")
                .font(.callout.weight(.medium))
                .monospacedDigit()
            if let source {
                Text("in \(CollectionText.quoted(source.name))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                AddToCollectionItems(sceneIDs: ids)
            } label: {
                Label("Add to Collection", systemImage: "rectangle.stack.badge.plus")
            }
            .fixedSize()
            .help("Add them to a collection (or drag them onto one); they stay where they are")
            if let source, !inSource.isEmpty {
                let others = model.collections.filter { $0.id != source.id }
                Menu {
                    ForEach(others) { other in
                        Button(other.name) { Task { await model.moveToCollection(inSource, from: source.id, to: other.id) } }
                    }
                } label: {
                    Label("Move to", systemImage: "arrow.right.square")
                }
                .fixedSize()
                .disabled(others.isEmpty)
                .help("Move them to another collection: out of \(CollectionText.quoted(source.name))")
                Button(role: .destructive) {
                    Task { await model.removeFromCollection(inSource, source.id) }
                } label: {
                    Label("Remove from \(CollectionText.quoted(source.name))", systemImage: "minus.circle")
                }
                .help("Take them out of the collection; the scenes stay in your library")
            }
            // In the section the cards were chosen in, else the whole Library.
            let all = scope?.sceneIDs ?? order
            Button("Select All") { model.selection.selectAll(all, section: scope?.id.key) }
                .disabled(all.allSatisfy(model.selection.contains))
            Button("Done") { model.selection.clear() }
                .keyboardShortcut(.cancelAction)
                .help("End the selection (Esc)")
        }
        .controlSize(.regular)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selection")
    }
}
