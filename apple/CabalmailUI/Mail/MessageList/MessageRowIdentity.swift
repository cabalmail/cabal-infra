import Foundation
import CabalmailKit

/// Row identity for the message list's non-virtualized (`ForEach(visible)`)
/// path — search and filtered results.
///
/// `Envelope.id` is its UID, which is unique only *within* a folder. A
/// cross-folder search routinely returns the same UID twice (`zeta0803`
/// UID 1 and `alpha0803/kid` UID 1, say), and a `ForEach` handed two
/// elements with the same id draws only one of them: the second match is
/// counted by the header and then silently dropped from the list. Keying
/// on the row's `MessageRef` — its folder plus UID — separates those rows,
/// including one message filed in two folders under one UID (mail you send
/// yourself, in INBOX and Sent). The list loads each ref once (the search
/// paths drop a row a later page re-delivers), so the ref is unique per row.
///
/// `generation` changes when the message's row has to be replaced rather
/// than updated -- after a destructive full swipe that left it in place
/// (`MessageListViewModel.replaceRows(showing:)`).
struct MessageRowIdentity: Hashable {
    let ref: MessageRef
    var generation = 0
}

/// An envelope paired with the identity its row is drawn under.
struct IdentifiedEnvelope: Identifiable, Hashable {
    let id: MessageRowIdentity
    let envelope: Envelope
}

extension MessageRowIdentity {
    /// Pairs each envelope with its row identity, preserving order. What
    /// `ForEach` iterates in the search / filtered list. `generations` is
    /// the model's per-message row generation. Every row the model loads
    /// carries its folder (`MessageListViewModel.placedInFolder(_:)`, and
    /// `SearchedEnvelope` for search rows); a row without one keys on its
    /// UID alone, which is all a single-folder list needs.
    static func identify(
        _ envelopes: [Envelope],
        generations: [MessageRef: Int] = [:]
    ) -> [IdentifiedEnvelope] {
        envelopes.map { envelope in
            let ref = envelope.ref ?? MessageRef(folder: "", uid: envelope.uid)
            return IdentifiedEnvelope(
                id: MessageRowIdentity(ref: ref, generation: generations[ref] ?? 0),
                envelope: envelope
            )
        }
    }
}
