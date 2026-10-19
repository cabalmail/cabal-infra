import XCTest
@testable import CabalmailUI

/// The shape rule the reader's macOS toolbar stand-ins are built from
/// (#2016): every greyed slot must be the kind of control that replaces it,
/// because a chevron segment is worth real points and a narrow stand-in
/// moves every button after it when a message opens.
final class ReaderToolbarControlShapeTests: XCTestCase {

    func testReplyIsAPullDownMenu() {
        // `replyButton` is a `Menu` with no primary action: Reply, Reply All,
        // Forward.
        XCTAssertEqual(shape(.reply), .menu)
        XCTAssertEqual(shape(.reply, flagMenuHasRows: true), .menu)
    }

    func testDisposeAndReadAreSplitButtons() {
        // Both are `Menu { … } primaryAction: { … }` with
        // `.menuIndicator(optionMenuIndicator)`, which is `.visible` on macOS.
        XCTAssertEqual(shape(.dispose), .splitButton)
        XCTAssertEqual(shape(.toggleRead), .splitButton)
    }

    func testFlagFollowsThePalette() {
        // `flagButton` draws the plain button it always was while the palette
        // offers nothing, and a split button once it does.
        XCTAssertEqual(shape(.toggleFlag, flagMenuHasRows: false), .button)
        XCTAssertEqual(shape(.toggleFlag, flagMenuHasRows: true), .splitButton)
    }

    func testEveryOtherMacSlotIsAPlainButton() {
        let plain: [ReaderToolbarAction] = [
            .editDraft, .remoteContent, .readerMode,
            .move, .plainText, .viewSource, .viewHeaders, .printMessage
        ]
        for action in plain {
            XCTAssertEqual(shape(action), .button, "\(action.rawValue) draws a plain button")
            XCTAssertEqual(
                shape(action, flagMenuHasRows: true), .button,
                "\(action.rawValue) does not care about the flag palette"
            )
        }
    }

    func testThePaletteOnlyMovesTheFlagSlot() {
        // The guard against a rule that keys off the palette too widely: one
        // slot changes shape with it, and it is the flag.
        let actions = ReaderToolbarLayout.macToolbar(leading: .reply)
        let moved = actions.filter {
            shape($0, flagMenuHasRows: false) != shape($0, flagMenuHasRows: true)
        }
        XCTAssertEqual(moved, [.toggleFlag])
    }

    func testTheMacToolbarInventoryIsCovered() {
        // A new slot is visible here rather than silently drawing a plain
        // stand-in: both leading variants, eleven slots each.
        for leading in [LeadingReaderAction.reply, .editDraft] {
            let actions = ReaderToolbarLayout.macToolbar(leading: leading)
            XCTAssertEqual(actions.count, 11)
            XCTAssertEqual(Set(actions).count, 11, "no slot is drawn twice")
        }
        XCTAssertEqual(
            ReaderToolbarLayout.macToolbar(leading: .editDraft).first, .editDraft
        )
    }

    func testTheFeedsMoreMenuIsAMenuAndTheRestAreButtons() {
        XCTAssertEqual(FeedReaderToolbarLayout.macControlShape(for: .more), .menu)
        for action in [FeedReaderAction.read, .favorite, .readerMode, .remoteContent, .article] {
            XCTAssertEqual(
                FeedReaderToolbarLayout.macControlShape(for: action), .button,
                "\(action.rawValue) draws a plain button on the wide bar"
            )
        }
    }

    func testTheFeedStandInSetIsTheFullestWideBar() {
        // The stand-ins reserve the fullest set, so `.more` — the one menu —
        // is among them and its shape is the one that matters.
        XCTAssertEqual(
            FeedReaderToolbarLayout.standIns,
            [.read, .favorite, .readerMode, .remoteContent, .article, .more]
        )
    }

    private func shape(
        _ action: ReaderToolbarAction,
        flagMenuHasRows: Bool = false
    ) -> ReaderToolbarControlShape {
        ReaderToolbarLayout.macControlShape(for: action, flagMenuHasRows: flagMenuHasRows)
    }
}
