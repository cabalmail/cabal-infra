import XCTest
import CabalmailKit
@testable import CabalmailUI

// The compose From picker's filter. The picker opened a `Menu` until the
// filter came, and on macOS the only way to search a menu was type-to-select,
// which matched the start of an address and nothing else; #1702 was that
// search highlighting the wrong address once the drawn titles carried
// zero-width spaces. The list the picker opens now is filtered by
// `FromAddressFilter`, so these pin what typing finds.
final class FromAddressFilterTests: XCTestCase {

    private let work = Address(
        address: "work@acme.example.com", subdomain: "acme", tld: "example.com",
        comment: "Day job", favorite: true
    )
    private let daily = Address(address: "daily@qa0722.cabal-mail.com", subdomain: "qa0722", tld: "cabal-mail.com")
    private let shop = Address(
        address: "shop@store.example.com", subdomain: "store", tld: "example.com", comment: "Groceries"
    )
    private let alerts = Address(
        address: "alerts@bank.example.com", subdomain: "bank", tld: "example.com", favorite: true
    )

    private var addresses: [Address] { [work, daily, shop, alerts] }

    /// Nothing typed: every address, sorted, with the favorites also on top.
    func testABlankFilterListsEveryAddress() {
        let filter = FromAddressFilter(addresses: addresses, needle: "")
        XCTAssertEqual(filter.favorites.map(\.address), [alerts.address, work.address])
        XCTAssertEqual(filter.all.map(\.address), [alerts.address, daily.address, shop.address, work.address])
        XCTAssertEqual(FromAddressFilter(addresses: addresses, needle: "  "), filter)
    }

    /// Any part of the address, in any case: a subdomain, a domain, the
    /// middle of a local part.
    func testTheFilterMatchesAnyPartOfTheAddress() {
        XCTAssertEqual(FromAddressFilter(addresses: addresses, needle: "STORE").all, [shop])
        XCTAssertEqual(FromAddressFilter(addresses: addresses, needle: "ail").all, [daily])
        XCTAssertEqual(
            FromAddressFilter(addresses: addresses, needle: "example.com").all.map(\.address),
            [alerts.address, shop.address, work.address]
        )
    }

    /// The comment is searched too, as in the address sidebar and the React
    /// picker, which is what a comment on an address is for.
    func testTheFilterMatchesTheComment() {
        XCTAssertEqual(FromAddressFilter(addresses: addresses, needle: "groc").all, [shop])
        XCTAssertEqual(FromAddressFilter(addresses: addresses, needle: "day job").favorites, [work])
    }

    /// What the user types is the address's own characters, so the filter
    /// matches the address and not the string a row draws, which carries a
    /// zero-width space between every character (#1597). The negative
    /// control is the drawn string itself: it doesn't contain what was typed.
    func testTypedCharactersFindTheAddressRatherThanItsDrawnForm() {
        let typed = "daily@qa"
        XCTAssertFalse(AddressDisplay.wrappable(daily.address).contains(typed))
        XCTAssertEqual(FromAddressFilter(addresses: addresses, needle: typed).all, [daily])
    }

    /// The Favorites section shows only when a favorite matches, so a filter
    /// that matches none draws one plain list rather than an empty heading.
    func testTheFavoritesSectionHoldsOnlyMatchingFavorites() {
        let filter = FromAddressFilter(addresses: addresses, needle: "shop")
        XCTAssertEqual(filter.favorites, [])
        XCTAssertEqual(filter.all, [shop])
    }

    /// Return picks the first row drawn: the first favorite while that
    /// section shows, otherwise the first address.
    func testReturnPicksTheFirstRowDrawn() {
        XCTAssertEqual(FromAddressFilter(addresses: addresses, needle: "example").firstMatch, alerts)
        XCTAssertEqual(FromAddressFilter(addresses: addresses, needle: "a").firstMatch, alerts)
        XCTAssertEqual(FromAddressFilter(addresses: addresses, needle: "qa07").firstMatch, daily)
    }

    /// Nothing matches: no rows, and Return picks nothing.
    func testAFilterThatMatchesNothingIsEmpty() {
        let filter = FromAddressFilter(addresses: addresses, needle: "zzz")
        XCTAssertTrue(filter.isEmpty)
        XCTAssertNil(filter.firstMatch)
        XCTAssertTrue(FromAddressFilter(addresses: [], needle: "").isEmpty)
    }

    /// The filter field takes focus as the picker opens only where no
    /// software keyboard would rise over the rows. This suite is hosted by
    /// the macOS app, so `.current` has to resolve to the Mac's answer.
    func testOnlyTheMacFocusesTheFilterOnOpen() {
        XCTAssertTrue(HostPlatform.macOS.focusesPickerFilterOnOpen)
        XCTAssertFalse(HostPlatform.iOS.focusesPickerFilterOnOpen)
        XCTAssertFalse(HostPlatform.visionOS.focusesPickerFilterOnOpen)
        XCTAssertTrue(HostPlatform.current.focusesPickerFilterOnOpen)
    }
}
