import Foundation

// MARK: - Failed sends

extension CabalmailClient {
    /// Puts a message that ran out of retries back in the send queue with a
    /// fresh retry budget and starts a drain. The app's failed-send banner
    /// calls this; the entries come from `outbox.changes()`.
    public func retryFailedSend(id: UUID) async throws {
        guard try await outbox.resetForRetry(id: id) != nil else { return }
        #if canImport(Network)
        await sendQueue?.kickDrain()
        #endif
    }

    /// Deletes a message the user chose not to send after it failed.
    public func discardFailedSend(id: UUID) async throws {
        try await outbox.remove(id: id)
    }
}
