// AISessionRecovery — what LivePaper does with a session an earlier run left behind (ARCHITECTURE
// §10 "Session records and recovery"). The app asks at launch (AIService.recoverSessions); `livepaper
// ai sessions` lists the same states.
//
//   resolved, failed or cancelled        → left alone (nothing to review)
//   its runner (app or CLI) still runs   → left alone (the session is in that process's hands)
//   agent still running (same pid AND    → watched: "Still working (recovered)"; when it exits,
//     same start time and group)           LivePaper's check runs as for any session
//   agent gone, scene changed            → LivePaper's check, then the normal review
//   agent gone, scene unchanged          → discarded quietly
//
// Nothing here ever signals a process unless it is provably the recorded agent: a pid that is alive
// but started at another time (pid reuse) counts as gone.
import Foundation

public enum AISessionRecovery {
    public enum Decision: Equatable, Sendable {
        /// Not for this run to take over (`reason` says why).
        case leave(Reason)
        /// The agent still runs: watch it, check the scene when it exits.
        case watch(agent: LPProcessFacts)
        /// The agent is gone and changed the scene: check it, then offer it for review.
        case review
        /// Nothing happened: discard it quietly.
        case discard
    }

    public enum Reason: String, Equatable, Sendable {
        /// Accepted, discarded, failed or cancelled.
        case settled
        /// The app or CLI that runs it is still running.
        case runnerAlive
        /// Its workspace is gone (pruned, deleted).
        case noWorkspace
    }

    /// - Parameter probe: the process now running as a pid (ProcessProbe.facts; tests inject theirs).
    public static func decide(_ record: AISessionRecord, workspace: AIWorkspace,
                              probe: (pid_t) -> LPProcessFacts? = ProcessProbe.facts) -> Decision {
        if record.isSettled { return .leave(.settled) }
        if let runner = record.runner, runner.isSameProcess(as: probe(runner.pid)) { return .leave(.runnerAlive) }
        guard FileOps.isRealDirectory(workspace.root) else { return .leave(.noWorkspace) }
        if let agent = record.agent, agent.isSameProcess(as: probe(agent.pid)) { return .watch(agent: agent) }
        return sceneChanged(record, workspace: workspace) ? .review : .discard
    }

    /// `scene/scene.js` differs from what LivePaper left for the agent (the template, or the scene
    /// being changed). Without a recorded digest (a damaged record), assume it changed: the check decides.
    public static func sceneChanged(_ record: AISessionRecord, workspace: AIWorkspace) -> Bool {
        guard let before = record.sceneBefore else { return true }
        return FileDigest.sha256(workspace.scene.appendingPathComponent(SceneCompiler.sceneFile)) != before
    }

    // MARK: - Listing (`livepaper ai sessions`)

    public enum State: String, Sendable, CaseIterable {
        /// Its agent runs and the app or CLI that started it is still there.
        case running
        /// A later LivePaper took it over and it isn't decided yet (still running, or ready to review).
        case recovered
        /// The agent still runs but nobody watches it: LivePaper recovers it at its next launch.
        case orphaned
        /// Finished (or left behind) without a decision: LivePaper offers it for review at its next launch.
        case unreviewed
        case accepted
        case discarded
        case failed
        case cancelled
    }

    public static func state(of record: AISessionRecord, probe: (pid_t) -> LPProcessFacts? = ProcessProbe.facts) -> State {
        switch record.resolution {
        case .accepted?: return .accepted
        case .discarded?: return .discarded
        case nil: break
        }
        switch record.outcome?.status {
        case .failed?: return .failed
        case .cancelled?: return .cancelled
        case .passed?, nil: break
        }
        let runnerAlive = record.runner.map { $0.isSameProcess(as: probe($0.pid)) } ?? false
        let agentAlive = record.agent.map { $0.isSameProcess(as: probe($0.pid)) } ?? false
        if runnerAlive { return record.recoveredAt != nil ? .recovered : (record.outcome == nil ? .running : .unreviewed) }
        return agentAlive ? .orphaned : .unreviewed
    }

    // MARK: - The session's images, from LivePaper's copies

