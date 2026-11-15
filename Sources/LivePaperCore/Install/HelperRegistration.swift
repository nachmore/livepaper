// HelperRegistration — how the LivePaperHelper login agent is (un)registered.
//
// Preferred: SMAppService.agent(plistName:), which needs the plist inside the running app bundle
// (Contents/Library/LaunchAgents/<label>.plist) and shows up in System Settings › Login Items.
// Fallback (unbundled builds, or SMAppService refusing for good): a plist in ~/Library/LaunchAgents
// loaded with `launchctl bootstrap gui/<uid>`. It uses its own label (`LaunchAgentPlist.label`):
// a login-item record is keyed by its label, so a plist sharing the login item's label would share
// — and fight over — its record (docs/RESEARCH.md §6).
import Foundation
import ServiceManagement

/// The SMAppService side, behind a protocol so tests never register a real login item (which
/// would also post a user-visible "background item added" notification).
public protocol LoginItemRegistering: Sendable {
    /// Whether the running process is an app bundle that embeds the agent plist.
    var isAvailable: Bool { get }
    var status: LoginItemStatus { get }
    func register() throws -> LoginItemStatus
    func unregister() throws
}

/// SMAppService.agent for the helper plist embedded in the app bundle.
public struct SMAppServiceAgent: LoginItemRegistering {
    public let plistName: String
    public let appBundle: URL

    public init(plistName: String = "\(LPPaths.helperLabel).plist", appBundle: URL = Bundle.main.bundleURL) {
        self.plistName = plistName; self.appBundle = appBundle
    }

    public var isAvailable: Bool {
        appBundle.pathExtension == "app"
            && FileManager.default.fileExists(atPath: appBundle.appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)").path)
    }

    public var status: LoginItemStatus {
        guard isAvailable else { return .notFound }
        return Self.map(SMAppService.agent(plistName: plistName).status)
    }

    public func register() throws -> LoginItemStatus {
        let service = SMAppService.agent(plistName: plistName)
        try service.register()
        return Self.map(service.status)
    }

    public func unregister() throws {
        try SMAppService.agent(plistName: plistName).unregister()
    }

    static func map(_ status: SMAppService.Status) -> LoginItemStatus {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .notRegistered
        }
    }
}

/// How InstallService treats an error from `LoginItemRegistering.register()`.
enum LoginItemRegistrationFailure: Equatable {
    /// kSMErrorAlreadyRegistered: the login item exists; the job may only need starting.
    case alreadyRegistered
    /// kSMErrorLaunchDeniedByUser: the user switched it off in System Settings › General › Login Items.
    case deniedByUser
    /// Anything else: SMAppService can't be used here.
    case other

    init(_ error: Error) {
        let error = error as NSError
        guard ["SMAppServiceErrorDomain", "kSMErrorDomainFramework"].contains(error.domain) else { self = .other; return }
        switch error.code {
        case Int(kSMErrorAlreadyRegistered): self = .alreadyRegistered
        case Int(kSMErrorLaunchDeniedByUser): self = .deniedByUser
        default: self = .other
        }
    }
}

/// The ~/Library/LaunchAgents fallback.
enum LaunchAgentPlist {
    /// The fallback job's label — deliberately not the login item's (see the file comment).
    static let label = "\(LPPaths.helperLabel).fallback"
    /// Before the fallback had its own label it used the login item's; such a plist is migrated away.
    static let legacyLabel = LPPaths.helperLabel

    /// Same job as the plist embedded for SMAppService: start at login, restart after a crash
    /// (but not after a clean exit, e.g. when the user quits it), only in the GUI session.
    static func contents(label: String, program: URL) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [program.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
