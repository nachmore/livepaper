// Contract tests for the shared models and the cross-component contracts (state.json, notification
// names, playlist file types, runtime configuration keys) that no single component's tests can see.
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
        TestCase(name: "contracts.state.lock-settings") {
            // Today's shape round-trips; the hotkey stays optional (absent = no shortcut).
            let on = LPSharedState(lock: LPLockSettings(hotkey: .controlCommandQ, lockKeysShowScene: true))
            let back = try SceneManifest.decoder().decode(LPSharedState.self, from: SceneManifest.encoder().encode(on))
            try expectEqual(back, on)
            let json = try JSONSerialization.jsonObject(with: SceneManifest.encoder().encode(LPLockSettings(hotkey: nil))) as? [String: Any]
            // Both toggles are always written (the helper reads `showSceneBeforeDisplaySleep`, §4.4).
            try expectEqual(Set(json?.keys.map { $0 } ?? []), ["lockKeysShowScene", "showSceneBeforeDisplaySleep"])
            // state.json written before the single toggle (two flags for the same preference).
            func legacy(_ lock: String) throws -> LPLockSettings {
                try SceneManifest.decoder().decode(LPSharedState.self, from: Data(#"{"schema":1,"lock":\#(lock)}"#.utf8)).lock
            }
            try expectEqual(try legacy(#"{"hotkey":{"keyCode":37,"modifiers":["control","command"]},"takeOverSystemLock":true,"takeOverLockKey":false}"#),
                            LPLockSettings(hotkey: .controlCommandL, lockKeysShowScene: true))
            try expectEqual(try legacy(#"{"takeOverSystemLock":false,"takeOverLockKey":true}"#), LPLockSettings(hotkey: nil, lockKeysShowScene: true))
            try expectEqual(try legacy(#"{"takeOverSystemLock":false}"#), LPLockSettings(hotkey: nil, lockKeysShowScene: false))
            try expectEqual(try legacy(#"{"lockKeysShowScene":false,"takeOverSystemLock":true}"#).lockKeysShowScene, false)
            // …and before "show your scene when the screens turn off first": off.
            try expectEqual(try legacy(#"{"lockKeysShowScene":true}"#).showSceneBeforeDisplaySleep, false)
            let presleep = LPSharedState(lock: LPLockSettings(hotkey: nil, showSceneBeforeDisplaySleep: true))
            try expectEqual(try SceneManifest.decoder().decode(LPSharedState.self, from: SceneManifest.encoder().encode(presleep)), presleep)
        },
        TestCase(name: "contracts.notifications") {
            let names = [LPNotification.stateChanged, LPNotification.openApp, LPNotification.lockNow, LPNotification.lockNowAccepted,
                         LPNotification.lockRefused, LPNotification.hotkeyRecording, LPNotification.published]
            try expectEqual(Set(names).count, names.count)
            try expect(names.allSatisfy { $0.hasPrefix(LPPaths.bundleID + ".") })
            try expectEqual(LPNotification.requestIDKey, "requestID")
            try expectEqual(LPNotification.activeKey, "active")
        },
        TestCase(name: "contracts.playlist.extensions-match-saver") {
            // Publish rejects what the saver would silently skip; both must agree.
            try expectEqual(LPPlaylistEntry.webExtensions, SaverPlaylistLoader.webExtensions)
            try expectEqual(LPPlaylistEntry.videoExtensions, SaverPlaylistLoader.videoExtensions)
        },
        TestCase(name: "contracts.runtime.config-keys") {
            // applyConfig() silently ignores unknown keys, so every key a host injects into
            // window.LIVEPAPER_CONFIG must be one of runtime.js's TYPES.
            let runtime = try String(contentsOf: repositoryRoot.appendingPathComponent("Runtime/runtime.js"), encoding: .utf8)
            guard let start = runtime.range(of: "var TYPES = {"), let end = runtime[start.upperBound...].range(of: "};") else {
                throw TestFailure(description: "TYPES not found in runtime.js")
            }
            let known = Set(runtime[start.upperBound..<end.lowerBound].matches(of: #/([A-Za-z0-9]+)\s*:/#).map { String($0.output.1) })
            let saver = SaverWebConfig(showClock: true, clockPosition: .top, profile: .init(fps: 60, scale: 1), seed: 1,
                                       power: SaverPowerState(onBattery: false, lowPowerMode: false))
            let saverKeys = (try JSONSerialization.jsonObject(with: Data(saver.json.utf8)) as? [String: Any])?.keys.map { $0 } ?? []
            let hosts: [String: [String]] = [
                "saver": saverKeys + ["lockUI"],                                                        // + WebSceneHost's lockUI
                "app preview": ["performance", "power", "lowPower", "clock", "reducedMotion", "preview", "fps", "scale"],
                "render server": ["still", "t", "bench", "clock", "debug", "dprMax", "seed", "fps", "scale"],
            ]
            for (host, keys) in hosts {
                let unknown = Set(keys).subtracting(known)
                try expect(unknown.isEmpty, "\(host) injects keys runtime.js ignores: \(unknown.sorted())")
            }
            try expect(known.contains("lockUI") && known.contains("preview"))
            // A scene loaded while the lock UI is up starts with its clock hidden.
            try expect(runtime.contains("lockUIShowing = !!cfg.lockUI"), "runtime.js reads the initial lockUI")
            let host = try String(contentsOf: repositoryRoot.appendingPathComponent("Saver/WebSceneHost.swift"), encoding: .utf8)
            try expect(host.contains("LIVEPAPER_CONFIG.lockUI"), "the saver passes the initial lock-UI state")
        },
        TestCase(name: "contracts.install.status-defaults") {
            let s = InstallStatus()
            try expect(!s.lockKeysShowScene && !s.lockKeysChangedByLivePaper && s.helperLoginItem == .notRegistered)
            try expect(InstallStep(title: "x", outcome: .failed("y")).isFailure && !InstallStep(title: "x", outcome: .skipped("y")).isFailure)
            let r = PublishResult(playlist: LPPlaylist(), skipped: ["b": "2", "a": "1"])
            try expectEqual(r.skippedScenes, [.init(id: "a", reason: "1"), .init(id: "b", reason: "2")])
        },
    ] }

    /// The repository checkout this test binary was built from.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
