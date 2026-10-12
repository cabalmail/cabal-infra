/// What a window carries across a change of layout shell, beyond its route:
/// Settings, which is a sheet in the split and a tab in the tab layouts, and
/// a search in progress. The rules are here; `SceneNavigator` applies what
/// they decide, since only it holds the tab and the window's search model.
struct ShellHandOff: Equatable {
    /// Whether the split's Settings sheet is open. Its own state rather than
    /// the Settings tab: the tab follows what happens in the split
    /// (`followSplit`, a navigate request), including selections nobody made
    /// — a restore landing after a slow load, another window archiving the
    /// open message — and none of those should close Settings.
    private(set) var settingsSheetOpen = false

    /// What the navigator does after a change of layout.
    enum Step: Equatable {
        case nothing
        /// Show this tab: Settings for the sheet that was open, Search for a
        /// search in progress.
        case showTab(CompactTab)
        /// End the search left behind in the Search tab, as the window's own
        /// clear does (the pill and the session), and at once rather than in
        /// a task: the split's landing takes the search model next and must
        /// find it idle.
        case endLeftoverSearch
    }

    /// A Settings request in the split: the gear on its folder panel, or ⌘,.
    mutating func openSettingsSheet() {
        settingsSheetOpen = true
    }

    /// The window's layout shell changed, given as the host's own old and new
    /// layouts rather than the navigator's `layoutIsWide`, which a tree's
    /// landing also writes, so that a tab tree landing first can't hide a
    /// narrowing. `tab` is the tab the window is on. `searchIsEngaged` is
    /// whether its search holds a query or a run search; a focused, empty
    /// field has nothing to carry.
    ///
    /// Turning to the tabs, an open Settings sheet becomes the Settings tab.
    /// Otherwise a search the window is in the middle of opens the Search
    /// tab, which shows it with its field (#1989); the Mail tab has no
    /// search.
    ///
    /// Turning to the split, the Settings tab becomes the sheet. A search
    /// carries over only from the Search tab: the split draws any search in
    /// place of its list, so one left behind in the Search tab would take
    /// over from the message or feed item the user was reading in another
    /// tab. It ends instead, as a folder pick ended it when the Mail tab
    /// still shared the search.
    mutating func layoutChanged(wasWide: Bool, isWide: Bool, tab: CompactTab, searchIsEngaged: Bool) -> Step {
        if wasWide, !isWide {
            if settingsSheetOpen {
                settingsSheetOpen = false
                return .showTab(.settings)
            }
            return searchIsEngaged ? .showTab(.search) : .nothing
        }
        if !wasWide, isWide {
            if tab == .settings { settingsSheetOpen = true }
            if tab != .search, searchIsEngaged { return .endLeftoverSearch }
        }
        return .nothing
    }

    /// The split's Settings sheet was dismissed; `isShowing` is whether the
    /// split is showing it. Returns whether the tab goes back to the section
    /// the split shows: it does when the sheet came from the Settings tab, as
    /// a pick in the split moves it (`followSplit`), so the next fold doesn't
    /// reopen Settings. Off the split there is no sheet, so one a fold tore
    /// down is not a dismissal.
    mutating func sheetDismissed(isShowing: Bool, tab: CompactTab) -> Bool {
        guard isShowing else { return false }
        settingsSheetOpen = false
        return tab == .settings
    }
}
