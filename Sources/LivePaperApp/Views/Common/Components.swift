// Small reusable views: badges, status rows, cards, banners, flow layout.
import LivePaperCore
import SwiftUI

// MARK: - Environment

private struct LivePreviewsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Off in the snapshot harness so no WebKit/AVFoundation content is created there.
    var livePreviewsEnabled: Bool {
        get { self[LivePreviewsEnabledKey.self] }
        set { self[LivePreviewsEnabledKey.self] = newValue }
    }
}

// MARK: - Badges

/// A compact capsule badge drawn over thumbnails (always on a dark scrim so it reads on any art).
struct OverlayBadge: View {
    let title: String
    let symbol: String
    var tint: Color = .white

    var body: some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.45), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
    }
}

extension SceneBadge {
    var tint: Color {
        switch self {
        case .web: return .white
        case .ai: return Color(red: 0.86, green: 0.78, blue: 1.0)
        case .video: return Color(red: 0.75, green: 0.9, blue: 1.0)
        }
    }
}

extension EnergyClass {
    /// For window backgrounds (light and dark).
    var tint: Color {
        switch self {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .orange
        case .unmeasured: return .secondary
        }
    }

    /// For the dark scrim of thumbnail badges, where system colours would read too dark.
    var overlayTint: Color {
        switch self {
        case .low: return Color(red: 0.6, green: 0.95, blue: 0.65)
        case .medium: return Color(red: 1.0, green: 0.88, blue: 0.45)
        case .high: return Color(red: 1.0, green: 0.68, blue: 0.45)
        case .unmeasured: return .white.opacity(0.8)
        }
    }
}

/// Energy class as an inline badge (for light backgrounds).
struct EnergyBadge: View {
    let energy: EnergyClass
    var body: some View {
        Label(energy.label, systemImage: energy.symbolName)
            .font(.callout)
            .foregroundStyle(energy.tint)
            .help(energy.explanation)
            .accessibilityLabel(energy.label)
            .accessibilityHint(energy.explanation)
    }
}

// MARK: - Status rows

struct SetupCheckRow: View {
    let check: SetupCheck

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.body.weight(.semibold))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.body.weight(.medium))
                Text(check.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(stateDescription)
    }

    private var symbol: String {
        switch check.state {
        case .done: return "checkmark.circle.fill"
        case .needed: return "circle"
        case .optional: return "circle.dashed"
        case .managed: return "building.columns"
        }
    }

    private var tint: Color {
        switch check.state {
        case .done: return .green
        case .needed: return .secondary
        case .optional: return .secondary
        case .managed: return .orange
        }
    }

    private var stateDescription: String {
        switch check.state {
        case .done: return "Done"
        case .needed: return "Needs action"
        case .optional: return "Optional"
        case .managed: return "Managed by your organisation"
        }
    }
}

/// "● Active" style status.
struct StatusDot: View {
    let title: String
    let ok: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(title)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Cards

/// The rounded container used for the large cards (Create, session side panel).
struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

extension View {
    func card(cornerRadius: CGFloat = 16) -> some View { modifier(CardBackground(cornerRadius: cornerRadius)) }

    /// Liquid Glass on macOS 26, a material elsewhere — for small floating controls.
    @ViewBuilder
    func floatingGlass(cornerRadius: CGFloat = 12) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

/// A titled section inside detail screens.
struct SectionBox<Content: View>: View {
    let title: String
    var symbol: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title)
            } icon: {
                if let symbol { Image(systemName: symbol) }
            }
            .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 12)
    }
}

/// Label/value rows for metadata grids.
struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).gridColumnAlignment(.leading)
        }
    }
}

// MARK: - Banners

/// The stack of non-modal banners shown at the top of the main window's content area.
struct BannerStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.banners.banners) { banner in
                BannerView(banner: banner) { model.banners.dismiss(banner.id) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .frame(maxWidth: 560)
        .animation(.snappy, value: model.banners.banners.map(\.id))
    }
}

struct BannerView: View {
    let banner: BannerCenter.Banner
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.body.weight(.semibold))
                if let message = banner.message {
                    Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !banner.actions.isEmpty {
                    HStack {
                        ForEach(banner.actions) { action in
                            Button(action.title) {
                                action.perform()
                                dismiss()
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .floatingGlass(cornerRadius: 14)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }

    private var symbol: String {
        switch banner.style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch banner.style {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - Layout

/// Side by side when there is room (children share the width by `weights` and get equal heights),
/// stacked vertically otherwise. Unlike ViewThatFits it decides on the *available* width, so long
/// single-line text ideal widths can't force the stacked layout.
struct AdaptiveStack: Layout {
    var threshold: CGFloat
    var weights: [CGFloat] = []
    var spacing: CGFloat = 20

    private func widths(total: CGFloat, count: Int) -> [CGFloat] {
        let w = (0..<count).map { $0 < weights.count ? max(weights[$0], 0.01) : 1 }
        let sum = w.reduce(0, +)
        let usable = max(0, total - spacing * CGFloat(count - 1))
        return w.map { usable * $0 / sum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? threshold
        if width >= threshold {
            let ws = widths(total: width, count: subviews.count)
            let h = zip(subviews, ws).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
            return CGSize(width: width, height: h)
        }
        let hs = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: hs.reduce(0, +) + spacing * CGFloat(subviews.count - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        if bounds.width >= threshold {
            var x = bounds.minX
            for (view, w) in zip(subviews, widths(total: bounds.width, count: subviews.count)) {
                view.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w, height: bounds.height))
                x += w + spacing
            }
        } else {
            var y = bounds.minY
            for view in subviews {
                let h = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                view.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
                y += h + spacing
            }
        }
    }
}

/// Wrapping horizontal layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // With no width proposed (ideal size), wrap at the widest chip rather than laying every chip
        // out on one endless row, which would make any container think the chips need a huge width.
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let rows = arrange(width: proposal.width ?? widest, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !current.indices.isEmpty && current.width + spacing + size.width > width {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(i)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
