import Foundation

/// Which list a pinned list column is showing, for the width it keeps in a
/// window (`ListColumnPolicy`).
///
/// Each keeps its own width in each window's scene storage, so two windows,
/// or the mail and feed lists, no longer share one (the Duo spec: "each
/// tab's list width … Keep nothing navigation-related in app-wide settings").
/// `SplitShell` keys only `mail` and `feeds`: there search results take over
/// whichever list the column shows, with the search field in that column's
/// header, so a width of its own would resize the column the moment the
/// field took focus. `search` is for the one view tree's Search split.
enum ListColumnTab: String, CaseIterable, Sendable {
    case mail, feeds, search

    /// This list's width in a window's scene storage, in points; 0 is none.
    var sceneStorageKey: String { "cabalmail.window.listColumnWidth.\(rawValue)" }

    /// The one width every window shared before widths were per window and
    /// per list. Dropped rather than carried over: each window opens once at
    /// its default, which on an iPhone Duo is the fold.
    static let retiredAppWideKey = "cabalmail.layout.listColumnWidth"

    static func retireAppWideWidth(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: retiredAppWideKey)
    }
}
