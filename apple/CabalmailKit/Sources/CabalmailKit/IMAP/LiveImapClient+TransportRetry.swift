import Foundation

// MARK: - Transport retry
//
// Lifted out of `LiveImapClient.swift` to keep that file under SwiftLint's
// 400-line file_length cap. These helpers are part of the same actor and
// reach `invalidate()` / `connectAndAuthenticate()` / `invalidateSelectedFolder()`
// directly via actor isolation.

extension LiveImapClient {
    /// Runs `operation`, and on a `.transport` / `.network` failure from a
    /// cached connection, invalidates + reconnects + runs it once more.
    ///
    /// Also retries once on a `"No mailbox selected"` server response: the
    /// optimistic select-skip in `select(...)` keys off our cached
    /// `selectedFolder`, but the server can implicitly drop us out of
    /// SELECTED state in ways the client doesn't observe (a parallel
    /// failed SELECT, a folder deleted/renamed by another client, etc.).
    /// Resetting the cache and re-running `operation` re-issues SELECT and
    /// recovers without bothering the user.
    ///
    /// The retry fires at most once. If the reconnect itself fails, or the
    /// second attempt fails for any reason, the error surfaces unchanged —
    /// no endless reconnect loops on a genuinely broken network. Other
    /// server errors (auth, protocol, command rejections) bypass the retry.
    ///
    /// The closure is actor-isolated (no `@Sendable`), so it can reference
    /// `self` and mutate actor state freely.
    func withTransportRetry<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch let error as CabalmailError where Self.isRecoverableTransportError(error) {
            await invalidate()
            try await connectAndAuthenticate()
            return try await operation()
        } catch let error as CabalmailError where Self.isNoMailboxSelected(error) {
            invalidateSelectedFolder()
            return try await operation()
        }
    }

    static func isRecoverableTransportError(_ error: CabalmailError) -> Bool {
        switch error {
        case .transport, .network: return true
        default: return false
        }
    }

    /// Detects the IMAP "No mailbox selected" response. Servers vary in
    /// wording (Dovecot: `"No mailbox selected."`; some older servers:
    /// `"No mailbox is selected."`), so we match case-insensitively on the
    /// stable substring.
    static func isNoMailboxSelected(_ error: CabalmailError) -> Bool {
        guard case let .imapCommandFailed(_, detail) = error else { return false }
        return detail.range(of: "no mailbox", options: .caseInsensitive) != nil
            && detail.range(of: "selected", options: .caseInsensitive) != nil
    }
}
