// ReferenceWorkspace — a session's reference images on disk (ARCHITECTURE §4.1, §10):
//
//   <ws>/references/
//     references.json   index {schema, images:[{file, summary, role, width, height, asset?, assetSHA256?}]}
//     ref-01.jpg        the vision copy (≤ 2000 px, sRGB, no metadata; .png when transparent), 0o444
//     ref-01.json       ReferenceSummary
//   <ws>/scene/assets/reference.jpg   animate only: ≤ 3840 px, fits the asset limits (.png when transparent)
//
// The picture to animate is always ref-01 (`numbered`), so ref-NN, the order harnesses get the
// images in (Codex attaches a prefix of them) and TASK.md's table all agree.
//
// Only bytes LivePaper prepared are written (no original names or paths); the pasted or dropped
// data never touches a temporary file. `TASK.md` › "Reference images" says how to use each.
import CryptoKit
import Darwin
import Foundation

/// `references/references.json`.
public struct ReferenceIndex: Codable, Sendable, Equatable {
    public struct Image: Codable, Sendable, Equatable {
        /// "ref-01.jpg" (in `references/`).
        public var file: String
        /// "ref-01.json".
        public var summary: String
        public var role: AIReferenceRole
        public var width: Int
        public var height: Int
        /// Workspace-relative, animate only: "scene/assets/reference.jpg".
        public var asset: String?
        public var assetSHA256: String?
    }
    public var schema = 1
    public var images: [Image]
}

/// An image a harness may be handed directly (Codex `-i`, custom `{references}`).
public struct HarnessReferenceImage: Sendable, Equatable {
    /// Workspace-relative: "references/ref-01.jpg".
    public var path: String
    public var role: AIReferenceRole
    public var byteCount: Int
    public init(path: String, role: AIReferenceRole, byteCount: Int) { self.path = path; self.role = role; self.byteCount = byteCount }
}

/// What one session's workspace holds (empty when the session has no references).
public struct SessionReferences: Sendable, Equatable {
    public struct Image: Sendable, Equatable {
        /// 1-based: ref-01 …
        public var index: Int
        public var role: AIReferenceRole
        /// "ref-01.jpg"
        public var file: String
        public var byteCount: Int
        public var summary: ReferenceSummary
    }
    public struct Animate: Sendable, Equatable {
        /// Package-relative: "assets/reference.jpg".
        public var assetPath: String
        /// The asset's bytes, to put back if the agent changed them.
        public var data: Data
        public var width: Int
        public var height: Int
        public var sha256: String
        public var fingerprint: ReferenceFingerprint
        /// The asset is a PNG with see-through parts (a cut-out): the scene chooses what is behind them.
        public var transparent: Bool = false
        /// The picture was transparent, but only a JPEG flattened over black fitted the asset limit.
        public var flattened: Bool = false
    }
    public var images: [Image] = []
    public var animate: Animate?
    public init() {}

    public var isEmpty: Bool { images.isEmpty }
    /// nil without references (history.jsonl then has no `references` key).
    public var counts: ReferenceCounts? { isEmpty ? nil : ReferenceCounts(roles: images.map(\.role)) }
    /// In index order (ref-01 first, which is the picture to animate when there is one).
    public var harnessImages: [HarnessReferenceImage] {
        images.map { HarnessReferenceImage(path: ReferenceWorkspace.directoryName + "/" + $0.file, role: $0.role, byteCount: $0.byteCount) }
    }
    /// What the final check compares the stills with.
    public var checkTarget: ReferenceTarget? {
        animate.map { ReferenceTarget(assetPath: $0.assetPath, assetSHA256: $0.sha256, fingerprint: $0.fingerprint) }
    }
}

extension AIWorkspace {
    /// `<ws>/references`
    public var references: URL { root.appendingPathComponent(ReferenceWorkspace.directoryName) }
}

public enum ReferenceWorkspace {
    public static let directoryName = "references"
    public static let indexFileName = "references.json"
    /// `scene/assets/reference.jpg|png`
    public static let assetBaseName = "reference"

    public static func imageFileName(index: Int, format: EncodedReferenceImage.Format) -> String {
        String(format: "ref-%02d.", index) + format.fileExtension
    }
    public static func summaryFileName(index: Int) -> String { String(format: "ref-%02d.json", index) }
    public static func relativeImagePath(index: Int, format: EncodedReferenceImage.Format) -> String {
        directoryName + "/" + imageFileName(index: index, format: format)
    }
    /// "assets/reference.jpg"
    static func assetPath(_ format: EncodedReferenceImage.Format) -> String {
        SceneCompiler.assetsDirectory + "/" + assetBaseName + "." + format.fileExtension
    }

    // MARK: - Writing

