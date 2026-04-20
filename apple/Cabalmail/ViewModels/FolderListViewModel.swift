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
    var unreadCounts: [String: Int] = [:]
    var isLoading = false
    var errorMessage: String?

    private let client: CabalmailClient

    init(client: CabalmailClient) {
        self.client = client
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await client.imapClient.connectAndAuthenticate()
            let all = try await client.imapClient.listFolders()
            folders = sortForSidebar(all)
            unreadCounts = [:]
            for folder in folders {
                if let status = try? await client.imapClient.status(path: folder.path) {
                    unreadCounts[folder.path] = status.unseen ?? 0
                }
            }
            errorMessage = nil
        } catch let error as CabalmailError {
            errorMessage = String(describing: error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Inbox first, then user folders alpha, then system folders grouped
    /// at the bottom. Mirrors the plan's Phase-4 sidebar spec.
    private func sortForSidebar(_ input: [Folder]) -> [Folder] {
        let systemNames: Set<String> = ["Sent", "Drafts", "Trash", "Junk", "Archive"]
        let inbox = input.filter { $0.path.caseInsensitiveCompare("INBOX") == .orderedSame }
        let system = input
            .filter { systemNames.contains($0.path) }
            .sorted { $0.path < $1.path }
        let userFolders = input
            .filter { folder in
                !inbox.contains(folder)
                    && !system.contains(folder)
                    && !folder.attributes.contains("\\Noselect")
            }
            .sorted { $0.path < $1.path }
        return inbox + userFolders + system
    }
}
