// AISessionView — one AI create/modify session: the agent's live activity, the stills it renders,
// LivePaper's own check of the result and the decision (accept / replace / try again / discard).
//
// Sessions run for many minutes. Everything here is driven by AISessionState, which bounds the
// timeline, and the elapsed clock only ticks while the agent runs, so the view stays cheap.
import LivePaperCore
import SwiftUI

struct AISessionView: View {
    let session: AISessionModel
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(session: session)
            Divider()
            HStack(spacing: 0) {
                SessionTimeline(state: session.state)
                    .frame(minWidth: 340, maxWidth: .infinity)
                Divider()
                ScrollView {
                    SessionResultPanel(session: session)
                        .padding(20)
                }
                .frame(width: 400)
                .background(.background.secondary)
            }
        }
        .navigationTitle(session.isModify ? "Modify with AI" : "Create with AI")
    }
}

// MARK: - Header

private struct SessionHeader: View {
    let session: AISessionModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SessionPhaseIcon(phase: session.state.phase, resolution: session.resolution)
                .font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .help(session.prompt)
                HStack(spacing: 6) {
                    Text(session.harness.uiTitle)
                    if let m = session.model { Text("\u{00B7}"); Text(m) }
                    if let source = session.clonedFrom { Text("\u{00B7}"); Text("copy of \(source)") }
                    Text("\u{00B7}")
                    Text(session.state.lastStatus).lineLimit(1)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            ElapsedLabel(session: session)
            if session.isRunning {
                Button(role: .cancel) {
                    session.cancel()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop the agent (\u{2318}.)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }
}

/// "4:05" — ticks once a second only while the session runs.
private struct ElapsedLabel: View {
    let session: AISessionModel

    var body: some View {
        Group {
            if session.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(LPFormat.elapsed(session.elapsed(now: context.date)))
                }
            } else {
                Text(LPFormat.elapsed(session.elapsed()))
            }
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .accessibilityLabel("Elapsed time")
    }
}

// MARK: - Timeline

private struct SessionTimeline: View {
    let state: AISessionState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if state.droppedEntries > 0 {
                    Text("\(state.droppedEntries) earlier steps hidden")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                ForEach(state.entries) { TimelineRow(entry: $0) }
                if !state.phase.isTerminal {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(state.phase == .validating ? "Checking the result\u{2026}" : "Working\u{2026}")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.top, 2)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Follows new activity while the user is at the bottom; scrolling up stops following.
        .defaultScrollAnchor(.bottom)
        .accessibilityLabel("Agent activity")
    }
}

private struct TimelineRow: View {
    let entry: AISessionState.Entry
    @State private var expanded = false

