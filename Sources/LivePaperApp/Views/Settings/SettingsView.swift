// SettingsView — the Settings window: Screen Saver, Lock, Performance, AI and About (+ Uninstall).
import AppKit
import LivePaperCore
import SwiftUI

struct SettingsView: View {
    enum Tab: Hashable { case screenSaver, lock, performance, ai, about }
    @State private var tab: Tab
    @Environment(AppModel.self) private var model

    init(initialTab: Tab = .screenSaver) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            ScreenSaverSettingsTab()
                .tabItem { Label("Screen Saver", systemImage: "play.rectangle.on.rectangle") }
                .tag(Tab.screenSaver)
            LockSettingsTab()
                .tabItem { Label("Lock", systemImage: "lock") }
                .tag(Tab.lock)
            PerformanceSettingsTab()
                .tabItem { Label("Performance", systemImage: "leaf") }
                .tag(Tab.performance)
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(Tab.ai)
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(width: 640)
        .task { await model.refreshInstallStatus() }
        .refreshesInstallStatusOnActivation()
    }
}

extension View {
    /// Re-reads InstallStatus whenever LivePaper becomes active again — typically after the user
    /// changed something in System Settings — so status rows are never stale.
    func refreshesInstallStatusOnActivation() -> some View {
        modifier(RefreshOnActivation())
    }
}

private struct RefreshOnActivation: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshInstallStatus() }
        }
    }
}

// MARK: - Screen saver

private struct ScreenSaverSettingsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var needsGuidedSelection = false

    var body: some View {
        let status = model.installStatus
        Form {
            Section {
                ForEach(SetupChecklist.checks(for: .screenSaver, status: status)) { SetupCheckRow(check: $0) }
                if !(status.saverInstalled && status.saverUpToDate && status.saverSelected) {
                    HStack {
                        Button("Make LivePaper My Screen Saver") {
                            Task { needsGuidedSelection = !(await model.makeLivePaperScreenSaver()) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isInstallBusy)
                        if model.isInstallBusy { ProgressView().controlSize(.small) }
                    }
                }
                if needsGuidedSelection && !status.saverSelected {
                    GuidedSaverSelection()
                }
            } header: {
                HStack {
                    Text("Status")
                    Spacer()
                    StatusDot(title: SetupChecklist.saverSummary(status), ok: status.saverInstalled && status.saverSelected)
                        .font(.callout)
                }
            }
            Section("Playlist") {
                LabeledContent("Playing", value: model.playlistSummary)
                Button("Edit Playlist\u{2026}") {
                    model.section = .playlist
                    openWindow(id: WindowID.main)
                }
            }
            Section {
                Button("Run Setup Again\u{2026}") {
                    model.showOnboarding = true
                    openWindow(id: WindowID.main)
                }
            } footer: {
                Text("Setup checks every step again and only changes what still needs it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 420)
    }
}

// MARK: - Lock

private struct LockSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.installStatus
        let lock = model.sharedState.lock
        Form {
            Section {
                LabeledContent("Lock shortcut") {
                    HotkeyRecorderView(hotkey: Binding(get: { model.sharedState.lock.hotkey },
                                                       set: { key in model.updateLock { $0.hotkey = key } }))
                }
                Text("Starts your scene and locks your Mac, so the lock screen shows the scene instead of the plain wallpaper. Needs no special permissions.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(SetupChecklist.checks(for: .lock, status: status)) { check in
                    HStack {
                        SetupCheckRow(check: check)
                        Spacer()
                        switch (check.id, check.state) {
                        case (.helper, .needed):
                            Button("Start Helper") { Task { await model.registerHelper() } }
                                .disabled(model.isInstallBusy)
                        case (.password, .needed):
                            Button("Open Lock Screen Settings\u{2026}") { SystemActions.openLockScreenSettings() }
                        default:
                            EmptyView()
                        }
                    }
                }
            } header: {
                Text("LivePaper lock")
            }
            Section {
                Toggle(isOn: Binding(get: { lock.takeOverSystemLock },
                                     set: { v in model.updateLock { $0.takeOverSystemLock = v } })) {
                    Text("Use \u{2303}\u{2318}Q for LivePaper lock")
                    Text("The standard Lock Screen shortcut shows your scene too.")
                }
                Toggle(isOn: Binding(get: { lock.takeOverLockKey },
                                     set: { v in model.updateLock { $0.takeOverLockKey = v } })) {
                    Text("Use the lock key")
                    Text("The Touch ID / lock key in the top-right corner of the keyboard shows your scene.")
                }
                if (lock.takeOverSystemLock || lock.takeOverLockKey) && !status.accessibilityTrusted {
                    Label("These need Accessibility access before they take effect.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                ForEach(SetupChecklist.checks(for: .lockKeys, status: status)) { check in
                    HStack {
                        SetupCheckRow(check: check)
                        Spacer()
                        if !status.accessibilityTrusted {
                            Button("Open Accessibility Settings\u{2026}") { model.openAccessibilitySettings() }
                        }
                    }
                }
            } header: {
                Text("System lock keys")
            } footer: {
                Text("macOS locks immediately when you use its own lock keys, before any screen saver can start, so the lock screen shows the plain wallpaper. With these on, the LivePaper helper catches the keys and runs its own lock instead. If the helper isn't running, the keys work exactly as before. Apple menu \u{203A} Lock Screen always uses the plain lock.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 520)
    }
}

// MARK: - Performance

private struct PerformanceSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("Screen saver quality", selection: Binding(get: { model.playlist.performance },
                                                                  set: { p in Task { await model.setPerformance(p) } })) {
                    ForEach(LPPerformanceProfile.allCases, id: \.self) { profile in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.uiTitle)
                            Text(profile.uiExplanation).font(.callout).foregroundStyle(.secondary)
                        }
                        .tag(profile)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(model.isPublishing)
            } footer: {
                Text("Applies to the screen saver and lock screen. Scenes also slow down by themselves if a frame takes too long.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Energy badges") {
                ForEach([EnergyClass.low, .medium, .high, .unmeasured], id: \.self) { energy in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: energy.symbolName).foregroundStyle(energy.tint).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(energy.label)
                            Text(energy.explanation).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 480)
    }
}

// MARK: - AI

private struct AISettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Default agent", selection: $model.aiPreferences.defaultHarnessID) {
                    Text("First available").tag(String?.none)
                    ForEach(model.availableHarnesses) { Text($0.uiTitle).tag(Optional($0.id)) }
                }
                if model.harnesses.isEmpty && !model.isDetectingHarnesses {
                    Text("No AI command-line tools were found on your PATH. Install Claude Code, Codex or Kiro CLI, or add a custom command below.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.harnesses) { harness in
                    LabeledContent(harness.uiTitle, value: LPFormat.abbreviatingHome(harness.executable))
                        .font(.callout)
                }
                HStack {
                    Button("Look Again") { Task { await model.detectHarnesses() } }
                        .disabled(model.isDetectingHarnesses)
                    if model.isDetectingHarnesses { ProgressView().controlSize(.small) }
                }
            } header: {
                Text("Agents")
            }
            Section {
                TextField("Model", text: $model.aiPreferences.model, prompt: Text("Agent default"))
                Picker("Time limit", selection: $model.aiPreferences.timeoutMinutes) {
                    ForEach(AIPreferences.timeoutChoices, id: \.self) { Text("\($0) minutes").tag($0) }
                }
            } header: {
                Text("Defaults")
            } footer: {
                Text("A session that runs longer than the time limit is stopped.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                TextField("Command", text: $model.aiPreferences.customCommand,
                          prompt: Text("mytool --prompt-file {prompt_file} --cwd {workspace}"))
                    .font(.body.monospaced())
                if let problem = AIPreferences.customCommandProblem(model.aiPreferences.customCommand) {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } header: {
                Text("Custom command")
            } footer: {
                Text("Runs in the session workspace. Placeholders: \(AIPreferences.placeholders.joined(separator: " ")).")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 500)
    }
}

// MARK: - About

private struct AboutSettingsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showUninstall = false

    private static let repository = URL(string: "https://github.com/nachmore/livepaper")

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LivePaper").font(.title2.weight(.semibold))
                        Text("Version \(model.environment.appVersion)").foregroundStyle(.secondary)
                        Text(AppInfo.copyright).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                if let repo = Self.repository {
                    Link("Source code on GitHub", destination: repo)
                    Link("Report a problem", destination: repo.appendingPathComponent("issues"))
                    Link("Apache License 2.0", destination: repo.appendingPathComponent("blob/main/LICENSE"))
                }
            }
            Section {
                Button("Run Setup Again\u{2026}") {
                    model.showOnboarding = true
                    openWindow(id: WindowID.main)
                }
                Button("Uninstall LivePaper\u{2026}", role: .destructive) { showUninstall = true }
            } footer: {
                Text("Uninstalling removes the screen saver and helper and restores your previous screen saver.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 400)
        .sheet(isPresented: $showUninstall) { UninstallSheet() }
    }
}

