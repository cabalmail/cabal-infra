import Foundation
import CabalmailKit

/// The accessibility identifier a message row is drawn under.
///
/// A folder list keeps the bare form, `message.row.<uid>`: a UID is unique
/// within one folder, and the SimDrive recipes and source scans that address
/// folder rows are written against it (`docs/apple.md`, "Addressing
/// controls").
///
/// The global search surface shows rows from every folder at once, and there
/// a UID addresses nothing on its own: two unrelated messages in two folders
/// routinely share one -- INBOX 316 and Sent 316 both landed in a single
/// 35-row result set for a three-letter term, and `tap id:message.row.316`
/// resolved to whichever the tree held first, leaving the other row with no
/// identifier that reached it (#1991). Search rows take
/// `message.row.<folder>/<uid>`: the row's own `/`-delimited folder path and
/// its UID, which is the pair that already identifies the row everywhere
/// else (`MessageRef`, and `MessageRowIdentity` for `ForEach`).
enum MessageRowIdentifier {
    static let prefix = "message.row"

    /// `folder` is the row's own folder (`Envelope.folder`); `crossFolder`
    /// says whether the list may show rows from more than one folder, which
    /// is true only on the search surface (`MessageListScope.search`). A
    /// folder list's Unread / Flagged pills are searches too, but they narrow
    /// to that list's one folder, so their rows keep the bare form.
    ///
    /// A cross-folder row naming no folder falls back to the bare form --
    /// ambiguous, as it was before, but nothing places a search row without
    /// one (`SearchedEnvelope`).
    static func identifier(uid: UInt32, folder: String?, crossFolder: Bool) -> String {
        guard crossFolder, let folder, !folder.isEmpty else { return "\(prefix).\(uid)" }
        return "\(prefix).\(folder)/\(uid)"
    }

    /// The identifier `envelope`'s row takes in a list of `scope`.
    static func identifier(for envelope: Envelope, scope: MessageListScope) -> String {
        identifier(uid: envelope.uid, folder: envelope.folder, crossFolder: scope.isSearch)
    }
}
