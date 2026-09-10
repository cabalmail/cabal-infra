import Foundation

// MARK: - Session maintenance

extension CabalmailClient {
    /// Removes every piece of locally cached user data: the on-disk envelope
    /// snapshots and message bodies, the local draft buffers, the outbox
    /// queue, and the in-memory address list. Called on sign-out.
    ///
    /// The caches live in a shared, non-user-scoped application-support
    /// directory, so without this a second account signing in on the same
    /// device would read the previous user's mail straight from disk (and the
    /// outbox drain would even resubmit the previous user's queued messages
    /// under the new session). Best-effort: a failure to clear one cache
    /// doesn't stop the rest.
    public func clearLocalData() async {
        await addressCache.invalidate()
        try? await envelopeCache.clearAll()
        try? await bodyCache.clearAll()
        try? await draftStore.removeAll()
        try? await outbox.removeAll()
        try? await rssStore?.clear()
        // Explicit rather than relying on the cache change stream's
        // `.cleared` event: sign-out must not race a fire-and-forget task
        // with the next account's sign-in.
        await spotlightIndexer?.removeAll()
    }

    /// Kicks the Spotlight sweep for the current session — refreshes the
    /// subscribed-folder set and indexes each subscribed folder's top page.
    /// Called (fire-and-forget) by `wireSession` on sign-in / restore.
    public func refreshSpotlightIndex() async {
        guard let spotlightIndexer else { return }
        await spotlightIndexer.sweep(imap: imapClient, envelopeCache: envelopeCache)
    }

    /// Activate or deactivate MetricKit diagnostic collection. The Settings
    /// toggle bridges its `Preferences.crashReportingEnabled` value into
    /// this method so a user opt-in immediately starts receiving crash and
    /// hang payloads (the next reports arrive at *the following* launch,
    /// per MetricKit's delivery semantics).
    public nonisolated func setCrashReportingEnabled(_ enabled: Bool) {
        if enabled {
            metricKitCollector.start()
        } else {
            metricKitCollector.stop()
        }
    }
}
