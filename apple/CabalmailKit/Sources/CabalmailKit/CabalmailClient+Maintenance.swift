import Foundation

// MARK: - Session maintenance

extension CabalmailClient {
    /// Removes every piece of locally cached user data: the on-disk envelope
    /// snapshots and message bodies, the local draft buffers, the outbox
    /// queue, and the saved address list, folder list and folder counts.
    /// Called on sign-out.
    ///
    /// The outbox, drafts, address list and feed store live in a shared,
    /// non-user-scoped application-support directory, so without this a
    /// second account signing in on the same device would read the previous
    /// user's data straight from disk (and the outbox drain would even
    /// resubmit the previous user's queued messages under the new session).
    /// A client with an account keeps its message lists, bodies and folder
    /// state in that account's own directory, and they are emptied here all
    /// the same; so is whatever an earlier build left where those three used
    /// to be, if the launch could not move it into its account's directory
    /// (`AccountDirectory.prepareAtLaunch(root:remembered:)`). Best-effort: a failure to clear one cache
    /// doesn't stop the rest. It is not silent either: a step that fails
    /// has left that account's data on disk, so each one says so in the log
    /// (`WipeReport`; the address and folder caches report their own).
    public func clearLocalData() async {
        await clearLocalData(endingSession: false)
    }

    /// The wipe's steps. For a session that is ending, two differ.
    ///
    /// The account's own directory is removed rather than emptied: its
    /// stores are closed, for every client that shares them, so one still
    /// held cannot write the account's mail back, and the directory goes in
    /// one rename (`AccountStoreLease.removeAccountDirectory()`). A client
    /// without an account directory empties its caches in place, as a
    /// client that carries on does.
    ///
    /// The feeds step is skipped: the caller has retired the store, and the
    /// retire is that step (it clears, then closes the store), so a second
    /// clear could only fail on the closed database and report feeds as
    /// left behind on every healthy sign-out (#2568).
    private func clearLocalData(endingSession: Bool) async {
        await addressCache.clear()
        if endingSession, let accountLease {
            await accountLease.removeAccountDirectory()
        } else {
            await folderStateCache.clear()
            do { try await envelopeCache.clearAll() } catch { WipeReport.failed("saved message lists", error) }
            do { try await bodyCache.clearAll() } catch { WipeReport.failed("saved message bodies", error) }
        }
        removeLegacyCaches()
        do { try await draftStore.removeAll() } catch { WipeReport.failed("drafts", error) }
        do { try await outbox.removeAll() } catch { WipeReport.failed("outbox", error) }
        if !endingSession {
            do { try await rssStore?.clear() } catch { WipeReport.failed("feeds", error) }
        }
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
        // The feeds step of this wipe, whether it throws or not: a retire
        // that fails has still closed the store, so there is nothing a
        // second attempt could clear, and its one line is the report.
        do { try await rssStore?.retire() } catch { WipeReport.failed("feed store (retiring)", error) }
        await clearLocalData(endingSession: true)
    }

    /// Removes the message lists, bodies and folder state a build from
    /// before the account directory left in the shared directory. The
    /// launch moves them into the remembered account's directory, so this
    /// finds some only when that move failed. This client never opens them,
    /// so emptying its own caches does not reach them, and they are still
    /// the last account's mail on this device. Nothing to do for a
    /// client without an account, whose own caches are those directories.
    private nonisolated func removeLegacyCaches() {
        for directory in accountLease?.legacyDirectories ?? [] {
            if let error = WipeReport.remove(directory, using: .default) {
                WipeReport.failed("mail saved by an earlier version (\(directory.lastPathComponent))", error)
            }
        }
    }

    /// `shutdown()` for the client of an interactive sign-in that did not
    /// finish: the password or the code was refused, the request failed, or
    /// the user backed out of the second-factor prompt. If building this
    /// client is what made its account's directory, and no other client of
    /// that account is alive, the directory is removed, so a mistyped
    /// username does not leave a directory behind for an account that never
    /// signed in. A directory that was already there is left alone.
    public func abandonSignIn() async {
        accountLease?.release(removingNewDirectory: true)
        await shutdown()
    }

    /// This client's account has just signed in: every other account's
    /// directory of saved mail is removed. One is there when a session
    /// ended without its wipe (a force quit, or a launch whose refresh was
    /// refused) and this is another account. Only for a sign-in that has
    /// succeeded: one that may still be refused removes nothing, so a
    /// mistyped username cannot take the real account's saved mail. Nothing
    /// to do for a client without an account directory.
    public func removeOtherAccountsData() async {
        await accountLease?.removeOtherAccountDirectories()
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
