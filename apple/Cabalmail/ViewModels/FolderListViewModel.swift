import Foundation
import Observation
import CabalmailKit

/// Backs `FolderListView`. Owns the folder list + unread counts, re-fetches
/// on explicit refresh.
///
/// Folder ordering follows the plan's sidebar layout: Inbox pinned first,
/// then user folders, then system folders grouped (Sent/Drafts/Trash/Junk).
/// Unread counts come from per-folder `STATUS (UNSEEN)` — walked sequentially
/// because all commands share one IMAP connection.
@Observable
@MainActor
final class FolderListViewModel {
    var folders: [Folder] = []
    var isLoading = false
    var errorMessage: String?

    private let client: CabalmailClient
    private let appState: AppState

    init(client: CabalmailClient, appState: AppState) {
        self.client = client
        self.appState = appState
    }

    func refresh() async {
        await loadFolderList()
        await refreshUnreadCounts()
    }

    /// Fetch + publish the folder list without walking per-folder STATUS.
    /// Split out so the parent view can seed a default selection (Inbox)
    /// the moment the sidebar arrives — the unread-count walk fans out
    /// across every folder and can take a second or two on first load,
    /// during which there's no reason to leave the user staring at an
    /// empty pane.
    func loadFolderList() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await client.imapClient.connectAndAuthenticate()
            let all = try await client.imapClient.listFolders()
            folders = sortForSidebar(all)
            errorMessage = nil
        } catch let error as CabalmailError {
            errorMessage = String(describing: error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Folders the user has subscribed to. Mirrors the sort of `folders`
    /// (which already pins Inbox first, then user folders, then system
    /// folders), filtered to the subscribed subset.
    var subscribedFolders: [Folder] {
        folders.filter { $0.isSubscribed }
    }

    /// Optimistically flip the subscription state, fire the IMAP/API call,
    /// and revert on failure. Mirrors the React rail's behavior so toggling
    /// from the Apple sidebar feels as responsive as the web client.
    func toggleSubscription(_ folder: Folder) async {
        let target = !folder.isSubscribed
        applySubscription(path: folder.path, to: target)
        do {
            try await client.imapClient.connectAndAuthenticate()
            if target {
                try await client.imapClient.subscribe(path: folder.path)
            } else {
                try await client.imapClient.unsubscribe(path: folder.path)
            }
            errorMessage = nil
        } catch let error as CabalmailError {
            applySubscription(path: folder.path, to: !target)
            errorMessage = String(describing: error)
        } catch {
            applySubscription(path: folder.path, to: !target)
            errorMessage = error.localizedDescription
        }
    }

    private func applySubscription(path: String, to subscribed: Bool) {
        guard let index = folders.firstIndex(where: { $0.path == path }) else { return }
        let previous = folders[index]
        folders[index] = Folder(
            path: previous.path,
            attributes: previous.attributes,
            isSubscribed: subscribed
        )
    }

    /// Walk each folder's `STATUS (UNSEEN)` and publish the counts in one
    /// shot. Runs after `loadFolderList()` (and after the parent has had a
    /// chance to seed a default selection), so the sidebar's unread badges
    /// fill in without blocking initial navigation.
    func refreshUnreadCounts() async {
        var counts: [String: Int] = [:]
        for folder in folders {
            if let status = try? await client.imapClient.status(path: folder.path) {
                let count = status.unseen ?? 0
                counts[folder.path] = count
                // Publish each count as it arrives so badges fill in
                // progressively rather than appearing in one shot at the
                // end of the walk.
                appState.setUnreadCount(folderPath: folder.path, count: count)
            }
        }
        appState.setUnreadCounts(counts)
    }

    /// Inbox first, then user folders arranged as a `/`-delimited tree
    /// (peers alphabetical, children directly under their parent), then
    /// system folders grouped at the bottom.
    private func sortForSidebar(_ input: [Folder]) -> [Folder] {
        let systemNames: Set<String> = ["Sent", "Drafts", "Trash", "Junk", "Archive"]
        let inbox = input.filter { $0.path.caseInsensitiveCompare("INBOX") == .orderedSame }
        let system = input
            .filter { systemNames.contains($0.path) }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        let userFolders = input.filter { folder in
            !inbox.contains(folder)
                && !system.contains(folder)
                && !folder.attributes.contains("\\Noselect")
        }
        return inbox + FolderTree.sortUserTree(userFolders) + system
    }

    /// Indentation depth - delegates to `FolderTree.depth(for:)`.
    func depth(for folder: Folder) -> Int {
        FolderTree.depth(for: folder)
    }

    /// True iff this folder has at least one descendant in the current list -
    /// drives the per-folder collapse chevron in "All folders".
    func hasChildren(_ folder: Folder) -> Bool {
        FolderTree.hasChildren(folder, in: folders)
    }
}