    /// The order images are numbered in: the picture to animate first, the rest as given.
    public static func numbered(_ refs: [PreparedReference]) -> [PreparedReference] {
        refs.filter { $0.role == .animate } + refs.filter { $0.role != .animate }
    }

    /// Writes `refs` (in order: ref-01 is the first; see `numbered`) into the workspace, and for the image to animate
    /// its full-resolution copy into the candidate's assets. Throws `ReferenceError.noRoomForAsset`
    /// when the scene's own assets leave too little room for it. `clock`: where the scene's clock is
    /// (the picture to animate's brightness is measured behind it).
    static func write(_ refs: [PreparedReference], into ws: AIWorkspace, clock: LPClockPosition = .top) throws -> SessionReferences {
        var session = SessionReferences()
        guard !refs.isEmpty else { return session }
        try ReferencePrompts.validate(refs)
        let fm = FileManager.default
        try fm.createDirectory(at: ws.references, withIntermediateDirectories: true)
        var index = ReferenceIndex(images: [])
        for (i, ref) in refs.enumerated() {
            let n = i + 1
            let file = imageFileName(index: n, format: ref.vision.format)
            var summary = ref.summary
            summary.file = file
            summary.role = ref.role
            var entry = ReferenceIndex.Image(file: file, summary: summaryFileName(index: n), role: ref.role,
                                             width: ref.vision.width, height: ref.vision.height)
            if ref.role == .animate {
                let animate = try writeAsset(from: ref, scene: ws.scene)
                // The summary measured the top clock; a scene being changed may keep its clock at the bottom.
                if clock == .bottomLeft || clock == .bottomRight {
                    summary.brightness = ReferenceAnalysis.brightness(animate.fingerprint.bitmap, clock: clock)
                }
                summary.asset = .init(path: "scene/" + animate.assetPath, width: animate.width, height: animate.height, bytes: animate.data.count)
                entry.asset = "scene/" + animate.assetPath
                entry.assetSHA256 = animate.sha256
                session.animate = animate
            }
            try writeReadOnly(ref.vision.data, to: ws.references.appendingPathComponent(file))
            try writeReadOnly(try ReferenceSummary.encoder().encode(summary) + Data("\n".utf8),
                              to: ws.references.appendingPathComponent(summaryFileName(index: n)))
            session.images.append(.init(index: n, role: ref.role, file: file, byteCount: ref.vision.data.count, summary: summary))
            index.images.append(entry)
        }
        try writeReadOnly(try ReferenceSummary.encoder().encode(index) + Data("\n".utf8), to: ws.references.appendingPathComponent(indexFileName))
        return session
    }

    /// The picture to animate as `scene/assets/reference.(jpg|png)`, replacing any earlier one.
    static func writeAsset(from ref: PreparedReference, scene: URL) throws -> SessionReferences.Animate {
        let assets = scene.appendingPathComponent(SceneCompiler.assetsDirectory)
        for format in [EncodedReferenceImage.Format.jpeg, .png] {
            let old = scene.appendingPathComponent(assetPath(format))
            if FileOps.entryExists(old) { try FileManager.default.removeItem(at: old) }
        }
        if FileOps.entryExists(assets) {
            guard FileOps.isRealDirectory(assets) else {
                throw AIError.unsupported("The scene's assets entry isn't a folder, so LivePaper can't add the picture to animate.")
            }
        } else {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        }
        let asset = try ReferenceImporter.animateAsset(from: ref.master, otherAssetBytes: assetBytes(in: assets))
        let path = assetPath(asset.format)
        let url = scene.appendingPathComponent(path)
        try asset.data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        return SessionReferences.Animate(assetPath: path, data: asset.data, width: asset.width, height: asset.height,
                                         sha256: ReferenceImporter.sha256(asset.data), fingerprint: try ReferenceFingerprint(data: asset.data),
                                         transparent: asset.format == .png, flattened: ref.master.format == .png && asset.format == .jpeg)
    }

    /// Bytes of the regular files the compiler would inline from `assets/` (hidden entries skipped).
    static func assetBytes(in assets: URL) -> Int {
        guard let walker = FileManager.default.enumerator(at: assets, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                          options: [.skipsHiddenFiles]) else { return 0 }
        var total = 0
        for case let url as URL in walker {
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            if v?.isRegularFile == true, v?.isSymbolicLink != true { total += v?.fileSize ?? 0 }
        }
        return total
    }

    private static func writeReadOnly(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
    }

    // MARK: - TASK.md

    static func megabytes(_ bytes: Int) -> String { String(format: "%.1f", Double(bytes) / Double(1 << 20)) }

