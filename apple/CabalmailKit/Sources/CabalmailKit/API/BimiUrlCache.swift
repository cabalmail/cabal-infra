import Foundation

/// Per-session, domain-keyed memo for BIMI logo lookups.
///
/// `fetchBimiURL` has no transport-level cache, so resolving a sender
/// domain's logo always round-trips the Lambda `/fetch_bimi` endpoint.
/// The message detail view only ever asks for one sender at a time, so
/// that was fine — but the message list shows an avatar per row, and its
/// rows recycle as the user scrolls, so the same handful of domains would
/// otherwise be re-fetched on every scroll-back. This cache collapses each
/// domain to at most one round-trip per app launch (shared by the list and
/// the detail view).
///
/// Entries are keyed by lowercased domain and store the *task*, not the
/// resolved value, so two rows that miss the same domain concurrently share
/// one in-flight fetch instead of racing two. Misses are cached too (a
/// domain with no BIMI record, or a failed lookup, resolves to `nil` and
/// stays `nil` for the session) — matching `LiveContactsStore`'s
/// cache-the-miss policy, on the same reasoning: a known-unknown shouldn't
/// re-hit the network on every render.
public actor BimiUrlCache {
    private var tasks: [String: Task<URL?, Never>] = [:]

    public init() {}

    /// Returns the cached BIMI URL for `domain`, invoking `fetch` exactly
    /// once per domain per session on a miss. Concurrent callers for the
    /// same domain await the same in-flight fetch.
    ///
    /// `fetch` is expected to swallow its own errors (return `nil`); a `nil`
    /// result — whether "no BIMI record" or "lookup failed" — is cached.
    public func url(
        forDomain domain: String,
        fetch: @escaping @Sendable (String) async -> URL?
    ) async -> URL? {
        let key = domain.lowercased()
        if let existing = tasks[key] {
            return await existing.value
        }
        let task = Task { await fetch(key) }
        tasks[key] = task
        return await task.value
    }
}
