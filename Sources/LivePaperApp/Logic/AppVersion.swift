// AppVersion — how the app names its version in Settings › About. Foundation only (also compiled
// into LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/).
import Foundation

enum AppVersion {
    /// "0.1.0.195": the marketing version, then the build number (the commit count, scripts/build.sh),
    /// so two builds of the same version can be told apart. A beta keeps its suffix
    /// ("0.1.0-beta.2.195"); a missing or non-numeric build is left out; `swift run` shows "dev".
    static func display(short: String?, build: String?) -> String {
        let version = short?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "dev"
        guard let build = build?.trimmingCharacters(in: .whitespaces), !build.isEmpty, build.allSatisfy(\.isNumber),
              !version.hasSuffix(".\(build)") else { return version }
        return "\(version).\(build)"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
