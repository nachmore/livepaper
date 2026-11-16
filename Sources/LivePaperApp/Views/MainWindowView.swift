// MainWindowView — the main window: sidebar navigation, the selected screen, non-modal banners,
// scene-action sheets and the onboarding sheet.
import AppKit
import LivePaperCore
import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            DetailRouter()
        }
        .overlay(alignment: .top) { BannerStack() }
        .sheet(item: $model.sceneAction) { action in
            SceneActionSheet(action: action)
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView()
        }
        .background(WindowAccessor { DockIconPolicy.shared.mainWindowAppeared($0) })
        .refreshesInstallStatusOnActivation()
        // Opening the window re-reads the library and playlist (a safety net next to the disk watcher).
        .onAppear { Task { await model.refreshFromDisk() } }
        .frame(minWidth: 860, minHeight: 560)
    }
}

/// Picks the screen for the sidebar selection.
private struct DetailRouter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.section ?? .library {
        case .library:
            LibraryScreen()
        case .create:
            CreateView()
        case .playlist:
            PlaylistView()
        case .session(let id):
            if let session = model.session(id: id) {
                AISessionView(session: session)
                    .id(session.id)
            } else {
                ContentUnavailableView("Session closed", systemImage: "sparkles",
                                       description: Text("This AI session is no longer available."))
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.section) {
            Section {
                Label("Library", systemImage: "square.grid.2x2")
                    .badge(model.entries.count)
                    .tag(AppModel.Section.library)
                Label("Create", systemImage: "plus.square.on.square")
                    .tag(AppModel.Section.create)
                Label("Screen Saver", systemImage: "play.rectangle.on.rectangle")
                    .tag(AppModel.Section.playlist)
            }
            if !model.sessions.isEmpty {
                Section("AI Sessions") {
                    ForEach(model.sessions) { session in
                        SessionSidebarRow(session: session)
                            .tag(AppModel.Section.session(session.id))
                            .contextMenu {
                                if session.isRunning {
                                    Button("Stop") { session.cancel() }
                                }
                                Button("Close Session", role: .destructive) { model.discard(session) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { SetupStatusFooter() }
    }
}

private struct SessionSidebarRow: View {
    let session: AISessionModel

    var body: some View {
        HStack(spacing: 8) {
            SessionPhaseIcon(phase: session.state.phase, resolution: session.resolution)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).lineLimit(1)
                Text(session.state.lastStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Small status glyph for an AI session (sidebar, menu bar, session header).
struct SessionPhaseIcon: View {
    let phase: AISessionState.Phase
    var resolution: AISessionModel.Resolution?

    var body: some View {
        Group {
            switch phase {
            case .starting, .running, .validating:
                ProgressView().controlSize(.small)
            case .succeeded:
                if case .accepted = resolution {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Image(systemName: "sparkles").foregroundStyle(.purple)
                }
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .cancelled:
                Image(systemName: "stop.circle").foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityLabel(AISessionState.describe(phase))
    }
}

/// Bottom of the sidebar: whether LivePaper is actually the screen saver, with a way to finish setup.
private struct SetupStatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.installStatus
        let ready = status.saverInstalled && status.saverSelected
        // Some displays show another screen saver: one click selects LivePaper on all of them.
        let partly = status.saverInstalled && status.saverPartlySelected
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(ready ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(ready ? "Screen saver active" : partly ? "Not on every display" : "Setup not finished")
                    .font(.callout.weight(.medium))
            }
            Text(ready ? model.playlistSummary : partly ? SetupChecklist.saverSummary(status) + "."
                       : "LivePaper isn't your screen saver yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if partly {
                Button(SetupState.everyDisplayActionTitle) {
                    // The guided step lives in setup, for when macOS doesn't let LivePaper do it.
                    Task { if !(await model.makeLivePaperScreenSaver()) { model.showOnboarding = true } }
                }
                .controlSize(.small)
                .disabled(model.isInstallBusy)
            } else if !ready {
                Button("Finish Setup\u{2026}") { model.showOnboarding = true }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Window plumbing

/// Hands the hosting NSWindow to `onWindow` once the view is in a window (used for the Dock policy).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReportingView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
