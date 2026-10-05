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
}
