import Foundation

extension CabalmailClient {
    /// The raw RFC 5322 bytes of one message, through the body cache: a
    /// message that has been read is served from disk; anything else is
    /// fetched and cached. The reader's open and the list's drag-out both
    /// come through here.
    ///
    /// The cache is keyed by the folder's UIDVALIDITY. It comes from the
    /// folder's envelope snapshot, or else from STATUS. When STATUS fails
    /// (offline, with no snapshot for the folder: a search hit's source
    /// folder, or one Mark All as Read has just invalidated), the body is
    /// looked up under the UIDVALIDITY the folder last reported, so a body
    /// read before still opens (#1810). That saved value is used for this
    /// lookup only: on a miss the STATUS error stands, and nothing is
    /// fetched or stored under it.
    ///
    /// Storing the fetched bytes is best-effort: a failed cache write (a full
    /// disk, a removed cache directory) is logged and the bytes are still
    /// returned (#1811).
    public func rawMessage(folder: String, uid: UInt32) async throws -> Data {
        let uidValidity: UInt32
        if let snapshot = await envelopeCache.snapshot(for: folder) {
            uidValidity = snapshot.uidValidity
        } else {
            do {
                uidValidity = try await imapClient.status(path: folder).uidValidity ?? 0
            } catch {
                if let saved = await savedFolderStatus(path: folder)?.uidValidity,
                   let cached = await bodyCache.fetch(folder: folder, uidValidity: saved, uid: uid) {
                    return cached
                }
                throw error
            }
        }
        if let cached = await bodyCache.fetch(folder: folder, uidValidity: uidValidity, uid: uid) {
            return cached
        }
        let raw = try await imapClient.fetchBody(folder: folder, uid: uid)
        do {
            try await bodyCache.store(folder: folder, uidValidity: uidValidity, uid: uid, bytes: raw.bytes)
        } catch {
            CabalmailLog.warn("bodies", "could not cache a message body: \(error.localizedDescription)")
        }
        return raw.bytes
    }

    /// Forgets messages the server has confirmed gone from their folders (a
    /// dispose, move or purge that landed): each leaves its own folder's
    /// envelope cache, and its body leaves the body cache. The list, the
    /// reader and the search surface all come through here, so a removal
    /// from global search clears the source folder's offline copy too
    /// (#1869).
    ///
    /// The body cache is keyed by the folder's UIDVALIDITY, resolved per
    /// folder from the ref itself, then the folder's envelope snapshot, then
    /// the value the folder last reported, then a STATUS. When none resolves
    /// (offline, with nothing saved), the body entry is left alone rather
    /// than guessed at. A ref minted under a UIDVALIDITY the snapshot has
    /// since replaced leaves the snapshot's row alone: its UID may name a
    /// different message now.
    public func forgetRemovedMessages(_ refs: [MessageRef]) async {
        for (folder, group) in Dictionary(grouping: refs, by: \.folder) {
            let snapshotValidity = await envelopeCache.snapshot(for: folder)?.uidValidity
            let current = group.filter { !$0.conflicts(withUIDValidity: snapshotValidity) }
            try? await envelopeCache.remove(uids: current.map(\.uid), folder: folder)
            var folderValidity: UInt32?
            if group.contains(where: { $0.uidValidity == nil }) {
                folderValidity = await uidValidityForForgetting(folder: folder, snapshot: snapshotValidity)
            }
            for ref in group {
                guard let key = ref.uidValidity ?? folderValidity else { continue }
                await bodyCache.remove(folder: folder, uidValidity: key, uid: ref.uid)
            }
        }
    }

    /// The folder's UIDVALIDITY for forgetting a body: its snapshot's, the
    /// one it last reported, or a STATUS's; nil when none answers.
    private func uidValidityForForgetting(folder: String, snapshot: UInt32?) async -> UInt32? {
        if let snapshot, snapshot != 0 { return snapshot }
        if let saved = await savedFolderStatus(path: folder)?.uidValidity, saved != 0 { return saved }
        guard let fetched = try? await imapClient.status(path: folder).uidValidity, fetched != 0 else { return nil }
        return fetched
    }
}
