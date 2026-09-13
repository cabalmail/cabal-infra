import XCTest
@testable import CabalmailKit

/// #1547: the revoke confirmation drew `cmg6m7da@7389v9rd.-` / `cabal-mail.com`
/// on an iPhone, because an address is one unbreakable token and SwiftUI
/// answers a token that cannot fit by hyphenating it. The hyphen is not in the
/// address, and since addresses carry their own hyphens the result names an
/// address the user does not own. Every surface that asks the user to read an
/// address back now goes through `AddressDisplay`.
final class AddressDisplayTests: XCTestCase {
    /// The address from the report's first two arms.
    private let sample = "cmg6m7da@7389v9rd.cabal-mail.com"

    private static let zeroWidthSpace: Character = "\u{200B}"

    private func visibleCharacters(of text: String) -> String {
        String(text.filter { $0 != Self.zeroWidthSpace })
    }

    // MARK: - The primitive

    func testWrappableKeepsEveryVisibleCharacter() {
        XCTAssertEqual(
            visibleCharacters(of: AddressDisplay.wrappable(sample)),
            sample,
            "stripping the break opportunities must give the address back unchanged"
        )
    }

    func testWrappableAddsNoHyphen() {
        let wrapped = AddressDisplay.wrappable(sample)
        XCTAssertEqual(
            wrapped.filter { $0 == "-" }.count,
            sample.filter { $0 == "-" }.count,
            "the only hyphens drawn may be the address's own"
        )
        XCTAssertFalse(wrapped.contains("\u{00AD}"), "a soft hyphen still draws as a hyphen at a wrap point")
    }

    func testWrappableOffersABreakBetweenEveryPairOfCharacters() {
        // What stops the hyphenation: with a legal break available anywhere,
        // the layout engine never has to invent one.
        let wrapped = Array(AddressDisplay.wrappable(sample))
        XCTAssertEqual(wrapped.count, sample.count * 2 - 1)
        for (index, character) in wrapped.enumerated() where index % 2 == 1 {
            XCTAssertEqual(character, Self.zeroWidthSpace, "no break opportunity at offset \(index)")
        }
    }

    func testWrappableDoesNotTrailABreakOpportunity() {
        // A trailing break would let the wrap fall after the final character,
        // drawing an empty last line.
        XCTAssertEqual(AddressDisplay.wrappable(sample).last, sample.last)
    }

    func testWrappableHandlesEmptyAndSingleCharacterInput() {
        XCTAssertEqual(AddressDisplay.wrappable(""), "")
        XCTAssertEqual(AddressDisplay.wrappable("a"), "a")
    }

    // MARK: - The confirmation copy

    func testRevokeTitleReadsAsTheAddressAndNothingElse() {
        XCTAssertEqual(visibleCharacters(of: AddressDisplay.revokeTitle(sample)), "Revoke \(sample)?")
        XCTAssertTrue(AddressDisplay.revokeTitle(sample).contains(Self.zeroWidthSpace))
    }

    func testSuspendTitleReadsAsTheAddressAndNothingElse() {
        XCTAssertEqual(visibleCharacters(of: AddressDisplay.suspendTitle(sample)), "Suspend \(sample)?")
        XCTAssertTrue(AddressDisplay.suspendTitle(sample).contains(Self.zeroWidthSpace))
    }

    func testRevokeMessageWrapsTheAddressAndKeepsTheWording() {
        XCTAssertEqual(
            visibleCharacters(of: AddressDisplay.revokeMessage(sample)),
            "Mail sent to \(sample) will be rejected. This can't be undone."
        )
        XCTAssertTrue(
            AddressDisplay.revokeMessage(sample).contains(AddressDisplay.wrappable(sample)),
            "the message must carry the wrappable address, not the raw one"
        )
    }

    func testSuspendMessageWrapsTheAddressAndKeepsTheWording() {
        XCTAssertEqual(
            visibleCharacters(of: AddressDisplay.suspendMessage(sample)),
            """
            The DNS records for \(sample) will be removed and inbound mail \
            will stop being deliverable. The address is kept and can be reinstated \
            at any time.
            """
        )
        XCTAssertTrue(AddressDisplay.suspendMessage(sample).contains(AddressDisplay.wrappable(sample)))
    }

    /// The unbreakable token is what the layout engine hyphenates, so it must
    /// not survive anywhere in the drawn string — a partially wrapped address
    /// would still hyphenate in the run that was left whole.
    func testRevokeMessageDoesNotCarryTheUnbreakableToken() {
        XCTAssertFalse(AddressDisplay.revokeMessage(sample).contains(sample))
        XCTAssertFalse(AddressDisplay.revokeTitle(sample).contains(sample))
    }
}
