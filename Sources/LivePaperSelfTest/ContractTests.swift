// Contract tests for the shared models (owner: lead).
import Foundation
import LivePaperCore

extension SelfTests {
    static var contracts: [TestCase] { [
        TestCase(name: "contracts.manifest.roundtrip") {
            let m = SceneManifest(id: "aurora-lake", name: "Aurora Lake", kind: .web)
            let d = try SceneManifest.encoder().encode(m)
            let back = try SceneManifest.decoder().decode(SceneManifest.self, from: d)
            try expectEqual(back.id, "aurora-lake"); try expectEqual(back.runtime, 1)
        },
        TestCase(name: "contracts.manifest.tolerant") {
            let back = try SceneManifest.decoder().decode(SceneManifest.self, from: Data(#"{"id":"x"}"#.utf8))
            try expectEqual(back.name, "x"); try expectEqual(back.kind, .web); try expectEqual(back.clock.position, .top)
        },
        TestCase(name: "contracts.slug") {
            try expectEqual(SceneManifest.slug(from: "Aurora  Lake!"), "aurora-lake")
            try expect(SceneManifest.isValidID("a-1")); try expect(!SceneManifest.isValidID("-a")); try expect(!SceneManifest.isValidID("A"))
        },
        TestCase(name: "contracts.performance.automatic") {
            try expectEqual(LPPerformanceProfile.automatic.resolved(onBatteryOrLowPower: true), .init(fps: 30, scale: 0.75))
            try expectEqual(LPPerformanceProfile.automatic.resolved(onBatteryOrLowPower: false), .init(fps: 60, scale: 1))
        },
        TestCase(name: "contracts.hotkey.display") { try expectEqual(LPHotkey.controlCommandL.displayString, "⌃⌘L") },
    ] }
}
