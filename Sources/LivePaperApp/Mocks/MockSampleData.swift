// MockSampleData — the sample library used with LIVEPAPER_MOCK=1, in snapshots and in self tests.
// All names, descriptions and artwork are original.
import Foundation
import LivePaperCore

enum MockSampleData {
    struct Sample {
        var manifest: SceneManifest
        var style: MockArtwork.Style
        var builtin: Bool
        /// history.jsonl lines (AI provenance).
        var history: [[String: String]] = []
        var check: CheckReport?
    }

    static let referenceDate = Date(timeIntervalSince1970: 1_794_000_000) // Nov 2026

    static func samples(now: Date = referenceDate) -> [Sample] {
        func days(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }
        func perf(_ ms: Double?, _ mw: Double?, _ d: Double) -> SceneManifest.Performance {
            .init(benchMs: ms, energyMw: mw, checkedAt: days(d))
        }
        func web(_ id: String, _ name: String, _ desc: String, tags: [String], perf p: SceneManifest.Performance?,
                 created: Double, author: String, parent: String? = nil, clock: LPClockPosition = .top) -> SceneManifest {
            SceneManifest(id: id, name: name, description: desc, kind: .web, clock: .init(position: clock), author: author,
                          created: days(created), updated: days(max(0, created - 1)), parent: parent, tags: tags, performance: p)
        }
        func video(_ id: String, _ name: String, _ desc: String, tags: [String], created: Double) -> SceneManifest {
            SceneManifest(id: id, name: name, description: desc, kind: .video, video: .init(file: "video.mov"), author: "you",
                          created: days(created), updated: days(created), tags: tags)
        }
        func line(_ action: String, _ harness: String, _ model: String, _ prompt: String, _ summary: String, _ d: Double) -> [String: String] {
            ["date": ISO8601DateFormatter().string(from: days(d)), "action": action, "harness": harness, "model": model,
             "prompt": prompt, "summary": summary]
        }
        func report(passed: Bool, bench: Double, big: Double, mw: Double?, problems: [String] = [], warnings: [String] = [], d: Double) -> CheckReport {
            CheckReport(passed: passed, problems: problems, warnings: warnings,
                        benchMs: ["1512x982@2 t=14": bench, "5120x1440@1 t=14": big], energyMw: mw, checkedAt: days(d))
        }

        return [
            Sample(manifest: web("aurora-lake", "Aurora Lake", "Ribbons of light drift over a still, mirrored lake.",
                                 tags: ["aurora", "night", "calm"], perf: perf(1.2, 58, 20), created: 40, author: "LivePaper"),
                   style: .aurora, builtin: true,
                   check: report(passed: true, bench: 1.2, big: 1.9, mw: 58, d: 20)),
            Sample(manifest: web("drifting-dunes", "Drifting Dunes", "Warm dunes at dusk with long, slowly moving shadows.",
                                 tags: ["dunes", "warm", "minimal"], perf: perf(0.8, 41, 20), created: 40, author: "LivePaper"),
                   style: .dunes, builtin: true),
            Sample(manifest: web("orbiting-garden", "Orbiting Garden", "A small solar system turning around a soft sun.",
                                 tags: ["orbit", "space"], perf: perf(2.1, 96, 20), created: 40, author: "LivePaper"),
                   style: .orbit, builtin: true),
            Sample(manifest: web("neon-rain", "Neon Rain", "Rain on a window at night, city lights blurred behind it.",
                                 tags: ["rain", "city", "night"], perf: perf(2.8, 132, 2), created: 3, author: "you"),
                   style: .rain, builtin: false,
                   history: [line("create", "Claude Code 2.1.4", "default", "Rain on a window at night with blurred city lights behind it",
                                  "Layered bokeh lights with procedural raindrop streaks; drops are pooled to keep the bench under 3 ms.", 3)],
                   check: report(passed: true, bench: 2.8, big: 3.6, mw: 132,
                                 warnings: ["Clock region is slightly busy at t=600; consider dimming the top 20 %."], d: 2)),
            Sample(manifest: video("coastline-at-dusk", "Coastline at Dusk", "Gentle waves under a pink evening sky.",
                                   tags: ["ocean", "video"], created: 6), style: .ocean, builtin: false),
            Sample(manifest: web("paper-lanterns", "Paper Lanterns", "Lanterns drift upward through a warm summer night.",
                                 tags: ["lanterns", "warm", "night"], perf: perf(1.9, 88, 1), created: 9, author: "you"),
                   style: .lanterns, builtin: false,
                   history: [line("create", "Codex 0.58.0", "gpt-5-codex", "Paper lanterns drifting upward through a warm summer night",
                                  "Lanterns are sprites with additive glow; 38 instances with depth-based parallax.", 9),
                             line("modify", "Claude Code 2.1.4", "default", "Make them rise more slowly and add a faint starfield",
                                  "Halved rise speed, added a cached starfield layer.", 1)],
                   check: report(passed: true, bench: 1.9, big: 2.7, mw: 88, d: 1)),
            Sample(manifest: web("tidal-glass", "Tidal Glass", "Overlapping panes of sea glass catching the light.",
                                 tags: ["glass", "abstract"], perf: perf(5.6, 310, 0.2), created: 0.5, author: "you"),
                   style: .glass, builtin: false,
                   history: [line("create", "Kiro CLI 1.20.0", "", "Sea glass shapes overlapping and catching light like a tide pool",
                                  "Translucent rounded shapes with caustic highlights.", 0.5)],
                   check: report(passed: false, bench: 5.6, big: 8.9, mw: 310,
                                 problems: ["Bench is 5.6 ms/frame at 1512x982@2 (budget 4 ms). Draw fewer overlapping translucent shapes or cache them in an offscreen canvas."],
                                 d: 0.2)),
            Sample(manifest: video("morning-fog", "Morning Fog", "Pine ridges dissolving into slow-moving fog.",
                                   tags: ["fog", "forest", "video"], created: 12), style: .fog, builtin: false),
            Sample(manifest: web("ink-bloom", "Ink Bloom", "Blooms of ink unfolding in deep water.",
                                 tags: ["ink", "abstract"], perf: nil, created: 0.1, author: "you", parent: "aurora-lake"),
                   style: .ink, builtin: false),
        ]
    }

    /// The tiny placeholder scene code written into mock web packages.
    static let sceneJS = """
    // Placeholder scene written by LivePaper's mock services.
    LivePaper.scene({
      setup(lp) {},
      draw(lp) {
        const g = lp.ctx.createLinearGradient(0, 0, 0, lp.h);
        g.addColorStop(0, '#0b1830'); g.addColorStop(1, '#1d3d5c');
        lp.ctx.fillStyle = g; lp.ctx.fillRect(0, 0, lp.w, lp.h);
      }
    });
    """
}
