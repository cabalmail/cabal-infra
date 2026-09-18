import Foundation
import CabalmailKit

/// The mail sidebar's folder filter: which folders the tree draws.
///
/// Replaces the old Subscribed / All folders sections with pills above the
/// tree. `subscribed` and `unread` are independent toggles — both on means
/// "subscribed folders with unread mail" — and the All pill is the state
/// with neither on. The value is sticky per device (`@AppStorage` in
/// `FolderListView`), never synced: which folders a sidebar shows is a
/// property of the screen it is on, not of the account.
///
/// Pure, so the pill semantics and the predicate are testable without a
/// `List`. The rows it yields go through `FolderSectionRows`, which computes
/// depth and chevrons against whatever list it is handed — a folder whose
/// parent is filtered out simply draws at the parent's depth, as it did in
/// the old Subscribed section.
struct FolderListFilter: Equatable {
    var subscribed: Bool
    var unread: Bool

    /// The pill state a fresh install starts on: subscribed folders at a
    /// glance, everything else one tap away — the same first impression the
    /// Subscribed section used to give.
    static let defaultForMail = FolderListFilter(subscribed: true, unread: false)

    /// Neither toggle on: every folder.
    var isAll: Bool { !subscribed && !unread }

    /// The filter needs a count for *every* folder, not just the subscribed
    /// ones the sidebar fetches proactively. `FolderListView` answers by
    /// walking STATUS across the whole list once when this becomes true
    /// (and again on each manual refresh while it stays true); that keeps
    /// "subscribed means proactive" intact, because the walk is something
    /// the user asked for by choosing the pill.
    var needsEveryCount: Bool { unread && !subscribed }

    enum Pill: String, CaseIterable, Identifiable {
        case all, subscribed, unread

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all:        return "All"
            case .subscribed: return "Subscribed"
            case .unread:     return "Unread"
            }
        }
    }

    func isOn(_ pill: Pill) -> Bool {
        switch pill {
        case .all:        return isAll
        case .subscribed: return subscribed
        case .unread:     return unread
        }
    }

    /// The state after tapping a pill: All clears both toggles; the other
    /// two flip themselves. Tapping All while already on All is a no-op.
    func toggled(_ pill: Pill) -> FolderListFilter {
        var next = self
        switch pill {
        case .all:        next = FolderListFilter(subscribed: false, unread: false)
        case .subscribed: next.subscribed.toggle()
        case .unread:     next.unread.toggle()
        }
        return next
    }

    /// The folders the tree draws. `selection` is exempt: reading the last
    /// unread message in a folder must not pull that folder out from under
    /// the user, and unsubscribing the open folder shouldn't either.
    func apply(
        to folders: [Folder],
        unreadCounts: [String: Int],
        selection: String?
    ) -> [Folder] {
        guard !isAll else { return folders }
        return folders.filter { folder in
            if folder.path == selection { return true }
            if subscribed && !folder.isSubscribed { return false }
            if unread && (unreadCounts[folder.path] ?? 0) <= 0 { return false }
            return true
        }
    }
}
