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
                ForEach(SetupChecklist.checks(for: .screenSaver, state: model.setupState)) { SetupCheckRow(check: $0) }
                if !(status.saverInstalled && status.saverUpToDate && status.saverSelected) {
                    HStack {
                        Button(model.setupState.selectActionTitle(otherwise: "Make LivePaper My Screen Saver")) {
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
        let checks = SetupChecklist.checks(for: .lock, state: model.setupState)
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.lockKeysShowScene }, set: { on in Task { await model.setLockKeysShowScene(on) } })) {
                    Text("Use \u{2303}\u{2318}Q and the lock key for LivePaper lock")
                    Text("Also Apple menu \u{203A} Lock Screen. Your Mac starts the scene, then locks.")
                }
                ForEach(checks.filter { $0.id == .password }) { check in
                    HStack {
                        SetupCheckRow(check: check)
                        Spacer()
                        if check.state == .needed {
                            Button("Open Lock Screen Settings\u{2026}") { SystemActions.openLockScreenSettings() }
                        }
                    }
                }
            } header: {
                Text("Lock keys")
            } footer: {
                Text("macOS normally locks straight to the wallpaper. With this on it starts your screen saver first, so the lock screen shows your scene. Closing the lid still shows the wallpaper; for the screens turning off, see below. No permissions are needed, and uninstalling LivePaper restores the previous behaviour.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle(isOn: Binding(get: { model.showSceneBeforeDisplaySleep }, set: { model.setShowSceneBeforeDisplaySleep($0) })) {
                    Text("Show your scene when the screens turn off first")
                    Text("If your screens turn off before the screen saver starts, LivePaper starts it a few seconds earlier, so the lock screen shows your scene instead of the wallpaper.")
                }
                if let status = model.preSleepStatus {
                    Text(status)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Screens turning off")
            } footer: {
                Text("Trade-off: moving the mouse in the last few seconds before the screens turn off then asks for your password.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent("Lock shortcut") {
                    HotkeyRecorderView(hotkey: Binding(get: { model.sharedState.lock.hotkey },
                                                       set: { key in model.updateLock { $0.hotkey = key } }))
                }
                ForEach(checks.filter { $0.id == .helper }) { check in
                    HStack {
                        SetupCheckRow(check: check)
                        Spacer()
                        if model.setupState.helperNeedsApproval {
                            Button("Open Login Items\u{2026}") { SystemActions.openLoginItemsSettings() }
                        } else if check.state == .needed {
                            Button(model.setupState.helperActionTitle) { Task { await model.registerHelper() } }
                                .disabled(model.isInstallBusy)
                        } else if model.setupState.helperOtherCopy != nil {
                            Button(SetupState.useThisCopysHelperTitle) { Task { await model.registerHelper() } }
                                .disabled(model.isInstallBusy)
                        }
                    }
                }
            } header: {
                Text("Extra shortcut")
            } footer: {
                Text("A shortcut of your choice that starts your scene and locks, provided by the LivePaper helper.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 440)
        // The status line follows the energy settings, the power source and the password setting.
        .task { await model.refreshInstallStatus() }
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
        Form {
            Section {
                Picker("Default agent", selection: binding(\.preferredHarness)) {
                    Text("First available").tag(String?.none)
                    ForEach(model.availableHarnesses) { Text($0.uiTitle).tag(Optional($0.id)) }
                }
                if model.harnesses.isEmpty && !model.isDetectingHarnesses {
                    Text("No AI command-line tools were found on your PATH. Install Claude Code, Codex or Kiro CLI, or add a custom command below.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.harnesses.filter { $0.kind != .custom }) { harness in
                    LabeledContent {
                        TextField("Model", text: modelBinding(harness.kind), prompt: Text("Default model"))
                            .frame(maxWidth: 200)
                    } label: {
                        Text(harness.uiTitle)
                        Text(LPFormat.abbreviatingHome(harness.executable))
                    }
                }
                HStack {
                    Button("Look Again") { Task { await model.detectHarnesses() } }
                        .disabled(model.isDetectingHarnesses)
                    if model.isDetectingHarnesses { ProgressView().controlSize(.small) }
                }
            } header: {
                Text("Agents")
            } footer: {
                Text("The model is passed to the agent unless you pick another one when starting a session. Leave it empty for the agent\u{2019}s own default.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Picker("Time limit", selection: binding(\.timeoutMinutes)) {
                    ForEach(AIPreferences.timeoutChoices(including: model.aiSettings.timeoutMinutes), id: \.self) {
                        Text("\($0) minutes").tag($0)
                    }
                }
            } header: {
                Text("Sessions")
            } footer: {
                Text("A session that runs longer than the time limit is stopped.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                let template = model.aiSettings.customTemplate ?? ""
                TextField("Command", text: Binding(get: { template },
                                                   set: { model.aiSettings.customTemplate = $0.isEmpty ? nil : $0 }),
                          prompt: Text("mytool --prompt-file {prompt_file} --cwd {workspace}"))
                    .font(.body.monospaced())
                TextField("Model", text: modelBinding(.custom), prompt: Text("Fills {model}; optional"))
                if let problem = AIPreferences.customCommandProblem(template) {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } header: {
                Text("Custom command")
            } footer: {
                Text("Runs in the session workspace with the task on standard input. Placeholders: \(AIPreferences.placeholders.joined(separator: " ")).")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 500)
    }

    /// Edits one field of the stored AI settings (saved through AIServicing on every change).
    private func binding<T>(_ keyPath: WritableKeyPath<AISettings, T>) -> Binding<T> {
        Binding(get: { model.aiSettings[keyPath: keyPath] }, set: { model.aiSettings[keyPath: keyPath] = $0 })
    }

    private func modelBinding(_ kind: AIHarness.Kind) -> Binding<String> {
        Binding(get: { model.aiSettings.models[kind.rawValue] ?? "" },
                set: { model.aiSettings.models[kind.rawValue] = $0.isEmpty ? nil : $0 })
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
                            .textSelection(.enabled)   // for bug reports
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
    /// The step log of the last run; nil until Uninstall is pressed.
    @State private var report: UninstallReport?

    /// `report` lets the snapshot harness show the log state.
    init(report: UninstallReport? = nil) {
        _report = State(initialValue: report)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let report {
                ResultView(report: report)
            } else {
                PlanView(plan: model.uninstallPlan(keepScenes: keepScenes))
                Toggle("Keep my scenes", isOn: $keepScenes)
                    .toggleStyle(.checkbox)
                    .disabled(running)
            }
            HStack {
                if running {
                    ProgressView().controlSize(.small)
                    Text("Uninstalling\u{2026}").foregroundStyle(.secondary)
                }
                Spacer()
                buttons
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    @ViewBuilder
    private var buttons: some View {
        if let report, report.succeeded {
            Button(model.environment.appBundlePath == nil ? "Done" : "Move to Trash and Quit") {
                dismiss()
                SystemActions.moveAppToTrashAndQuit(model)
            }
            .keyboardShortcut(.defaultAction)
        } else if report != nil {
            Button("Close", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(running)
            Button("Try Again", action: uninstall)
                .keyboardShortcut(.defaultAction)
                .disabled(running)
        } else {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(running)
            Button("Uninstall", role: .destructive, action: uninstall)
                .disabled(running)
        }
    }

    private func uninstall() {
        running = true
        let keep = keepScenes
        Task {
            report = await model.uninstall(keepScenes: keep)
            running = false
        }
    }

    /// Before: exactly what will happen.
    private struct PlanView: View {
        let plan: UninstallPlan

        var body: some View {
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
                        Image(systemName: Self.symbol(item.action))
                            .foregroundStyle(Self.tint(item.action))
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
        }

        static func symbol(_ a: UninstallPlan.Item.Action) -> String {
            switch a {
            case .remove: return "minus.circle.fill"
            case .restore: return "arrow.uturn.backward.circle.fill"
            case .keep: return "checkmark.circle.fill"
            }
        }

        static func tint(_ a: UninstallPlan.Item.Action) -> Color {
            switch a {
            case .remove: return .red
            case .restore: return .blue
            case .keep: return .green
            }
        }
    }

    /// After: the step log from InstallServicing.performUninstall.
    private struct ResultView: View {
        let report: UninstallReport

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: report.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(report.succeeded ? Color.green : Color.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.succeeded ? "LivePaper was uninstalled" : "Uninstall didn\u{2019}t finish")
                        .font(.title3.weight(.semibold))
                    Text(report.summary).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(report.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: Self.symbol(row.state))
                            .foregroundStyle(Self.tint(row.state))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title)
                                .foregroundStyle(row.state == .skipped ? .secondary : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = row.detail {
                                Text(detail).font(.callout)
                                    .foregroundStyle(row.state == .failed ? Color.red : .secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(Self.label(row.state))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(cornerRadius: 10)
        }

        static func symbol(_ s: UninstallReport.Row.State) -> String {
            switch s {
            case .done: return "checkmark.circle.fill"
            case .skipped: return "minus.circle"
            case .failed: return "xmark.octagon.fill"
            case .planned: return "circle.dashed"
            }
        }

        static func tint(_ s: UninstallReport.Row.State) -> Color {
            switch s {
            case .done: return .green
            case .skipped, .planned: return .secondary
            case .failed: return .red
            }
        }

        static func label(_ s: UninstallReport.Row.State) -> String {
            switch s {
            case .done: return "Done"
            case .skipped: return "Skipped"
            case .failed: return "Failed"
            case .planned: return "Planned"
            }
        }
    }
}
