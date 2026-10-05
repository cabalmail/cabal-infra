import Foundation

/// Folder-list and folder-status reads that save what the server said, so an
/// app opened without a connection can still draw the sidebar and the message
/// list's counts. Callers that only need a live answer can keep using
/// `imapClient` directly; these exist for the paths whose answer is worth
/// keeping for the next offline launch.
extension CabalmailClient {
    /// `/list_folders`, saving the answer for offline launches.
    public func folders() async throws -> [Folder] {
        let generation = await folderStateCache.generation
        let folders = try await imapClient.listFolders()
        await folderStateCache.recordFolders(folders, ifUnchangedSince: generation)
        return folders
    }

    /// The folder list to draw: the server's when it answers, or, when it
    /// can't be reached, the list the last successful `folders()` saved
    /// (possibly in an earlier launch) along with the error that made it fall
    /// back. The fallback takes the failures that queue a send
    /// (`shouldQueue`), like `addressesForSending`.
    ///
    /// A saved list can lag the server, missing a folder made elsewhere since
    /// or keeping one deleted: callers must not act on it as current, the way
    /// the Spotlight gate (which purges folders missing from its set) or the
    /// launch landing's reconcile do.
    public func foldersForDisplay() async throws -> (folders: [Folder], savedBecause: CabalmailError?) {
        do {
            return (try await folders(), nil)
        } catch let error as CabalmailError where Self.shouldQueue(error) {
            guard let saved = await folderStateCache.lastKnownFolders() else { throw error }
            return (saved, error)
        }
    }

    /// Deletes `path` on the server, then from the saved list.
    public func deleteFolder(path: String) async throws {
        try await imapClient.deleteFolder(path: path)
        await folderStateCache.removeFolder(path: path)
    }

    /// Subscribes to or unsubscribes from `path` on the server, then in the
    /// saved list.
    public func setSubscribed(_ isSubscribed: Bool, path: String) async throws {
        if isSubscribed {
            try await imapClient.subscribe(path: path)
        } else {
            try await imapClient.unsubscribe(path: path)
        }
        await folderStateCache.setSubscribed(isSubscribed, path: path)
    }

    /// STATUS for `path`, saving the counts for offline launches.
    public func folderStatus(path: String, flagged: Bool = false) async throws -> FolderStatus {
        let generation = await folderStateCache.generation
        let status = try await imapClient.status(path: path, flagged: flagged)
        await folderStateCache.recordStatus(status, for: path, ifUnchangedSince: generation)
        return status
    }

    /// The counts the last successful `folderStatus(path:flagged:)` saved for
    /// `path`, possibly in an earlier launch. For display while the server is
    /// out of reach: they can lag it, so they must never drive paging,
    /// pruning or UIDVALIDITY decisions.
    public func savedFolderStatus(path: String) async -> FolderStatus? {
        await folderStateCache.lastKnownStatus(for: path)
    }

    /// Every folder's saved counts, keyed by path. See `savedFolderStatus`.
    public func savedFolderStatuses() async -> [String: FolderStatus] {
        await folderStateCache.lastKnownStatuses()
    }
}
