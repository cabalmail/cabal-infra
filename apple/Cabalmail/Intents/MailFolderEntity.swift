#if os(iOS)
import AppIntents
import CabalmailKit

/// One IMAP folder. `id` is the full `/`-delimited path — the identity used
/// across the Kit.
struct MailFolderEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Folder"
    static let defaultQuery = MailFolderQuery()

    let id: String

    var displayRepresentation: DisplayRepresentation {
        let name = id.split(separator: "/").last.map(String.init) ?? id
        guard name != id else { return DisplayRepresentation(title: "\(name)") }
        // Nested folders show the full path so "Receipts" under two parents
        // stays distinguishable in Siri's disambiguation list.
        return DisplayRepresentation(title: "\(name)", subtitle: "\(id)")
    }
}

struct MailFolderQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [MailFolderEntity] {
        identifiers.map(MailFolderEntity.init(id:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [MailFolderEntity] {
        await folderEntities().filter { $0.id.localizedCaseInsensitiveContains(string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [MailFolderEntity] {
        await folderEntities()
    }

    /// Folders in the canonical sidebar order. The folder-parameterized
    /// App Shortcut phrases resolve against this list (snapshotted by
    /// `updateAppShortcutParameters()` on session start). Errors and the
    /// signed-out state read as an empty list rather than throwing — these
    /// are browse paths, not action paths.
    @MainActor
    private func folderEntities() async -> [MailFolderEntity] {
        guard
            let client = try? await IntentBridge.shared.activeClient(),
            let folders = try? await client.imapClient.listFolders()
        else { return [] }
        return FolderTree.sidebarOrder(folders, dropNoselectUserFolders: true)
            .map { MailFolderEntity(id: $0.path) }
    }
}
#endif
