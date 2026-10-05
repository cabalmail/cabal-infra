import SwiftUI

/// What the wide-layout content column shows, and what a sidebar folder pick
/// has to do to the search state for that pick to be visible.
///
/// The column has always preferred global search results to any folder while
/// the search field is engaged, written as an inline `if` in
/// `MailRootView.contentColumn`. Nothing kept the two pieces of state that
/// feed it in step, so #1217: picking a folder from the sidebar during a
/// search set `selectedFolder` and slid the panel away, the sidebar drew the
/// row as `Selected`, and the column carried on showing the search results
/// under a "Search" title. The pick had landed — clearing the query dropped
/// you straight into it — but nothing on screen said so.
///
/// A pure rule rather than an inline `if` so it can be tested directly:
/// `MailRootView`'s `@State` isn't reachable from a unit test, this is (same
/// reasoning as `CompactColumnPolicy`, one width class over).
enum ContentColumnPolicy {

    /// What the column renders. The folder case carries a path rather than a
    /// `Folder` so the rule stays comparable without a fixture.
    enum Mode: Equatable {

        /// Global search results.
        case search

        /// The named mailbox's message list.
        case folder(String)

        /// The "pick a folder from the sidebar" prompt.
        case empty
    }

    /// The precedence `contentColumn` renders, stated once.
    static func mode(isSearching: Bool, selectedFolderPath: String?) -> Mode {
        if isSearching { return .search }
        guard let selectedFolderPath else { return .empty }
        return .folder(selectedFolderPath)
    }

    /// Whether a sidebar write of `picked` has to end the search first.
    ///
    /// Picking a mailbox is a navigation intent, and `mode` above is why it
    /// cannot be honoured while the search is still engaged. Two clauses,
    /// both load-bearing:
    ///
    /// - No search running, nothing to end. This is the launch landing and
    ///   the cross-client cursor restore, which write `selectedFolder`
    ///   without any user gesture behind them.
    /// - **A write of `nil` is not a pick.** The sidebar's selection binding
    ///   is written by more than the user's finger — a remount or a folder
    ///   that stopped existing clears it — and treating that as a navigation
    ///   intent would throw away a search the user is still reading.
    static func pickEndsSearch(isSearching: Bool, picked: String?) -> Bool {
        guard isSearching else { return false }
        return picked != nil
    }
}
