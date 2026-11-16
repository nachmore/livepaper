// CollectionMenus — "Add to Collection ▸" (with checkmarks), "Move to Collection ▸", and the bar
// that appears while cards are selected in a grid.
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

/// While cards are selected (⌘-click, ⇧-click): how many, what can be done with them, and Done.
struct SelectionBar: View {
    let grid: SceneGrid
    /// The grid's cards in order (the selection is acted on in this order).
    let order: [String]
    @Environment(AppModel.self) private var model

    var body: some View {
        let ids = model.selection.ordered(order)
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            Text(ids.count == 1 ? "1 scene selected" : "\(ids.count) scenes selected")
                .font(.callout.weight(.medium))
                .monospacedDigit()
            Spacer()
            Menu {
                AddToCollectionItems(sceneIDs: ids)
            } label: {
                Label("Add to Collection", systemImage: "rectangle.stack.badge.plus")
            }
            .fixedSize()
            if let id = grid.collectionID, let c = model.collection(id: id) {
                Menu {
                    ForEach(model.collections.filter { $0.id != id }) { other in
                        Button(other.name) { Task { await model.moveToCollection(ids, from: id, to: other.id) } }
                    }
                } label: {
                    Label("Move to", systemImage: "arrow.right.square")
                }
                .fixedSize()
                .disabled(model.collections.count < 2)
                Button(role: .destructive) {
                    Task { await model.removeFromCollection(ids, id) }
                } label: {
                    Label("Remove from \u{201C}\(c.name)\u{201D}", systemImage: "minus.circle")
                }
            }
            Button("Select All") { model.selection.selectAll(order) }
                .disabled(ids.count == order.count)
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