    /// What the check and the picture's restore need (SessionReferences), from the record and the
    /// copies next to it. `problem` is set when the record names a picture to animate whose copy
    /// is missing or damaged: LivePaper then can't put the picture back or compare with it, so the
    /// session can't be checked as it was meant to be.
    static func sessionReferences(_ record: AISessionRecord, store: AISessionRecordStore) -> (SessionReferences, problem: String?) {
        var refs = SessionReferences()
        for (i, r) in record.references.enumerated() {
            guard let summary = r.summary else { continue }
            let file = (r.file as NSString).lastPathComponent
            refs.images.append(.init(index: i + 1, role: r.role, file: file, byteCount: store.copy(named: r.copy, for: record.id)?.count ?? 0,
                                     summary: summary))
        }
        guard let a = record.animate else { return (refs, nil) }
        let missing = "LivePaper no longer has its copy of the picture to animate, so it can't check this scene as the session asked."
        guard let data = store.copy(named: a.copy, for: record.id), ReferenceImporter.sha256(data) == a.sha256,
              let fingerprint = try? ReferenceFingerprint(data: data) else { return (refs, missing) }
        refs.animate = .init(assetPath: a.asset, data: data, width: a.width, height: a.height, sha256: a.sha256, fingerprint: fingerprint,
                             transparent: a.transparent, flattened: a.flattened)
        return (refs, nil)
    }

    /// The images as the app holds them (thumbnails, Try Again), rebuilt from LivePaper's copies —
    /// nothing is decoded and no original is opened. Images whose copy or summary is gone are left out.
    public static func preparedReferences(_ record: AISessionRecord, store: AISessionRecordStore) -> [PreparedReference] {
        record.references.compactMap { r -> PreparedReference? in
            guard let summary = r.summary, let data = store.copy(named: r.copy, for: record.id) else { return nil }
            let vision = EncodedReferenceImage(data: data, format: r.format, width: r.width, height: r.height)
            var master = vision
            if r.role == .animate {
                // The picture as the scene has it: what a new session puts into its scene again.
                guard let a = record.animate, let asset = store.copy(named: a.copy, for: record.id),
                      ReferenceImporter.sha256(asset) == a.sha256 else { return nil }
                master = EncodedReferenceImage(data: asset, format: a.copy.hasSuffix(".png") ? .png : .jpeg, width: a.width, height: a.height)
            }
            let o = summary.original
            let probe = ReferenceProbe(width: o.width, height: o.height, typeIdentifier: r.format.typeIdentifier, formatName: o.format,
                                       frameCount: o.frames, hasAlpha: o.transparent, byteCount: data.count)
            return PreparedReference(role: r.role, displayName: r.name, requestedPath: nil, originPath: nil, original: probe,
                                     master: master, vision: vision, summary: summary)
        }
    }

    /// The record entries and copies for a session's images (`numbered`: in the workspace's order).
    static func recordedReferences(_ numbered: [PreparedReference], written: SessionReferences)
        -> (references: [AISessionRecord.Reference], animate: AISessionRecord.Animate?, copies: [String: Data]) {
        var entries: [AISessionRecord.Reference] = [], copies: [String: Data] = [:]
        for (ref, image) in zip(numbered, written.images) {
            let copy = image.file   // "ref-01.jpg"
            copies[copy] = ref.vision.data
            entries.append(.init(role: image.role, name: ref.displayName, file: ReferenceWorkspace.directoryName + "/" + image.file, copy: copy,
                                 format: ref.vision.format, width: ref.vision.width, height: ref.vision.height, summary: image.summary))
        }
        var animate: AISessionRecord.Animate?
        if let a = written.animate {
            let copy = "asset." + (a.assetPath as NSString).pathExtension
            copies[copy] = a.data
            animate = .init(asset: a.assetPath, copy: copy, sha256: a.sha256, width: a.width, height: a.height,
                            transparent: a.transparent, flattened: a.flattened)
        }
        return (entries, animate, copies)
    }
}

/// Accepting a session's result — the one way a candidate reaches the library, for every session
/// (the app's, a recovered one's, `livepaper ai`'s).
public enum AICandidate {
    /// Adds (create) or replaces (modify) the scene. A created scene's id always comes from its
    /// name (`SceneManifest.slug`), whatever the candidate's scene.json says — the template's id,
    /// or one the agent typed — and the library makes it unique; a modified scene keeps its id.
    public static func accept(_ package: URL, request: AISessionRequest, library: LibraryServicing) throws -> SceneItem {
        switch request {
        case .create:
            if var m = try? SceneManifest.load(package: package) {
                let id = SceneManifest.slug(from: m.name)
                if m.id != id { m.id = id; try m.write(package: package) }
            }
            return try library.importPackage(at: package)
        case .modify(let id, _):
            return try library.replaceContents(id: id, with: package)
        }
    }
}
