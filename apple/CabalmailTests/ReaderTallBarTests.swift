import XCTest
@testable import CabalmailUI

/// The reader's own bar in a window taller than wide
/// (`ReaderToolbarLayout.tallBar`): the iPhone Duo open upright or in laptop
/// pose, an iPad in portrait.
final class ReaderTallBarTests: XCTestCase {
    /// The iPhone Duo spec's bar for every tall window, in its order: the
    /// list's bar is behind the message or below a laptop fold there.
    func testATallWindowsBarCarriesTheSpecsSetInOrder() {
        XCTAssertEqual(
            ReaderToolbarLayout.ownBar(leading: .reply, paneWidth: 669, fillsTallWindow: true),
            [.reply, .dispose, .toggleFlag, .toggleRead, .pageUp, .pageDown, .overflow, .compose]
        )
        XCTAssertEqual(
            ReaderToolbarLayout.ownBar(leading: .editDraft, paneWidth: 669, fillsTallWindow: true).first,
            .editDraft
        )
    }

    /// Whatever its width, and only while it fills a tall window: a reader
    /// beside the list keeps the width-sized bar.
    func testOnlyAReaderFillingATallWindowDrawsTheTallBar() {
        XCTAssertEqual(
            ReaderToolbarLayout.ownBar(leading: .reply, paneWidth: 480, fillsTallWindow: true),
            ReaderToolbarLayout.tallBar(leading: .reply)
        )
        XCTAssertEqual(
            ReaderToolbarLayout.ownBar(leading: .reply, paneWidth: 669),
            [.reply, .toggleRead, .toggleFlag, .remoteContent, .readerMode, .dispose, .overflow]
        )
    }

    /// The display toggles move to the menu to make room, so nothing the
    /// wide bar draws is lost: every action is on the tall bar or the menu.
    func testTheTallBarLosesNoAction() {
        for leading in [LeadingReaderAction.reply, .editDraft] {
            let reachable = Set(ReaderToolbarLayout.tallBar(leading: leading))
                .union(ReaderToolbarLayout.demotedToOverflow)
                .union(ReaderToolbarLayout.touchOverflowOnly)
            let wide = Set(ReaderToolbarLayout.ownBar(leading: leading, paneWidth: 669))

            XCTAssertTrue(wide.isSubset(of: reachable), "\(leading)")
            XCTAssertFalse(ReaderToolbarLayout.tallBar(leading: leading).contains(.readerMode), "\(leading)")
        }
    }
}
