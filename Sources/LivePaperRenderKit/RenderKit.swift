// LivePaperRenderKit — off-screen WebKit renderer + render socket server (ARCHITECTURE §8).
//
//   RenderServer.swift      socket server: accept loop, request queue, server lock, App Nap guard
//   SceneRenderer.swift     the ops (still, bench, live, thumbnail) on one reusable off-screen window
//   RenderPage.swift        one WKWebView page load with the runtime's ready/error messages
//   ProcessEnergy.swift     CPU time + energy of the WebKit processes this process owns
//   Bitmap.swift            exact-size RGBA bitmaps, luminance, PNG/JPEG output
import Foundation

/// Namespace of the render kit. `RenderServer` lives inside it so both `LivePaperRenderKit.RenderServer`
/// and plain `RenderServer` (typealias below) work: the enum shares the module's name, so a
/// top-level class could not be reached as `LivePaperRenderKit.RenderServer`.
public enum LivePaperRenderKit {
    public static let version = "0.1.0"
}

public typealias RenderServer = LivePaperRenderKit.RenderServer