    /// "## Reference images" in TASK.md: what was attached, how to look at it and how to use each role.
    static func taskSection(_ refs: SessionReferences, workspace: AIWorkspace, unattached: Int) -> String {
        guard !refs.isEmpty else { return "" }
        let n = refs.images.count
        let budgets = CheckBudgets()
        var lines: [String] = [
            "## Reference images",
            "",
            "The user attached \(n == 1 ? "1 image" : "\(n) images"). LivePaper copied \(n == 1 ? "it" : "them") into `./\(directoryName)/` " +
                "(resized, metadata removed). \(n == 1 ? "It is the only copy" : "They are the only copies") you can open \u{2014} you can't " +
                "read files outside this workspace \u{2014} and paths in the request that LivePaper attached now read `\(directoryName)/ref-NN.\u{2026}`.",
            "",
            "Look at every image before you plan. Images attached to this conversation are these files in the table's order " +
                "(the first attachment is ref-01, the second ref-02, \u{2026}), possibly only the first few; open the others with your " +
                "image tool (Claude Code: Read; Kiro: read with mode \"Image\" and image_paths; Codex: view_image). Absolute folder: " +
                "`\(workspace.references.path)`. `\(directoryName)/ref-NN.json` has size, aspect, brightness, dominant palette " +
                "(hex + share) and a coarse colour grid (top row first).",
            "",
            "| Image | Role | Size | Notes |",
            "|---|---|---|---|",
        ]
        for image in refs.images {
            let s = image.summary
            let palette = s.palette.prefix(3).map { "\($0.hex) \(Int(($0.share * 100).rounded())) %" }.joined(separator: ", ")
            let notes = "brightness \(Int(s.brightness.mean.rounded()))/255, behind the clock \(Int(s.brightness.behindClock.rounded()))/255" +
                (palette.isEmpty ? "" : "; palette \(palette)")
            lines.append("| `\(directoryName)/\(image.file)` | \(image.role == .animate ? "**animate**" : "reference") | " +
                         "\(s.width)\u{00D7}\(s.height), \(s.aspect) \(s.orientation) | \(notes) |")
        }
        if refs.images.contains(where: { $0.role == .reference }) {
            lines += [
                "",
                "### Reference images: a starting point",
                "",
                "Use them as the user's brief \u{2014} subject, composition, palette, light, mood, style \u{2014} and build an original " +
                    "LivePaper scene: reinterpret, don't trace. Don't put these files or crops of them into `scene/`; draw procedurally.",
            ]
        }
        if let animate = refs.animate, let image = refs.images.first(where: { $0.role == .animate }) {
            let s = image.summary
            let asset = "scene/" + animate.assetPath, assetName = (animate.assetPath as NSString).lastPathComponent
            let perSize = s.brightness.sizes.map { "\($0.aspect) \(Int($0.behindClock.rounded()))" }.joined(separator: ", ")
            let clockAt = s.brightness.clock == .bottomLeft ? " (bottom left)" : s.brightness.clock == .bottomRight ? " (bottom right)" : ""
            var brightness = "5. Brightness: mean \(Int(s.brightness.mean.rounded()))/255; behind the clock\(clockAt) up to " +
                "\(Int(s.brightness.behindClock.rounded()))/255" + (perSize.isEmpty ? "" : " (\(perSize))") +
                "; limits \(Int(budgets.maxMeanLuma)) / \(Int(budgets.maxClockLuma)) at every screen shape. "
            if let k = s.brightness.darkenTo {
                brightness += "That is too bright for the check: darken evenly to about \(String(format: "%.2f", k)) (e.g. black at alpha " +
                    "\(String(format: "%.2f", 1 - k)) over the picture) and/or add a soft dark gradient behind the clock; never recolour."
            } else {
                brightness += "Keep it that way: overlays shouldn't brighten the picture, least of all behind the clock."
            }
            var transparency: [String] = []
            if animate.transparent {
                transparency = ["", "The picture has transparent areas (a cut-out). Draw whatever fits behind them first \u{2014} a dark " +
                    "backdrop keeps the clock readable; the brightness numbers above count them as black \u{2014} then the picture over it. " +
                    "The check compares only the picture's opaque parts, so any backdrop is fine."]
            } else if animate.flattened {
                transparency = ["", "The picture had transparent areas, but only a JPEG flattened over black fitted the asset limit: " +
                    "the black is part of the picture now."]
            }
            lines += [
                "",
                "### Animate this exact image: `\(directoryName)/\(image.file)`",
                "",
                "The user wants THIS picture brought to life, not a new picture inspired by it. Open `\(directoryName)/\(image.file)` " +
                    "with your image tool before you plan, and plan the effects for the regions it really has (water, sky, foliage, " +
                    "light). Full-resolution copy: `\(asset)` (\(animate.width)\u{00D7}\(animate.height)).",
                "",
                "1. Load it with `LivePaper.image('\(assetName)')` (decoded before setup) and draw it as the base of every frame, " +
                    "cover-fit: `s = Math.max(lp.w / img.width, lp.h / img.height)`, centred; it must fill 16:10, 32:9 and 5:4 with no " +
                    "bars, stretching or mirroring (\(cropNote(aspect: s.aspectRatio))).",
                "2. Keep it recognisably the same picture: composition, colours, details. Don't redraw, restyle, recolour or replace it.",
                "3. Bring it to life subtly, with motion that belongs to what it shows: water shimmer/ripples (strips offset by smooth " +
                    "noise), drifting clouds/fog/mist (soft low-alpha layers), wind in foliage/grass (gentle sway of strips or cut-outs), " +
                    "particles that fit (snow, rain, dust, fireflies, embers), slow light changes (glints, a soft glow, never flashing), " +
                    "a slow Ken Burns camera (\u{2264} 6 % zoom/pan, periods \u{2265} 60 s, seamless sin/cos).",
                "4. Motion must still reach every region (the check measures it): the slow camera moves every textured part; add local " +
                    "motion where the picture is smooth (sky, water, shadows).",
                brightness,
                "6. Budgets: one drawImage of the picture per frame (9-argument form), effects in a few layers pre-rendered in resize(), " +
                    "\u{2264} 40 strips, no per-frame getImageData/filter/shadowBlur, fewer effects when lp.quality < 1.",
                "7. Leave `\(asset)` exactly as it is (don't edit, re-encode, rename or delete it; LivePaper restores it when you finish). " +
                    "It uses \(megabytes(animate.data.count)) MB of the \(SceneCompiler.maxAssetTotalBytes >> 20) MB asset limit.",
                "",
                "LivePaper's check compares the stills with this picture (cover-fit, allowing a slow camera): a scene that doesn't show " +
                    "it fails; one that drifts far from it gets a warning. Example: `sdk/SCENE_API.md` \u{00A7}7 \"Animating a still picture\".",
            ] + transparency
        }
        if unattached > 0 {
            lines += ["", unattachedSentence]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// How each of the check's screen shapes crops a picture of `aspect` (width / height) when
    /// it is cover-fit: "16:10 crops its top and bottom, 32:9 shows a horizontal band of it, 5:4 crops its sides".
    public static func cropNote(aspect a: Double) -> String {
        func crop(_ screen: Double) -> String {
            if abs(a / screen - 1) <= 0.02 { return "shows all of it" }
            return a > screen ? "crops its sides" : "crops its top and bottom"
        }
        let wide = abs(a / (32.0 / 9) - 1) <= 0.02 || a > 32.0 / 9 ? crop(32.0 / 9) : "shows a horizontal band of it"
        return "16:10 \(crop(1512.0 / 982)), 32:9 \(wide), 5:4 \(crop(1.25))"
    }

    static let unattachedSentence = "The request mentions files on the user's Mac that weren't attached; you can't open them. " +
        "Work from the request and any attached images."

    // MARK: - The in-session check

    /// The reference the CLI's `livepaper check` compares with, when it runs inside an AI session on
    /// that session's candidate (`<ws>/scene`) and the session animates a picture. The index is in
    /// the agent's reach (Codex may write anywhere in the workspace), so this is advisory: LivePaper's
    /// own final check uses the target it kept in memory.
    public static func checkTarget(forPackage package: URL,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> ReferenceTarget? {
        guard AISessionPolicy.isActive(environment), let wsPath = environment[AISessionPolicy.workspaceVariable], !wsPath.isEmpty,
              let wsReal = AISessionPolicy.realPath(wsPath), let pkgReal = AISessionPolicy.realPath(package.standardizedFileURL.path),
              pkgReal == (wsReal as NSString).appendingPathComponent("scene") else { return nil }
        let dir = URL(fileURLWithPath: wsReal).appendingPathComponent(directoryName)
        let indexURL = dir.appendingPathComponent(indexFileName)
        guard FileOps.isRegularFile(indexURL), let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(ReferenceIndex.self, from: data),
              let entry = index.images.first(where: { $0.role == .animate }),
              let asset = entry.asset, let sha = entry.assetSHA256 else { return nil }
        let plain = { (name: String) in !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") }
        guard plain(entry.file), asset.hasPrefix("scene/" + SceneCompiler.assetsDirectory + "/" + assetBaseName + "."),
              [EncodedReferenceImage.Format.jpeg, .png].map({ "scene/" + assetPath($0) }).contains(asset),
              sha.count == 64, sha.allSatisfy(\.isHexDigit) else { return nil }
        let vision = dir.appendingPathComponent(entry.file)
        guard FileOps.isRegularFile(vision), let fingerprint = try? ReferenceFingerprint(contentsOf: vision) else { return nil }
        return ReferenceTarget(assetPath: String(asset.dropFirst("scene/".count)), assetSHA256: sha, fingerprint: fingerprint)
    }
}
