import Foundation
import CabalmailKit

/// The address list's filter: every address, or only the favorites. Sticky
/// per device (`@AppStorage`), never synced — the same reasoning as
/// `FolderListFilter` and `FeedListFilter`: which rows a sidebar shows is a
/// property of the screen it is on, not of the account.
///
/// One Favorites pill that toggles, as the Feeds tab's Unread pill does,
/// rather than an All / Favorites pair: off already means every address. It
/// replaces the list's old Favorites and All addresses sections, which drew
/// each favorite twice.
enum AddressListFilter: String {
    case all, favorites

    /// A fresh install shows every address: an address list with nothing
    /// favorited yet would otherwise open empty.
    static let defaultForAddresses: AddressListFilter = .all

    /// The one pill's label.
    static let pillLabel = "Favorites"

    var favoritesOnly: Bool { self == .favorites }

    /// The state after tapping the pill.
    var toggled: AddressListFilter { favoritesOnly ? .all : .favorites }

    /// The pill, then the text filter. The needle matches the address or its
    /// comment, case-insensitively; blank matches everything.
    func apply(to addresses: [Address], needle: String) -> [Address] {
        let byPill = favoritesOnly ? addresses.filter(\.favorite) : addresses
        let needle = needle.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return byPill }
        return byPill.filter { address in
            address.address.lowercased().contains(needle)
                || (address.comment?.lowercased().contains(needle) ?? false)
        }
    }

    /// Whether the list should offer to turn the pill off: it is on, and it
    /// hides something the pill-less list would show for the same needle —
    /// there are no favorites yet, or the typed text matches only addresses
    /// that are not favorites. Same job as the folder sidebar's hint row
    /// (#1662), so the pill never leaves an empty list that says nothing.
    func hidesMatches(in addresses: [Address], needle: String) -> Bool {
        guard favoritesOnly else { return false }
        return apply(to: addresses, needle: needle).isEmpty
            && !AddressListFilter.all.apply(to: addresses, needle: needle).isEmpty
    }

    /// The hint row's text, or nil when `hidesMatches` is false.
    func hint(for addresses: [Address], needle: String) -> String? {
        guard hidesMatches(in: addresses, needle: needle) else { return nil }
        let typed = !needle.trimmingCharacters(in: .whitespaces).isEmpty
        return typed ? "No favorites match. Show all addresses" : "No favorites yet. Show all addresses"
    }
}
