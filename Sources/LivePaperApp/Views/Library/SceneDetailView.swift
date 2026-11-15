// SceneDetailView — a large live preview with aspect toggles, actions, metadata, the performance
// report and AI provenance for one scene.
import LivePaperCore
import SwiftUI

/// Display shapes the preview can be shown at: a typical laptop and a super-ultrawide monitor.
enum PreviewAspect: String, CaseIterable, Identifiable {
    case laptop, ultrawide
    var id: String { rawValue }
    var label: String { self == .laptop ? "16:10" : "32:9" }
    var ratio: CGFloat { self == .laptop ? 16.0 / 10.0 : 32.0 / 9.0 }
    var help: String { self == .laptop ? "Preview on a laptop-shaped display" : "Preview on a super-ultrawide display" }
}

struct SceneDetailView: View {
    let sceneID: String
    @Environment(AppModel.self) private var model

    var body: some View {
        if let entry = model.entry(id: sceneID) {
            SceneDetailContent(entry: entry)
        } else {
            ContentUnavailableView("Scene not found", systemImage: "questionmark.square.dashed",
                                   description: Text("It may have been deleted."))
        }
    }
}

private struct SceneDetailContent: View {
    let entry: LibraryEntry
    @Environment(AppModel.self) private var model
    @State private var aspect: PreviewAspect = .laptop
    @State private var details: AppModel.SceneDetails?
    @State private var previewError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                preview
                header
                actions
                AdaptiveStack(threshold: 680, spacing: 16) {
                    aboutBox.frame(maxHeight: .infinity, alignment: .top)
                    performanceBox.frame(maxHeight: .infinity, alignment: .top)
                }
                historyBox
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(entry.manifest.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    SceneMenuItems(entry: entry)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More actions")
            }
        }
        .task(id: DetailsKey(entry: entry, revision: model.detailsRevision)) {
            details = await model.details(for: entry.item)
        }
    }

    // MARK: preview

    private var preview: some View {
        VStack(spacing: 10) {
            // The black box takes the display's shape exactly, so the preview never letterboxes.
            Color.black
                .aspectRatio(aspect.ratio, contentMode: .fit)
                .overlay {
                    ScenePreview(item: entry.item, quality: .full, showClock: true, cornerRadius: 14) { message in previewError = message }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                .frame(maxWidth: .infinity, maxHeight: 460)
                .animation(.snappy, value: aspect)
            HStack {
                Picker("Display shape", selection: $aspect) {
                    ForEach(PreviewAspect.allCases) { a in
                        Text(a.label).tag(a).help(a.help)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                .accessibilityLabel("Display shape")
                if let previewError {
                    Label(previewError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help(previewError)
                }
                Spacer()
                if model.isInPlaylist(entry.id) {
                    Label("In the screen saver playlist", systemImage: "play.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: header + actions

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.manifest.name).font(.largeTitle.weight(.semibold))
                    .textSelection(.enabled)
                InlineBadge(title: entry.badge.label, symbol: entry.badge.symbolName)
                if entry.item.isBuiltin {
                    InlineBadge(title: "Built-in", symbol: "lock")
                        .help("Included with LivePaper. Clone it to make changes.")
                }
            }
            if !entry.manifest.description.isEmpty {
                Text(entry.manifest.description)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.useAsScreenSaver(entry.id) }
            } label: {
                Label("Use as Screen Saver", systemImage: "play.rectangle.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(model.isPublishing)
            Button {
                Task { await model.addToPlaylist(entry.id) }
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
            .disabled(model.isPublishing || (model.isInPlaylist(entry.id) && model.playlist.mode != .single))
            Button {
                model.sceneAction = .modify(entry.id)
            } label: {
                Label("Modify with AI\u{2026}", systemImage: "wand.and.stars")
            }
            .disabled(entry.manifest.kind == .video)
            .help(entry.manifest.kind == .video ? "Video scenes can't be modified with AI." : "Describe a change and let an agent make it")
            Button {
                model.sceneAction = .clone(entry.id)
            } label: {
                Label("Clone\u{2026}", systemImage: "plus.square.on.square")
            }
            if model.isPublishing { ProgressView().controlSize(.small) }
        }
        .controlSize(.large)
    }

    // MARK: sections

    private var aboutBox: some View {
        let m = entry.manifest
        return SectionBox(title: "About", symbol: "info.circle") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                InfoRow(label: "Kind", value: m.kind == .video ? "Video" : "Animated (web)")
                if let file = m.video?.file { InfoRow(label: "Video", value: "\(file) \u{00B7} \(m.video?.fit == .fit ? "fit" : "fill")") }
                InfoRow(label: "Clock", value: m.clock.position.uiTitle)
                if let author = m.author, !author.isEmpty { InfoRow(label: "Author", value: author) }
                if let created = m.created { InfoRow(label: "Created", value: created.formatted(date: .abbreviated, time: .shortened)) }
                if let updated = m.updated { InfoRow(label: "Updated", value: updated.formatted(.relative(presentation: .named))) }
                if let parent = m.parent {
                    InfoRow(label: "Cloned from", value: model.entry(id: parent)?.manifest.name ?? parent)
                }
                if !m.tags.isEmpty { InfoRow(label: "Tags", value: m.tags.joined(separator: ", ")) }
                InfoRow(label: "Location", value: LPFormat.abbreviatingHome(entry.item.packageURL.path))
            }
            .font(.callout)
        }
    }

    private var performanceBox: some View {
        SectionBox(title: "Performance", symbol: "gauge.with.dots.needle.33percent") {
            VStack(alignment: .leading, spacing: 10) {
                EnergyBadge(energy: entry.energy)
                Text(entry.energy.explanation).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let report = details?.report {
                    CheckReportSummary(report: report)
                } else if let p = entry.manifest.performance, p.benchMs != nil || p.energyMw != nil {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        if let ms = p.benchMs { InfoRow(label: "Frame time", value: LPFormat.milliseconds(ms)) }
                        if let mw = p.energyMw { InfoRow(label: "Energy", value: LPFormat.power(milliwatts: mw)) }
                        if let at = p.checkedAt { InfoRow(label: "Checked", value: at.formatted(.relative(presentation: .named))) }
                    }
                    .font(.callout)
                }
                if !entry.item.isBuiltin {
                    HStack(spacing: 8) {
                        Button(model.checkingSceneIDs.contains(entry.id) ? "Checking\u{2026}" : "Run Check") {
                            Task { await model.runCheck(entry.id) }
                        }
                        .disabled(model.checkingSceneIDs.contains(entry.id))
                        if model.checkingSceneIDs.contains(entry.id) { ProgressView().controlSize(.small) }
                    }
                    .help("Renders the scene at several sizes and measures its frame time and energy")
                }
            }
        }
    }

    @ViewBuilder
    private var historyBox: some View {
        let history = details?.provenance ?? []
        if !history.isEmpty {
            SectionBox(title: "History", symbol: "clock.arrow.circlepath") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(history.reversed()) { ProvenanceRow(entry: $0) }
                }
            }
        }
    }

    private struct DetailsKey: Equatable {
        let entry: LibraryEntry
        let revision: Int
    }
}

/// A badge for light/dark window backgrounds.
struct InlineBadge: View {
    let title: String
    let symbol: String
    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}

/// Passed/problems, bench rows and energy from a check report (detail view and AI session).
struct CheckReportSummary: View {
    let report: CheckReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(report.passed ? "Check passed" : "Check found problems",
                  systemImage: report.passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                .foregroundStyle(report.passed ? .green : .red)
                .font(.callout.weight(.semibold))
            ForEach(Array((report.problems + report.jsErrors).enumerated()), id: \.offset) { _, problem in
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(CheckReportFile.sortedBench(report), id: \.key) { row in
                    InfoRow(label: BenchLabel.title(row.key), value: LPFormat.milliseconds(row.ms) + " / frame")
                }
                if let mw = report.energyMw { InfoRow(label: "Energy on battery", value: LPFormat.power(milliwatts: mw)) }
                InfoRow(label: "Checked", value: report.checkedAt.formatted(.relative(presentation: .named)))
            }
            .font(.callout)
        }
    }
}

private struct ProvenanceRow: View {
    let entry: ProvenanceEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.isAI ? "sparkles" : "doc.on.doc")
                .foregroundStyle(entry.isAI ? Color.purple : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.title).font(.callout.weight(.semibold))
                    if let date = entry.date {
                        Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let prompt = entry.prompt {
                    Text("\u{201C}\(prompt)\u{201D}").font(.callout).italic().textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let summary = entry.summary {
                    Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                let via = [entry.harness, entry.model].compactMap { $0 }.joined(separator: " \u{00B7} ")
                if !via.isEmpty { Text(via).font(.caption).foregroundStyle(.tertiary) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
