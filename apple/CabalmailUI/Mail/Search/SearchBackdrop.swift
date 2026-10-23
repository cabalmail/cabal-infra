import SwiftUI

/// What the phone's Search tab shows until a search runs: the screen of the
/// tab that was in front when Search was tapped, dimmed behind the field.
///
/// On the tab layout, tapping Search morphs the button into a field at the
/// bottom and collapses the rest of the bar to one button for the tab the
/// user came from (`TabShell`). The system does that only with the Search
/// tab selected, and a selected tab shows its own content, so the tab that
/// was in front can't stay on screen as itself. Instead `TabShell` captures
/// its last frame as Search is tapped, and `SearchView` shows that until the
/// first search is submitted; the results then take over the screen. The
/// capture is a picture, not the tab: tapping it goes back to the tab
/// (`returnToTab`), as the collapsed tab button does.
struct SearchBackdrop {
    /// The window's last frame before Search took over, above the tab bar's
    /// band; transparent below it.
    let image: Image
    /// The size of the window the frame was captured in.
    let size: CGSize
    /// The tab the frame shows, for VoiceOver ("Back to Mail").
    let tabTitle: String
    /// Selects that tab again.
    let returnToTab: () -> Void

    /// How much the frame is dimmed: enough to read as inactive behind the
    /// field, little enough that the screen is still the one the user was on.
    static let dimming = 0.2

    /// Whether the backdrop stands in for the results: only before a search
    /// runs. Once a term is submitted (`submittedQuery`), or the filters have
    /// run one with no term (`isSearchActive`), the screen is the results'.
    /// Clearing the field ends the search (`MessageListView`'s
    /// `onChange(of: searchQuery)`), and the backdrop comes back. A typed term
    /// that hasn't been submitted keeps the backdrop: nothing has been
    /// searched yet.
    static func standsIn(submittedQuery: String, isSearchActive: Bool) -> Bool {
        submittedQuery.isEmpty && !isSearchActive
    }

    /// Whether the frame still matches a window of `windowSize`. A rotation
    /// or a resize while Search is open would stretch it over a screen it no
    /// longer shows, so the search surface shows instead.
    func fits(_ windowSize: CGSize) -> Bool {
        abs(windowSize.width - size.width) < 1 && abs(windowSize.height - size.height) < 1
    }
}
