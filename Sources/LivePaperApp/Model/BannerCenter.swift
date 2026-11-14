// BannerCenter — non-modal, in-window notifications with optional recovery actions.
//
// Errors in LivePaper never block the UI with alerts: they appear as banners at the top of the main
// window, each with the action most likely to fix the problem (Retry, Open Settings, …).
// Foundation + Observation only (also compiled into LivePaperSelfTest via AppLogic/).
import Foundation
import Observation

@MainActor
@Observable
final class BannerCenter {
    enum Style: Sendable { case info, success, warning, error }

    struct Action: Identifiable {
        let id = UUID()
        let title: String
        let perform: @MainActor () -> Void
    }

    struct Banner: Identifiable {
        let id = UUID()
        let style: Style
        let title: String
        let message: String?
        let actions: [Action]
        /// Info and success banners go away on their own; warnings and errors wait for the user.
        var autoDismissAfter: TimeInterval? {
            switch style {
            case .info, .success: return 6
            case .warning, .error: return nil
            }
        }
    }

    /// Newest last. Capped so a failure loop can't flood the window.
    private(set) var banners: [Banner] = []
    static let maxVisible = 4

    @discardableResult
    func post(_ style: Style, _ title: String, message: String? = nil, actions: [Action] = []) -> UUID {
        // Collapse exact repeats (e.g. the same publish error twice) into the latest one.
        banners.removeAll { $0.title == title && $0.message == message }
        let banner = Banner(style: style, title: title, message: message, actions: actions)
        banners.append(banner)
        if banners.count > BannerCenter.maxVisible { banners.removeFirst(banners.count - BannerCenter.maxVisible) }
        if let delay = banner.autoDismissAfter {
            let id = banner.id
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.dismiss(id)
            }
        }
        return banner.id
    }

    /// Posts an error banner; `retry` adds a "Try Again" action.
    func error(_ title: String, _ error: Error, retry: (@MainActor () -> Void)? = nil) {
        let actions = retry.map { [Action(title: "Try Again", perform: $0)] } ?? []
        post(.error, title, message: error.localizedDescription, actions: actions)
    }

    func dismiss(_ id: UUID) { banners.removeAll { $0.id == id } }
}
