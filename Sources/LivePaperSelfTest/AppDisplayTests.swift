// Self tests for the app's side of multiple displays (ARCHITECTURE §11, Screen Saver › Multiple
// displays): PlaylistDraft's display rules, the display identity shared with the saver, AppModel's
// connected displays, and what the mock publish makes of the display settings (it mirrors
// PublishService, whose own tests are core.publish.displays). Fake display ids only.
import CoreGraphics
import Foundation
import LivePaperCore

extension SelfTests {
    static let displayA1 = "00000000-0000-4000-8000-0000000000A1"
    static let displayA2 = "00000000-0000-4000-8000-0000000000A2"
    static let displayA3 = "00000000-0000-4000-8000-0000000000A3"

    static func testDisplay(_ id: String, _ name: String, x: Double = 0, y: Double = 0, width: Double = 1512, height: Double = 982,
                            builtin: Bool = false, menuBar: Bool = false) -> LPDisplay {
        LPDisplay(id: id, name: name, frame: LPRect(x: x, y: y, width: width, height: height), scale: 2,
                  isBuiltin: builtin, isMenuBar: menuBar)
    }

    static var appDisplays: [TestCase] { [
        TestCase(name: "app.playlist.displays.assign") {
            let a1 = testDisplay(displayA1.lowercased(), "Built-in Retina Display", builtin: true, menuBar: true)
            var d = PlaylistDraft(PlaylistSettings())
            try expectEqual(d.assignment(for: displayA1), nil)
            d.assign("aurora", to: a1)
            try expectEqual(d.assignment(for: displayA1.lowercased()), "aurora")   // any letter case
            try expectEqual(d.settings.displays.assignments, [displayA1: "aurora"])
            try expectEqual(d.settings.displayNames, [displayA1: "Built-in Retina Display"])
            try expectEqual(d.settings.displays.mode, .same)                      // assigning doesn't switch the mode
            // The same choice again changes nothing (no phantom "Unsaved changes").
            let before = d
            d.assign("aurora", to: a1)
            try expectEqual(d, before)
            // A display reporting no name keeps the remembered one.
            d.assign("beach", to: testDisplay(displayA1, ""))
            try expectEqual(d.assignment(for: displayA1), "beach")
            try expectEqual(d.settings.displayNames, [displayA1: "Built-in Retina Display"])
            // "Playlist" (nil) and blank ids remove the choice and its name.
            d.assign(nil, to: a1)
            try expectEqual(d.settings.displays.assignments, [:])
            try expectEqual(d.settings.displayNames, [:])
            d.assign("  ", to: a1)
            try expectEqual(d.settings.displays.assignments, [:])
            try expectEqual(d, PlaylistDraft(PlaylistSettings()))
        },
        TestCase(name: "app.playlist.displays.remembered-forget") {
            let a1 = testDisplay(displayA1, "Built-in"), a2 = testDisplay(displayA2, "Studio Display", x: 1512)
            let s = PlaylistSettings(displays: LPDisplaySettings(mode: .choose, assignments: [
                displayA1: "aurora", displayA3: "lanterns", "display-7": "beach"]), displayNames: [displayA3: "Office Monitor"])
            let d = PlaylistDraft(s)
            let remembered = d.rememberedDisplays(connected: [a1, a2])
            try expectEqual(remembered.map(\.name), ["Display 7", "Office Monitor"])   // by name; connected ones aren't listed
            try expectEqual(remembered.map(\.id), ["DISPLAY-7", displayA3])
            try expectEqual(remembered.map(\.sceneID), ["beach", "lanterns"])
            try expectEqual(d.rememberedDisplays(connected: []).count, 3)
            var e = d
            e.forgetDisplay(displayA3.lowercased())
            try expectEqual(e.settings.displays.assignments, [displayA1: "aurora", "DISPLAY-7": "beach"])
            try expectEqual(e.settings.displayNames, [:])
            try expectEqual(e.rememberedDisplays(connected: [a1, a2]).map(\.id), ["DISPLAY-7"])
            // Names for displays nobody named (an assignment from `livepaper publish --display`).
            try expectEqual(PlaylistDraft.fallbackDisplayName("37d8832a-2d66-02ca-b9f7-8f30a301b230"), "Display 37D8832A")
            try expectEqual(PlaylistDraft.fallbackDisplayName("display-5"), "Display 5")
            try expectEqual(d.displayName(for: displayA3.lowercased()), "Office Monitor")
            try expectEqual(d.displayName(for: displayA2), "Display 00000000")
        },
        TestCase(name: "app.playlist.displays.name-pruning") {
            // Names are kept only for assigned displays, keyed like the assignments.
            var d = PlaylistDraft(PlaylistSettings(displays: LPDisplaySettings(mode: .choose, assignments: [displayA1: "aurora"]),
                                                   displayNames: [displayA1.lowercased(): "Built-in", displayA2: "Stale"]))
            d.assign("beach", to: testDisplay(displayA3, "Office Monitor"))
            try expectEqual(d.settings.displayNames, [displayA1: "Built-in", displayA3: "Office Monitor"])
            d.forgetDisplay(displayA1)
            try expectEqual(d.settings.displayNames, [displayA3: "Office Monitor"])
            d.assign(nil, to: testDisplay(displayA3, "Office Monitor"))
            try expectEqual(d.settings.displayNames, [:])
        },
        TestCase(name: "app.playlist.displays.effective") {
            let available = ["aurora", "beach"]
            var s = PlaylistSettings(displays: LPDisplaySettings(assignments: [displayA1: "aurora", displayA2: "gone"]))
            for mode in [LPDisplayMode.same, .different, .span] {
                s.displays.mode = mode
                try expectEqual(PlaylistDraft(s).effectiveAssignments(available: available), [:])   // only "Choose" publishes them
            }
            s.displays.mode = .choose
            try expectEqual(PlaylistDraft(s).effectiveAssignments(available: available), [displayA1: "aurora"])   // a deleted scene plays the playlist
            try expectEqual(PlaylistDraft(s).effectiveAssignments(available: []), [:])
            // Display settings leave the deck alone.
            try expectEqual(PlaylistDraft(s).effectiveSceneIDs(available: available), available)
        },
        TestCase(name: "app.playlist.displays.span-support") {
            let m: [String: SceneManifest] = [
                "web": SceneManifest(id: "web", name: "Web", kind: .web),
                "web-span": SceneManifest(id: "web-span", name: "Web span", kind: .web, span: true),
                "web-no": SceneManifest(id: "web-no", name: "Web no", kind: .web, span: false),
                "video": SceneManifest(id: "video", name: "Video", kind: .video, video: .init(file: "v.mov")),
                "video-no": SceneManifest(id: "video-no", name: "Video no", kind: .video, video: .init(file: "v.mov"), span: false),
            ]
            let r = PlaylistDraft.spanSupport(ids: ["web-span", "web", "video", "video-no", "gone", "web-no"], manifests: m)
            try expectEqual(r.spanning, ["web-span", "video"])
            try expectEqual(r.notSpanning, ["web", "video-no", "web-no"])
            try expectEqual(PlaylistDraft.spanSupportSummary(spanning: 3, total: 5), "3 of 5 scenes can span; the others show on every display.")
            try expectEqual(PlaylistDraft.spanSupportSummary(spanning: 2, total: 2), "All 2 scenes can span.")
            try expectEqual(PlaylistDraft.spanSupportSummary(spanning: 1, total: 1), "This scene can span.")
            try expectEqual(PlaylistDraft.spanSupportSummary(spanning: 0, total: 1), "This scene can\u{2019}t span, so it shows on every display.")
            try expectEqual(PlaylistDraft.spanSupportSummary(spanning: 0, total: 3), "None of these scenes can span, so they show on every display.")
            try expectEqual(PlaylistDraft.spanSupportSummary(spanning: 0, total: 0), "")
            // The mock library's built-ins span, like the real ones; videos do by default.
            let samples = Dictionary(MockSampleData.samples().map { ($0.manifest.id, $0.manifest) }, uniquingKeysWith: { a, _ in a })
            let all = PlaylistDraft.spanSupport(ids: MockSampleData.samples().map(\.manifest.id), manifests: samples)
            try expectEqual(all.spanning.sorted(), ["aurora-lake", "coastline-at-dusk", "drifting-dunes", "morning-fog", "orbiting-garden"])
        },
        TestCase(name: "app.playlist.displays.summary") {
            let names = ["a": "Aurora", "b": "Beach"], available = ["a", "b"]
            let a1 = testDisplay(displayA1, "Built-in", builtin: true, menuBar: true), a2 = testDisplay(displayA2, "Studio", x: 1512)
            let two = LPDisplayLayout([a1, a2]), one = LPDisplayLayout([a1]), onlyA2 = LPDisplayLayout([a2])
            func summary(_ mode: LPDisplayMode, _ assignments: [String: String] = [:], on layout: LPDisplayLayout?,
                         playlist: LPPlaylistMode = .shuffle, ids: [String] = []) -> String {
                PlaylistDraft.summary(PlaylistSettings(mode: playlist, sceneIDs: ids,
                                                       displays: LPDisplaySettings(mode: mode, assignments: assignments)),
                                      available: available, names: names, displays: layout)
            }
            let base = "Shuffle \u{00B7} all 2 scenes \u{00B7} every 5 minutes"
            for layout in [two, one, nil] { try expectEqual(summary(.same, on: layout), base) }
            try expectEqual(summary(.different, on: two), base + " \u{00B7} different on each display")
            try expectEqual(summary(.different, on: nil), base + " \u{00B7} different on each display")
            try expectEqual(summary(.different, on: one), base)                                    // needs two displays
            try expectEqual(summary(.span, on: two), base + " \u{00B7} spanning all displays")
            try expectEqual(summary(.span, on: one), base)
            try expectEqual(summary(.choose, [displayA1: "a"], on: two), base + " \u{00B7} chosen per display")
            try expectEqual(summary(.choose, [displayA1: "a"], on: one), base + " \u{00B7} chosen per display")   // applies to one display too
            try expectEqual(summary(.choose, [displayA1: "a"], on: onlyA2), base)                  // that display isn't connected
            try expectEqual(summary(.choose, [displayA1: "gone"], on: two), base)                  // deleted: it plays the playlist
            try expectEqual(summary(.choose, [:], on: two), base)
            try expectEqual(summary(.choose, [displayA1: "a"], on: nil), base + " \u{00B7} chosen per display")
            // One scene: "Different" can't differ; spanning still shows.
            try expectEqual(summary(.different, on: two, playlist: .single, ids: ["b"]), "Beach")
            try expectEqual(summary(.span, on: two, playlist: .single, ids: ["b"]), "Beach \u{00B7} spanning all displays")
            try expectEqual(PlaylistDraft.summary(PlaylistSettings(displays: LPDisplaySettings(mode: .span)), available: [], names: [:],
                                                  displays: two), "No scenes yet")
        },
        TestCase(name: "app.playlist.displays.titles") {
            try expectEqual(LPDisplayMode.allCases.map(\.uiTitle),
                            ["Same on every display", "Different on each display", "Choose per display", "Span across displays"])
            try expectEqual(LPDisplayMode.same.uiExplanation, "Every display shows the same scene.")
            try expectEqual(LPDisplayMode.choose.uiExplanation, "Pick a scene for each display. Displays without a choice play the playlist.")
            try expect(LPDisplayMode.span.uiExplanation.contains("System Settings \u{203A} Displays"))
            try expectEqual(Set(LPDisplayMode.allCases.map(\.uiExplanation)).count, LPDisplayMode.allCases.count)
            try expectEqual(LPBatteryDisplays.allCases.map(\.uiTitle), ["The scene", "A still picture", "Nothing (black)"])
        },
        TestCase(name: "app.displays.identity") {
            // The keys the app shows and stores are the saver's: the UUID uppercased, else DISPLAY-<id>.
            var count: UInt32 = 0
            _ = CGGetActiveDisplayList(0, nil, &count)
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            _ = CGGetActiveDisplayList(count, &ids, &count)
            for id in ids.prefix(Int(count)) {
                let key = DisplayIdentity.key(for: id)
                try expectEqual(key, LPDisplay.normalizedID(key))
                try expect(UUID(uuidString: key) != nil || key == LPDisplay.fallbackID(id), key)
                try expectEqual(DisplayIdentity.key(for: id), key)
            }
            // NSScreen frames (Cocoa, y up) become the saver's top-left frames.
            let menuBar = DisplayIdentity.display(id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                                  menuBarScreenHeight: 982, scale: 2, isMenuBar: true, isBuiltin: true)
            try expectEqual(menuBar.frame, LPRect(x: 0, y: 0, width: 1512, height: 982))
            try expectEqual(menuBar.id, DisplayIdentity.key(for: 1))
            let aboveLeft = DisplayIdentity.display(id: 2, name: "Studio", frame: CGRect(x: -500, y: 982, width: 2560, height: 1440),
                                                    menuBarScreenHeight: 982, scale: 1, isMenuBar: false, isBuiltin: false)
            try expectEqual(aboveLeft.frame, LPRect(x: -500, y: -1440, width: 2560, height: 1440))
            try expectEqual(aboveLeft, LPDisplay.cocoa(id: DisplayIdentity.key(for: 2), name: "Studio", x: -500, y: 982, width: 2560,
                                                       height: 1440, menuBarScreenHeight: 982, scale: 1))
            let below = DisplayIdentity.display(id: 3, name: "TV", frame: CGRect(x: 200, y: -1080, width: 1920, height: 1080),
                                                menuBarScreenHeight: 982, scale: 1, isMenuBar: false, isBuiltin: false)
            try expectEqual(below.frame, LPRect(x: 200, y: 982, width: 1920, height: 1080))
            // Laid out like the saver: left to right, the built-in display is main.
            let layout = LPDisplayLayout([below, menuBar, aboveLeft])
            try expectEqual(layout.displays.map(\.name), ["Studio", "Built-in", "TV"])
            try expectEqual(layout.main?.name, "Built-in")
        },
    ] }

