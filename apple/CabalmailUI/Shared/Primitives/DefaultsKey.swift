import Foundation

/// App `UserDefaults` keys that more than one file reads.
///
/// Every other app key is a literal in the single file that owns it, which is
/// fine; the feed keys are shared between the wide sidebar's Feeds section
/// and the compact Feeds tab, the folder tree's is also named by
/// `AccountLeftovers`, and a key spelled twice is a key that can be spelled
/// wrong once. The Kit keeps its own keys the same way (`static let`).
enum DefaultsKey {
    /// The folder tree's collapsed paths, device-wide. A window renders its
    /// own set (`SidebarCollapse`) and seeds from this one.
    static let folderCollapsedPaths = "cabalmail.folder.collapsedPaths"
    /// The Feeds tree's collapsed folder ids, device-wide. A window renders
    /// its own set (`SidebarCollapse`) and seeds from this one.
    static let feedsCollapsedFolders = "cabalmail.feeds.collapsedFolders"
    /// The notification "Choose folders" list (`PushSettings`, which only
    /// the platforms with push compile; named here so `AccountLeftovers`
    /// can name it on every platform).
    static let pushChosenFolders = "cabalmail.push.chosenFolders"
    /// The Feeds pill's `FeedListFilter` raw value.
    static let feedsFilter = "cabalmail.feeds.filter"
}
