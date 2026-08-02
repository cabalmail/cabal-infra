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
/// A row whose envelope has no Message-ID falls back to the UID-only
/// map, which keeps the first row seen for that UID — the same
/// best-effort answer the old map gave, minus the trap.
struct SearchSourceFolderIndex: Equatable {
    /// Exact per-row key. `messageID` is nil for envelopes the server
    /// returned without a Message-ID header.
    private struct RowKey: Hashable {
        let uid: UInt32
        let messageID: String?
    }

    private var byRow: [RowKey: String] = [:]
    private var byUID: [UInt32: String] = [:]

    /// Empty index — folder mode and single-folder searches, where
    /// `sourceFolder(for:)` falls back to the model's own folder.
    init() {}

    init(_ rows: [SearchedEnvelope]) {
        // First-wins on both maps: duplicates are a genuine ambiguity
        // (two rows the index can't tell apart), and keeping the first
        // match in server order is the row the user sees highest.
        byRow = Dictionary(
            rows.map { (RowKey(uid: $0.envelope.uid, messageID: $0.envelope.messageId), $0.folder) },
            uniquingKeysWith: { first, _ in first }
        )
        byUID = Dictionary(
            rows.map { ($0.envelope.uid, $0.folder) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var isEmpty: Bool { byRow.isEmpty }

    /// The folder `envelope` came from, or nil when this index doesn't
    /// know it (folder mode, or a row that was never part of the result
    /// set).
    func folder(for envelope: Envelope) -> String? {
        byRow[RowKey(uid: envelope.uid, messageID: envelope.messageId)] ?? byUID[envelope.uid]
    }
}
