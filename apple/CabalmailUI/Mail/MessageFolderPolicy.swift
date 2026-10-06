import Foundation
import CabalmailKit

/// The folder a row's message lives in, as the `Folder` value the reader and
/// the row's move picker take.
///
/// A row carries its own folder (`Envelope.folder`): a cross-folder search
/// result names the mailbox it came from, and two results that share a UID
/// name different ones. The reader opens against that folder rather than the
/// sidebar's, so its mark-read, flag, move and delete reach the message the
/// user picked, and the move picker hides that folder rather than the
/// list's. The given folder's `Folder` value (the sidebar's, or the list's)
/// is reused when the paths match, so its metadata is kept; a row with no
/// folder of its own is that folder's.
///
/// A pure rule rather than inline in the views, so it is testable: the
/// selection binding, the detail column and the move sheet sit in view
/// bodies a unit test cannot reach.
enum MessageFolderPolicy {
    static func folder(for envelope: Envelope?, in context: Folder?) -> Folder? {
        guard let path = envelope?.folder, path != context?.path else { return context }
        return Folder(path: path)
    }
}
