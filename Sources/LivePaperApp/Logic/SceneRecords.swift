// SceneRecords — tolerant readers for the per-scene files the UI shows: history.jsonl (AI
// provenance) and .check/report.json (last check). Foundation-only; also compiled into
// LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/.
//
// Both files are written by other components (and history.jsonl partly by AI agents), so malformed
// lines or unexpected date formats must degrade gracefully instead of failing the whole view.
import Foundation
import LivePaperCore

/// One line of history.jsonl: `{date, harness, model, prompt, summary}` (+ optional `action`).
struct ProvenanceEntry: Identifiable, Equatable, Sendable {
    let id: Int
    var date: Date?
    var action: String?
    var harness: String?
    var model: String?
    var prompt: String?
    var summary: String?
}

enum ProvenanceLog {
    static let fileName = "history.jsonl"

    static func parse(_ data: Data) -> [ProvenanceEntry] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [ProvenanceEntry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            func str(_ k: String) -> String? {
                guard let v = obj[k] as? String else { return nil }
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            out.append(ProvenanceEntry(id: out.count, date: str("date").flatMap(parseDate), action: str("action") ?? str("kind"),
                                       harness: str("harness"), model: str("model"), prompt: str("prompt"), summary: str("summary")))
        }
        return out
    }

    static func load(package: URL) -> [ProvenanceEntry] {
        guard let data = try? Data(contentsOf: package.appendingPathComponent(fileName)) else { return [] }
        return parse(data)
    }

    /// Cheap existence check used when building library cards.
    static func hasHistory(package: URL) -> Bool {
        let url = package.appendingPathComponent(fileName)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return false }
        return size.intValue > 0
    }

    /// ISO-8601 with or without fractional seconds.
    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}

enum CheckReportFile {
    static func url(package: URL) -> URL { package.appendingPathComponent(".check/report.json") }

    /// Decodes .check/report.json, accepting ISO-8601 (with or without fractions) or numeric dates.
    static func load(package: URL) -> CheckReport? {
        guard let data = try? Data(contentsOf: url(package: package)) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> CheckReport? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self), let date = ProvenanceLog.parseDate(s) { return date }
            if let n = try? c.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: n) }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised date")
        }
        return try? d.decode(CheckReport.self, from: data)
    }

    /// The bench that the budget applies to (1512×982@2x), falling back to the worst sample.
    static func primaryBenchMs(_ report: CheckReport) -> Double? {
        let primary = report.benchMs.filter { $0.key.hasPrefix("1512x982") }.values.max()
        return primary ?? report.benchMs.values.max()
    }

    /// Bench rows sorted for display: primary size first, then by key.
    static func sortedBench(_ report: CheckReport) -> [(key: String, ms: Double)] {
        report.benchMs.map { (key: $0.key, ms: $0.value) }.sorted { a, b in
            let pa = a.key.hasPrefix("1512x982"), pb = b.key.hasPrefix("1512x982")
            return pa != pb ? pa : a.key < b.key
        }
    }
}
