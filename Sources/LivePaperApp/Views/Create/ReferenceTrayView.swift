// ReferenceTrayView — the reference images of a Describe-it card or a Modify with AI sheet
// (ARCHITECTURE §11): thumbnails with a remove button and a role menu ("Reference" / "Animate this
// image"), Add Images…, notes about what was left out, the reasons images couldn't be added, and
// the "Attach" suggestions for paths typed into the prompt. The rules live in ReferenceTray.
import LivePaperCore
import SwiftUI

struct ReferenceTrayView: View {
    let tray: ReferenceTray
    /// The sheet's smaller tiles and hint.
    var compact = false
    /// A drag is over the card (highlights the empty hint).
    var dropTargeted = false

    @FocusState private var hintFocused: Bool

    private var side: CGFloat { compact ? 72 : 88 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if tray.isEmpty {
                emptyHint
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(Array(tray.items.enumerated()), id: \.element.id) { i, item in
                                ReferenceTile(item: item, index: i, count: tray.items.count, side: side, tray: tray)
                            }
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 2)
                    }
                    .scrollIndicators(.automatic)
                    // Newly added images come in at the end: keep them in view.
                    .onChange(of: tray.items.count) { old, new in
                        guard new > old, let last = tray.items.last else { return }
                        withAnimation(.snappy) { proxy.scrollTo(last.id, anchor: .trailing) }
                    }
                }
            }
            messages
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reference images")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo.on.rectangle.angled")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Reference images").font(.callout.weight(.medium))
            Text("optional").font(.callout).foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            if !tray.isEmpty {
                Text("\(tray.activeCount)/\(ReferenceLimits.maxImages)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(tray.activeCount) of \(ReferenceLimits.maxImages) images")
            }
            Button("Add Images\u{2026}") {
                let urls = SystemActions.chooseReferenceImages()
                if !urls.isEmpty { tray.addFiles(urls) }
            }
            .controlSize(.small)
            .help("Choose images or folders of images for the agent to work from (up to \(ReferenceLimits.maxImages))")
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 2) {
            if tray.isBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Looking for images\u{2026}").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("Drop images or folders here, paste with \u{2318}V, or use Add Images\u{2026}")
                    .font(.callout)
                    .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
            }
            if !compact {
                Text("The agent works from copies (metadata removed). Mark one \u{201C}Animate\u{201D} to bring that exact picture to life.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: compact ? 40 : 56, alignment: .leading)
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(dropTargeted || hintFocused ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [5, 4]))
        }
        // Focusable (click or Tab), so ⌘V pastes images here too; the card's paste handler takes them.
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .focusable()
        .focused($hintFocused)
        .focusEffectDisabled()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Drop images or folders here, or paste them with Command-V while this is focused.")
    }

    /// Why images couldn't be added (one line per failed tile, with Remove), then the notes.
    @ViewBuilder
    private var messages: some View {
        let failures = tray.failures
        if !failures.isEmpty || !tray.notes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(failures, id: \.id) { failure in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).accessibilityHidden(true)
                        Text(failure.message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button("Remove") { tray.remove(failure.id) }
                            .buttonStyle(.link)
                    }
                    .accessibilityElement(children: .combine)
                }
                ForEach(Array(tray.notes.enumerated()), id: \.offset) { i, note in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button { tray.dismissNote(at: i) } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Dismiss")
                            .accessibilityLabel("Dismiss note")
                    }
                }
            }
            .font(.caption)
        }
    }
}

// MARK: - Tile

private struct ReferenceTile: View {
    let item: ReferenceTray.Item
    let index: Int
    let count: Int
    let side: CGFloat
    let tray: ReferenceTray
    @FocusState private var focused: Bool

    private var isAnimate: Bool { item.role == .animate && !item.isFailed }
    private var isReady: Bool { if case .ready = item.state { return true } else { return false } }

    var body: some View {
        VStack(spacing: 4) {
            picture
            roleControl
        }
        .frame(minWidth: side)   // the role menu may be a little wider than a compact tile
    }

