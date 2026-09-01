import XCTest
import CabalmailKit
@testable import Cabalmail

/// `SortMenuPolicy`: what the message list's sort menu offers, which row
/// each group marks, and the identity that makes macOS redraw it.
///
/// The reported defect (#1367, measured on macOS 26.6.2 through raw
/// `AXUIElementCopyAttributeValue`): every row of that menu answered
/// `AXMenuItemMarkChar = missing value`, because the active field drew a
/// `Label(…, systemImage: "checkmark")` and the direction drew an arrow —
/// pictures inside a row's label rather than a state the row carries. The
/// rows here carry `isOn` so the view can render a `Toggle`, which is what
/// sets the native mark.
final class SortMenuPolicyTests: XCTestCase {
    private func rows(
        _ field: SortCriterion.Field, _ direction: SortCriterion.Direction
    ) -> [ReaderMenuRow<SortMenuOption>] {
        SortMenuPolicy.rows(criterion: SortCriterion(field: field, direction: direction))
    }

    // MARK: - Rows

    func testOffersEveryFieldThenEveryDirection() {
        let menu = rows(.dateReceived, .descending)
        XCTAssertEqual(
            menu.map(\.option),
            [
                .field(.dateReceived), .field(.dateSent), .field(.from), .field(.subject),
                .direction(.ascending), .direction(.descending),
            ]
        )
        XCTAssertEqual(
            menu.map(\.label),
            ["Date Received", "Date Sent", "From", "Subject", "Ascending", "Descending"]
        )
    }

    /// One divider, between the field group and the direction group.
    func testDirectionGroupStartsAfterASingleDivider() {
        let menu = rows(.subject, .ascending)
        XCTAssertEqual(menu.map(\.startsGroup), [false, false, false, false, true, false])
    }

    /// The whole point of the fix: the state is on the row. Exactly one
    /// field and exactly one direction are marked, and both move with the
    /// criterion.
    func testMarksTheFieldAndTheDirectionInEffect() {
        XCTAssertEqual(
            rows(.dateReceived, .descending).map(\.isOn),
            [true, false, false, false, false, true]
        )
        XCTAssertEqual(
            rows(.from, .ascending).map(\.isOn),
            [false, false, true, false, true, false]
        )
    }

    /// The direction was the half the report's own framing missed: before
    /// the fix the menu drew one flip row whose arrow glyph was equally
    /// unreadable, so a marked direction row has to move on its own.
    func testTheDirectionMarkMovesWithTheFieldUnchanged() {
        let ascending = rows(.subject, .ascending)
        let descending = rows(.subject, .descending)
        XCTAssertEqual(ascending.map(\.isOn).suffix(2), [true, false])
        XCTAssertEqual(descending.map(\.isOn).suffix(2), [false, true])
        XCTAssertEqual(ascending.map(\.isOn).prefix(4), descending.map(\.isOn).prefix(4))
    }

    /// A row's key names the option, not what it draws, so the two groups
    /// cannot collide and a label change does not move a row's identity.
    func testKeysAreUniqueAndNameTheOption() {
        let keys = rows(.from, .ascending).map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(keys.first, "field.dateReceived")
        XCTAssertEqual(keys.last, "direction.descending")
    }

    // MARK: - Picking a row

    /// Picking a field keeps the direction and picking a direction keeps
    /// the field — the behaviour the two separate `Button` actions used to
    /// spell out inline.
    func testPickingAFieldKeepsTheDirection() {
        let current = SortCriterion(field: .dateReceived, direction: .ascending)
        XCTAssertEqual(
            SortMenuPolicy.criterion(picking: .field(.subject), from: current),
            SortCriterion(field: .subject, direction: .ascending)
        )
    }

    func testPickingADirectionKeepsTheField() {
        let current = SortCriterion(field: .from, direction: .ascending)
        XCTAssertEqual(
            SortMenuPolicy.criterion(picking: .direction(.descending), from: current),
            SortCriterion(field: .from, direction: .descending)
        )
    }

    /// Picking the row that is already marked is the identity — the view
    /// model's own `setSort` guard then makes it a no-op.
    func testPickingTheMarkedRowReproducesTheCurrentCriterion() {
        let current = SortCriterion(field: .dateSent, direction: .descending)
        XCTAssertEqual(SortMenuPolicy.criterion(picking: .field(.dateSent), from: current), current)
        XCTAssertEqual(
            SortMenuPolicy.criterion(picking: .direction(.descending), from: current), current
        )
    }

    // MARK: - Identity

    /// A `Toggle` brings macOS's materialize-once menu with it (#1329,
    /// #1337): the menu the fix makes readable would otherwise freeze on
    /// the state it was first opened with. Both marks have to move it.
    func testIdentityChangesWhenTheCheckedFieldMoves() {
        XCTAssertNotEqual(
            SortMenuPolicy.identity(rows(.dateReceived, .descending)),
            SortMenuPolicy.identity(rows(.subject, .descending))
        )
    }

    func testIdentityChangesWhenTheCheckedDirectionMoves() {
        XCTAssertNotEqual(
            SortMenuPolicy.identity(rows(.dateReceived, .descending)),
            SortMenuPolicy.identity(rows(.dateReceived, .ascending))
        )
    }

    /// The other half of the contract: an identity that churned on every
    /// body pass would rebuild the menu constantly.
    func testIdentityIsStableForUnchangedContent() {
        XCTAssertEqual(
            SortMenuPolicy.identity(rows(.from, .ascending)),
            SortMenuPolicy.identity(rows(.from, .ascending))
        )
    }
}
