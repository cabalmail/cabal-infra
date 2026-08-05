import Foundation

/// What a dispose-family affordance actually does in the folder currently on
/// screen.
///
/// Every dispose surface — the trailing row swipe, the reader's toolbar
/// button, the row / selection context menus, the bulk action bar, Cmd+Delete
/// — starts from a requested destination (the `DisposeAction` preference, or
/// an explicit Archive on the menus) and then has to reconcile it with where
/// the user already is. Two folders are their own destination:
///
/// - In **Trash**, "move to Trash" is meaningless, so a delete means gone
///   forever and stages a confirmation.
/// - In **Archive**, "move to Archive" is a same-folder move: the server
///   honors it, hands the message a fresh UID, and the client prunes the row
///   for a message that never left. So the archive affordance becomes
///   Restore, which puts the message back in INBOX.
///
/// The rule lives here, as a pure function of (request, folder), so both the
/// labels the views draw and the operations they run come from one decision
/// rather than a `folderPath ==` test repeated at each surface.
public enum DisposeIntent: Equatable, Sendable {
    /// File the message into Archive or Trash — the ordinary case.
    case move(DisposeAction)
    /// Undo the archive: move back to INBOX. Only inside Archive.
    case restore
    /// Permanent delete, behind a confirmation. Only inside Trash.
    case purge

    /// The intent behind the *default* dispose affordance — the trailing row
    /// swipe, the reader's toolbar button, Cmd+Delete — which follows the
    /// user's `DisposeAction` preference.
    ///
    /// Trash is checked before the preference: inside Trash the affordance is
    /// Delete Forever whichever way the preference points, which is the
    /// long-standing behavior of these surfaces.
    public static func standard(
        preference: DisposeAction,
        in folderPath: String
    ) -> DisposeIntent {
        if folderPath == FolderTree.trashPath { return .purge }
        if folderPath == FolderTree.archivePath && preference == .archive { return .restore }
        return .move(preference)
    }

    /// The intent behind an *explicitly* Archive affordance — the row and
    /// selection context menus' Archive item, the bulk bar's Archive button,
    /// and the reader overflow's alternate destination when the preference
    /// points at Trash.
    ///
    /// Inside Trash this stays a real archive: it's the rescue path out of
    /// the deleted pile, not a same-folder move.
    public static func archiving(in folderPath: String) -> DisposeIntent {
        folderPath == FolderTree.archivePath ? .restore : .move(.archive)
    }

    /// Where a move-shaped intent sends the message; `nil` for `.purge`,
    /// which moves nothing.
    public var destinationFolder: String? {
        switch self {
        case .move(let action): return action.destinationFolder
        case .restore:          return FolderTree.inboxPath
        case .purge:            return nil
        }
    }

    /// Whether this intent destroys anything the user can't get back — drives
    /// the destructive button role and the red swipe tint. Restore is a plain
    /// move back to the inbox, so it reads as neither.
    public var isDestructive: Bool {
        switch self {
        case .move(let action): return action == .trash
        case .restore:          return false
        case .purge:            return true
        }
    }
}
