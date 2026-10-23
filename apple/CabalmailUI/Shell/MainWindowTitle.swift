/// What a main window calls itself: the name iPadOS shows in the Window
/// menu's Open Windows list and on the window's app-switcher card.
///
/// A `WindowGroup` with no title of its own takes its scene title from the
/// content's navigation title, and the trailing inspector's
/// `AddressListView` ("Addresses") is the one that wins on the regular
/// split — so every iPad window was called "Addresses" whatever folder it
/// showed (#2036). The window names itself from its route instead, and
/// `namesMainWindowScene(_:)` (`MainSceneActivation.swift`) writes the
/// answer onto `UIWindowScene.title`. `AddressListView` keeps its own
/// navigation title: the inspector is still called Addresses, the *window*
/// is not.
///
/// The Mac names its scene in the `WindowGroup` itself
/// (`CabalmailMacApp.swift`) and is left alone.
enum MainWindowTitle {
    /// What a window with no place to report calls itself.
    static let appName = "Cabalmail"

    /// The title for a window showing `folderName` in mail, or the feed
    /// reader, or one of the tab bar's utility tabs.
    ///
    /// - Parameters:
    ///   - isWide: whether the window draws the regular split, which has no
    ///     tab bar; the compact tab decides everywhere else.
    ///   - splitShowsFeeds: the wide split's feed side is up
    ///     (`SceneNavigator.splitShowsFeeds`): the window is in the feeds
    ///     section *with a list open*, so a feeds section with none still
    ///     shows mail.
    ///   - compactTab: the tab bar's tab, on the layouts that have one.
    ///   - folderName: the open folder's name, as the message list titles
    ///     itself (`Folder.name`); nil before one is picked.
    static func title(
        isWide: Bool,
        splitShowsFeeds: Bool,
        compactTab: CompactTab,
        folderName: String?
    ) -> String {
        if isWide {
            return splitShowsFeeds ? CompactTab.feeds.title : mailTitle(folderName)
        }
        switch compactTab {
        case .mail:
            return mailTitle(folderName)
        // Folders, Addresses, Settings and Search name themselves: a window
        // parked on one of those tabs really is showing that, and Folders
        // (visionOS's own tab) browses the tree rather than a folder.
        case .folders, .feeds, .addresses, .settings, .search:
            return compactTab.title
        }
    }

    /// Mail's half: the folder, else the app name — a window that has not
    /// landed on a folder yet has nothing more specific to say.
    private static func mailTitle(_ folderName: String?) -> String {
        guard let folderName, !folderName.isEmpty else { return appName }
        return folderName
    }
}
