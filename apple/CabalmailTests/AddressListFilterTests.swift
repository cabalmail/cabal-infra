import XCTest
import CabalmailKit
@testable import CabalmailUI

// The address list's one pill: Favorites toggles, and off is every address.
// It replaced the Favorites / All addresses sections, so the unified list
// must still be able to show just the favorites, and say so when that hides
// what the user is looking for.
final class AddressListFilterTests: XCTestCase {
    private static let fav = Address(address: "fav@a.example", subdomain: "a", tld: "example", favorite: true)
    private static let plain = Address(address: "plain@b.example", subdomain: "b", tld: "example",
                                       comment: "Shopping")
    private static let both = [fav, plain]

    func testFreshInstallShowsEveryAddress() {
        XCTAssertEqual(AddressListFilter.defaultForAddresses, .all)
        XCTAssertEqual(AddressListFilter.defaultForAddresses.apply(to: Self.both, needle: ""), Self.both)
    }

    func testThePillTogglesBetweenTheTwoStoredStates() {
        XCTAssertEqual(AddressListFilter.all.toggled, .favorites)
        XCTAssertEqual(AddressListFilter.favorites.toggled, .all)
        XCTAssertNil(AddressListFilter(rawValue: "unread"), "an unknown stored value falls back to the default")
    }

    func testEachAddressAppearsOnceWithThePillOff() {
        // The old sections listed a favorite under both headings.
        let shown = AddressListFilter.all.apply(to: Self.both, needle: "")
        XCTAssertEqual(shown.filter { $0.address == Self.fav.address }.count, 1)
    }

    func testThePillKeepsOnlyFavorites() {
        XCTAssertEqual(AddressListFilter.favorites.apply(to: Self.both, needle: ""), [Self.fav])
    }

    func testTheTextFilterMatchesAddressOrCommentAndStacksWithThePill() {
        XCTAssertEqual(AddressListFilter.all.apply(to: Self.both, needle: " SHOP "), [Self.plain])
        XCTAssertEqual(AddressListFilter.all.apply(to: Self.both, needle: "fav@"), [Self.fav])
        XCTAssertEqual(AddressListFilter.favorites.apply(to: Self.both, needle: "shop"), [])
    }

    func testTheHintAppearsOnlyWhenThePillHidesAMatch() {
        XCTAssertNil(AddressListFilter.all.hint(for: Self.both, needle: "shop"), "pill off hides nothing")
        XCTAssertNil(AddressListFilter.favorites.hint(for: Self.both, needle: ""), "a favorite is showing")
        XCTAssertNil(AddressListFilter.favorites.hint(for: Self.both, needle: "nomatch"), "nothing to reveal")
        XCTAssertEqual(AddressListFilter.favorites.hint(for: Self.both, needle: "shop"),
                       "No favorites match. Show all addresses")
        XCTAssertEqual(AddressListFilter.favorites.hint(for: [Self.plain], needle: ""),
                       "No favorites yet. Show all addresses")
        XCTAssertNil(AddressListFilter.favorites.hint(for: [], needle: ""), "an empty account says nothing")
    }
}
