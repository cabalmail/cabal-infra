import Foundation
import CabalmailKit

/// Resolves the mailbox that owns each row of a cross-folder search
/// result. Pure value type so the lookup rules are testable without a
/// view model; `MessageListViewModel` holds one and consults it from
/// `sourceFolder(for:)`.
///
/// IMAP UIDs are unique only *within* a folder, so a result set spanning
/// folders routinely carries the same UID twice (Archive UID 1 and
/// `zeta0802` UID 1, say). A plain `[UID: folder]` map is therefore both
/// lossy and, when built with `Dictionary(uniqueKeysWithValues:)`, fatal
/// — the duplicate key traps and takes the app down. The index keys on
/// UID *plus* Message-ID, which separates same-UID rows in different
/// folders while still separating the other collision shape: one message
/// filed in two folders, same Message-ID under two different UIDs.
///
/// One shape that key cannot separate: one message filed in two folders
/// under the *same* UID. Mail you send yourself lands in INBOX and Sent
/// with one Message-ID, and in a small mailbox the two UIDs can coincide;
/// nothing else on the wire tells the copies apart (the API carries no
/// INTERNALDATE or size). Every folder such a key came from is kept, so
/// `folders(for:)` can report the ambiguity even though `folder(for:)`
/// can only name the first.
///
/// A row whose envelope has no Message-ID keys on `(uid, nil)` like any
/// other; an envelope the index has never seen falls back to the UID-only
/// map, which keeps the first row seen for that UID — the same
/// best-effort answer the old map gave, minus the trap.
struct SearchSourceFolderIndex: Equatable {
    /// Exact per-row key. `messageID` is nil for envelopes the server
    /// returned without a Message-ID header.
    private struct RowKey: Hashable {
        let uid: UInt32
        let messageID: String?
    }

    /// Every distinct folder a row with this key came from, in server
    /// order. More than one entry only for rows the key can't tell apart.
    private var byRow: [RowKey: [String]] = [:]
    private var byUID: [UInt32: String] = [:]

    /// Empty index — folder mode and single-folder searches, where
    /// `sourceFolder(for:)` falls back to the model's own folder.
    init() {}

    init(_ rows: [SearchedEnvelope]) {
        add(rows)
    }

    var isEmpty: Bool { byRow.isEmpty }

    /// Extends the index with a later search page. Existing entries win
    /// `folder(for:)`, matching first-in-server-order: an earlier page's
    /// row is the one the user sees highest. A page that brings the same
    /// key from another folder still records that folder, so the copy on
    /// page 2 makes the copy on page 1 ambiguous.
    mutating func add(_ rows: [SearchedEnvelope]) {
        for row in rows {
            let key = RowKey(uid: row.envelope.uid, messageID: row.envelope.messageId)
            // Distinct folders, not rows: a page boundary can deliver the
            // same row twice, and that is not two copies.
            if byRow[key]?.contains(row.folder) != true { byRow[key, default: []].append(row.folder) }
            if byUID[row.envelope.uid] == nil { byUID[row.envelope.uid] = row.folder }
        }
    }

    /// The folder `envelope` came from, or nil when this index doesn't
    /// know it (folder mode, or a row that was never part of the result
    /// set). For rows the index can't tell apart this is the first one's
    /// folder; check `folders(for:)` before acting on more than one row.
    func folder(for envelope: Envelope) -> String? {
        byRow[RowKey(uid: envelope.uid, messageID: envelope.messageId)]?.first ?? byUID[envelope.uid]
    }

    /// Every folder a row indistinguishable from `envelope` came from:
    /// one entry for an ordinary row, several for the same message filed
    /// in more than one folder under one UID, and empty when this index
    /// doesn't know the row.
    func folders(for envelope: Envelope) -> [String] {
        byRow[RowKey(uid: envelope.uid, messageID: envelope.messageId)]
            ?? byUID[envelope.uid].map { [$0] }
            ?? []
    }
}
