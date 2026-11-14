// IntegrationShims — temporary stand-ins for APIs other workstreams are adding in parallel.
//
// Each shim is compiled only while its compilation condition is undefined. Once the real API is in
// the tree, define the condition for the LivePaperApp target in Package.swift
// (`.define("LIVEPAPER_HAS_RENDERSERVER")`, `.define("LIVEPAPER_HAS_LIVE_SERVICES")`) or delete the
// shim; the call sites stay exactly as they are. If the real API lands and the condition is not
// defined, the build fails with an ambiguity error rather than silently using the shim.
import Foundation
import LivePaperCore
import LivePaperRenderKit

#if !LIVEPAPER_HAS_RENDERSERVER
extension LivePaperRenderKit {
    /// Stand-in for the in-process RenderService (WS-runtime).
    enum RenderServer {
        /// Without the embedded server, `RenderClient` starts the headless `LivePaperRenderd` on
        /// demand, so the app still works; it just costs one more process while rendering.
        static func startEmbeddedServer() throws {
            NSLog("LivePaper: the embedded render server isn't part of this build; renders will use LivePaperRenderd.")
        }
    }
}
#endif

#if !LIVEPAPER_HAS_LIVE_SERVICES
extension LivePaperServices {
    /// Stand-in for the concrete service wiring (WS-core). Throwing makes the app fall back to its
    /// sample library (in a temporary directory) and say so in a banner.
    static func live() throws -> LivePaperServices {
        throw NotImplemented("LivePaperServices.live()")
    }
}
#endif
