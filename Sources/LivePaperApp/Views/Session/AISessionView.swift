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
                VStack(spacing: 0) {
                    ScrollView {
                        SessionResultPanel(session: session)
                            .padding(20)
                    }
                    Divider()
                    // Pinned, so the decision is always visible however long the report is.
                    SessionDecisionBar(session: session)
                        .padding(16)
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
                    if let counts = session.referenceCounts {
                        Text("\u{00B7}")
                        Text(counts.total == 1 ? "1 reference" : "\(counts.total) references")
                            .help(counts.description)
                            .accessibilityLabel(counts.description)
                    }
                    Text("\u{00B7}")
                    Text(AISessionState.describe(session.state.phase)).lineLimit(1)
                    if session.state.toolCallCount > 0 {
                        Text("\u{00B7}")
                        Text(session.state.toolCallCount == 1 ? "1 tool call" : "\(session.state.toolCallCount) tool calls")
                    }
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
        .modifier(FollowsNewActivity())
        .accessibilityLabel("Agent activity")
    }
}

/// Keeps the newest activity in view while the user is at the bottom (scrolling up stops
/// following). On macOS 15+ short timelines still start at the top instead of the bottom.
private struct FollowsNewActivity: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .defaultScrollAnchor(.top, for: .alignment)
        } else {
            content.defaultScrollAnchor(.bottom)
        }
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

    var body: some View {
        let state = session.state
        VStack(alignment: .leading, spacing: 18) {
            hero(state)
            if !state.stills.isEmpty { filmstrip(state) }
            if !session.references.isEmpty { SessionReferences(references: session.references) }
            if let report = state.report {
                SectionBox(title: "LivePaper Check", symbol: "checklist") {
                    CheckReportSummary(report: report)
                }
            }
        }
        .task(id: state.package) { await loadCandidate(state.package) }
        .focusedSceneValue(\.fullScreenPreview, candidate.map { item in
            FullScreenPreviewAction { [model, session] in FullScreenPreviewLauncher.previewCandidate(item, session: session, model: model) }
        })
    }

    private func previewFullScreen() {
        guard let candidate else { return }
        FullScreenPreviewLauncher.previewCandidate(candidate, session: session, model: model)
    }

    /// On the live result, like the scene detail view's: see it on the whole screen, as the screen
    /// saver would show it, before deciding (comparing with the current version when modifying).
    private var fullScreenButton: some View {
        Button(action: previewFullScreen) {
            Label("Preview Full Screen", systemImage: FullScreenPreviewSymbol.name)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.5), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(10)
        .help(session.isModify && session.resolution == nil
              ? "Show the result on the whole screen, exactly as the screen saver will; \u{2190} \u{2192} compare it with the current version (\u{21E7}\u{2318}F, or double-click the preview)"
              : "Show the result on the whole screen, exactly as the screen saver will (\u{21E7}\u{2318}F, or double-click the preview)")
    }

    // Hero: the live result once it's ready, else the selected/latest still.
    @ViewBuilder
    private func hero(_ state: AISessionState) -> some View {
        Color.black
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay {
                if let candidate, selectedStill == nil {
                    ScenePreview(item: candidate, quality: .full, cornerRadius: 12)
                } else if let still = selectedStill ?? state.stills.last {
                    // Each `livepaper check` run rewrites the same files: the revision makes a rewrite reload.
                    ThumbnailImage(url: still, revision: state.stillRevision(still), maxPixel: 1024)
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
            .overlay(alignment: .bottomTrailing) {
                if candidate != nil && selectedStill == nil { fullScreenButton }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if selectedStill == nil { previewFullScreen() } }
            .accessibilityLabel(candidate != nil ? "Live preview of the result" : "Latest render")
    }

    private func filmstrip(_ state: AISessionState) -> some View {
        let stills = state.stills
        return VStack(alignment: .leading, spacing: 6) {
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
                            ThumbnailImage(url: url, revision: state.stillRevision(url), maxPixel: 240)
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

    private func loadCandidate(_ package: URL?) async {
        guard let package else { candidate = nil; return }
        let manifest = try? await offMain { try SceneManifest.load(package: package) }
        candidate = manifest.map { SceneItem(manifest: $0, packageURL: package, isBuiltin: false) }
    }
}

/// The images the agent was given (the prepared copies held in memory; the workspace's own copies
/// are pruned after a day): which one it animates, and that trying again keeps them.
private struct SessionReferences: View {
    let references: [PreparedReference]

    var body: some View {
        SectionBox(title: "References", symbol: "photo.on.rectangle.angled") {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(references.enumerated()), id: \.element.id) { i, reference in
                            tile(reference, index: i)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)
                Text(ReferenceTrayText.sessionCaption(roles: references.map(\.role)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tile(_ reference: PreparedReference, index: Int) -> some View {
        let animate = reference.role == .animate
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return ThumbnailImage(reference: reference, maxPixel: 240)
            .frame(width: 96, height: 60)
            .clipShape(shape)
            .overlay { shape.strokeBorder(animate ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: animate ? 2 : 1) }
            .overlay(alignment: .bottomLeading) {
                if animate { OverlayBadge(title: "Animate", symbol: "film").padding(4) }
            }
            .help(reference.displayName + (animate ? " \u{2014} the picture to animate" : ""))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reference image \(index + 1) of \(references.count), \(reference.displayName), \(animate ? "animate" : "reference")")
            .accessibilityAddTraits(.isImage)
    }
}

// MARK: - Decision

/// Accept / Replace / Try again / Discard, depending on how the session ended.
private struct SessionDecisionBar: View {
    let session: AISessionModel
    @Environment(AppModel.self) private var model
    @State private var feedback = ""
    @State private var accepting = false

    var body: some View {
        content.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        let state = session.state
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
                // Not Return: that would accept while the user is typing feedback below.
                .keyboardShortcut(.return, modifiers: .command)
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

    /// Return in the feedback box: try again with it. Nothing to send (no text, or a session is
    /// already starting): false, and Return does nothing.
    private func sendFeedback() -> Bool {
        guard !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.isStartingSession else { return false }
        Task { await model.retry(session, feedback: feedback) }
        return true
    }

    private func feedbackBox(buttonTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Return sends the feedback (⇧Return for a new line); ⌘Return stays the Add/Replace button.
            PromptEditor(text: $feedback, placeholder: "What should be different? Return sends it, \u{21E7}Return adds a line.",
                         label: "Feedback", onReturn: sendFeedback)
                .frame(minHeight: 52, maxHeight: 96)
            Button(buttonTitle) { Task { await model.retry(session, feedback: feedback) } }
                .disabled(model.isStartingSession)
                .help(session.references.isEmpty
                      ? "Starts a new session that keeps the prompt, with your feedback added"
                      : "Starts a new session that keeps the prompt and reference images, with your feedback added")
        }
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
