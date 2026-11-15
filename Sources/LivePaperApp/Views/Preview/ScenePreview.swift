// ScenePreview — a live, battery-conscious preview of a scene: the compiled HTML in a WKWebView for
// web scenes, a looping muted AVPlayerLayer for video scenes, and the thumbnail as a poster
// underneath while either loads.
//
// Battery rule: a preview only runs while somebody can see it (`LiveSceneHostView`, shared with the
// full-screen preview, see LiveSceneHost.swift). SwiftUI's lazy grids additionally dismantle
// previews that leave the viewport, which releases everything.
import AppKit
import IOKit.ps
import LivePaperCore
import SwiftUI

/// How hard a preview may work.
enum PreviewQuality: Equatable {
    /// Library card hover: 30 fps at half resolution, no clock.
    case hover
    /// Scene detail / AI result: the user's playlist profile, with the clock if enabled.
    case full
}

struct ScenePreview: View {
    let item: SceneItem
    var quality: PreviewQuality = .full
    /// Shows the scene's clock overlay (web scenes; the saver draws it for video scenes).
    var showClock = true
    /// Matches the container's rounded corners. SwiftUI's clipShape doesn't reliably clip AppKit
    /// views (WKWebView, AVPlayerLayer), so the host layer masks them itself.
    var cornerRadius: CGFloat = 0
    /// Reports runtime errors from the scene (e.g. to show a hint in the detail view).
    var onError: ((String) -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.livePreviewsEnabled) private var livePreviewsEnabled
    @State private var compiledHTML: URL?
    @State private var compileError: String?

    var body: some View {
        ZStack {
            ThumbnailImage(url: item.thumbnailURL, revision: model.thumbnailRevision[item.id] ?? 0,
                           placeholderSymbol: item.manifest.kind == .video ? "film" : "sparkles")
            if livePreviewsEnabled {
                live
            }
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of \(item.manifest.name)")
        .accessibilityAddTraits(.isImage)
        .task(id: compileKey) { await compileIfNeeded() }
    }

    @ViewBuilder
    private var live: some View {
        switch item.manifest.kind {
        case .video:
            if let video = videoURL {
                // The file keeps its name (video.mov) when the scene is replaced, so the view is
                // keyed on the manifest too: a new version gets a new player and its own fit.
                LivePreviewRepresentable(content: .video(video, fit: item.manifest.video?.fit ?? .fill), cornerRadius: cornerRadius)
                    .id(videoKey)
            }
        case .web:
            if let compiledHTML {
                LivePreviewRepresentable(content: .web(compiledHTML, configScript: LiveSceneContent.configScript(runtimeConfig), onError: onError),
                                         cornerRadius: cornerRadius)
            } else if compileError != nil {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(8)
                    .background(.black.opacity(0.4), in: Circle())
                    .help(compileError ?? "")
            }
        }
    }

    /// Changes with the scene's version, and with edits on disk that don't touch it (an editor,
    /// `livepaper check`: AppModel.previewRevision), so an open preview recompiles.
    private var compileKey: String {
        "\(item.id)#\(item.manifest.updated?.timeIntervalSince1970 ?? 0)#\(model.previewRevision[item.id] ?? 0)#\(livePreviewsEnabled)"
    }

    private var videoKey: String {
        "\(item.id)#\(item.manifest.updated?.timeIntervalSince1970 ?? 0)#\(item.manifest.video?.file ?? "")#\(item.manifest.video?.fit.rawValue ?? "")"
    }

    private var videoURL: URL? {
        guard let file = item.manifest.video?.file else { return nil }
        return item.packageURL.appendingPathComponent(file)
    }

    /// `window.LIVEPAPER_CONFIG` for the runtime (see Runtime/runtime.js, "Configuration").
    private var runtimeConfig: [String: Any] {
        let power = PowerSource.current()
        var cfg: [String: Any] = [
            "performance": model.playlist.performance.rawValue,
            "power": power.onBattery ? "battery" : "ac",
            "lowPower": power.lowPower,
            "clock": showClock && quality == .full && model.playlist.showClock,
            "reducedMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            // lp.env.preview: scenes may simplify for the app's small, short-lived previews.
            "preview": true,
        ]
        if quality == .hover {
            cfg["fps"] = 30
            cfg["scale"] = 0.5
        }
        return cfg
    }

    private func compileIfNeeded() async {
        guard livePreviewsEnabled, item.manifest.kind == .web else { return }
        do {
            compiledHTML = try await model.previewHTML(for: item)
            compileError = nil
        } catch {
            compiledHTML = nil
            compileError = error.localizedDescription
            onError?(error.localizedDescription)
        }
    }
}

/// Power facts the runtime adapts to (lp.env).
enum PowerSource {
    static func current() -> (onBattery: Bool, lowPower: Bool) {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else {
            return (false, lowPower)
        }
        return (type == kIOPSBatteryPowerValue, lowPower)
    }
}

// MARK: - AppKit host

/// SwiftUI wrapper of the shared `LiveSceneHostView` (LiveSceneHost.swift).
private struct LivePreviewRepresentable: NSViewRepresentable {
    let content: LiveSceneContent
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> LiveSceneHostView {
        let view = LiveSceneHostView(content: content)
        view.setCornerRadius(cornerRadius)
        return view
    }

    func updateNSView(_ view: LiveSceneHostView, context: Context) {
        view.setCornerRadius(cornerRadius)
        if view.content.identity != content.identity { view.replace(content) }
    }

    static func dismantleNSView(_ view: LiveSceneHostView, coordinator: ()) {
        view.tearDown()
    }
}