    // MARK: - AppModel

    /// What a test pretends is connected (AppEnvironment.connectedDisplays / observeDisplays).
    @MainActor final class DisplaySource {
        var displays: [LPDisplay]
        private(set) var observers = 0
        private(set) var cancels = 0
        private var handler: (@MainActor () -> Void)?
        init(_ displays: [LPDisplay]) { self.displays = displays }

        func observe(_ handler: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) {
            observers += 1
            self.handler = handler
            return { [weak self] in
                self?.cancels += 1
                self?.handler = nil
            }
        }

        func fire() { handler?() }
    }

    /// A started AppModel over fresh mock services whose environment reports `displays`.
    static func withDisplayModel(_ name: String, displays: [LPDisplay],
                                 _ body: @MainActor (AppModel, ModelFixture, DisplaySource) throws -> Void) throws {
        try withScratchPaths(name) { root in
            let services = try MockServices.make(root: root.appendingPathComponent("Mock"), pace: 0)
            let saved = SavedStates()
            let fx = ModelFixture(services: services, saved: saved, root: root)
            try MainActor.assumeIsolated {
                let source = DisplaySource(displays)
                var env = testEnvironment(root: root, saved: saved)
                env.connectedDisplays = { source.displays }
                env.observeDisplays = { source.observe($0) }
                let model = AppModel(services: services, environment: env)
                try awaitMain { await model.start() }
                try body(model, fx, source)
            }
        }
    }