    private var picture: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return content
            .frame(width: side, height: side)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(isAnimate ? Color.accentColor : (item.isFailed ? Color.red.opacity(0.7) : Color.secondary.opacity(0.3)),
                                   lineWidth: isAnimate ? 2.5 : 1)
            }
            .overlay {
                if focused { shape.inset(by: -3).strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 3) }
            }
            .overlay(alignment: .topLeading) {
                if isAnimate {
                    Image(systemName: "film")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .padding(5)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) { removeButton }
            .contentShape(shape)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onDeleteCommand { tray.remove(item.id) }
            .contextMenu { menuItems(includeRemove: true) }
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ReferenceTrayText.tileLabel(item, index: index, count: count))
            .accessibilityAddTraits(.isImage)
            .accessibilityAction(named: "Remove") { tray.remove(item.id) }
            .accessibilityActions {
                // Like the role menu: only a prepared image can be the one to animate.
                if isReady {
                    Button(isAnimate ? "Use as Reference" : "Animate This Image") {
                        tray.setRole(isAnimate ? .reference : .animate, for: item.id)
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch item.state {
        case .ready(let reference):
            ThumbnailImage(reference: reference, maxPixel: 176)
        case .preparing:
            ZStack {
                Color.secondary.opacity(0.15)
                ProgressView().controlSize(.small)
            }
        case .failed:
            ZStack {
                Color.secondary.opacity(0.12)
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.title3)
                    Text(item.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    private var removeButton: some View {
        Button { tray.remove(item.id) } label: {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.55))
                .font(.system(size: 16))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(3)
        .help("Remove")
        .accessibilityLabel("Remove \(item.displayName)")
    }

    /// "Reference ⌄" / "Animate ⌄" under the picture; preparing and failed tiles say so instead.
    @ViewBuilder
    private var roleControl: some View {
        switch item.state {
        case .ready:
            Menu {
                menuItems(includeRemove: false)
            } label: {
                Text(isAnimate ? "Animate" : "Reference")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption.weight(isAnimate ? .semibold : .regular))
            .foregroundStyle(isAnimate ? Color.accentColor : .secondary)
            .help(isAnimate ? ReferenceTrayText.animateChoice : ReferenceTrayText.referenceChoice)
            .accessibilityLabel("Role of \(item.displayName)")
            .accessibilityValue(isAnimate ? "Animate" : "Reference")
        case .preparing:
            Text("Preparing\u{2026}").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Text("Not added").font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func menuItems(includeRemove: Bool) -> some View {
        if case .ready = item.state {
            Button {
                tray.setRole(.reference, for: item.id)
            } label: {
                if item.role == .reference { Label(ReferenceTrayText.referenceChoice, systemImage: "checkmark") } else { Text(ReferenceTrayText.referenceChoice) }
            }
            Button {
                tray.setRole(.animate, for: item.id)
            } label: {
                if item.role == .animate { Label(ReferenceTrayText.animateChoice, systemImage: "checkmark") } else { Text(ReferenceTrayText.animateChoice) }
            }
        }
        if includeRemove {
            if case .ready = item.state { Divider() }
            Button("Remove", role: .destructive) { tray.remove(item.id) }
        }
    }

    private var help: String {
        switch item.state {
        case .ready: return item.displayName + (isAnimate ? " \u{2014} the picture to animate" : "")
        case .preparing: return "Preparing \(item.displayName)\u{2026}"
        case .failed(let why): return why
        }
    }
}

// MARK: - Suggestions

/// "The agent can't open “refs” on your Desktop. Attach copies of its images?" for up to three
/// image files or folders typed into the prompt. Nothing is attached until a button is clicked.
struct ReferenceSuggestionBar: View {
    let tray: ReferenceTray

    var body: some View {
        if !tray.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(tray.suggestions.prefix(3)), id: \.url) { chip($0) }
            }
        }
    }

    private func chip(_ m: PromptPathMention) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: m.kind == .folder ? "folder" : "photo")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(ReferenceTrayText.suggestion(m))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if m.kind == .folder {
                Button("Attach Folder") { tray.attach(m) }
                    .help("Attach copies of the images in this folder (up to \(ReferenceLimits.maxImages) in all)")
            } else {
                Button("Attach") { tray.attach(m) }
                    .help("Attach a copy as a reference: inspiration for style, colours and composition")
                Button("Animate It") { tray.attach(m, animate: true) }
                    .help("Attach a copy and have the scene show this exact picture, brought to life")
            }
            Button { tray.dismiss(m) } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Don\u{2019}t suggest this again")
                .accessibilityLabel("Dismiss suggestion")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25)))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Drop and paste target

extension View {
    /// Makes the whole card (or sheet) take reference images: drops of image files, folders and
    /// image data (Finder, Photos, a browser), and ⌘V of images while something other than the
    /// prompt box has focus (the prompt box handles its own paste). Highlights while a drag is over it.
    func referenceDropTarget(_ tray: ReferenceTray, isTargeted: Binding<Bool>, cornerRadius: CGFloat) -> some View {
        modifier(ReferenceDropTarget(tray: tray, isTargeted: isTargeted, cornerRadius: cornerRadius))
    }
}

private struct ReferenceDropTarget: ViewModifier {
    let tray: ReferenceTray
    @Binding var isTargeted: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .background(Color.accentColor.opacity(0.04), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onDrop(of: ReferenceDropReader.acceptedTypes, isTargeted: $isTargeted) { providers in
                Task { @MainActor in
                    let read = await ReferenceDropReader.inputs(from: providers, dataName: ReferenceTray.droppedName)
                    tray.add(read.inputs)
                    tray.addNotes(read.notes)
                }
                return true
            }
            .onPasteCommand(of: ReferenceDropReader.pasteTypes) { providers in
                Task { @MainActor in
                    let read = await ReferenceDropReader.inputs(from: providers, dataName: ReferenceTray.pastedName)
                    tray.add(read.inputs)
                    tray.addNotes(read.notes)
                }
            }
    }
}
