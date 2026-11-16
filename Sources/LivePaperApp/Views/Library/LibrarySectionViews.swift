// LibrarySectionViews — the pieces of a Library section (LibrarySections): its header (disclosure
// chevron, title, count; for a collection the ▶ it plays in the screen saver, what a drop would do,
// and the "…" menu), the slim drop hint of an empty collection, and the "New Collection" row after
// the collections (click it, or drop scenes on it to make a collection with them).
import LivePaperCore
import SwiftUI

struct LibrarySectionHeader: View {
    let section: LibrarySection
    var focus: FocusState<LibraryFocus?>.Binding
    /// Scene cards are dragged over the section: what dropping them does ("Add to “Calm Water”").
    var dropLabel: String?
    /// Scene cards are dragged over the header itself.
    var targeted = false
    let setCollapsed: (Bool) -> Void
    @Environment(AppModel.self) private var model

    private var isFocused: Bool { focus.wrappedValue == .header(section.id) }
    private var plays: Bool { section.collection.map { model.isFollowed($0.id) } ?? false }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(section.isCollapsed ? 0 : 90))
                    .frame(width: 14)
                Text(section.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(section.countText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if plays, let c = section.collection {
                    Label("Plays in the screen saver", systemImage: "play.rectangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.tint.opacity(0.14), in: Capsule())
                        .help(CollectionText.followsNote(c.name))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(section.title)
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits([.isHeader, .isButton])
            .accessibilityHint(section.isCollapsed ? "Expands the section." : "Collapses the section.")
            .accessibilityAction(.default) { setCollapsed(!section.isCollapsed) }
            Spacer(minLength: 8)
            if let dropLabel {
                Label(dropLabel, systemImage: "plus.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.accentColor, in: Capsule())
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            if let c = section.collection {
                Menu {
                    CollectionMenuItems(collection: c)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Play, preview, export, rename or delete \u{201C}\(c.name)\u{201D}")
                .accessibilityLabel("Actions for \u{201C}\(c.name)\u{201D}")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(targeted ? Color.accentColor.opacity(0.14) : .clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 2)
        }
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onTapGesture { setCollapsed(!section.isCollapsed) }
        .focusable()
        .focused(focus, equals: .header(section.id))
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { setCollapsed(true); return .handled }
        .onKeyPress(.rightArrow) { setCollapsed(false); return .handled }
        .onKeyPress(.space, phases: .down) { _ in setCollapsed(!section.isCollapsed); return .handled }
        .onKeyPress(.return) { setCollapsed(!section.isCollapsed); return .handled }
        .focusedValue(\.fullScreenPreview, previewAction)
        .contextMenu {
            if let c = section.collection { CollectionMenuItems(collection: c) }
        }
        .animation(.snappy(duration: 0.2), value: dropLabel)
    }

    /// ⇧⌘F on a collection's focused header steps through the collection.
    private var previewAction: FullScreenPreviewAction? {
        guard let id = section.collection?.id, FullScreenPreviewLauncher.canPreviewCollection(id, model: model) else { return nil }
        return FullScreenPreviewAction { FullScreenPreviewLauncher.previewCollection(id, model: model) }
    }

    private var accessibilityValue: String {
        var parts = [section.isCollapsed ? "Collapsed" : "Expanded"]
        let n = section.entries.count
        parts.append(section.entries.count == section.total ? CollectionText.sceneCount(n)
                                                            : "\(n) of \(section.total) scenes match")
        if plays { parts.append("plays in the screen saver") }
        if section.collection != nil { parts.append("collection") }
        return parts.joined(separator: ", ")
    }
}

/// An empty collection's body: where to drop scenes.
struct CollectionDropHint: View {
    let targeted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack.badge.plus")
            Text("Drag scenes here")
                .fontWeight(.medium)
            Text("or choose Add to Collection in a scene\u{2019}s menu")
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .foregroundStyle(targeted ? Color.accentColor : .secondary)
        .frame(maxWidth: .infinity, minHeight: 50)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(targeted ? Color.accentColor.opacity(0.08) : .clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
        .accessibilityElement(children: .combine)
    }
}

/// After the collections: makes a new one (the sheet), or — scenes dropped on it — one with them.
struct NewCollectionRow: View {
    let targeted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: targeted ? "rectangle.stack.badge.plus" : "plus")
                    .frame(width: 14)
                Text("New Collection\u{2026}")
                    .fontWeight(.medium)
                Text(targeted ? "Drop to make a collection with them" : "Drop scenes here to make one with them")
                    .foregroundStyle(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
            .font(.callout)
            .foregroundStyle(targeted ? Color.accentColor : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(targeted ? Color.accentColor.opacity(0.1) : .clear)
            }
            // Outlined only while scenes are dragged over it: at rest it is a quiet line, like a header.
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .help("A new collection (\u{2325}\u{2318}N). Drop scenes here to make one with them.")
    }
}
