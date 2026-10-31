import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The reader's Message menu in a tall window (`ReaderMessageMenuLayout`,
/// #1649): its rows in order from the bar's button, the ones that show only
/// when they apply, and the Addresses submenu's order.
final class ReaderMessageMenuLayoutTests: XCTestCase {
    private typealias Layout = ReaderMessageMenuLayout

    private let html = Layout.Content(hasHTML: true, hasPlainAlternative: true, addressCount: 3)

    func testAnHTMLMessageWithAddressesShowsEveryRowInOrder() {
        XCTAssertEqual(Layout.rows(for: html), [.loadImages, .addresses, .moveToFolder, .display, .more])
        XCTAssertEqual(Layout.displayRows(for: html), [.readerView, .plainText])
    }

    /// A plain-text message has no remote content to load and nothing to
    /// display another way.
    func testAPlainTextMessageHasNoImageOrDisplayRows() {
        let plain = Layout.Content(hasHTML: false, hasPlainAlternative: true, addressCount: 1)

        XCTAssertEqual(Layout.rows(for: plain), [.addresses, .moveToFolder, .more])
        XCTAssertEqual(Layout.displayRows(for: plain), [])
    }

    /// Plain Text toggles only between two parts the message has.
    func testAnHTMLOnlyMessageDisplaysReaderViewAlone() {
        let htmlOnly = Layout.Content(hasHTML: true, hasPlainAlternative: false, addressCount: 1)

        XCTAssertEqual(Layout.displayRows(for: htmlOnly), [.readerView])
        XCTAssertTrue(Layout.rows(for: htmlOnly).contains(.display))
    }

    func testNoAddressesNoAddressesRow() {
        let none = Layout.Content(hasHTML: true, hasPlainAlternative: false, addressCount: 0)

        XCTAssertFalse(Layout.rows(for: none).contains(.addresses))
    }

    /// The spec's budget: seven rows fit between the fold and the bar, and
    /// the rows still to join (Previous and Next, Attachments) need two.
    func testTheMenuLeavesRoomForTheRowsStillToJoin() {
        XCTAssertLessThanOrEqual(Layout.rows(for: html).count, 5)
    }

    // MARK: The Addresses submenu

    private func address(_ mailbox: String, _ host: String = "example.com") -> EmailAddress {
        EmailAddress(name: nil, mailbox: mailbox, host: host)
    }

    func testTheUsersOwnAddressesComeFirstThenTheHeadersOrder() {
        let sender = address("sender")
        let mine = address("me", "a.example.com")
        let other = address("other")
        let copied = address("copied")

        let ordered = Layout.addresses(from: [sender], to: [mine, other], cc: [copied]) { $0 == mine }

        XCTAssertEqual(ordered.map(\.address), [mine, sender, other, copied])
    }

    /// In Sent the user's own address is the From line; listed once, first.
    func testAnAddressNamedTwiceIsListedOnce() {
        let mine = address("Me", "A.example.com")
        let sameAgain = address("me", "a.example.com")
        let recipient = address("friend")

        let ordered = Layout.addresses(from: [mine], to: [recipient, sameAgain], cc: [sameAgain]) {
            $0.mailbox.lowercased() == "me"
        }

        XCTAssertEqual(ordered.map(\.address), [mine, recipient])
    }

    /// The user's own receiving address, the one they would revoke, lays
    /// its actions out in the Addresses submenu itself; every other address,
    /// a second one of their own included, opens a submenu.
    func testOnlyTheFirstOwnAddressLaysItsActionsOutInline() {
        let sender = address("sender")
        let mine = address("me", "a.example.com")
        let alsoMine = address("me", "b.example.com")

        let entries = Layout.addresses(from: [sender], to: [mine], cc: [alsoMine]) { $0.mailbox == "me" }

        XCTAssertEqual(entries.map(\.address), [mine, alsoMine, sender])
        XCTAssertEqual(entries.map(\.actionsInline), [true, false, false])
    }

    /// With none of the user's own in the header, every address opens a
    /// submenu: the sender's actions don't take the whole submenu.
    func testWithNoOwnAddressNothingIsInline() {
        let entries = Layout.addresses(from: [address("sender")], to: [address("other")], cc: []) { _ in false }

        XCTAssertEqual(entries.map(\.actionsInline), [false, false])
    }
}
