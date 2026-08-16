import Foundation

// Rules for the one thing a Drafts list has to decide when a compose
// session retires the copy it is showing — by saving over it, or by
// throwing it away. Lifted out of the view so it can be tested without a
// list, a reader, or a server.

/// The Drafts UIDs one compose session retired, and the copy that survived
/// them. Every `/save_draft` replace expunges the copy it replaces and
/// lands the new content under a fresh UID, so a session that was resumed
/// and re-saved leaves a chain behind (#1071) with exactly one survivor.
///
/// A discard retires the same chain with `survivingUID` nil: the whole
/// point of "throw this away" is that nothing takes its place (#1081).
struct DraftReplacement: Equatable, Sendable {
    let retiredUIDs: [UInt32]
    let survivingUID: UInt32?
}

/// What an open list should do with the message it is showing once the
/// replacement lands.
enum DraftReplacementOutcome: Equatable {
    /// This list isn't showing any of the retired copies — the rows still
    /// get pruned, but the selection is somebody else's message.
    case ignore
    /// Show this copy instead. The survivor is loaded, so the reader can be
    /// rebuilt against a UID the server actually holds.
    case repoint(UInt32)
    /// The survivor isn't in the loaded window (a refresh that didn't reach
    /// it, or a folder that moved on). Nothing to point at, so let the
    /// reader go rather than leave it rendering an expunged copy.
    case dismiss
}

enum DraftReplacementPolicy {
    /// Decides the fate of the currently-displayed message.
    ///
    /// The reader that Save Draft returns to is the whole problem: it holds
    /// the envelope *and the fetched body* of a UID `/save_draft` has since
    /// expunged, and Edit Draft seeds the next composer from exactly that.
    /// Sending from there ships the pre-edit content and leaves the saved
    /// copy behind as an orphan, because the discard rides on the retired
    /// UID (#1078). So a displayed copy that got retired is never left
    /// alone — it is either replaced by the survivor or dropped.
    ///
    /// A discard has no survivor to point at, so it always drops the reader
    /// (#1081). Deliberately *not* an advance to the next message the way a
    /// dispose is: the user's last action was "throw this away" from inside
    /// a composer, not "deal with this message" from the reader, so nothing
    /// says they want the next draft opened for them.
    static func resolve(
        displayedUID: UInt32?,
        replacement: DraftReplacement,
        loadedUIDs: [UInt32]
    ) -> DraftReplacementOutcome {
        guard let displayedUID,
              replacement.retiredUIDs.contains(displayedUID) else { return .ignore }
        guard let survivingUID = replacement.survivingUID,
              loadedUIDs.contains(survivingUID) else { return .dismiss }
        return .repoint(survivingUID)
    }

    /// What a closing compose session leaves for an open Drafts list, given
    /// the chain of server copies it retired: nil when there is nothing
    /// stale on screen to fix.
    ///
    /// The two closing exits that touch the server differ only in whether
    /// anything is left afterwards. Save Draft replaces, so the copies
    /// before the current ref are retired and the ref itself survives; a
    /// discard expunges the ref too, so the whole chain — including the
    /// current one — is retired with no survivor. Same rule for both
    /// discarding exits: the explicit "Discard draft" and the empty-body
    /// cancel that quietly drops the server copy (`.discardEmpty`).
    static func retirement(
        discarded: Bool,
        replacedUIDs: [UInt32],
        currentUID: UInt32?
    ) -> DraftReplacement? {
        guard discarded else {
            // A first save retires nothing — no stale row, nothing to say.
            guard !replacedUIDs.isEmpty, let currentUID else { return nil }
            return DraftReplacement(retiredUIDs: replacedUIDs, survivingUID: currentUID)
        }
        let chain = replacedUIDs + (currentUID.map { [$0] } ?? [])
        guard !chain.isEmpty else { return nil }
        return DraftReplacement(retiredUIDs: chain, survivingUID: nil)
    }
}
