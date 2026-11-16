// Self tests for multiple displays: the playlist and settings schema (back-compat both ways), scene
// manifests' "span", and the display layout (keys, order, main display, the virtual canvas).
// The publish side is in CoreTests.swift (core.publish.displays), the saver's in SaverTests.swift.
import Foundation
import LivePaperCore

/// Today's (pre-multi-display) playlist.json reader, frozen: an old saver decoding a new file.
private struct LegacyPlaylist: Codable, Equatable {
    struct Entry: Codable, Equatable {
        enum Kind: String, Codable { case web, video }
        var id: String, name: String, kind: Kind, file: String, clock: LPClockPosition, fit: LPVideoFit?
    }
    var schema: Int, generation: Int, mode: LPPlaylistMode, cycleMinutes: Int, showClock: Bool
    var performance: LPPerformanceProfile, scenes: [Entry]
}

/// Today's (pre-multi-display) playlist-settings.json reader, frozen: an old app or CLI.
private struct LegacySettings: Codable, Equatable {
    var mode: LPPlaylistMode, cycleMinutes: Int, showClock: Bool, performance: LPPerformanceProfile, sceneIDs: [String]
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private let uuidA = "00000000-0000-4000-8000-0000000000A1"
private let uuidB = "00000000-0000-4000-8000-0000000000A2"
private let uuidC = "00000000-0000-4000-8000-0000000000A3"
private let uuidD = "00000000-0000-4000-8000-0000000000A4"

/// A playlist.json written by LivePaper before display modes.
let legacyPlaylistJSON = """
{ "schema": 1, "generation": 42, "mode": "shuffle", "cycleMinutes": 5, "showClock": true, "performance": "automatic",
  "scenes": [ { "id": "aurora-lake", "name": "Aurora Lake", "kind": "web", "file": "aurora-lake.html", "clock": "top" },
              { "id": "beach", "name": "Beach", "kind": "video", "file": "beach.mov", "fit": "fill", "clock": "top" } ] }
"""

/// The architecture document's example of a new playlist.json.
let newPlaylistJSON = """
{ "schema": 1, "generation": 43, "mode": "shuffle", "cycleMinutes": 5, "showClock": true, "performance": "automatic",
  "displays": { "mode": "choose", "assignments": { "\(uuidA)": "ringed-giant" }, "onBattery": "still" },
  "displayScenes": [ { "id": "ringed-giant", "name": "Ringed Giant", "kind": "web", "file": "ringed-giant.html", "clock": "top", "span": true } ],
  "scenes": [ { "id": "aurora-lake", "name": "Aurora Lake", "kind": "web", "file": "aurora-lake.html", "clock": "top", "span": true },
              { "id": "beach", "name": "Beach", "kind": "video", "file": "beach.mov", "fit": "fill", "clock": "top", "span": true } ] }
"""

/// A display at a top-left global frame.
private func display(_ id: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, scale: Double = 2,
                     builtin: Bool = false, menuBar: Bool = false) -> LPDisplay {
    LPDisplay(id: id, name: id, frame: LPRect(x: x, y: y, width: w, height: h), scale: scale, isBuiltin: builtin, isMenuBar: menuBar)
}

extension SelfTests {
    static var coreDisplays: [TestCase] { [
        // MARK: playlist.json
        TestCase(name: "core.playlist.displays.oldFileDefaults") {
            let p = try decode(LPPlaylist.self, legacyPlaylistJSON)
            try expectEqual(p.generation, 42)
            try expectEqual(p.displays, .standard)
            try expectEqual(p.displays.mode, .same); try expectEqual(p.displays.onBattery, .live)
            try expect(p.displays.assignments.isEmpty)
            try expectEqual(p.displayScenes, [])
            try expectEqual(p.scenes.map(\.span), [nil, nil])
            try expectEqual(p.scenes.map(\.id), ["aurora-lake", "beach"])
            // The seven original keys stay required: an unreadable playlist still means "the fallback".
            for key in ["schema", "generation", "mode", "cycleMinutes", "showClock", "performance", "scenes"] {
                var obj = try JSONSerialization.jsonObject(with: Data(legacyPlaylistJSON.utf8)) as! [String: Any]
                obj.removeValue(forKey: key)
                let data = try JSONSerialization.data(withJSONObject: obj)
                try expect((try? JSONDecoder().decode(LPPlaylist.self, from: data)) == nil, "missing \(key) must not decode")
            }
        },
        TestCase(name: "core.playlist.displays.roundTrip") {
            let p = try decode(LPPlaylist.self, newPlaylistJSON)
            try expectEqual(p.displays, LPDisplaySettings(mode: .choose, assignments: [uuidA: "ringed-giant"], onBattery: .still))
            try expectEqual(p.displayScenes.map(\.id), ["ringed-giant"])
            try expectEqual(p.displayScenes.first?.span, true)
            try expectEqual(p.scenes.map(\.span), [true, true])
            let dir = try tempDir("playlist-displays")
            defer { try? FileManager.default.removeItem(at: dir) }
            try p.write(to: dir)
            try expectEqual(try LPPlaylist.load(from: dir), p)
            // Defaults are written too, so a newer reader never has to guess.
            let standard = LPPlaylist(generation: 1, scenes: p.scenes)
            try standard.write(to: dir)
            let text = try String(contentsOf: dir.appendingPathComponent(LPPlaylist.fileName), encoding: .utf8)
            try expect(text.contains("\"displays\"") && text.contains("\"displayScenes\"") && text.contains("\"same\""), text)
            try expectEqual(try LPPlaylist.load(from: dir), standard)
        },
        TestCase(name: "core.playlist.displays.tolerant") {
            func with(_ displays: String, scenes: String = "[]") throws -> LPPlaylist {
                try decode(LPPlaylist.self, """
                { "schema": 1, "generation": 3, "mode": "sequence", "cycleMinutes": 2, "showClock": false, "performance": "battery",
                  "scenes": [ { "id": "a", "name": "A", "kind": "web", "file": "a.html", "clock": "top" } ],
                  "displays": \(displays), "displayScenes": \(scenes) }
                """)
            }
            let five = try with("5")
            try expectEqual(five.displays, .standard)
            try expectEqual(five.mode, .sequence); try expectEqual(five.cycleMinutes, 2); try expectEqual(five.showClock, false)
            try expectEqual(five.scenes.map(\.id), ["a"])
            let mirror = try with(#"{"mode": "mirror", "onBattery": "dim", "assignments": {"\#(uuidB)": "b"}}"#)
            try expectEqual(mirror.displays.mode, .same); try expectEqual(mirror.displays.onBattery, .live)
            try expectEqual(mirror.displays.assignments, [uuidB: "b"])
            let badAssignments = try with(#"{"mode": "choose", "onBattery": "off", "assignments": ["a"]}"#)
            try expectEqual(badAssignments.displays, LPDisplaySettings(mode: .choose, assignments: [:], onBattery: .off))
            // Keys are trimmed and uppercased; empty keys or scene ids are dropped.
            let lower = try with(#"{"mode": "choose", "assignments": {" \#(uuidA.lowercased()) ": " ringed-giant ", "": "x", "\#(uuidC)": ""}}"#)
            try expectEqual(lower.displays.assignments, [uuidA: "ringed-giant"])
            // A broken displayScenes item is dropped, the others kept; a non-list is [].
            let mixed = try with(#"{"mode": "choose"}"#, scenes: #"[ {"id": "x"}, 7, {"id": "b", "name": "B", "kind": "web", "file": "b.html", "clock": "top"}, {"id": "v", "name": "V", "kind": "hologram", "file": "v.mov", "clock": "top"} ]"#)
            try expectEqual(mixed.displayScenes.map(\.id), ["b"])
            try expectEqual(try with("{}", scenes: #""nope""#).displayScenes, [])
            try expectEqual(try with("null", scenes: "null").displays, .standard)
            // A non-bool span on a deck entry fails that entry like any other malformed field (as before).
            try expectEqual(LPDisplaySettings(mode: .span).effectiveMode(displayCount: 1), .same)
            try expectEqual(LPDisplaySettings(mode: .different).effectiveMode(displayCount: 1), .same)
            try expectEqual(LPDisplaySettings(mode: .different).effectiveMode(displayCount: 2), .different)
            try expectEqual(LPDisplaySettings(mode: .choose).effectiveMode(displayCount: 1), .choose)
            try expectEqual(LPDisplaySettings(mode: .span).effectiveMode(displayCount: 3), .span)
            try expectEqual(LPDisplaySettings(assignments: [" \(uuidA.lowercased())": "x", uuidA: "y"]).assignments.count, 1)
        },
        TestCase(name: "core.playlist.oldReaderReadsNew") {
            let old = try decode(LegacyPlaylist.self, newPlaylistJSON)
            try expectEqual(old.generation, 43)
            try expectEqual(old.scenes.map(\.id), ["aurora-lake", "beach"])
            try expectEqual(old.scenes.last?.fit, .fill)
            // …and what this build writes, too.
            let dir = try tempDir("playlist-old-reader")
            defer { try? FileManager.default.removeItem(at: dir) }
            var p = try decode(LPPlaylist.self, newPlaylistJSON)
            p.displays.mode = .span
            try p.write(to: dir)
            let written = try JSONDecoder().decode(LegacyPlaylist.self, from: Data(contentsOf: dir.appendingPathComponent(LPPlaylist.fileName)))
            try expectEqual(written.scenes.count, 2)
            try expectEqual(written.mode, .shuffle)
        },

        // MARK: playlist-settings.json
        TestCase(name: "core.settings.tolerantDecoding") {
            try expectEqual(try decode(PlaylistSettings.self, "{}"), PlaylistSettings())
            let old = try decode(PlaylistSettings.self, #"{"mode": "sequence", "cycleMinutes": 9, "showClock": false, "performance": "best", "sceneIDs": ["b", "a"]}"#)
            try expectEqual(old, PlaylistSettings(mode: .sequence, cycleMinutes: 9, showClock: false, performance: .best, sceneIDs: ["b", "a"]))
            try expectEqual(old.displays, .standard); try expectEqual(old.displayNames, [:])
            let partial = try decode(PlaylistSettings.self, #"{"mode": "single", "sceneIDs": ["x"], "cycleMinutes": "soon", "performance": "turbo"}"#)
            try expectEqual(partial, PlaylistSettings(mode: .single, sceneIDs: ["x"]))
            let malformed = try decode(PlaylistSettings.self, #"{"mode": "sequence", "sceneIDs": ["x"], "displays": "lots", "displayNames": 3}"#)
            try expectEqual(malformed, PlaylistSettings(mode: .sequence, sceneIDs: ["x"]))
            let full = PlaylistSettings(mode: .single, cycleMinutes: 0, showClock: false, performance: .battery, sceneIDs: ["a"],
                                        displays: LPDisplaySettings(mode: .choose, assignments: [uuidA.lowercased(): "a"], onBattery: .off),
                                        displayNames: [uuidA: "Studio Display"])
            try expectEqual(full.displays.assignments, [uuidA: "a"])
            let data = try JSONEncoder().encode(full)
            try expectEqual(try JSONDecoder().decode(PlaylistSettings.self, from: data), full)
            // An old app or CLI reads a new file (and drops the new keys if it saves).
            try expectEqual(try JSONDecoder().decode(LegacySettings.self, from: data),
                            LegacySettings(mode: .single, cycleMinutes: 0, showClock: false, performance: .battery, sceneIDs: ["a"]))
            // The publish service reads the same tolerant way: a file without displays keeps its scenes.
            let dir = try tempDir("settings-tolerant")
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("playlist-settings.json")
            try Data(#"{"mode": "sequence", "sceneIDs": ["zen"]}"#.utf8).write(to: url)
            let publish = PublishService(library: LibraryService(libraryDirectory: dir, builtinDirectory: dir, templateDirectory: dir),
                                         compiler: SceneCompiler(), settingsURL: url, saverURL: dir.appendingPathComponent("none.saver"),
                                         lockURL: dir.appendingPathComponent("publish.lock"), notify: { _ in })
            try expectEqual(publish.loadSettings(), PlaylistSettings(mode: .sequence, sceneIDs: ["zen"]))
        },

        // MARK: scene.json
        TestCase(name: "core.manifest.span") {
            func manifest(_ extra: String, kind: String = "web") throws -> SceneManifest {
                try SceneManifest.decoder().decode(SceneManifest.self, from: Data(#"{"id": "s", "kind": "\#(kind)"\#(extra)}"#.utf8))
            }
            try expectEqual(try manifest(#", "span": true"#).span, true)
            try expectEqual(try manifest(#", "span": false"#).span, false)
            try expectEqual(try manifest("").span, nil)
            try expectEqual(try manifest(#", "span": "yes""#).span, nil)
            try expectEqual(try manifest(#", "span": 1, "name": "Kept""#).name, "Kept")
            try expectEqual(try manifest(#", "span": true"#).spans, true)
            try expectEqual(try manifest(#", "span": false"#).spans, false)
            try expectEqual(try manifest("").spans, false)                       // web scenes span only when they declare it
            try expectEqual(try manifest("", kind: "video").spans, true)         // videos span by default
            try expectEqual(try manifest(#", "span": false"#, kind: "video").spans, false)   // …and may opt out
            // Written only when set (manifests without it stay byte-identical).
            let m = SceneManifest(id: "s", name: "S", kind: .web, created: nil, updated: nil)
            let text = String(decoding: try SceneManifest.encoder().encode(m), as: UTF8.self)
            try expect(!text.contains("span"), text)
            var spanning = m
            spanning.span = true
            let back = try SceneManifest.decoder().decode(SceneManifest.self, from: SceneManifest.encoder().encode(spanning))
            try expectEqual(back.span, true)
        },

        // MARK: display layout
        TestCase(name: "core.displays.layout.order") {
            // One display.
            let one = LPDisplayLayout([display(uuidA, 0, 0, 1512, 982, builtin: true, menuBar: true)])
            try expectEqual(one.count, 1); try expectEqual(one.index(of: uuidA), 0)
            try expectEqual(one.viewport(of: uuidA), LPRect(x: 0, y: 0, width: 1512, height: 982))
            // Side by side, given in any order: left to right.
            let row = [display(uuidC, 3000, 0, 1000, 800), display(uuidA, -1500, 100, 1500, 900), display(uuidB, 0, 0, 3000, 1200)]
            try expectEqual(LPDisplayLayout(row).displays.map(\.id), [uuidA, uuidB, uuidC])
            try expectEqual(LPDisplayLayout(row.reversed()).displays.map(\.id), [uuidA, uuidB, uuidC])
            // Stacked with the same left edge: top to bottom.
            let stack = [display(uuidB, 0, 1080, 1920, 1080), display(uuidA, 0, 0, 1920, 1080)]
            try expectEqual(LPDisplayLayout(stack).displays.map(\.id), [uuidA, uuidB])
            // A portrait display, four displays, and ties broken by id.
            let four = [display(uuidD, 2560, -400, 1080, 1920), display(uuidC, 0, 1440, 1280, 800),
                        display(uuidB, 0, 0, 2560, 1440), display(uuidA, -1512, 458, 1512, 982)]
            try expectEqual(LPDisplayLayout(four).displays.map(\.id), [uuidA, uuidB, uuidC, uuidD])
            let tie = [display(uuidB, 0, 0, 100, 100), display(uuidA, 0, 0, 100, 100)]
            try expectEqual(LPDisplayLayout(tie).displays.map(\.id), [uuidA, uuidB])
            try expectEqual(LPDisplayLayout(four).index(of: uuidD.lowercased()), 3)
            try expectEqual(LPDisplayLayout(four).index(of: "nope"), nil)
        },
        TestCase(name: "core.displays.layout.cocoaFlip") {
            // The same arrangement described as NSScreen frames (Cocoa, y up, origin at the menu-bar
            // screen's bottom-left) and as CGDisplayBounds (top-left, y down): identical viewports.
            let mainH = 982.0
            let cocoa = [
                LPDisplay.cocoa(id: uuidA, x: 0, y: 0, width: 1512, height: 982, menuBarScreenHeight: mainH, isBuiltin: true, isMenuBar: true),
                LPDisplay.cocoa(id: uuidB, x: -2560, y: -200, width: 2560, height: 1440, menuBarScreenHeight: mainH),   // left, lower
                LPDisplay.cocoa(id: uuidC, x: 0, y: -1080, width: 1920, height: 1080, menuBarScreenHeight: mainH),       // below
                LPDisplay.cocoa(id: uuidD, x: 200, y: 982, width: 1280, height: 720, menuBarScreenHeight: mainH),        // above
            ]
            let cg = [
                display(uuidA, 0, 0, 1512, 982, builtin: true, menuBar: true),
                display(uuidB, -2560, mainH - (-200 + 1440), 2560, 1440),
                display(uuidC, 0, 982, 1920, 1080),
                display(uuidD, 200, -720, 1280, 720),
            ]
            try expectEqual(cocoa[1].frame, LPRect(x: -2560, y: -258, width: 2560, height: 1440))
            try expectEqual(cocoa[2].frame, LPRect(x: 0, y: 982, width: 1920, height: 1080))
            try expectEqual(cocoa[3].frame, LPRect(x: 200, y: -720, width: 1280, height: 720))
            let a = LPDisplayLayout(cocoa), b = LPDisplayLayout(cg)
            try expectEqual(a.displays.map(\.id), b.displays.map(\.id))
            try expectEqual(a.displays.map(\.frame), b.displays.map(\.frame))
            try expectEqual(a.canvas, b.canvas)
            try expectEqual(a.canvas, LPRect(x: -2560, y: -720, width: 2560 + 1920, height: 720 + 982 + 1080))
            try expectEqual(a.viewport(of: uuidA), LPRect(x: 2560, y: 720, width: 1512, height: 982))
            try expectEqual(a.viewport(of: uuidB), LPRect(x: 0, y: 462, width: 2560, height: 1440))
            try expectEqual(a.viewport(of: uuidC), LPRect(x: 2560, y: 1702, width: 1920, height: 1080))
            try expectEqual(a.viewport(of: uuidD), LPRect(x: 2760, y: 0, width: 1280, height: 720))
        },
        TestCase(name: "core.displays.layout.unionAndGaps") {
            // An L-shape: a laptop bottom-aligned next to a taller display (arrangement B of the span check).
            let l = LPDisplayLayout([display(uuidA, 0, 458, 1512, 982, builtin: true), display(uuidB, 1512, 0, 2560, 1440, menuBar: true)])
            try expectEqual(l.canvas, LPRect(x: 0, y: 0, width: 4072, height: 1440))
            try expectEqual(l.viewport(of: uuidA), LPRect(x: 0, y: 458, width: 1512, height: 982))
            try expectEqual(l.viewport(of: uuidB), LPRect(x: 1512, y: 0, width: 2560, height: 1440))
            // A gap between displays (not touching) stays part of the canvas.
            let gap = LPDisplayLayout([display(uuidA, 0, 0, 1000, 600), display(uuidB, 1200, 300, 800, 600)])
            try expectEqual(gap.canvas, LPRect(x: 0, y: 0, width: 2000, height: 900))
            try expectEqual(gap.viewport(of: uuidB), LPRect(x: 1200, y: 300, width: 800, height: 600))
            // A vertical offset with negative coordinates: the canvas origin moves, viewports follow.
            let up = LPDisplayLayout([display(uuidA, 0, 0, 1512, 982), display(uuidB, 204, -1080, 1920, 1080)])
            try expectEqual(up.canvas, LPRect(x: 0, y: -1080, width: 2124, height: 2062))
            try expectEqual(up.viewport(of: uuidA), LPRect(x: 0, y: 1080, width: 1512, height: 982))
            try expectEqual(up.viewport(of: uuidB), LPRect(x: 204, y: 0, width: 1920, height: 1080))
            try expect(LPRect(x: 0, y: 0, width: 10, height: 10).intersects(LPRect(x: 5, y: 5, width: 10, height: 10)))
            try expect(!LPRect(x: 0, y: 0, width: 10, height: 10).intersects(LPRect(x: 10, y: 0, width: 10, height: 10)), "touching")
            try expectEqual(LPRect(x: 1, y: 2, width: 3, height: 4).scaled(2), LPRect(x: 2, y: 4, width: 6, height: 8))
            try expectEqual(LPDisplayLayout([]).canvas, .zero)
            try expectEqual(LPDisplayLayout([]).viewport(of: uuidA), nil)
        },
        TestCase(name: "core.displays.layout.main") {
            let builtin = display(uuidB, 1512, 0, 1512, 982, builtin: true)
            let menu = display(uuidC, 3024, 0, 2560, 1440, menuBar: true)
            let other = display(uuidA, 0, 0, 1920, 1080)
            try expectEqual(LPDisplayLayout([other, builtin, menu]).main?.id, uuidB)
            try expectEqual(LPDisplayLayout([other, menu]).main?.id, uuidC)
            try expectEqual(LPDisplayLayout([menu, other].map { var d = $0; d.isMenuBar = false; return d }).main?.id, uuidA)
            try expectEqual(LPDisplayLayout([]).main, nil)
        },
        TestCase(name: "core.displays.layout.mixedDpr") {
            let mixed = LPDisplayLayout([display(uuidA, 0, 458, 1512, 982, scale: 2), display(uuidB, 1512, 0, 2560, 1440, scale: 1)])
            let same = LPDisplayLayout([display(uuidA, 0, 458, 1512, 982, scale: 1), display(uuidB, 1512, 0, 2560, 1440, scale: 1)])
            try expectEqual(mixed.canvas, same.canvas)
            try expectEqual(mixed.viewport(of: uuidA), same.viewport(of: uuidA))
            try expectEqual(mixed.viewport(of: uuidB), same.viewport(of: uuidB))
            try expectEqual(mixed.displays.map(\.scale), [2, 1])
        },
        TestCase(name: "core.displays.layout.dedupAndEmpty") {
            let l = LPDisplayLayout([display(uuidA.lowercased(), 0, 0, 100, 100), display(" \(uuidA) ", 500, 0, 100, 100),
                                     display(uuidB, 100, 0, 0, 100), display(uuidC, 100, 0, 100, -5), display("", 300, 0, 100, 100),
                                     display(uuidD, .nan, 0, 100, 100)])
            try expectEqual(l.displays.map(\.id), [uuidA])
            try expectEqual(l.displays.first?.frame.x, 0)   // the first of the duplicates wins
            try expectEqual(LPDisplay.normalizedID("  ab-cd "), "AB-CD")
            try expectEqual(LPDisplay.fallbackID(5), "DISPLAY-5")
            try expectEqual(LPDisplay(id: "display-7", frame: .zero).id, "DISPLAY-7")
            // Codable (the dev host passes displays as JSON).
            let d = display(uuidA, -10, 20, 300, 200, scale: 1.5, builtin: true, menuBar: false)
            try expectEqual(try JSONDecoder().decode(LPDisplay.self, from: JSONEncoder().encode(d)), d)
        },
    ] }
}
