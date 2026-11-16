// CollectionText — the app's rules and wording for collections that don't need SwiftUI: whether
// scenes are in a collection ("Add to Collection ▸" checkmarks), names for new collections, and what
// the banners say after adding, removing, moving, deleting, exporting and importing.
// Foundation-only; also compiled into LivePaperSelfTest via Sources/LivePaperSelfTest/AppLogic/.
import Foundation
import LivePaperCore

/// How many of some scenes a collection has (one scene: all or none).
enum CollectionMembership: Equatable, Sendable {
    case none, some, all

    init(_ sceneIDs: [String], in collection: SceneCollection) {
        let have = Set(collection.sceneIDs)
        let n = CollectionOrder.unique(sceneIDs).filter(have.contains).count
        self = sceneIDs.isEmpty || n == 0 ? .none : n == Set(sceneIDs).count ? .all : .some
    }

    /// Choosing the collection in "Add to Collection ▸" takes the scenes out when it has every one
    /// of them (its checkmark is on), and otherwise adds the ones it doesn't have.
    var choosingRemoves: Bool { self == .all }
}

enum CollectionText {
    static let newCollectionBaseName = "New Collection"

    /// "New Collection", then "New Collection 2", … (names are unique, ignoring case and accents).
    static func defaultNewName(existing: [String]) -> String {
        SceneCollection.uniqueName(newCollectionBaseName, existing: existing)
    }

    /// Trims a typed name; nil when it is blank or too long.
    static func validatedName(_ name: String) -> String? {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.count > SceneCollection.maxNameLength ? nil : SceneCollection.displayName(t)
    }

    /// Whether another collection already has this name (the one being renamed doesn't count).
    static func isTaken(_ name: String, in collections: [SceneCollection], except id: String? = nil) -> Bool {
        let key = SceneCollection.nameKey(name)
        return collections.contains { $0.id != id && SceneCollection.nameKey($0.name) == key }
    }

    /// "No scenes", "1 scene", "4 scenes".
    static func sceneCount(_ n: Int) -> String {
        n == 0 ? "No scenes" : n == 1 ? "1 scene" : "\(n) scenes"
    }

    /// “Aurora Lake” for one scene, "3 scenes" for more.
    static func scenes(_ ids: [String], names: [String: String]) -> String {
        ids.count == 1 ? quoted(names[ids[0]] ?? ids[0]) : "\(ids.count) scenes"
    }

    static func quoted(_ s: String) -> String { "\u{201C}\(s)\u{201D}" }

    static func added(_ ids: [String], to collection: String, names: [String: String]) -> String {
        "Added \(scenes(ids, names: names)) to \(quoted(collection))"
    }

    static func removed(_ ids: [String], from collection: String, names: [String: String]) -> String {
        "Removed \(scenes(ids, names: names)) from \(quoted(collection))"
    }

    static func moved(_ ids: [String], to collection: String, names: [String: String]) -> String {
        "Moved \(scenes(ids, names: names)) to \(quoted(collection))"
    }

    /// After dragging scenes from one collection's section to another's: a drag adds, it doesn't move.
    static func copiedNote(_ ids: [String], from collection: String) -> String {
        (ids.count == 1 ? "It stays in \(quoted(collection)) too." : "They stay in \(quoted(collection)) too.")
            + " To move scenes instead, use Move to Collection in their menu."
    }

    /// What a drop target says while scene cards are dragged over it.
    static func dropLabel(_ plan: CollectionDropPlan, collection: String) -> String? {
        switch plan {
        case .none: return nil
        case .add(let ids, _, _): return ids.count == 1 ? "Add to \(quoted(collection))" : "Add \(ids.count) to \(quoted(collection))"
        case .reorder: return "Move here"
        }
    }

    /// Nothing was added: every scene is in it already.
    static func alreadyIn(_ ids: [String], collection: String, names: [String: String]) -> String {
        ids.count == 1 ? "\(quoted(names[ids[0]] ?? ids[0])) is already in \(quoted(collection))"
                       : "These scenes are already in \(quoted(collection))"
    }

