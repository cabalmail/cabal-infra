import Foundation

/// App `UserDefaults` keys that more than one file reads.
///
/// Every other app key is a literal in the single file that owns it, which is
/// fine; these two are shared between the wide sidebar's Feeds section and the
/// compact Feeds tab, and a key spelled twice is a key that can be spelled
/// wrong once. The Kit keeps its own keys the same way (`static let`).
enum DefaultsKey {
    /// The Feeds tree's collapsed folder ids, device-wide. A window renders
    /// its own set (`SidebarCollapse`) and seeds from this one.
    static let feedsCollapsedFolders = "cabalmail.feeds.collapsedFolders"
    /// The Feeds pill's `FeedListFilter` raw value.
    static let feedsFilter = "cabalmail.feeds.filter"
}
