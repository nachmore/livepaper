// SceneHistory — `history.jsonl` (provenance, one JSON object per line) and `history/<timestamp>/`
// (previous versions kept by replaceContents). See ARCHITECTURE §4.2.
import Foundation

/// One line of a scene's `history.jsonl`.
public struct SceneHistoryEntry: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable {
        /// The scene was created by an AI session.
        case create
        /// An AI session changed the scene.
        case modify
        /// The scene was cloned from another one (`summary` names the source).
        case clone
        /// The scene's contents were replaced (previous version kept in `previous`).
        case replace
    }

    public var date: Date
    public var action: Action?
    /// Harness that produced the change (e.g. "claude"), for AI actions.
    public var harness: String?
    public var model: String?
    /// The user's prompt, for AI actions.
    public var prompt: String?
    public var summary: String?
    /// For `replace`: the `history/<timestamp>` directory holding the previous version.
    public var previous: String?
    /// For AI actions with reference images: how many of each role (never names or paths).
    public var references: ReferenceCounts?

    public init(date: Date = Date(), action: Action?, harness: String? = nil, model: String? = nil,
                prompt: String? = nil, summary: String? = nil, previous: String? = nil, references: ReferenceCounts? = nil) {
        self.date = date; self.action = action; self.harness = harness; self.model = model
        self.prompt = prompt; self.summary = summary; self.previous = previous; self.references = references
    }

    // Tolerant decoding: unknown actions from newer versions must not hide the rest of the line.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? Date(timeIntervalSince1970: 0)
        action = try? c.decodeIfPresent(Action.self, forKey: .action)
        harness = try? c.decodeIfPresent(String.self, forKey: .harness)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        prompt = try? c.decodeIfPresent(String.self, forKey: .prompt)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        previous = try? c.decodeIfPresent(String.self, forKey: .previous)
        references = try? c.decodeIfPresent(ReferenceCounts.self, forKey: .references)
    }
}

public enum SceneHistory {
    public static let fileName = "history.jsonl"
    public static let directoryName = "history"

    /// Reads every parseable line (malformed lines are skipped; agents may have touched the file).
    public static func entries(in package: URL) -> [SceneHistoryEntry] {
        guard let text = try? String(contentsOf: package.appendingPathComponent(fileName), encoding: .utf8) else { return [] }
        let decoder = SceneManifest.decoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(SceneHistoryEntry.self, from: Data($0.utf8)) }
    }

    /// Appends entries (atomically rewrites the file; history files are small).
    public static func append(_ new: [SceneHistoryEntry], to package: URL) throws {
        guard !new.isEmpty else { return }
        let url = package.appendingPathComponent(fileName)
        var data = (try? Data(contentsOf: url)) ?? Data()
        if let last = data.last, last != UInt8(ascii: "\n") { data.append(UInt8(ascii: "\n")) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for entry in new {
            data.append(try encoder.encode(entry))
            data.append(UInt8(ascii: "\n"))
        }
        try FileOps.writeAtomically(data, to: url)
    }

    public static func append(_ entry: SceneHistoryEntry, to package: URL) throws { try append([entry], to: package) }
}
