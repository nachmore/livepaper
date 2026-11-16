// CollectionSheets — New Collection, Rename and Delete, presented through `AppModel.collectionAction`
// (the Library's New Collection button and row, File › New Collection…, "Add to Collection ▸ New
// Collection…", a drop on New Collection, a collection section's menu).
import LivePaperCore
import SwiftUI

struct CollectionActionSheet: View {
    let action: AppModel.CollectionAction
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch action {
        case .new(let ids):
            CollectionNameSheet(collection: nil, sceneIDs: ids)
        case .rename(let id):
            if let c = model.collection(id: id) { CollectionNameSheet(collection: c, sceneIDs: []) } else { gone }
        case .delete(let id):
            if let c = model.collection(id: id) { DeleteCollectionSheet(collection: c) } else { gone }
        }
    }

    /// Deleted elsewhere (the CLI) while the sheet was opening.
    private var gone: some View { Color.clear.frame(width: 1, height: 1).onAppear { dismiss() } }
}

/// A name for a new collection (with `sceneIDs` in it), or a new name for `collection`.
private struct CollectionNameSheet: View {
    let collection: SceneCollection?
    let sceneIDs: [String]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false

    private var validName: String? { CollectionText.validatedName(name) }
    private var taken: Bool { validName.map { CollectionText.isTaken($0, in: model.collections, except: collection?.id) } ?? false }

    var body: some View {
        SheetScaffold(symbol: collection == nil ? "rectangle.stack.badge.plus" : "pencil",
                      title: collection.map { "Rename \u{201C}\($0.name)\u{201D}" } ?? "New Collection",
                      subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                if taken {
                    Text("A collection with this name already exists.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(collection == nil ? "Create" : "Rename", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(validName == nil || taken || busy)
        }
        .onAppear {
            name = collection?.name ?? CollectionText.defaultNewName(existing: model.collections.map(\.name))
        }
    }

    private var subtitle: String {
        if collection != nil { return "Its scenes stay as they are." }
        if sceneIDs.isEmpty { return "Gather scenes to play together, preview and share. A scene can be in several collections." }
        return "With \(CollectionText.scenes(sceneIDs, names: model.sceneNames))."
    }

    private func save() {
        guard let valid = validName, !taken, !busy else { return }
        busy = true
        Task {
            let ok: Bool
            if let collection {
                ok = valid == collection.name ? true : await model.renameCollection(collection.id, to: valid)
            } else {
                ok = await model.createCollection(name: valid, sceneIDs: sceneIDs) != nil
            }
            busy = false
            if ok { dismiss() }
        }
    }
}

private struct DeleteCollectionSheet: View {
    let collection: SceneCollection
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(symbol: "trash", title: "Delete the collection \u{201C}\(collection.name)\u{201D}?",
                      subtitle: CollectionText.deleteSubtitle(collection, sceneCount: model.sceneCount(of: collection))) {
            if model.isFollowed(collection.id) {
                Label("The screen saver keeps playing these scenes; it no longer follows a collection.",
                      systemImage: "play.rectangle.on.rectangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Delete", role: .destructive) {
                let id = collection.id
                dismiss()
                Task { await model.deleteCollection(id) }
            }
            .keyboardShortcut(.defaultAction)
        }
        .tint(.red)
    }
}
