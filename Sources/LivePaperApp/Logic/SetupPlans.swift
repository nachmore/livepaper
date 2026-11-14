// SetupPlans — onboarding checklist and uninstall plan, derived purely from InstallStatus and paths
// (Foundation-only; also compiled into LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/).
import Foundation
import LivePaperCore

// MARK: - Onboarding

/// The five onboarding pages. Every page is idempotent: it shows live status and only offers the
/// actions that are still needed, so re-running onboarding from Settings is always safe.
enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome, screenSaver, lock, lockKeys, firstScene
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .screenSaver: return "Screen saver"
        case .lock: return "Locking"
        case .lockKeys: return "Lock keys"
        case .firstScene: return "First scene"
        }
    }

    var symbolName: String {
        switch self {
        case .welcome: return "hand.wave"
        case .screenSaver: return "sparkles.tv"
        case .lock: return "lock"
        case .lockKeys: return "keyboard"
        case .firstScene: return "photo.on.rectangle"
        }
    }
}

/// One status row on an onboarding page (or in Settings).
struct SetupCheck: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case done
        case needed
        /// Nice to have; never blocks finishing onboarding.
        case optional
        /// Controlled by a configuration profile; the user can't change it here.
        case managed
    }
    enum ID: String, Sendable {
        case saverInstalled, saverSelected, helper, password, accessibility
    }
    let id: ID
    let title: String
    let detail: String
    let state: State
}

enum SetupChecklist {
    static func checks(for step: OnboardingStep, status s: InstallStatus) -> [SetupCheck] {
        switch step {
        case .welcome, .firstScene:
            return []
        case .screenSaver:
            return [
                SetupCheck(id: .saverInstalled, title: "LivePaper screen saver installed",
                           detail: s.saverInstalled
                               ? (s.saverUpToDate ? "Installed in your Screen Savers folder." : "Installed, but an update is available.")
                               : "Copies LivePaper.saver into ~/Library/Screen Savers.",
                           state: s.saverInstalled && s.saverUpToDate ? .done : .needed),
                SetupCheck(id: .saverSelected, title: "Selected as your screen saver",
                           detail: s.saverSelected ? "LivePaper plays when your Mac idles or locks."
                                                   : "Makes LivePaper the screen saver (your current choice is backed up).",
                           state: s.saverSelected ? .done : .needed),
            ]
        case .lock:
            let passwordState: SetupCheck.State = s.passwordImmediately ? .done : (s.managedByMDM ? .managed : .needed)
            let passwordDetail: String
            switch passwordState {
            case .done: passwordDetail = "Your Mac locks as soon as the screen saver starts."
            case .managed: passwordDetail = "Your organisation manages this setting, so LivePaper can't change it. Locking still works, but the scene may start before the password is required."
            default: passwordDetail = "In System Settings \u{203A} Lock Screen, set \u{201C}Require password after screen saver begins\u{201D} to Immediately."
            }
            return [
                SetupCheck(id: .helper, title: "LivePaper helper running",
                           detail: s.helperRunning ? "Provides the lock shortcut. It uses no CPU while idle."
                                                   : "A small login item that provides the lock shortcut.",
                           state: s.helperRunning ? .done : .needed),
                SetupCheck(id: .password, title: "Password required immediately", detail: passwordDetail, state: passwordState),
            ]
        case .lockKeys:
            return [
                SetupCheck(id: .accessibility, title: "Accessibility access (optional)",
                           detail: s.accessibilityTrusted
                               ? "LivePaper can take over \u{2303}\u{2318}Q and the lock key if you turn that on."
                               : "Only needed if you want \u{2303}\u{2318}Q or the lock key to show your scene.",
                           state: s.accessibilityTrusted ? .done : .optional),
            ]
        }
    }

    /// True when nothing on the page still needs the user's action.
    static func isComplete(_ step: OnboardingStep, status: InstallStatus) -> Bool {
        checks(for: step, status: status).allSatisfy { $0.state != .needed }
    }

    /// Where a re-run of onboarding should start: the first page that still needs something.
    static func firstIncompleteStep(status: InstallStatus) -> OnboardingStep {
        OnboardingStep.allCases.first { $0 != .welcome && !$0.isOptionalPage && !isComplete($0, status: status) } ?? .firstScene
    }

    /// Short line for the Settings › Screen saver status row.
    static func saverSummary(_ s: InstallStatus) -> String {
        if !s.saverInstalled { return "Not installed" }
        if !s.saverSelected { return "Installed, not selected" }
        if !s.saverUpToDate { return "Selected \u{2014} update available" }
        return "Active"
    }
}

private extension OnboardingStep {
    var isOptionalPage: Bool { self == .lockKeys || self == .firstScene }
}

// MARK: - Uninstall

/// Exactly what "Uninstall…" will do, listed in the confirmation sheet before anything happens.
struct UninstallPlan: Equatable, Sendable {
    struct Item: Identifiable, Equatable, Sendable {
        enum Action: String, Sendable { case remove, restore, keep }
        let id: String
        let action: Action
        /// A complete instruction ("Remove the LivePaper screen saver").
        let title: String
        /// A "~"-abbreviated path or short explanation.
        let detail: String
    }

    let items: [Item]

    /// - Parameters:
    ///   - keepScenes: the "Keep my scenes" checkbox.
    ///   - userSceneCount: shown next to the library row so the user knows what they'd lose.
    ///   - appBundlePath: the running .app, or nil when not running from a bundle (e.g. `swift run`).
    static func make(keepScenes: Bool, userSceneCount: Int, appBundlePath: String?,
                     home: String = NSHomeDirectory()) -> UninstallPlan {
        func short(_ url: URL) -> String { LPFormat.abbreviatingHome(url.path, home: home) }
        var items: [Item] = [
            Item(id: "helper", action: .remove, title: "Remove the LivePaper helper (login item)",
                 detail: "Stops it and removes \(LPPaths.helperLabel) from Login Items."),
            Item(id: "saver", action: .remove, title: "Remove the LivePaper screen saver", detail: short(LPPaths.installedSaver)),
            Item(id: "restore", action: .restore, title: "Restore your previous screen saver and settings",
                 detail: "From the backup taken at install (\(short(LPPaths.backups)))."),
        ]
        let scenes = userSceneCount == 1 ? "1 scene" : "\(userSceneCount) scenes"
        if keepScenes {
            items.append(Item(id: "library", action: .keep, title: "Keep your scenes (\(scenes))", detail: short(LPPaths.library)))
        } else {
            items.append(Item(id: "library", action: .remove, title: "Delete your scenes (\(scenes)) and AI workspaces",
                              detail: short(LPPaths.supportRoot)))
        }
        if let app = appBundlePath {
            items.append(Item(id: "app", action: .remove, title: "Move LivePaper.app to the Trash",
                              detail: LPFormat.abbreviatingHome(app, home: home)))
        }
        return UninstallPlan(items: items)
    }
}