    static var appModelDisplays: [TestCase] { [
        TestCase(name: "app.model.displays") {
            let laptop = testDisplay(displayA1, "Built-in Retina Display", builtin: true, menuBar: true)
            let studio = testDisplay(displayA2, "Studio Display", x: 1512, y: -229, width: 2560, height: 1440)
            try withDisplayModel("displays", displays: [studio, laptop]) { model, _, source in
                try expectEqual(model.displays.displays.map(\.id), [displayA1, displayA2])   // the saver's order
                try expectEqual(model.displays.main?.id, displayA1)
                try expectEqual(source.observers, 1)
                source.displays = [laptop]
                try expectEqual(model.displays.count, 2)          // nothing changes until a change is reported
                source.fire()
                try expectEqual(model.displays.displays.map(\.id), [displayA1])
                source.displays = [laptop, studio]
                source.fire()
                try expectEqual(model.displays.count, 2)
                // Starting again neither observes twice nor loses the displays.
                try awaitMain { await model.start() }
                try expectEqual(source.observers, 1)
                try expectEqual(source.cancels, 0)
                try expectEqual(model.displays.count, 2)
                // The summary knows how many displays there are.
                var s = model.playlist
                s.displays.mode = .different
                try awaitMain { _ = await model.savePlaylist(s, announce: false, publishNow: false) }
                try expect(model.playlistSummary.hasSuffix(" \u{00B7} different on each display"), model.playlistSummary)
                source.displays = [laptop]
                source.fire()
                try expect(!model.playlistSummary.contains("display"), model.playlistSummary)
            }
            // Without display information (tests, a probe that found nothing) the summary is unchanged.
            try withModel("displays-none") { model, _ in
                try expectEqual(model.displays.count, 0)
                try expectEqual(model.playlistSummary, "Shuffle \u{00B7} all 9 scenes \u{00B7} every 5 minutes")
            }
        },
        TestCase(name: "app.model.displays-publish") {
            try withDisplayModel("displays-publish", displays: MockSampleData.defaultDisplays) { model, fx, _ in
                let publish = try unwrap(fx.services.publish as? MockPublishService)
                try fx.services.install.installSaver()
                publish.simulatedSkips = ["tidal-glass": "tidal-glass: scene.js has a syntax error on line 3."]
                var s = PlaylistSettings(mode: .sequence, sceneIDs: ["aurora-lake", "coastline-at-dusk", "neon-rain"])
                s.displays = LPDisplaySettings(mode: .choose, assignments: [
                    displayA1: "neon-rain",                               // in the playlist
                    displayA2: "paper-lanterns",                          // a library scene outside it
                    displayA3: "paper-lanterns",                          // … staged once for both
                    "00000000-0000-4000-8000-0000000000A4": "gone",       // deleted: dropped
                    "00000000-0000-4000-8000-0000000000A5": "tidal-glass", // can't be published: reported, dropped
                ], onBattery: .still)
                var ok = false
                try awaitMain { ok = await model.savePlaylist(s) }
                try expect(ok)
                var published = try unwrap(model.lastPublished)
                try expectEqual(published.scenes.map(\.id), ["aurora-lake", "coastline-at-dusk", "neon-rain"])
                try expectEqual(published.displays, LPDisplaySettings(mode: .choose, assignments: [
                    displayA1: "neon-rain", displayA2: "paper-lanterns", displayA3: "paper-lanterns"], onBattery: .still))
                try expectEqual(published.displayScenes.map(\.id), ["paper-lanterns"])
                try expectEqual(model.lastPublishResult?.skipped.keys.sorted(), ["tidal-glass"])
                // The built-in web scene and the video span; the user's web scenes don't.
                try expectEqual(published.scenes.map(\.span), [true, true, false])
                try expectEqual(published.displayScenes.map(\.span), [false])
                // Display-only scenes count as published.
                let banner = try unwrap(model.banners.banners.last)
                try expect(banner.message?.hasPrefix("4 scenes published.") == true, banner.message ?? "")
                // The settings keep every choice, also those the publish couldn't use.
                try expectEqual(model.playlist, s)
                try expectEqual(fx.services.publish.loadSettings(), s)
                try expect(model.isShownBySaver("paper-lanterns") && !model.isInPlaylist("paper-lanterns"))

                // Other modes publish no assignments and no display-only scenes; mode and battery always.
                s.displays.mode = .different
                s.displays.onBattery = .off
                try awaitMain { ok = await model.savePlaylist(s, announce: false) }
                try expect(ok)
                published = try unwrap(model.lastPublished)
                try expectEqual(published.displays, LPDisplaySettings(mode: .different, onBattery: .off))
                try expectEqual(published.displayScenes, [])
                try expect(!model.isShownBySaver("paper-lanterns"))
                try expectEqual(model.playlist.displays.assignments.count, 5)   // kept for when "Choose" is back
            }
        },
        TestCase(name: "app.model.settings-round-trip-displays") {
            try withDisplayModel("settings-displays", displays: []) { model, fx, _ in
                var s = PlaylistSettings(mode: .shuffle, cycleMinutes: 10)
                s.displays = LPDisplaySettings(mode: .span, assignments: [displayA1: "aurora-lake"], onBattery: .off)
                s.displayNames = [displayA1: "Built-in Retina Display"]
                var ok = false
                try awaitMain { ok = await model.savePlaylist(s, announce: false, publishNow: false) }
                try expect(ok)
                try expectEqual(fx.services.publish.loadSettings(), s)
                // Another model (the next launch) reads them back.
                let next = AppModel(services: fx.services, environment: testEnvironment(root: fx.root, saved: SavedStates()))
                try awaitMain { await next.loadPlaylist() }
                try expectEqual(next.playlist, s)
                // A file from before display settings keeps everything else and gets the defaults.
                let url = fx.root.appendingPathComponent("Mock/playlist-settings.json")
                try Data(#"{"mode":"sequence","cycleMinutes":2,"showClock":false,"performance":"battery","sceneIDs":["ink-bloom"]}"#.utf8)
                    .write(to: url)
                try awaitMain { await next.loadPlaylist() }
                try expectEqual(next.playlist, PlaylistSettings(mode: .sequence, cycleMinutes: 2, showClock: false,
                                                                performance: .battery, sceneIDs: ["ink-bloom"]))
                try expectEqual(next.playlist.displays, .standard)
                // A malformed display block doesn't cost the rest of the playlist.
                try Data(#"{"mode":"single","sceneIDs":["ink-bloom"],"displays":{"mode":"mirror","assignments":7},"displayNames":3}"#.utf8)
                    .write(to: url)
                try awaitMain { await next.loadPlaylist() }
                try expectEqual(next.playlist.mode, .single)
                try expectEqual(next.playlist.sceneIDs, ["ink-bloom"])
                try expectEqual(next.playlist.displays, .standard)
                try expectEqual(next.playlist.displayNames, [:])
            }
        },
        TestCase(name: "app.model.delete-assigned-scene") {
            try withDisplayModel("delete-assigned", displays: MockSampleData.defaultDisplays) { model, fx, _ in
                try fx.services.install.installSaver()
                try awaitMain { await model.refreshInstallStatus() }
                var s = PlaylistSettings(mode: .sequence, sceneIDs: ["aurora-lake", "neon-rain"])
                s.displays = LPDisplaySettings(mode: .choose, assignments: [displayA2: "ink-bloom"])
                try awaitMain { _ = await model.savePlaylist(s, announce: false) }
                try expectEqual(model.lastPublished?.displays.assignments, [displayA2: "ink-bloom"])
                try expect(model.isShownBySaver("ink-bloom"))
                // Deleting a scene the saver doesn't have publishes nothing.
                var generation = try unwrap(model.lastPublished?.generation)
                try awaitMain { await model.delete("tidal-glass") }
                try expectEqual(model.lastPublished?.generation, generation)
                // Deleting the chosen one publishes again without it; the choice stays (shown as deleted).
                try awaitMain { await model.delete("ink-bloom") }
                generation += 1
                try expectEqual(model.lastPublished?.generation, generation)
                try expectEqual(model.lastPublished?.displays.assignments, [:])
                try expectEqual(model.lastPublished?.displayScenes, [])
                try expectEqual(model.playlist.displays.assignments, [displayA2: "ink-bloom"])
                try expect(!model.isShownBySaver("ink-bloom"))
            }
        },
    ] }
}
