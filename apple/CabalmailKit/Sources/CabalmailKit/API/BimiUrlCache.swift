import Foundation

/// Per-session, domain-keyed memo for BIMI logo lookups.
///
/// `fetchBimiURL` has no transport-level cache, so resolving a sender
/// domain's logo always round-trips the Lambda `/fetch_bimi` endpoint.
/// The message detail view only ever asks for one sender at a time, so
/// that was fine — but the message list shows an avatar per row, and its
/// rows recycle as the user scrolls, so the same handful of domains would
/// otherwise be re-fetched on every scroll-back. This cache collapses each
/// domain to at most one successful round-trip per app launch (shared by
/// the list and the detail view).
///
/// Entries are keyed by lowercased domain and store the *task*, not the
/// resolved value, so two rows that miss the same domain concurrently share
/// one in-flight fetch instead of racing two. Definite misses are cached
/// too (a domain with no BIMI record resolves to `nil` and stays `nil` for
/// the session) — matching `LiveContactsStore`'s cache-the-miss policy, on
/// the same reasoning: a known-unknown shouldn't re-hit the network on
/// every render. A lookup that *fails* is not an answer, though: the
/// endpoint reports every miss as a `nil` URL and never errors, so a thrown
/// fetch means the request never got one (offline, a gateway error, an
/// expired session). Those resolve to `nil` for the callers waiting on
/// them but leave no entry behind, so the next lookup asks again (#1889).
public actor BimiUrlCache {
    private var tasks: [String: Task<URL?, Error>] = [:]

    public init() {}

    /// Returns the cached BIMI URL for `domain`, invoking `fetch` on a miss
    /// until it returns an answer. Concurrent callers for the same domain
    /// await the same in-flight fetch.
    ///
    /// A value `fetch` returns, `nil` included, is the answer for the
    /// session. An error it throws is reported as `nil` to every caller of
    /// that fetch and is not cached.
    public func url(
        forDomain domain: String,
        fetch: @escaping @Sendable (String) async throws -> URL?
    ) async -> URL? {
        let key = domain.lowercased()
        let task: Task<URL?, Error>
        if let existing = tasks[key] {
            task = existing
        } else {
            task = Task { try await fetch(key) }
            tasks[key] = task
        }
        do {
            return try await task.value
        } catch {
            // Each waiter lands here; only the entry for this failed fetch
            // goes, never one a later lookup has already replaced it with.
            if tasks[key] == task { tasks[key] = nil }
            return nil
        }
    }
}
