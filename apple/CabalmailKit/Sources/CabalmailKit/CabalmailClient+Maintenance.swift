import Foundation

// MARK: - Session maintenance

extension CabalmailClient {
    /// Removes every piece of locally cached user data: the on-disk envelope
    /// snapshots and message bodies, the local draft buffers, the outbox
    /// queue, and the saved address list, folder list and folder counts.
    /// Called on sign-out.
    ///
    /// The caches live in a shared, non-user-scoped application-support
    /// directory, so without this a second account signing in on the same
    /// device would read the previous user's mail straight from disk (and the
    /// outbox drain would even resubmit the previous user's queued messages
    /// under the new session). Best-effort: a failure to clear one cache
    /// doesn't stop the rest. It is not silent either: a step that fails
    /// has left that account's data on disk, so each one says so in the log
    /// (`WipeReport`; the address and folder caches report their own).
    public func clearLocalData() async {
        await addressCache.clear()
        await folderStateCache.clear()
        do { try await envelopeCache.clearAll() } catch { WipeReport.failed("saved message lists", error) }
        do { try await bodyCache.clearAll() } catch { WipeReport.failed("saved message bodies", error) }
        do { try await draftStore.removeAll() } catch { WipeReport.failed("drafts", error) }
        do { try await outbox.removeAll() } catch { WipeReport.failed("outbox", error) }
        do { try await rssStore?.clear() } catch { WipeReport.failed("feeds", error) }
        // Explicit rather than relying on the cache change stream's
        // `.cleared` event: sign-out must not race a fire-and-forget task
        // with the next account's sign-in.
        await spotlightIndexer?.removeAll()
    }

    /// `clearLocalData()` for the client of a session that is ending. Its
    /// feed store is retired rather than only emptied: a feed sync the
    /// session started (the Feeds sidebar's, which runs until the sidebar
    /// goes after the sign-out) would otherwise write the account's catalog
    /// and items back into the file the next account's client opens (#1937).
    /// A client that carries on, such as a new account's whose cache a
    /// different user left behind, uses `clearLocalData()`.
    public func clearLocalDataEndingSession() async {
        // First, so nothing the ending session still stores is indexed
        // behind the wipe below.
        await spotlightIndexer?.stop()
        do { try await rssStore?.retire() } catch { WipeReport.failed("feed store (retiring)", error) }
        await clearLocalData()
    }

    /// Kicks the Spotlight sweep for the current session — indexes each
    /// subscribed feed's newest items from the feed store, refreshes the
    /// subscribed-folder set and indexes each subscribed folder's top page.
    /// Called (fire-and-forget) by `wireSession` on sign-in / restore.
    public func refreshSpotlightIndex() async {
        guard let spotlightIndexer else { return }
        await spotlightIndexer.sweep(imap: imapClient, envelopeCache: envelopeCache, feedStore: rssStore)
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

/// What the sign-out wipe says when a step of it fails. A failed step leaves
/// the last account's data where the next account's client opens it, which
/// is the property the wipe exists for, so it is an error line in the
/// unified log and in Settings > Debug Log rather than a discarded `try?`.
/// Nothing retries here: another account's next sign-in wipes again before
/// it is wired.
enum WipeReport {
    static let category = "LocalWipe"

    static func failed(_ name: String, _ error: Error) {
        CabalmailLog.error(category, "\(name) not cleared, so they may still be on this device: \(error)")
    }

    /// Removes one file or directory of the wipe. A path that is already
    /// gone is cleared; any other failure is returned for the caller to
    /// report once it has finished its own clean-up.
    static func remove(_ url: URL, using fileManager: FileManager) -> Error? {
        do {
            try fileManager.removeItem(at: url)
            return nil
        } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            return error
        }
    }
}
