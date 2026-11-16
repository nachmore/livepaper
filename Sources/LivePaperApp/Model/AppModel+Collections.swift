// AppModel+Collections — collections of scenes in the app (ARCHITECTURE §11): reading them, the
// sidebar's and the menus' edits, export and import, and the screen saver following one.
//
// The screen saver plays the copies compiled when the playlist was published, so a change to the
// collection the playlist follows is published again here (quietly; only when a saver is
// installed — otherwise just the stored copy of its scenes is updated). Changes the CLI makes
// publish themselves (CollectionCommands); the disk watcher only re-reads them.
//
// Foundation + Observation only (also compiled into LivePaperSelfTest via AppLogic/).
import Foundation
import LivePaperCore

extension AppModel {
    // MARK: - Reading

    func loadCollections() async {
        collectionsReadSeq += 1
        let seq = collectionsReadSeq
        let service = services.collections
        let fresh = (try? await offMain { service.collections() }) ?? []
        // Reads run off the main actor and may finish out of order (see reloadLibrary).
        guard seq > collectionsAppliedSeq else { return }
        collectionsAppliedSeq = seq
        applyCollections(fresh)
    }

    /// The service's answer to an edit is the newest state there is.
    private func didEditCollections() async {
        collectionsReadSeq += 1
        collectionsAppliedSeq = collectionsReadSeq
        let service = services.collections
        applyCollections((try? await offMain { service.collections() }) ?? collections)
    }

    private func applyCollections(_ fresh: [SceneCollection]) {
        if fresh != collections { collections = fresh }
        // The collection on screen was deleted (here, or by the CLI): back to the library.
        if case .collection(let id)? = section, !fresh.contains(where: { $0.id == id }) { section = .library }
    }

    func collection(id: String) -> SceneCollection? { collections.first { $0.id == id } }

    /// The collection's scenes that are in the library, in its order (others are skipped).
    func collectionEntries(_ id: String) -> [LibraryEntry] {
        guard let c = collection(id: id) else { return [] }
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return c.sceneIDs.compactMap { byID[$0] }
    }

    /// How many of its scenes are in the library (the sidebar's count).
    func sceneCount(of collection: SceneCollection) -> Int {
        collection.existingSceneIDs(available: Set(availableSceneIDs)).count
    }

    /// The collections a scene is in, by name.
    func collections(containing sceneID: String) -> [SceneCollection] {
        collections.filter { $0.sceneIDs.contains(sceneID) }
    }

    func isFollowed(_ collectionID: String) -> Bool { playlist.collectionID == collectionID && collection(id: collectionID) != nil }

    func showCollection(_ id: String) {
        section = .collection(id)
        collectionPath = []
    }

    // MARK: - Editing

    /// - Parameter show: open it once it is created (the sidebar's "New Collection…"); creating one
    ///   for some scenes stays where the user is and offers "Show".
    @discardableResult
    func createCollection(name: String, sceneIDs: [String] = [], show: Bool? = nil) async -> SceneCollection? {
        let service = services.collections
        do {
            let created = try await offMain { try service.create(name: name, sceneIDs: sceneIDs) }
            await didEditCollections()
            if show ?? sceneIDs.isEmpty {
                showCollection(created.id)
            } else {
                banners.post(.success, "Created \(CollectionText.quoted(created.name))",
                             message: CollectionText.sceneCount(created.sceneIDs.count) + ".",
                             actions: [.init(title: "Show") { [weak self] in self?.showCollection(created.id) }])
            }
            return created
        } catch {
            banners.error("Couldn\u{2019}t create the collection", error)
            return nil
        }
    }

    @discardableResult
    func renameCollection(_ id: String, to name: String) async -> Bool {
        let service = services.collections
        do {
            _ = try await offMain { try service.rename(id: id, to: name) }
            await didEditCollections()
            return true
        } catch {
            banners.error("Couldn\u{2019}t rename the collection", error)
            return false
        }
    }

