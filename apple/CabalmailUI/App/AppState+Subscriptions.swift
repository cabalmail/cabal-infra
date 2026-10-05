import Foundation

// Mutators for `subscribedFolderPaths`, declared on the main type in
// `AppState.swift` (stored properties can't live in an extension under
// @Observable). Own file, like `AppState+Feeds.swift`, so the primary file
// stays under SwiftLint's `file_length` cap.
@MainActor
extension AppState {
    /// Replace the whole subscribed set from a fresh folder list.
    func setSubscribedFolders(_ paths: Set<String>) {
        subscribedFolderPaths = paths
    }

    /// Record one folder's subscription flip (optimistic toggle or its
    /// revert). A flip before any list has landed seeds the set, so the
    /// banner can answer for that folder at least.
    func setSubscription(folderPath: String, isSubscribed: Bool) {
        var paths = subscribedFolderPaths ?? []
        if isSubscribed {
            paths.insert(folderPath)
        } else {
            paths.remove(folderPath)
        }
        subscribedFolderPaths = paths
    }
}
