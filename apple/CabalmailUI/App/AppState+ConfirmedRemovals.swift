import Foundation

// The confirmed-removal shield (see `AppState.confirmedRemovals`): UIDs the
// server has confirmed gone from a folder, which a refresh already in flight
// when the removal landed must not bring back. Recorded by the list's and the
// reader's removal paths once a move or purge succeeds; read by
// `MessageListViewModel.shieldFetched` and its refresh at merge time.
extension AppState {
    /// How long a confirmed removal keeps shielding its UID. A request can't
    /// be in flight this long (the API gateway gives up after 29 s), so by
    /// then no fetch issued before the removal can still land.
    static let confirmedRemovalWindow: Duration = .seconds(60)

    /// Record that the server confirmed `uids` gone from `folderPath`.
    func recordConfirmedRemovals(
        folderPath: String,
        uids: some Sequence<UInt32>,
        at now: ContinuousClock.Instant = .now
    ) {
        var entries = liveConfirmedRemovals(folderPath: folderPath, now: now)
        for uid in uids { entries[uid] = now }
        confirmedRemovals[folderPath] = entries.isEmpty ? nil : entries
    }

    /// The UIDs confirmed gone from `folderPath` within the window.
    func confirmedRemovalUIDs(folderPath: String, now: ContinuousClock.Instant = .now) -> Set<UInt32> {
        Set(liveConfirmedRemovals(folderPath: folderPath, now: now).keys)
    }

    /// True when a removal from `folderPath` was confirmed after `instant` --
    /// that is, while a request issued at `instant` may have been answered
    /// from the folder as it stood before the removal.
    func removalConfirmed(folderPath: String, after instant: ContinuousClock.Instant) -> Bool {
        confirmedRemovals[folderPath]?.values.contains { $0 > instant } ?? false
    }

    /// Forget a folder's confirmed removals: a changed UIDVALIDITY starts the
    /// UID space over, so the old numbers say nothing about the new ones.
    func clearConfirmedRemovals(folderPath: String) {
        confirmedRemovals[folderPath] = nil
    }

    private func liveConfirmedRemovals(
        folderPath: String,
        now: ContinuousClock.Instant
    ) -> [UInt32: ContinuousClock.Instant] {
        (confirmedRemovals[folderPath] ?? [:]).filter { now - $0.value < Self.confirmedRemovalWindow }
    }
}