    var body: some View {
        switch entry.kind {
        case .status(let text):
            Label(text, systemImage: "circle.fill")
                .labelStyle(TimelineStatusLabelStyle())
                .font(.callout)
                .foregroundStyle(.secondary)
        case .text(let text):
            Text(AgentText.render(text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        case .tools(let calls):
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(call.name).font(.caption.weight(.semibold)).frame(width: 56, alignment: .leading)
                            Text(call.detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(3).textSelection(.enabled)
                        }
                    }
                }
                .padding(.leading, 4)
                .padding(.top, 4)
            } label: {
                Label(ToolSummary.title(calls), systemImage: "wrench.and.screwdriver")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .stills(let n):
            Label(n == 1 ? "Rendered a still" : "Rendered \(n) stills", systemImage: "photo.on.rectangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .check(let passed, let summary):
            Label("LivePaper check: \(summary)", systemImage: passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(passed ? .green : .red)
        case .finished:
            Label("The scene is ready to review.", systemImage: "sparkles")
                .font(.callout.weight(.medium))
                .foregroundStyle(.purple)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .cancelled:
            Label("Stopped.", systemImage: "stop.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TimelineStatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.system(size: 5)).frame(width: 12)
            configuration.title
        }
    }
}

// MARK: - Result panel

private struct SessionResultPanel: View {
    let session: AISessionModel
    @Environment(AppModel.self) private var model
    @State private var selectedStill: URL?
    @State private var candidate: SceneItem?
    @State private var feedback = ""
    @State private var accepting = false

    var body: some View {
        let state = session.state
        VStack(alignment: .leading, spacing: 18) {
            hero(state)
            if !state.stills.isEmpty { filmstrip(state.stills) }
            if let report = state.report {
                SectionBox(title: "LivePaper Check", symbol: "checklist") {
                    CheckReportSummary(report: report)
                }
            }
            decision(state)
        }
        .task(id: state.package) { await loadCandidate(state.package) }
    }

    // Hero: the live result once it's ready, else the selected/latest still.
    @ViewBuilder
    private func hero(_ state: AISessionState) -> some View {
        Color.black
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay {
                if let candidate, selectedStill == nil {
                    ScenePreview(item: candidate, quality: .full)
                } else if let still = selectedStill ?? state.stills.last {
                    ThumbnailImage(url: still, maxPixel: 1024)
                } else {
                    VStack(spacing: 10) {
                        if state.phase.isTerminal {
                            Image(systemName: "photo").font(.largeTitle.weight(.light))
                            Text("No renders").font(.callout)
                        } else {
                            ProgressView().controlSize(.regular).tint(.white)
                            Text("Waiting for the first render\u{2026}").font(.callout)
                        }
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topLeading) {
                if candidate != nil && selectedStill == nil {
                    OverlayBadge(title: "Live", symbol: "play.fill").padding(8)
                }
            }
            .accessibilityLabel(candidate != nil ? "Live preview of the result" : "Latest render")
    }

    private func filmstrip(_ stills: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Renders").font(.headline)
                Text("\(stills.count)").foregroundStyle(.secondary)
                Spacer()
                if candidate != nil && selectedStill != nil {
                    Button("Show Live") { selectedStill = nil }.buttonStyle(.link)
                }
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(stills, id: \.self) { url in
                        Button {
                            selectedStill = url
                        } label: {
                            ThumbnailImage(url: url, maxPixel: 240)
                                .frame(width: 96, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(url == (selectedStill ?? (candidate == nil ? stills.last : nil)) ? Color.accentColor : .clear,
                                                      lineWidth: 2)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Render \((stills.firstIndex(of: url) ?? 0) + 1)")
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: 64)
        }
    }

    @ViewBuilder
    private func decision(_ state: AISessionState) -> some View {
        switch (state.phase, session.resolution) {
        case (.succeeded, .accepted(let id)):
            VStack(alignment: .leading, spacing: 10) {
                Label(session.isModify ? "Scene updated" : "Added to your library", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                HStack {
                    Button("Show Scene") { model.showScene(id) }
                    Button("Use as Screen Saver") { Task { await model.useAsScreenSaver(id) } }
                }
            }
        case (.succeeded, _):
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    accepting = true
                    Task {
                        await model.accept(session)
                        accepting = false
                    }
                } label: {
                    Label(acceptTitle, systemImage: session.isModify ? "arrow.triangle.2.circlepath" : "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(accepting)
                .keyboardShortcut(.defaultAction)
                feedbackBox(buttonTitle: "Try Again with Feedback")
                Button("Discard", role: .destructive) { model.discard(session) }
                    .buttonStyle(.link)
                    .foregroundStyle(.red)
            }
        case (.failed(let message), _):
            VStack(alignment: .leading, spacing: 12) {
                Label("The agent didn\u{2019}t finish", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                feedbackBox(buttonTitle: "Try Again")
                Button("Close Session") { model.discard(session) }.buttonStyle(.link)
            }
        case (.cancelled, _):
            VStack(alignment: .leading, spacing: 12) {
                Text("You stopped this session.").foregroundStyle(.secondary)
                feedbackBox(buttonTitle: "Start Again")
                Button("Close Session") { model.discard(session) }.buttonStyle(.link)
            }
        default:
            Text("The agent is working. You can switch to other screens; LivePaper lets you know when the scene is ready.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var acceptTitle: String {
        guard session.isModify else { return "Add to Library" }
        let name = session.targetSceneID.flatMap { model.entry(id: $0)?.manifest.name } ?? "Scene"
        return "Replace \u{201C}\(name)\u{201D}"
    }

    private func feedbackBox(buttonTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Feedback", text: $feedback, prompt: Text("What should be different? (optional)"), axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            Button(buttonTitle) { model.retry(session, feedback: feedback) }
        }
    }

    private func loadCandidate(_ package: URL?) async {
        guard let package else { candidate = nil; return }
        let manifest = try? await offMain { try SceneManifest.load(package: package) }
        candidate = manifest.map { SceneItem(manifest: $0, packageURL: package, isBuiltin: false) }
    }
}

// MARK: - Formatting helpers

enum AgentText {
    /// Agents write Markdown; render inline styles (bold, code, links) and keep line breaks.
    static func render(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
