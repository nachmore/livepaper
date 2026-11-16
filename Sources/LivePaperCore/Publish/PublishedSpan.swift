// PublishedSpan — whether a scene spans displays as published (`LPPlaylistEntry.span`; "Span across
// displays", ARCHITECTURE §4.3).
//
// scene.json's `"span": true` is the scene's claim to be a pure function of lp.t, the seed and the
// canvas size. Every display renders its own frames, so a scene that breaks the rules `livepaper
// check` enforces (SCENE_API.md §16) would drift apart across the displays; such a scene is published
// as not spanning (it shows whole on every display) instead:
//  * scene.js calls Math.random() — the same scan the check makes (SceneChecker.spanSourceFindings);
//  * otherwise the scene's last check, when it is at least as new as scene.js, decides
//    (`CheckReport.spanVerdict`: update(), a slice that doesn't match its crop, span renders that failed);
//  * without such a check: scene.js gives the scene an update() (SceneSourceScanner.definesUpdate).
// Videos keep `SceneManifest.spans` (one shared player shows every display its crop).
import Foundation

public enum PublishedSpan {
    /// Reads scene.js and `.check/report.json` from the package.
    public static func spans(_ scene: SceneItem) -> Bool {
        let m = scene.manifest
        guard m.kind == .web else { return m.spans }
        guard m.spans else { return false }
        let js = scene.packageURL.appendingPathComponent(SceneCompiler.sceneFile)
        let source = (try? String(contentsOf: js, encoding: .utf8)) ?? ""
        let reportURL = scene.packageURL.appendingPathComponent(SceneChecker.checkDirectory)
            .appendingPathComponent(SceneChecker.reportFile)
        let report = loadReport(reportURL)
        let modified = (try? js.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return spans(manifest: m, sceneJS: source, report: report.flatMap { isCurrent($0, sceneJSModified: modified) ? $0 : nil })
    }

    /// The decision, given scene.js and the check report that still describes it (nil: none, or an
    /// older one).
    public static func spans(manifest m: SceneManifest, sceneJS: String, report: CheckReport?) -> Bool {
        guard m.kind == .web else { return m.spans }
        guard m.spans else { return false }
        if !SceneChecker.spanSourceFindings(sceneJS).problems.isEmpty { return false }
        if let verdict = report?.spanVerdict { return verdict }
        return !SceneSourceScanner.definesUpdate(sceneJS)
    }

    /// A report describes scene.js as it is when it was written after scene.js last changed (report
    /// dates are whole seconds).
    public static func isCurrent(_ report: CheckReport, sceneJSModified: Date?) -> Bool {
        guard let modified = sceneJSModified else { return false }
        return modified.timeIntervalSinceReferenceDate.rounded(.down) <= report.checkedAt.timeIntervalSinceReferenceDate
    }

    /// `.check/report.json` (ISO-8601 dates, with or without fractions, as `livepaper check` and older
    /// builds wrote them).
    static func loadReport(_ url: URL) -> CheckReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                let f = ISO8601DateFormatter()
                if let date = f.date(from: s) { return date }
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = f.date(from: s) { return date }
            }
            if let n = try? c.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: n) }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised date")
        }
        return try? d.decode(CheckReport.self, from: data)
    }
}
