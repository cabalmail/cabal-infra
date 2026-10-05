import Foundation
import Observation
import CabalmailKit

// The in-progress input behind each Feeds management sheet, owned by the
// presenting view rather than the sheet: sheet-local `@State` is lost when
// SwiftUI re-creates the sheet's body, which dismissing a `Picker`'s menu
// does on compact iPhone (#889, the mail folder sheet's lesson).

/// Subscribe sheet: the address and the folder it lands in.
@Observable
final class SubscribeFeedForm {
    var url = ""
    /// Folder id, or `""` for the picker's top-level row.
    var folderId = ""

    /// The address to send, or nil when there is nothing usable yet. A bare
    /// host is allowed and read as https (the server refuses plain http
    /// that cannot upgrade, with its own message).
    var normalizedURL: String? {
        FeedFormRules.normalizedFeedURL(url)
    }

    var canSubscribe: Bool { normalizedURL != nil }

    func reset(folderId: String?) {
        url = ""
        self.folderId = folderId ?? ""
    }
}

/// Folder sheet: create, or rename / move when `editing` is set.
@Observable
final class FeedFolderForm {
    var name = ""
    /// Parent folder id, or `""` for top level.
    var parentId = ""
    var editing: RssFolder?

    var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard let editing else { return true }
        return trimmed != editing.name || parentId != editing.parentFolderId
    }

    /// The fields that changed, for an edit; nil when nothing did.
    var folderUpdate: RssFolderUpdate? {
        guard let editing else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var update = RssFolderUpdate()
        if trimmed != editing.name { update.name = trimmed }
        if parentId != editing.parentFolderId { update.parentFolderId = parentId }
        return update.name == nil && update.parentFolderId == nil ? nil : update
    }

    func reset(editing: RssFolder?, parentId: String?) {
        self.editing = editing
        name = editing?.name ?? ""
        self.parentId = editing?.parentFolderId ?? parentId ?? ""
    }
}

/// Subscription settings sheet: the per-feed preferences and the title.
@Observable
final class FeedSubscriptionSettingsForm {
    var customTitle = ""
    var folderId = ""
    var orderingMode: RssOrderingMode = .newestFirst
    var defaultOpenMode: RssOpenMode = .summary
    var defaultStyling: RssStyling = .reader
    var defaultRemoteContent: RssRemoteContentMode = .inherit

    func load(from subscription: RssSubscription) {
        customTitle = subscription.customTitle
        folderId = subscription.folderId
        orderingMode = subscription.orderingMode
        defaultOpenMode = subscription.defaultOpenMode
        defaultStyling = subscription.defaultStyling
        defaultRemoteContent = subscription.defaultRemoteContent
    }

    /// Only the fields that differ from the subscription; nil when none do,
    /// so the sheet's Save stays disabled and the server never sees a
    /// `nothing_to_update`.
    func update(against subscription: RssSubscription) -> RssSubscriptionUpdate? {
        var update = RssSubscriptionUpdate()
        var changed = false
        let title = customTitle.trimmingCharacters(in: .whitespaces)
        if title != subscription.customTitle { update.customTitle = title; changed = true }
        if folderId != subscription.folderId { update.folderId = folderId; changed = true }
        if orderingMode != subscription.orderingMode { update.orderingMode = orderingMode; changed = true }
        if defaultOpenMode != subscription.defaultOpenMode { update.defaultOpenMode = defaultOpenMode; changed = true }
        if defaultStyling != subscription.defaultStyling { update.defaultStyling = defaultStyling; changed = true }
        if defaultRemoteContent != subscription.defaultRemoteContent {
            update.defaultRemoteContent = defaultRemoteContent
            changed = true
        }
        return changed ? update : nil
    }
}

/// Pure rules shared by the forms and the pickers.
enum FeedFormRules {
    /// Trims, adds `https://` to a bare host, and requires a host. Returns
    /// nil for anything that cannot be an address at all; the server does
    /// the real validation (D1: apex form, https only).
    static func normalizedFeedURL(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard let components = URLComponents(string: text), let host = components.host, host.contains(".") else {
            return nil
        }
        return text
    }
}

/// One row of a folder picker: the folder, indented by its depth.
struct FeedFolderChoice: Identifiable, Equatable {
    let id: String
    let label: String
    let depth: Int
}

/// Folder picker rows in tree order, optionally without one folder and its
/// descendants (a folder cannot be moved under itself).
enum FeedFolderChoices {
    static func choices(folders: [RssFolder], excluding excluded: String? = nil) -> [FeedFolderChoice] {
        let byParent = Dictionary(grouping: folders, by: \.parentFolderId)
        var out: [FeedFolderChoice] = []
        func walk(_ parentId: String, depth: Int) {
            let children = (byParent[parentId] ?? []).sorted {
                ($0.displayOrder, $0.name.lowercased()) < ($1.displayOrder, $1.name.lowercased())
            }
            for folder in children where folder.folderId != excluded {
                out.append(FeedFolderChoice(id: folder.folderId, label: folder.name, depth: depth))
                walk(folder.folderId, depth: depth + 1)
            }
        }
        walk("", depth: 0)
        return out
    }
}
