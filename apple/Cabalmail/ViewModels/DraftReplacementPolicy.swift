import Foundation

// Rules for the one thing a Drafts list has to decide when a compose
// session saves over the copy it is showing. Lifted out of the view so it
// can be tested without a list, a reader, or a server.

/// The Drafts UIDs one compose session retired, and the copy that survived
/// them. Every `/save_draft` replace expunges the copy it replaces and
/// lands the new content under a fresh UID, so a session that was resumed
/// and re-saved leaves a chain behind (#1071) with exactly one survivor.
struct DraftReplacement: Equatable, Sendable {
    let retiredUIDs: [UInt32]
    let survivingUID: UInt32
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
    static func resolve(
        displayedUID: UInt32?,
        replacement: DraftReplacement,
        loadedUIDs: [UInt32]
    ) -> DraftReplacementOutcome {
        guard let displayedUID,
              replacement.retiredUIDs.contains(displayedUID) else { return .ignore }
        return loadedUIDs.contains(replacement.survivingUID)
            ? .repoint(replacement.survivingUID)
            : .dismiss
    }
}
