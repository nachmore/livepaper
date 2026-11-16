// DisplaysSection — the Screen Saver screen's "Multiple displays" section: the display mode, the
// connected displays (in the saver's order, as arranged in System Settings › Displays, the main one
// tagged), a scene per display for "Choose per display" (and the choices kept for displays that
// aren't connected), which scenes can span, and what the other displays show on battery. Edits go
// into the playlist draft like the rest of the screen. Always shown, also with one display.
import AppKit
import LivePaperCore
import SwiftUI

struct DisplaysSection: View {
    @Binding var draft: PlaylistDraft
    @Environment(AppModel.self) private var model

    private var layout: LPDisplayLayout { model.displays }
    private var mode: LPDisplayMode { draft.settings.displays.mode }

    var body: some View {
        Section {
            Picker("Displays", selection: $draft.settings.displays.mode) {
                ForEach(LPDisplayMode.allCases, id: \.self) { Text($0.uiTitle).tag($0) }
            }
            Text(mode.uiExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
            if layout.count >= 2 {
                DisplayArrangement(layout: layout, spanning: mode == .span)
                    .frame(height: 92)
                    .accessibilityHidden(true)   // the rows below say the same
            }
            ForEach(Array(layout.displays.enumerated()), id: \.element.id) { index, display in
                displayRow(display, number: index + 1)
            }
            if layout.count < 2 {
                Label(singleDisplayNote, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if mode == .choose { rememberedRows }
            if mode == .span { spanRow }
            Picker("On battery, other displays show", selection: $draft.settings.displays.onBattery) {
                ForEach(LPBatteryDisplays.allCases, id: \.self) { Text($0.uiTitle).tag($0) }
            }
            Text("On battery or in Low Power Mode. The main display \u{2014} the built-in display, or the one with the menu bar \u{2014} always shows the scene.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            Text("Multiple displays")
        }
    }

    private var singleDisplayNote: String {
        mode == .choose
            ? "Only one display is connected. Displays you connect later play the playlist until you choose a scene for them."
            : "Only one display is connected. These settings take effect when you connect another."
    }

    // MARK: displays

    @ViewBuilder
    private func displayRow(_ display: LPDisplay, number: Int) -> some View {
        let label = DisplayLabel(display: display, number: number, isMain: display.id == layout.main?.id)
        if mode == .choose {
            Picker(selection: assignment(display)) {
                Text("Playlist").tag(String?.none)
                Divider()
                ForEach(model.entries) { entry in
                    Text(entry.manifest.name).tag(Optional(entry.id))
                }
                if let id = draft.assignment(for: display.id), model.entry(id: id) == nil {
                    Text("Scene deleted \u{2014} plays the playlist").tag(Optional(id))
                }
            } label: {
                label
            }
            .contextMenu { copyID(display) }
        } else {
            label.contextMenu { copyID(display) }
        }
    }

    private func assignment(_ display: LPDisplay) -> Binding<String?> {
        Binding(get: { draft.assignment(for: display.id) },
                set: { draft.assign($0, to: display) })
    }

    private func copyID(_ display: LPDisplay) -> some View {
        Button("Copy Display ID") { SystemActions.copyToPasteboard(display.id) }
    }

    /// Choices kept for displays that aren't connected: they apply again when the display is back.
    private var rememberedRows: some View {
        ForEach(draft.rememberedDisplays(connected: layout.displays)) { remembered in
            LabeledContent {
                HStack(spacing: 10) {
                    Text(model.entry(id: remembered.sceneID)?.manifest.name ?? "Scene deleted")
                        .foregroundStyle(.secondary)
                    Button("Forget") { draft.forgetDisplay(remembered.id) }
                        .controlSize(.small)
                        .help("Forget the scene chosen for \(remembered.name)")
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "display")
                        .foregroundStyle(.tertiary)
                        .frame(width: DisplayLabel.badgeWidth)
                    HStack(spacing: 4) {
                        Text(remembered.name)
                        Text("(not connected)").foregroundStyle(.secondary)
                    }
                }
            }
            .contextMenu {
                Button("Copy Display ID") { SystemActions.copyToPasteboard(remembered.id) }
            }
        }
    }

    // MARK: span

    @ViewBuilder
    private var spanRow: some View {
        let ids = draft.effectiveSceneIDs(available: model.availableSceneIDs)
        let manifests = Dictionary(model.entries.map { ($0.id, $0.manifest) }, uniquingKeysWith: { a, _ in a })
        let support = PlaylistDraft.spanSupport(ids: ids, manifests: manifests)
        let total = support.spanning.count + support.notSpanning.count
        if total > 0 {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(PlaylistDraft.spanSupportSummary(spanning: support.spanning.count, total: total))
                    if !support.spanning.isEmpty && !support.notSpanning.isEmpty {
                        Text("On every display: " + names(support.notSpanning))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "rectangle.split.3x1")
                    .foregroundStyle(.secondary)
            }
            .help("Videos span unless their scene.json says \u{201C}span\u{201D}: false. Web scenes span when they declare \u{201C}span\u{201D}: true, which livepaper check verifies.")
        }
    }

    /// "Neon Rain, Ink Bloom" — at most four names, then "and 3 more".
    private func names(_ ids: [String]) -> String {
        let shown = ids.prefix(4).map { model.sceneNames[$0] ?? $0 }
        let rest = ids.count - shown.count
        return shown.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "")
    }
}

/// One connected display: its number in the saver's order (as in the arrangement above), name,
/// "Main" tag and size.
private struct DisplayLabel: View {
    static let badgeWidth: CGFloat = 26
    let display: LPDisplay
    let number: Int
    let isMain: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isMain ? Color.white : Color.secondary)
                .frame(width: Self.badgeWidth, height: 18)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isMain ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(display.name.isEmpty ? "Display \(number)" : display.name)
                    if isMain {
                        Text("Main")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .help("The main display: the built-in display, or the one with the menu bar. On battery it always shows the scene, and a scene spanning the displays shows its clock here.")
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Display \(number), \(display.name)" + (isMain ? ", main" : ""))
    }

