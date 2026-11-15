// CreateView — the two ways to make a scene: import a video, or describe it to an AI agent.
import LivePaperCore
import SwiftUI
import UniformTypeIdentifiers

struct CreateView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create a Scene").font(.largeTitle.weight(.semibold))
                    Text("Start from a video you already have, or describe something new and let an AI agent build it.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                AdaptiveStack(threshold: 780, weights: [0.42, 0.58]) {
                    VideoCreateCard()
                    DescribeCreateCard()
                }
            }
            .padding(28)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Create")
    }
}

/// The large icon + title + subtitle heading of a create card.
private struct CardHeading: View {
    let symbol: String
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Video

struct VideoCreateCard: View {
    @Environment(AppModel.self) private var model
    @State private var file: URL?
    @State private var name = ""
    @State private var optimizeForBattery = true
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardHeading(symbol: "film", title: "Video",
                        subtitle: "Loops a clip silently, decoded by the media engine for the lowest energy use.",
                        tint: .blue)
            dropZone
            if file != nil {
                TextField("Name", text: $name, prompt: Text("Scene name"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Scene name")
            }
            Toggle(isOn: $optimizeForBattery) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Optimise for battery")
                    Text("Converts to HEVC at display resolution. Takes a minute, then plays with a fraction of the energy.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(model.videoImport != nil)
            if let progress = model.videoImport {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction) {
                        Text(optimizeForBattery ? "Optimising \(progress.fileName)\u{2026}" : "Copying \(progress.fileName)\u{2026}")
                            .font(.callout)
                    }
                    Text(progress.fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                HStack {
                    Button("Choose Video\u{2026}") { if let url = SystemActions.chooseVideo() { pick(url) } }
                    Spacer()
                    Button("Add to Library", action: add)
                        .buttonStyle(.borderedProminent)
                        .disabled(file == nil || SceneNaming.validated(name) == nil)
                }
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: file == nil ? "arrow.down.doc" : "film.stack")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            if let file {
                Text(file.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Button("Choose a Different Video") { self.file = nil; name = "" }
                    .buttonStyle(.link)
                    .font(.callout)
                    .disabled(model.videoImport != nil)
            } else {
                Text("Drop a video here").font(.callout.weight(.medium))
                Text("MOV, MP4 or M4V").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [6, 4]))
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: VideoFiles.isVideo) else { return false }
            pick(url)
            return true
        } isTargeted: { isTargeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(file == nil ? "Video drop zone" : "Selected video \(file?.lastPathComponent ?? "")")
    }

    private func pick(_ url: URL) {
        file = url
        name = SceneNaming.suggestedName(forFile: url)
    }

    private func add() {
        guard let file, let valid = SceneNaming.validated(name) else { return }
        let battery = optimizeForBattery
        Task {
            if await model.importVideo(from: file, name: valid, optimizeForBattery: battery) != nil {
                self.file = nil
                name = ""
            }
        }
    }
}

enum VideoFiles {
    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie)
    }
}

// MARK: - Describe it (AI)

struct DescribeCreateCard: View {
    @Environment(AppModel.self) private var model
    @State private var prompt = ""
    @State private var harnessID: String?
    @State private var modelName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardHeading(symbol: "sparkles", title: "Describe it",
                        subtitle: "An AI agent on your Mac writes an animated scene, checks it renders well and stays light on the battery.",
                        tint: .purple)
            PromptEditor(text: $prompt, placeholder: "Describe the scene: what moves, the mood, the colours\u{2026}")
                .frame(minHeight: 120, idealHeight: 140)
            VStack(alignment: .leading, spacing: 6) {
                Text("Need an idea?").font(.callout).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(PromptComposer.inspirations, id: \.self) { idea in
                        Button {
                            prompt = idea
                        } label: {
                            Text(PromptComposer.title(for: idea, limit: 34))
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.quaternary.opacity(0.7), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(idea)
                        .accessibilityLabel("Use idea: \(idea)")
                    }
                }
            }
            HarnessPickerRow(harnessID: $harnessID, modelName: $modelName)
            HStack {
                Text("Usually takes 3\u{2013}10 minutes. You can keep working meanwhile.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: generate) {
                    Label("Generate", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!PromptComposer.isUsable(prompt) || selectedHarness == nil)
                .help("Start the agent (\u{2318}\u{21A9})")
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
        .onAppear {
            if harnessID == nil { harnessID = model.preferredHarness?.id }
        }
    }

    private var selectedHarness: AIHarness? { model.availableHarnesses.first { $0.id == harnessID } }

    private func generate() {
        guard let harness = selectedHarness, PromptComposer.isUsable(prompt) else { return }
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.startSession(.create(prompt: prompt), harness: harness, model: trimmed.isEmpty ? nil : trimmed) != nil {
            prompt = ""
        }
    }
}
