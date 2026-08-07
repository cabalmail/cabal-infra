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
/// on UID *plus* Message-ID separates those rows, matching the key
/// `SearchSourceFolderIndex` already uses to route each row back to its
/// own mailbox.
///
/// `occurrence` is the last-resort tiebreak for rows that are
/// indistinguishable even then — same UID and no Message-ID on either,
/// which the server can return for envelopes it couldn't parse. Distinct
/// identities there are still better than a vanished row; it only means
/// SwiftUI rebuilds the later duplicate if an earlier one is removed.
struct MessageRowIdentity: Hashable {
    let uid: UInt32
    let messageID: String?
    /// 0 for the first row with this (uid, messageID) pair, 1 for the next,
    /// and so on. Non-zero only in the indistinguishable case above.
    let occurrence: Int
}

/// An envelope paired with the identity its row is drawn under.
struct IdentifiedEnvelope: Identifiable, Hashable {
    let id: MessageRowIdentity
    let envelope: Envelope
}

extension MessageRowIdentity {
    /// Pairs each envelope with an identity unique across `envelopes`,
    /// preserving order. What `ForEach` iterates in the search / filtered
    /// list.
    static func identify(_ envelopes: [Envelope]) -> [IdentifiedEnvelope] {
        var seen: [Key: Int] = [:]
        return envelopes.map { envelope in
            let key = Key(uid: envelope.uid, messageID: envelope.messageId)
            let occurrence = seen[key, default: 0]
            seen[key] = occurrence + 1
            return IdentifiedEnvelope(
                id: MessageRowIdentity(
                    uid: envelope.uid,
                    messageID: envelope.messageId,
                    occurrence: occurrence
                ),
                envelope: envelope
            )
        }
    }

    private struct Key: Hashable {
        let uid: UInt32
        let messageID: String?
    }
}
