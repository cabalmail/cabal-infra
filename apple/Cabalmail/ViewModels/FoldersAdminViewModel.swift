import Foundation
import Observation
import CabalmailKit

/// Backs `FoldersAdminView`. Wraps the IMAP `LIST`, `LSUB`, `CREATE`,
/// `DELETE`, `SUBSCRIBE`, and `UNSUBSCRIBE` commands with list state, error
/// reporting, and the grouping logic the UI uses (subscribed vs
/// unsubscribed; hide `\Noselect` rows from delete affordances).
///
/// System folders (INBOX, Sent, Drafts, Trash, Junk, Archive) stay present
/// but are surfaced as non-deletable rows — the IMAP server would usually
/// reject a `DELETE` on them anyway, but explicit UI gating is clearer than
/// letting the server say no.
@Observable
@MainActor
final class FoldersAdminViewModel {
    var folders: [Folder] = []
    var isLoading = false
    var errorMessage: String?

    /// Set of folders the user has expanded in the UI. Persisted only for
    /// the lifetime of the view model — Phase 7 polish may persist this
    /// across launches alongside the rest of the UI state.
    var expandedPaths: Set<String> = []

    private let client: CabalmailClient

    init(client: CabalmailClient) {
        self.client = client
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await client.imapClient.connectAndAuthenticate()
            folders = try await client.imapClient
                .listFolders()
                .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
            errorMessage = nil
        } catch let error as CabalmailError {
            errorMessage = String(describing: error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleSubscription(_ folder: Folder) async {
        do {
            try await client.imapClient.connectAndAuthenticate()
            if folder.isSubscribed {
                try await client.imapClient.unsubscribe(path: folder.path)
            } else {
                try await client.imapClient.subscribe(path: folder.path)
            }
            updateSubscription(for: folder.path, to: !folder.isSubscribed)
            errorMessage = nil
        } catch let error as CabalmailError {
            errorMessage = String(describing: error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createFolder(name: String, parent: String?) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        do {
            try await client.imapClient.connectAndAuthenticate()
            try await client.imapClient.createFolder(name: trimmed, parent: parent)
            // Auto-subscribe on create so the new folder shows up in the
            // Mail sidebar without a second tap; Dovecot doesn't do this
            // for us. Best-effort — if the server rejects the SUBSCRIBE,
            // the folder is still created and the refresh below will
            // surface it in the unsubscribed section.
            try? await client.imapClient.subscribe(
                path: fullPath(for: trimmed, parent: parent)
            )
            await refresh()
            errorMessage = nil
            return true
        } catch let error as CabalmailError {
            errorMessage = String(describing: error)
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }

    func deleteFolder(_ folder: Folder) async {
        guard canDelete(folder) else { return }
        do {
            try await client.imapClient.connectAndAuthenticate()
            try await client.imapClient.deleteFolder(path: folder.path)
            folders.removeAll { $0.path == folder.path }
            errorMessage = nil
        } catch let error as CabalmailError {
            errorMessage = String(describing: error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Classification helpers

    /// Folders the user can create subfolders under. Anything `\Noselect`
    /// (container-only) is excluded from the parent picker because child
    /// `CREATE` would fail with a server error.
    var possibleParents: [Folder] {
        folders.filter { !$0.attributes.contains("\\Noselect") }
    }

    static let systemPaths: Set<String> = [
        "INBOX", "Sent", "Drafts", "Trash", "Junk", "Archive"
    ]

    /// Deletion is available for user folders the server marks as leaves —
    /// system folders and `\Noselect` containers stay protected.
    func canDelete(_ folder: Folder) -> Bool {
        !Self.systemPaths.contains(folder.path)
            && !folder.attributes.contains("\\Noselect")
    }

    /// Subscription toggles apply to every row — system folders too, since
    /// a user may well want INBOX hidden or Sent unsubscribed on mobile.
    func canToggleSubscription(_ folder: Folder) -> Bool {
        !folder.attributes.contains("\\Noselect")
    }

    /// Best-effort classification: folders whose path starts with a known
    /// system name group together at the top of the list for fast access,
    /// with user folders listed below alphabetically.
    var sortedForDisplay: [Folder] {
        let system = folders
            .filter { Self.systemPaths.contains($0.path) }
            .sorted { $0.path == "INBOX" && $1.path != "INBOX" }
        let user = folders
            .filter { !Self.systemPaths.contains($0.path) }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        return system + user
    }

    // MARK: - Internals

    private func updateSubscription(for path: String, to subscribed: Bool) {
        guard let index = folders.firstIndex(where: { $0.path == path }) else { return }
        let previous = folders[index]
        folders[index] = Folder(
            path: previous.path,
            attributes: previous.attributes,
            isSubscribed: subscribed
        )
    }

    private func fullPath(for name: String, parent: String?) -> String {
        if let parent, !parent.isEmpty {
            return "\(parent)/\(name)"
        }
        return name
    }
}
