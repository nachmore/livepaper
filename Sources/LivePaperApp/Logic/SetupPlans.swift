// SetupPlans — onboarding checklist and uninstall plan, derived purely from setup state and paths
// (Foundation-only; also compiled into LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/).
import Foundation
import LivePaperCore

// MARK: - Onboarding

/// What setup looks at: InstallServicing's status (which includes the lock keys).
struct SetupState: Equatable, Sendable {
    var install: InstallStatus

    init(install: InstallStatus = InstallStatus()) {
        self.install = install
    }

    /// `immediateLockLaunchesScreenSaver` is on: ⌃⌘Q, Apple menu › Lock Screen and the lock key
    /// start the scene before locking.
    var lockKeysShowScene: Bool { install.lockKeysShowScene }

    /// The helper is registered as a login item but macOS waits for the user to allow it.
    var helperNeedsApproval: Bool { !install.helperRunning && install.helperLoginItem == .requiresApproval }
}

/// The onboarding pages. Every page is idempotent: it shows live status and only offers the
/// actions that are still needed, so re-running onboarding from Settings is always safe.
enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome, screenSaver, lock, firstScene
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .screenSaver: return "Screen saver"
        case .lock: return "Locking"
        case .firstScene: return "First scene"
        }
    }

    var symbolName: String {
        switch self {
        case .welcome: return "hand.wave"
        case .screenSaver: return "sparkles.tv"
        case .lock: return "lock"
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
        case saverInstalled, saverSelected, lockKeys, password, helper
    }
    let id: ID
    let title: String
    let detail: String
    let state: State
}

enum SetupChecklist {
    static func checks(for step: OnboardingStep, state: SetupState) -> [SetupCheck] {
        let s = state.install
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
                SetupCheck(id: .lockKeys, title: "Your lock keys show the scene",
                           detail: state.lockKeysShowScene
                               ? "\u{2303}\u{2318}Q, Apple menu \u{203A} Lock Screen and the lock key start your scene, then lock."
                               : "Makes \u{2303}\u{2318}Q, Apple menu \u{203A} Lock Screen and the lock key start your scene before locking. No permissions needed.",
                           state: state.lockKeysShowScene ? .done : .needed),
                SetupCheck(id: .password, title: "Password required immediately", detail: passwordDetail, state: passwordState),
                SetupCheck(id: .helper, title: state.helperNeedsApproval ? "LivePaper helper waiting for approval" : "LivePaper helper running",
                           detail: s.helperRunning
                               ? "Adds your own lock shortcut and opens LivePaper from the screen saver. Uses no CPU while idle."
                               : state.helperNeedsApproval
                                   ? "Allow LivePaper in System Settings \u{203A} General \u{203A} Login Items."
                                   : "A small login item for your own lock shortcut and the screen saver's \u{201C}Open LivePaper\u{201D} button.",
                           state: s.helperRunning ? .done : .needed),
            ]
        }
    }

    /// True when nothing on the page still needs the user's action.
    static func isComplete(_ step: OnboardingStep, state: SetupState) -> Bool {
        checks(for: step, state: state).allSatisfy { $0.state != .needed }
    }

    /// Where a re-run of onboarding should start: the first page that still needs something.
    static func firstIncompleteStep(state: SetupState) -> OnboardingStep {
        OnboardingStep.allCases.first { $0 != .welcome && $0 != .firstScene && !isComplete($0, state: state) } ?? .firstScene
    }

    /// Short line for the Settings › Screen saver status row.
    static func saverSummary(_ s: InstallStatus) -> String {
        if !s.saverInstalled { return "Not installed" }
        if !s.saverSelected { return "Installed, not selected" }
        if !s.saverUpToDate { return "Selected \u{2014} update available" }
        return "Active"
    }
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
    ///   - restoresLockKeys: LivePaper changed what the lock keys do (`InstallStatus.lockKeysChangedByLivePaper`).
    ///   - appBundlePath: the running .app, or nil when not running from a bundle (e.g. `swift run`).
    static func make(keepScenes: Bool, userSceneCount: Int, restoresLockKeys: Bool, appBundlePath: String?,
                     home: String = NSHomeDirectory()) -> UninstallPlan {
        func short(_ url: URL) -> String { LPFormat.abbreviatingHome(url.path, home: home) }
        var items: [Item] = [
            Item(id: "helper", action: .remove, title: "Remove the LivePaper helper (login item)",
                 detail: "Stops it and removes \(LPPaths.helperLabel) from Login Items."),
            Item(id: "saver", action: .remove, title: "Remove the LivePaper screen saver", detail: short(LPPaths.installedSaver)),
            Item(id: "restore", action: .restore, title: "Restore your previous screen saver and settings",
                 detail: "From the backup taken at install (\(short(LPPaths.backups)))."),
        ]
        if restoresLockKeys {
            items.append(Item(id: "lock-keys", action: .restore, title: "Restore what \u{2303}\u{2318}Q and the lock key do",
                              detail: "They work as they did before LivePaper changed them."))
        }
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

/// The uninstall step log (InstallServicing.performUninstall) as the sheet shows it.
struct UninstallReport: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        enum State: Equatable, Sendable { case done, skipped, failed, planned }
        let id: Int
        /// The step, with the home folder shown as "~".
        let title: String
        /// Why it was skipped or failed.
        let detail: String?
        let state: State
    }

    let rows: [Row]

    var failures: [Row] { rows.filter { $0.state == .failed } }
    var succeeded: Bool { failures.isEmpty }

    static func make(_ steps: [InstallStep], home: String = NSHomeDirectory()) -> UninstallReport {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        let rows = steps.enumerated().map { i, step -> Row in
            let title = step.title.replacingOccurrences(of: prefix, with: "~/")
            switch step.outcome {
            case .done: return Row(id: i, title: title, detail: nil, state: .done)
            case .planned: return Row(id: i, title: title, detail: nil, state: .planned)
            case .skipped(let why): return Row(id: i, title: title, detail: "Nothing to do: \(why).", state: .skipped)
            case .failed(let why): return Row(id: i, title: title, detail: why, state: .failed)
            }
        }
        return UninstallReport(rows: rows)
    }

    /// One line above the log.
    var summary: String {
        let n = failures.count
        if n == 0 { return "LivePaper was removed and your previous settings are back." }
        return (n == 1 ? "1 step" : "\(n) steps") + " didn\u{2019}t finish. Fix the problem below if you can, then try again \u{2014} finished steps are skipped."
    }
}
