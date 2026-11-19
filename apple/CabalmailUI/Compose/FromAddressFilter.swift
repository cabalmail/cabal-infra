import CabalmailKit

/// What the compose From picker lists for the text typed into its filter.
///
/// A pure value so the rule is testable directly: `FromAddressList`'s body
/// isn't reachable from a unit test, this is.
///
/// Matching is the address list's own (`AddressListFilter.all`): the address
/// or its comment, case-insensitively, a blank filter matching everything.
/// That is also what the React picker matches (its subdomain term is part of
/// the address already), so a note written in one client finds the address
/// in every one.
///
/// The two lists keep the picker's sections: **Favorites** on top when any
/// favorite matches, then **All addresses** inclusive, each sorted by
/// address.
struct FromAddressFilter: Equatable {
    let favorites: [Address]
    let all: [Address]

    init(addresses: [Address], needle: String) {
        let matches = AddressListFilter.all.apply(to: addresses, needle: needle)
            .sorted { $0.address < $1.address }
        favorites = matches.filter(\.favorite)
        all = matches
    }

    /// Nothing matched. A blank filter over an empty address list is empty
    /// too; the picker tells the two apart by the filter text.
    var isEmpty: Bool { all.isEmpty }

    /// The row Return picks: the first one drawn, which is the first favorite
    /// when the Favorites section is showing.
    var firstMatch: Address? { favorites.first ?? all.first }
}
