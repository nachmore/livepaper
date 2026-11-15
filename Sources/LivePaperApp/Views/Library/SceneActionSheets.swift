// SceneActionSheets — Clone, Modify with AI and Delete, presented from cards, the detail view and
// the Scene menu through `AppModel.sceneAction`.
import LivePaperCore
import SwiftUI

struct SceneActionSheet: View {
    let action: AppModel.SceneAction
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let entry = model.entry(id: action.sceneID) {
            switch action {
            case .clone: CloneSheet(entry: entry)
            case .modify: ModifySheet(entry: entry)
            case .delete: DeleteSheet(entry: entry)
            }
        } else {
            // The scene disappeared (deleted elsewhere) while the sheet was opening.
            Color.clear.frame(width: 1, height: 1).onAppear { dismiss() }
        }
    }
}

/// Shared frame for the action sheets: icon + title, content, buttons.
private struct SheetScaffold<Content: View, Buttons: View>: View {
    let symbol: String
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title3.weight(.semibold))
                    if let subtitle {
                        Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

// MARK: - Clone

private struct CloneSheet: View {
    let entry: LibraryEntry
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false

    var body: some View {
        SheetScaffold(symbol: "plus.square.on.square", title: "Clone \u{201C}\(entry.manifest.name)\u{201D}",
                      subtitle: "Makes an editable copy in your library. The original stays as it is.") {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(clone)
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Clone", action: clone)
                .keyboardShortcut(.defaultAction)
                .disabled(SceneNaming.validated(name) == nil || busy)
        }
        .onAppear {
            name = SceneNaming.uniqueCopyName(for: entry.manifest.name, existing: model.entries.map(\.manifest.name))
        }
    }

    private func clone() {
        guard let valid = SceneNaming.validated(name), !busy else { return }
        busy = true
        Task {
            if let item = await model.clone(entry.id, name: valid) {
                dismiss()
                model.showScene(item.id)
            }
            busy = false
        }
    }
}

// MARK: - Modify with AI

private struct ModifySheet: View {
    let entry: LibraryEntry
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var harnessID: String?
    @State private var modelName = ""
    @State private var busy = false

    var body: some View {
        SheetScaffold(symbol: "wand.and.stars", title: "Modify \u{201C}\(entry.manifest.name)\u{201D} with AI",
                      subtitle: entry.item.isBuiltin
                          ? "Built-in scenes are read-only, so LivePaper modifies a copy. You review the result before it's saved."
                          : "The agent edits a copy; you review the result before it replaces this scene.") {
            VStack(alignment: .leading, spacing: 12) {
                PromptEditor(text: $prompt, placeholder: "What should change? For example: \u{201C}Slower, with a warmer palette and fewer particles.\u{201D}")
                    .frame(height: 110)
                HarnessPickerRow(harnessID: $harnessID, modelName: $modelName)
            }
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Start", action: start)
                .keyboardShortcut(.defaultAction)
                .disabled(!PromptComposer.isUsable(prompt) || selectedHarness == nil || busy)
        }
        .onAppear {
            harnessID = model.preferredHarness?.id
        }
    }

    private var selectedHarness: AIHarness? { model.availableHarnesses.first { $0.id == harnessID } }

    private func start() {
        guard let harness = selectedHarness, PromptComposer.isUsable(prompt), !busy else { return }
        busy = true
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let session = await model.startModify(sceneID: entry.id, prompt: prompt, harness: harness,
                                                  model: trimmed.isEmpty ? nil : trimmed)
            busy = false
            if session != nil { dismiss() }
        }
    }
}

// MARK: - Delete

private struct DeleteSheet: View {
    let entry: LibraryEntry
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(symbol: "trash", title: "Delete \u{201C}\(entry.manifest.name)\u{201D}?",
                      subtitle: "The scene, its AI history and previous versions are removed from your library. This can't be undone.") {
            if model.isInPlaylist(entry.id) && !PlaylistDraft(model.playlist).includesAllScenes {
                Label("It will also be removed from the screen saver playlist.", systemImage: "play.rectangle.on.rectangle")
                    .foregroundStyle(.secondary)
            }
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Delete", role: .destructive) {
                let id = entry.id
                dismiss()
                Task { await model.delete(id) }
            }
            .keyboardShortcut(.defaultAction)
        }
        .tint(.red)
    }
}

// MARK: - Shared AI inputs

/// A multi-line prompt box with a placeholder (TextEditor has none of its own).
struct PromptEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
            .accessibilityLabel("Prompt")
            .accessibilityHint(placeholder)
    }
}

/// Harness picker (detected CLIs with versions + the custom command) and the optional model field.
struct HarnessPickerRow: View {
    @Binding var harnessID: String?
    @Binding var modelName: String
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let harnesses = model.availableHarnesses
        let selected = harnesses.first { $0.id == harnessID }
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Agent").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                if harnesses.isEmpty && (model.isDetectingHarnesses || !model.hasDetectedHarnesses) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Looking for AI tools\u{2026}").foregroundStyle(.secondary)
                    }
                } else if harnesses.isEmpty {
                    HStack(spacing: 8) {
                        Text("No AI command-line tools found.").foregroundStyle(.secondary)
                        Button("Set Up\u{2026}") { openSettings() }
                            .controlSize(.small)
                        Button("Look Again") { Task { await model.detectHarnesses() } }
                            .controlSize(.small)
                    }
                    .help("LivePaper works with Claude Code, Codex and Kiro CLI, or any command you configure in Settings \u{203A} AI.")
                } else {
                    Picker("Agent", selection: $harnessID) {
                        ForEach(harnesses) { h in
                            Text(h.uiTitle).tag(Optional(h.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            GridRow {
                Text("Model").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                TextField("Model", text: $modelName, prompt: Text(model.defaultModel(for: selected) ?? "Default"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .help("Optional. Passed to the agent as its model name; leave empty for the default from Settings \u{203A} AI.")
            }
        }
        .onChange(of: harnesses) { _, list in
            if harnessID == nil || !list.contains(where: { $0.id == harnessID }) {
                harnessID = AIPreferences.preferredHarness(in: list, preferredID: model.aiSettings.preferredHarness)?.id
            }
        }
    }
}