    /// Never deletes scenes. A playlist that followed it keeps playing its scenes, as a list.
    func deleteCollection(_ id: String) async {
        let service = services.collections
        do {
            let gone = try await offMain { try service.delete(id: id) }
            let count = gone.existingSceneIDs(available: Set(availableSceneIDs)).count
            await didEditCollections()
            if playlist.collectionID == id {
                var s = playlist.following([gone])
                s.collectionID = nil
                await storeOrPublish(s)
            }
            banners.post(.success, "Deleted the collection \(CollectionText.quoted(gone.name))",
                         message: CollectionText.deleteSubtitle(gone, sceneCount: count))
        } catch {
            banners.error("Couldn\u{2019}t delete the collection", error)
        }
    }

    /// Adds scenes at the end (or `placement`). `playlistNote`: the user asked to add to the playlist,
    /// which is this collection.
    func addToCollection(_ sceneIDs: [String], _ collectionID: String, at placement: CollectionPlacement = .end,
                         playlistNote: Bool = false) async {
        guard !sceneIDs.isEmpty else { return }
        let service = services.collections
        let name = collection(id: collectionID)?.name ?? ""
        do {
            let edit = try await offMain { try service.add(sceneIDs, to: collectionID, at: placement) }
            await didEditCollections()
            guard !edit.changed.isEmpty else {
                banners.post(.info, CollectionText.alreadyIn(sceneIDs, collection: edit.collection.name, names: sceneNames))
                return
            }
            await collectionDidChange(edit.collection)
            let followed = isFollowed(collectionID)
            banners.post(.success, CollectionText.added(edit.changed, to: edit.collection.name, names: sceneNames),
                         message: playlistNote || followed ? "The screen saver plays this collection, so it plays \(edit.changed.count == 1 ? "it" : "them") too." : nil,
                         actions: section == .collection(collectionID) ? []
                             : [.init(title: "Show") { [weak self] in self?.showCollection(collectionID) }])
        } catch {
            banners.error("Couldn\u{2019}t add to \(CollectionText.quoted(name))", error)
        }
    }

    func removeFromCollection(_ sceneIDs: [String], _ collectionID: String, announce: Bool = true) async {
        guard !sceneIDs.isEmpty else { return }
        let service = services.collections
        let name = collection(id: collectionID)?.name ?? ""
        do {
            let edit = try await offMain { try service.remove(sceneIDs, from: collectionID) }
            // On the collection's own screen the removed cards are gone, and so is their selection.
            if section == .collection(collectionID) { selection.retain(edit.collection.sceneIDs) }
            await didEditCollections()
            guard !edit.changed.isEmpty else { return }
            await collectionDidChange(edit.collection)
            if announce { banners.post(.success, CollectionText.removed(edit.changed, from: edit.collection.name, names: sceneNames)) }
        } catch {
            banners.error("Couldn\u{2019}t remove from \(CollectionText.quoted(name))", error)
        }
    }

    /// Drag and drop within a collection (no banner: the grid shows it).
    func moveScenes(_ sceneIDs: [String], in collectionID: String, to placement: CollectionPlacement) async {
        let service = services.collections
        do {
            let edit = try await offMain { try service.move(sceneIDs, in: collectionID, to: placement) }
            await didEditCollections()
            if !edit.changed.isEmpty { await collectionDidChange(edit.collection) }
        } catch {
            banners.error("Couldn\u{2019}t change the order", error)
        }
    }

    /// "Move to ▸": into another collection and out of this one.
    func moveToCollection(_ sceneIDs: [String], from source: String, to target: String) async {
        guard source != target, !sceneIDs.isEmpty else { return }
        let service = services.collections
        do {
            let added = try await offMain { try service.add(sceneIDs, to: target, at: .end) }
            let removed = try await offMain { try service.remove(sceneIDs, from: source) }
            selection.clear()
            await didEditCollections()
            if !added.changed.isEmpty { await collectionDidChange(added.collection) }
            if !removed.changed.isEmpty { await collectionDidChange(removed.collection) }
            banners.post(.success, CollectionText.moved(sceneIDs, to: added.collection.name, names: sceneNames),
                         actions: [.init(title: "Show") { [weak self] in self?.showCollection(target) }])
        } catch {
            banners.error("Couldn\u{2019}t move the scenes", error)
        }
    }

