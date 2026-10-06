import Foundation
import CabalmailKit

// The confirmed-removal shield (see `AppState.confirmedRemovals`): messages
// the server has confirmed gone from their folder, which a refresh already
// in flight when the removal landed must not bring back. Recorded by the
// list's and the reader's removal paths once a move or purge succeeds; read
// by `MessageListViewModel.shieldFetched` and its refresh at merge time.
extension AppState {
    /// How long a confirmed removal keeps shielding its message. A request
    /// can't be in flight this long (the API gateway gives up after 29 s),
    /// so by then no fetch issued before the removal can still land.
    static let confirmedRemovalWindow: Duration = .seconds(60)

    /// Record that the server confirmed `refs` gone from their folders.
    /// Entries past the window are dropped for the folders recorded into,
    /// as they always were; other folders' entries are left for their own
    /// next record.
    func recordConfirmedRemovals(
        _ refs: some Sequence<MessageRef>,
        at now: ContinuousClock.Instant = .now
    ) {
        let refs = Array(refs)
        let folders = Set(refs.map(\.folder))
        confirmedRemovals = confirmedRemovals.filter {
            !folders.contains($0.key.folder) || now - $0.value < Self.confirmedRemovalWindow
        }
        for ref in refs { confirmedRemovals[ref] = now }
    }

    /// The messages confirmed gone from `folderPath` within the window.
    func confirmedRemovalRefs(folderPath: String, now: ContinuousClock.Instant = .now) -> Set<MessageRef> {
        Set(confirmedRemovals.compactMap { ref, confirmedAt in
            ref.folder == folderPath && now - confirmedAt < Self.confirmedRemovalWindow ? ref : nil
        })
    }

    /// True when a removal from `folderPath` was confirmed after `instant` --
    /// that is, while a request issued at `instant` may have been answered
    /// from the folder as it stood before the removal.
    func removalConfirmed(folderPath: String, after instant: ContinuousClock.Instant) -> Bool {
        confirmedRemovals.contains { $0.key.folder == folderPath && $0.value > instant }
    }

    /// Forget a folder's confirmed removals: a changed UIDVALIDITY starts the
    /// UID space over, so the old numbers say nothing about the new ones.
    func clearConfirmedRemovals(folderPath: String) {
        confirmedRemovals = confirmedRemovals.filter { $0.key.folder != folderPath }
    }
}
