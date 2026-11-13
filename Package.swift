// swift-tools-version: 6.0
// LivePaper — builds with the Xcode Command Line Tools only (no Xcode project).
// `swift build` builds the Swift targets; scripts/build.sh assembles build/LivePaper.app (incl. the
// .saver, which is compiled separately with swiftc because SwiftPM can't emit MH_BUNDLE).
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "LivePaper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LivePaper", targets: ["LivePaperApp"]),
        .executable(name: "LivePaperHelper", targets: ["LivePaperHelper"]),
        .executable(name: "livepaper", targets: ["LivePaperCLI"]),
        .executable(name: "LivePaperRenderd", targets: ["LivePaperRenderd"]),
    ],
    targets: [
        // Foundation-only model + services shared by every component except the saver.
        .target(name: "LivePaperCore", swiftSettings: swift5),
        // Off-screen WebKit renderer + render socket server (AppKit/WebKit).
        .target(name: "LivePaperRenderKit", dependencies: ["LivePaperCore"], swiftSettings: swift5),
        .executableTarget(name: "LivePaperApp", dependencies: ["LivePaperCore", "LivePaperRenderKit"], swiftSettings: swift5),
        .executableTarget(name: "LivePaperHelper", dependencies: ["LivePaperCore"], swiftSettings: swift5),
        // The CLI must never link AppKit/WebKit (it runs inside AI agents' shells).
        .executableTarget(name: "LivePaperCLI", dependencies: ["LivePaperCore"], swiftSettings: swift5),
        .executableTarget(name: "LivePaperRenderd", dependencies: ["LivePaperCore", "LivePaperRenderKit"], swiftSettings: swift5),
        // XCTest/swift-testing aren't available with CLT only: `swift run LivePaperSelfTest`.
        .executableTarget(name: "LivePaperSelfTest", dependencies: ["LivePaperCore"], swiftSettings: swift5),
    ]
)