enum AppInfo {
    /// NSHumanReadableCopyright from Info.plist (fallback for `swift run`).
    static var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? "Copyright \u{00A9} 2026 Oren Nachman. Apache License 2.0."
    }
}

// MARK: - Uninstall

struct UninstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var keepScenes = true
    @State private var running = false

    var body: some View {
        let plan = model.uninstallPlan(keepScenes: keepScenes)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Uninstall LivePaper?").font(.title3.weight(.semibold))
                    Text("Here is exactly what will happen:").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(plan.items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: symbol(item.action))
                            .foregroundStyle(tint(item.action))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                            Text(item.detail).font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(cornerRadius: 10)
            Toggle("Keep my scenes", isOn: $keepScenes)
                .toggleStyle(.checkbox)
                .disabled(running)
            HStack {
                if running {
                    ProgressView().controlSize(.small)
                    Text("Uninstalling\u{2026}").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(running)
                Button("Uninstall", role: .destructive, action: uninstall)
                    .disabled(running)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func uninstall() {
        running = true
        let keep = keepScenes
        Task {
            let ok = await model.uninstall(keepScenes: keep)
            running = false
            if ok {
                dismiss()
                SystemActions.moveAppToTrashAndQuit(model)
            }
        }
    }

    private func symbol(_ a: UninstallPlan.Item.Action) -> String {
        switch a {
        case .remove: return "minus.circle.fill"
        case .restore: return "arrow.uturn.backward.circle.fill"
        case .keep: return "checkmark.circle.fill"
        }
    }

    private func tint(_ a: UninstallPlan.Item.Action) -> Color {
        switch a {
        case .remove: return .red
        case .restore: return .blue
        case .keep: return .green
        }
    }
}
