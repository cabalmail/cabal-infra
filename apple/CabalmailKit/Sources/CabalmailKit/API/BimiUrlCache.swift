import Foundation

/// Per-process, domain-keyed memo for BIMI logo lookups (one instance, on
/// `AppState`, which outlives sign-out).
///
/// `fetchBimiURL` has no transport-level cache, so resolving a sender
/// domain's logo always round-trips the Lambda `/fetch_bimi` endpoint.
/// The message detail view only ever asks for one sender at a time, so
/// that was fine — but the message list shows an avatar per row, and its
/// rows recycle as the user scrolls, so the same handful of domains would
/// otherwise be re-fetched on every scroll-back. This cache collapses each
/// domain to at most one answered round-trip per app launch (shared by the
/// list and the detail view).
///
/// Entries are keyed by lowercased domain and store the *task*, not the
/// resolved value, so two rows that miss the same domain concurrently share
/// one in-flight fetch instead of racing two. Misses are cached too (the
/// endpoint answers `{"url": null}` whenever it has no logo to give) —
/// matching `LiveContactsStore`'s cache-the-miss policy, on the same
/// reasoning: a known-unknown shouldn't re-hit the network on every render.
/// A lookup that throws got no answer at all (offline, a gateway error, an
/// expired session), so it is not cached: its callers get `nil` and the
/// next lookup asks again. Caching it had kept an offline launch's senders
/// on initials until relaunch (#1889).
public actor BimiUrlCache {
    private var tasks: [String: Task<URL?, Never>] = [:]

    public init() {}

    /// Returns the cached BIMI URL for `domain`, invoking `fetch` on a miss
    /// until it returns an answer. Concurrent callers for the same domain
    /// await the same in-flight fetch.
    ///
    /// A value `fetch` returns, `nil` included, is the domain's answer for
    /// the life of the cache. An error it throws reaches every caller of
    /// that fetch as `nil` and leaves no entry behind.
    public func url(
        forDomain domain: String,
        fetch: @escaping @Sendable (String) async throws -> URL?
    ) async -> URL? {
        let key = domain.lowercased()
        if let existing = tasks[key] {
            return await existing.value
        }
        let task = Task {
            do {
                return try await fetch(key)
            } catch {
                // Isolated to the actor, and unable to start before the
                // entry below is stored, so the entry it drops is its own.
                self.tasks[key] = nil
                return nil
            }
        }
        tasks[key] = task
        return await task.value
    }

    /// `url(forDomain:fetch:)` through `client`'s `/fetch_bimi`. The
    /// endpoint's 400, its rejection of a sender host that isn't a domain
    /// (`localhost`, say), is an answer — no logo — and is cached like one;
    /// any other error is a lookup that failed.
    public func url(forDomain domain: String, using client: any ApiClient) async -> URL? {
        await url(forDomain: domain) { key in
            do {
                return try await client.fetchBimiURL(senderDomain: key)
            } catch CabalmailError.server(let code, _) where code == "400" {
                return nil
            }
        }
    }
}
