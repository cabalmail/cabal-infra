import Foundation
import CabalmailKit

/// Per-install state that names the last account's folders and feeds, and
/// that Sign Out leaves in place so the same account finds it again. When a
/// different account signs in (`AccountIdentity`), it starts without it.
///
/// - The folder tree's and the Feeds tree's device-wide collapsed sets hold
///   the last account's folder paths and feed-folder ids. A window's own
///   copy is tagged with its account already (`SidebarCollapse`), so only
///   the device-wide seeds go.
/// - The notification "Choose folders" list holds its folder paths. Only
///   the list goes, back to Inbox: whether notifications are on, and the
///   Inbox, All or Chosen scope, are the device's choices (`PushSettings`).
/// - The Debug Log holds lines about the last account's folders, addresses
///   and server errors. It is in memory, so a relaunch clears it anyway.
///
/// Settings are not here: they are stored per account and switch with it.
enum AccountLeftovers {
    /// The `UserDefaults` keys a different account's sign-in removes.
    static let defaultsKeys = [
        DefaultsKey.folderCollapsedPaths,
        DefaultsKey.feedsCollapsedFolders,
        DefaultsKey.pushChosenFolders,
    ]

    /// Removes the keys. Removing one refreshes the `@AppStorage` views
    /// that read it, so no view has to be told.
    static func resetDefaults(in defaults: UserDefaults) {
        for key in defaultsKeys {
            defaults.removeObject(forKey: key)
        }
    }

    /// Empties Settings > Debug Log. Before the different-account wipe, so
    /// what that wipe reports about itself stays readable.
    static func clearDebugLog() {
        DebugLogStore.shared.clear()
    }
}
