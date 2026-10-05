import Foundation
import CabalmailKit

/// The mail sidebar's folder filter: which folders the tree draws.
///
/// Replaces the old Subscribed / All folders sections with pills above the
/// tree. `subscribed` and `unread` are independent toggles — both on means
/// "subscribed folders with unread mail", both off means every folder.
/// There is deliberately no All pill: turning both toggles off is the same
/// act, and a third pill only restated it. The value is sticky per device
/// (`@AppStorage` in
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

    /// Both toggles off — what the text-filter hint row applies.
    static let unfiltered = FolderListFilter(subscribed: false, unread: false)

    /// The filter needs a count for *every* folder, not just the subscribed
    /// ones the sidebar fetches proactively. `FolderListView` answers by
    /// walking STATUS across the whole list once when this becomes true
    /// (and again on each manual refresh while it stays true); that keeps
    /// "subscribed means proactive" intact, because the walk is something
    /// the user asked for by choosing the pill.
    var needsEveryCount: Bool { unread && !subscribed }

    enum Pill: String, CaseIterable, Identifiable {
        case subscribed, unread

        var id: String { rawValue }

        var label: String {
            switch self {
            case .subscribed: return "Subscribed"
            case .unread:     return "Unread"
            }
        }
    }

    func isOn(_ pill: Pill) -> Bool {
        switch pill {
        case .subscribed: return subscribed
        case .unread:     return unread
        }
    }

    /// The state after tapping a pill: that toggle flips, the other stays.
    func toggled(_ pill: Pill) -> FolderListFilter {
        var next = self
        switch pill {
        case .subscribed: next.subscribed.toggle()
        case .unread:     next.unread.toggle()
        }
        return next
    }

    /// Whether `folder` answers the sidebar's text filter. Lifted out of
    /// `FolderListView.filteredFolders` so `hint(for:visible:needle:)`
    /// counts matches by the same rule the tree draws them by; `needle` is
    /// already trimmed and lowercased.
    static func matches(_ folder: Folder, needle: String) -> Bool {
        folder.path.lowercased().contains(needle)
            || folder.name.lowercased().contains(needle)
    }

    /// What the sidebar says when a find loses to the pills (#1662).
    ///
    /// The pills run before the text filter, so typing the name of a folder
    /// the current pill excludes drew nothing at all — no row, no empty
    /// state, no hint that a pill two rows above was the reason. The pills
    /// stay authoritative over the rows (a pill reading Subscribed must not
    /// quietly list unsubscribed folders), but the tree owes the user the
    /// count it is suppressing and one click that turns the pills off.
    struct Hint: Equatable {
        /// Folders the needle matched and the pills then removed.
        var suppressed: Int
        /// Whether the tree drew any row at all under this needle.
        var anyVisible: Bool

        /// Phrased as the action the row performs, because the row is the
        /// button that performs it.
        var label: String {
            let matches = suppressed == 1 ? "match" : "matches"
            return anyVisible
                ? "Show \(suppressed) more \(matches) in all folders"
                : "Show \(suppressed) hidden \(matches) in all folders"
        }
    }

    /// The hint for a needle, or `nil` when there is nothing to say: an
    /// empty needle, no pill on (which suppresses nothing), or a needle
    /// whose every match is already drawn. `visible` is what the tree drew
    /// — pills and needle both applied.
    func hint(for folders: [Folder], visible: [Folder], needle rawNeedle: String) -> Hint? {
        let needle = rawNeedle.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty, !isAll else { return nil }
        let matched = folders.filter { FolderListFilter.matches($0, needle: needle) }.count
        let suppressed = matched - visible.count
        guard suppressed > 0 else { return nil }
        return Hint(suppressed: suppressed, anyVisible: !visible.isEmpty)
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