    private var detail: String {
        var parts = ["\(Int(display.frame.width.rounded())) \u{00D7} \(Int(display.frame.height.rounded()))"]
        if display.isBuiltin { parts.append("built-in") }
        if display.isMenuBar { parts.append("menu bar") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// The arrangement as in System Settings › Displays, scaled to fit and numbered like the rows. While
/// spanning, one gradient runs across all displays, as the scene does.
private struct DisplayArrangement: View {
    let layout: LPDisplayLayout
    let spanning: Bool

    var body: some View {
        Canvas { context, size in
            let canvas = layout.canvas
            guard !canvas.isEmpty, size.width > 8, size.height > 8 else { return }
            let canvasX = CGFloat(canvas.x), canvasY = CGFloat(canvas.y)
            let scale: CGFloat = min((size.width - 8) / CGFloat(canvas.width), (size.height - 8) / CGFloat(canvas.height))
            let width = CGFloat(canvas.width) * scale, height = CGFloat(canvas.height) * scale
            let origin = CGPoint(x: (size.width - width) / 2, y: (size.height - height) / 2)
            func rect(_ d: LPDisplay) -> CGRect {
                let x: CGFloat = origin.x + (CGFloat(d.frame.x) - canvasX) * scale
                let y: CGFloat = origin.y + (CGFloat(d.frame.y) - canvasY) * scale
                return CGRect(x: x, y: y, width: CGFloat(d.frame.width) * scale, height: CGFloat(d.frame.height) * scale)
                    .insetBy(dx: 1.5, dy: 1.5)
            }
            let accent = Color.accentColor
            if spanning {
                var all = Path()
                for d in layout.displays { all.addPath(Path(roundedRect: rect(d), cornerRadius: 4, style: .continuous)) }
                context.fill(all, with: .linearGradient(Gradient(colors: [Color(red: 0.15, green: 0.55, blue: 0.75),
                                                                         Color(red: 0.42, green: 0.35, blue: 0.85),
                                                                         Color(red: 0.78, green: 0.38, blue: 0.62)]),
                                                        startPoint: origin, endPoint: CGPoint(x: origin.x + width, y: origin.y + height)))
            }
            for (index, display) in layout.displays.enumerated() {
                let r = rect(display)
                let shape = Path(roundedRect: r, cornerRadius: 4, style: .continuous)
                let isMain = display.id == layout.main?.id
                if !spanning { context.fill(shape, with: .color(isMain ? accent.opacity(0.18) : Color.secondary.opacity(0.12))) }
                context.stroke(shape, with: .color(isMain ? accent : Color.secondary.opacity(0.55)), lineWidth: isMain ? 1.5 : 1)
                if display.isMenuBar {
                    let bar = CGRect(x: r.minX + 3, y: r.minY + 3, width: max(0, r.width - 6), height: 3)
                    context.fill(Path(roundedRect: bar, cornerRadius: 1.5),
                                 with: .color(spanning ? Color.white.opacity(0.7) : Color.secondary.opacity(0.45)))
                }
                let number = Text("\(index + 1)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(spanning ? Color.white : (isMain ? accent : Color.secondary))
                context.draw(context.resolve(number), at: CGPoint(x: r.midX, y: r.midY))
            }
        }
    }
}