    /// After deleting a scene that was in collections: "It was also removed from “Night Skies”."
    static func removedFromCollections(_ collections: [SceneCollection]) -> String? {
        let names = SceneCollection.sorted(collections).map { quoted($0.name) }
        switch names.count {
        case 0: return nil
        case 1: return "It was also removed from \(names[0])."
        case 2: return "It was also removed from \(names[0]) and \(names[1])."
        default: return "It was also removed from \(names.count) collections."
        }
    }

    /// The live link, as the UI words it wherever the screen saver plays a collection.
    static func followsNote(_ name: String) -> String {
        "The screen saver follows \(quoted(name)): adding, removing or reordering its scenes updates it."
    }

    /// The delete sheet's subtitle.
    static func deleteSubtitle(_ collection: SceneCollection, sceneCount: Int) -> String {
        sceneCount == 0 ? "The collection is empty." : "Its \(sceneCount == 1 ? "scene stays" : "\(sceneCount) scenes stay") in your library."
    }

    /// "Exported “Night Skies” to Night Skies.lpcollection" + what's in it.
    static func exportMessage(_ result: CollectionExport) -> String {
        var parts: [String] = []
        let mine = result.includedScenes.count, builtin = result.builtinScenes.count
        parts.append(mine == 1 ? "1 of your scenes is in the file" : "\(mine) of your scenes are in the file")
        if builtin > 0 {
            parts.append(builtin == 1 ? "1 built-in scene is named, not copied (every LivePaper has it)"
                                      : "\(builtin) built-in scenes are named, not copied (every LivePaper has them)")
        }
        if !result.missingScenes.isEmpty {
            parts.append("\(result.missingScenes.count) no longer in your library \(result.missingScenes.count == 1 ? "was" : "were") left out")
        }
        return parts.joined(separator: "; ") + "."
    }

    /// What an import banner says (the style, the title and the message). `lacking` imports offer
    /// "Add N Scenes" / "Import as a Copy" (AppModel).
    struct ImportBanner: Equatable, Sendable {
        enum Style: Equatable, Sendable { case info, success, warning }
        var style: Style
        var title: String
        var message: String?
    }

    static func importBanner(_ result: CollectionImport, fileName: String) -> ImportBanner {
        let name = quoted(result.collection.name)
        var lines: [String] = []
        let fresh = result.importedScenes.count, had = result.existingScenes.count
        var style = ImportBanner.Style.success
        let title: String
        switch result.outcome {
        case .created:
            title = "Imported the collection \(name)"
            let total = result.collection.sceneIDs.count
            var line = sceneCount(total)
            if fresh > 0 && had > 0 { line += ": \(fresh) new to your library, \(had) you already had" }
            else if had > 0 && total > 0 { line += ", all already in your library" }
            lines.append(line + ".")
        case .merged:
            title = result.added.isEmpty ? "\(name) already has every scene in \(fileName)"
                                         : "Added \(sceneCount(result.added.count).lowercased()) to \(name)"
            if result.added.isEmpty { style = .info }
            if fresh > 0 { lines.append("\(fresh == 1 ? "1 is" : "\(fresh) are") new to your library.") }
        case .alreadyPresent:
            title = "\(name) is already in your library"
            style = result.lacking.isEmpty ? .info : .warning
            if !result.lacking.isEmpty {
                let names = result.lacking.prefix(3).map(quoted).joined(separator: ", ") + (result.lacking.count > 3 ? ", …" : "")
                lines.append("\(fileName) has \(sceneCount(result.lacking.count).lowercased()) it doesn\u{2019}t: \(names).")
            }
        }
        if !result.missing.isEmpty {
            if style == .success { style = .warning }
            let first = result.missing[0]
            lines.append(result.missing.count == 1
                ? "\(quoted(first.name)) couldn\u{2019}t be added: \(first.reason)."
                : "\(result.missing.count) scenes couldn\u{2019}t be added, such as \(quoted(first.name)): \(first.reason).")
        }
        return ImportBanner(style: style, title: title, message: lines.isEmpty ? nil : lines.joined(separator: " "))
    }
}
