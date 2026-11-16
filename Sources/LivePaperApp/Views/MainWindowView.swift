// MainWindowView — the main window: sidebar navigation, the selected screen, non-modal banners,
// scene- and collection-action sheets and the onboarding sheet. (Collections are sections of the
// Library, LibraryView.)
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
        .sheet(item: $model.collectionAction) { action in
            CollectionActionSheet(action: action)
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
    @State private var filesTargeted = false

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
        // .lpcollection and .lpscene files dropped from Finder are imported (scenes the library already
        // has just open), here as on the Library.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { [CollectionArchive.fileExtension, SceneManifest.packageExtension].contains($0.pathExtension.lowercased()) }
            for url in files {
                Task {
                    if url.pathExtension.lowercased() == CollectionArchive.fileExtension { await model.importCollection(at: url) }
                    else { await model.openScenePackage(at: url) }
                }
            }
            return !files.isEmpty
        } isTargeted: { filesTargeted = $0 }
        .overlay {
            if filesTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).padding(4).allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SetupStatusFooter() }
    }
}

private struct SessionSidebarRow: View {
    let session: AISessionModel

    var body: some View {
        HStack(spacing: 8) {
            SessionPhaseIcon(phase: session.state.phase, resolution: session.resolution)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.title).lineLimit(1)
                    if session.isRecovered { RecoveredBadge() }
                }
                Text(session.state.lastStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Recovered": a session LivePaper picked up again after it quit, crashed or was restarted while
/// the session ran (sidebar, session header).
struct RecoveredBadge: View {
    var body: some View {
        Text("Recovered")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.orange.opacity(0.16), in: Capsule())
            .fixedSize()
            .help("LivePaper quit while this session ran and picked it up again when it started.")
            .accessibilityLabel("Recovered")
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
        // A wallpaper-settings format LivePaper doesn't know: it can't tell, System Settings can.
        let unknown = status.saverInstalled && status.saverSelectionUnknown
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(ready ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(ready ? "Screen saver active" : partly ? "Not on every display" : unknown ? "Can\u{2019}t check the screen saver"
                           : "Setup not finished")
                    .font(.callout.weight(.medium))
            }
            Text(ready ? model.playlistSummary : partly ? SetupChecklist.saverSummary(status) + "."
                       : unknown ? "Check System Settings \u{203A} Wallpaper \u{203A} Screen Saver."
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
            } else if unknown {
                Button("Open Screen Saver Settings") { model.openScreenSaverSettings() }
                    .controlSize(.small)
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