    /// "Add to Collection ▸" with checkmarks: choosing a collection that has every one of the scenes
    /// takes them out, otherwise adds the ones it lacks.
    func toggleCollection(_ sceneIDs: [String], _ collectionID: String) async {
        guard let c = collection(id: collectionID) else { return }
        if CollectionMembership(sceneIDs, in: c).choosingRemoves {
            await removeFromCollection(sceneIDs, collectionID)
        } else {
            await addToCollection(sceneIDs, collectionID)
        }
    }

    /// A collection's scenes changed: when the screen saver follows it, publish it again.
    private func collectionDidChange(_ collection: SceneCollection) async {
        guard playlist.collectionID == collection.id else { return }
        await storeOrPublish(playlist.following([collection]))
    }

    /// Publishes `settings` quietly when a saver is installed, else stores them for setup to publish.
    private func storeOrPublish(_ settings: PlaylistSettings) async {
        if !installStatusLoaded { await refreshInstallStatus() }
        await savePlaylist(settings, announce: false, publishNow: installStatus.saverInstalled)
    }

    // MARK: - The screen saver

    /// "Use as Screen Saver" on a collection: the playlist follows it (a live link, see the file
    /// comment). The playback settings stay.
    func useCollectionAsScreenSaver(_ id: String) async {
        guard let c = collection(id: id) else { return }
        guard !c.existingSceneIDs(available: Set(availableSceneIDs)).isEmpty else {
            banners.post(.info, "\(CollectionText.quoted(c.name)) is empty", message: "Add scenes to it first.")
            return
        }
        var draft = PlaylistDraft(playlist)
        draft.follow(c)
        guard await savePlaylist(draft.settings, announce: false) else { return }
        banners.post(.success, "The screen saver plays \(CollectionText.quoted(c.name))", message: CollectionText.followsNote(c.name),
                     actions: [.init(title: "Show Screen Saver") { [weak self] in self?.section = .playlist }])
    }

    // MARK: - Export / import

    func exportCollection(_ id: String, to url: URL) async {
        let service = services.collections
        do {
            let result = try await offMain { try service.export(id: id, to: url) }
            banners.post(.success, "Exported \(CollectionText.quoted(result.collection.name)) to \(url.lastPathComponent)",
                         message: CollectionText.exportMessage(result))
        } catch {
            banners.error("Couldn\u{2019}t export the collection", error) { [weak self] in Task { await self?.exportCollection(id, to: url) } }
        }
    }

    /// Opening a .lpcollection (double-click in Finder, File › Import Collection…, a drop on the
    /// sidebar). Scenes the library already has aren't imported again; a collection it already has
    /// isn't changed unless the user asks ("Add N Scenes" merges, "Import as a Copy" makes another).
    func importCollection(at url: URL, mode: CollectionImportMode = .automatic) async {
        let service = services.collections
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let result: CollectionImport
        do {
            result = try await offMain { try service.importCollection(at: url, mode: mode) }
        } catch {
            banners.error("Couldn\u{2019}t import \(url.lastPathComponent)", error)
            return
        }
        if !result.importedScenes.isEmpty {
            await reloadLibrary()
            Task { await self.generateMissingThumbnails() }
        }
        await didEditCollections()
        if result.outcome == .merged, !result.added.isEmpty { await collectionDidChange(result.collection) }
        let banner = CollectionText.importBanner(result, fileName: url.lastPathComponent)
        let id = result.collection.id
        var actions: [BannerCenter.Action] = []
        if result.outcome == .alreadyPresent && !result.lacking.isEmpty {
            let n = result.lacking.count
            actions.append(.init(title: n == 1 ? "Add 1 Scene" : "Add \(n) Scenes") { [weak self] in
                Task { await self?.importCollection(at: url, mode: .merge) }
            })
            actions.append(.init(title: "Import as a Copy") { [weak self] in Task { await self?.importCollection(at: url, mode: .copy) } })
        } else if section != .collection(id) {
            actions.append(.init(title: "Show") { [weak self] in self?.showCollection(id) })
        }
        let style: BannerCenter.Style
        switch banner.style {
        case .info: style = .info
        case .success: style = .success
        case .warning: style = .warning
        }
        banners.post(style, banner.title, message: banner.message, actions: actions)
    }
}
