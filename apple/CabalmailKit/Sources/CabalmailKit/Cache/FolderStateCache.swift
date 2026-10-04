import Foundation

/// The folder list and per-folder STATUS counts the server last returned,
/// kept on disk so an app opened without a connection can still draw the
/// sidebar's folders and badges and the message list's All / Unread /
/// Flagged counts.
///
/// Nothing here stands in for a live answer. `CabalmailClient` records what
/// the server said (`folders()`, `folderStatus(path:flagged:)`) and reads it
/// back only when the server can't be reached (`foldersForDisplay()`,
/// `savedFolderStatus(path:)`). Without a directory (tests, previews) the
/// cache saves nothing, like `AddressCache`.
public actor FolderStateCache {
    private struct Saved: Codable {
        var folders: [Folder]?
        var statuses: [String: FolderStatus] = [:]
    }

    /// Read back on every call rather than held in memory: the push and
    /// Siri handlers build clients of their own over the same directory, and
    /// a copy held here would write their updates over.
    private let fileURL: URL?

    /// Bumped by `clear()` and by changes this device makes to the list. A
    /// fetch reads it before going to the server and records its answer only
    /// if it hasn't moved, so a request still in flight at sign-out can't
    /// write the signed-out account's folders back, nor a list read before a
    /// delete put the deleted folder back.
    public private(set) var generation = 0

    public init(directory: URL? = nil) {
        self.fileURL = directory?.appendingPathComponent("folders.json")
    }

    /// Saves a folder list, dropping the counts of folders no longer in it.
    public func recordFolders(_ folders: [Folder], ifUnchangedSince generation: Int) {
        guard generation == self.generation, fileURL != nil else { return }
        var state = load()
        state.folders = folders
        let paths = Set(folders.map(\.path))
        state.statuses = state.statuses.filter { paths.contains($0.key) }
        save(state)
    }

    /// Saves one folder's STATUS. A reply that left a count out (the cheap
    /// STATUS carries no flagged count) keeps the one saved before.
    public func recordStatus(_ status: FolderStatus, for path: String, ifUnchangedSince generation: Int) {
        guard generation == self.generation, fileURL != nil else { return }
        var state = load()
        let previous = state.statuses[path]
        state.statuses[path] = FolderStatus(
            messages: status.messages ?? previous?.messages,
            unseen: status.unseen ?? previous?.unseen,
            flagged: status.flagged ?? previous?.flagged,
            recent: status.recent ?? previous?.recent,
            uidValidity: status.uidValidity ?? previous?.uidValidity,
            uidNext: status.uidNext ?? previous?.uidNext
        )
        save(state)
    }

    /// Drops `path` and its counts from the saved list, after this device
    /// deleted it, so an offline launch doesn't bring it back.
    public func removeFolder(path: String) {
        generation += 1
        guard fileURL != nil else { return }
        var state = load()
        guard let folders = state.folders else { return }
        state.folders = folders.filter { $0.path != path }
        state.statuses[path] = nil
        save(state)
    }

    /// Records a subscription change this device made in the saved list.
    public func setSubscribed(_ isSubscribed: Bool, path: String) {
        generation += 1
        guard fileURL != nil else { return }
        var state = load()
        guard let folders = state.folders else { return }
        state.folders = folders.map { folder in
            guard folder.path == path else { return folder }
            return Folder(path: folder.path, attributes: folder.attributes, isSubscribed: isSubscribed)
        }
        save(state)
    }

    /// Adjusts a saved folder's counts to a change made on this device (a
    /// message read, Mark All as Read, Empty Trash), so an offline launch
    /// shows the counts the app last showed rather than the STATUS before
    /// the change. Only a folder the server has reported is adjusted; after
    /// `clear()` there is none, so a change racing sign-out writes nothing.
    public func recordLocalCounts(unseen: Int, messages: Int?, for path: String) {
        guard fileURL != nil else { return }
        var state = load()
        guard let previous = state.statuses[path] else { return }
        let total = messages ?? previous.messages
        state.statuses[path] = FolderStatus(
            messages: total,
            unseen: unseen,
            // An emptied folder (Empty Trash) has nothing flagged either.
            flagged: previous.flagged.map { flagged in total.map { min(flagged, $0) } ?? flagged },
            recent: previous.recent,
            uidValidity: previous.uidValidity,
            uidNext: previous.uidNext
        )
        save(state)
    }

    /// The folder list last saved, possibly by an earlier launch.
    public func lastKnownFolders() -> [Folder]? {
        guard fileURL != nil else { return nil }
        return load().folders
    }

    /// The STATUS counts last saved for `path`, possibly by an earlier launch.
    public func lastKnownStatus(for path: String) -> FolderStatus? {
        lastKnownStatuses()[path]
    }

    /// Every folder's saved STATUS counts, keyed by path.
    public func lastKnownStatuses() -> [String: FolderStatus] {
        guard fileURL != nil else { return [:] }
        return load().statuses
    }

    /// Forgets everything, in memory and on disk. Sign-out calls this so the
    /// next account on the device doesn't inherit this one's folders.
    public func clear() {
        generation += 1
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func load() -> Saved {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Saved.self, from: data) else {
            return Saved()
        }
        return decoded
    }

    private func save(_ state: Saved) {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(state).write(to: fileURL, options: .atomic)
        } catch {
            CabalmailLog.warn("FolderStateCache", "couldn't save folder state: \(error)")
        }
    }
}
