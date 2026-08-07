import XCTest
@testable import Cabalmail

// Regression coverage for issue #871: the reader's header block was pinned to
// 15% of the pane's height. A ScrollView is greedy along its scroll axis, so
// the block was always exactly that tall — and the standard iPhone header
// (subject + from + To + date + sender authentication) needs about a line
// more than that, which put `AuthResultsLine` just below the block's bottom
// edge, covered by the body web view. The verdict a user most needs to see,
// "not verified", was the one that was never visible.
final class ReaderHeaderHeightPolicyTests: XCTestCase {

    // The geometry the tester captured on an iPhone 16 Pro: a 788pt reading
    // pane, a header needing ~231pt for its five lines. The old 15% rule gave
    // it 118pt.
    private let paneHeight: CGFloat = 788
    private let standardHeaderHeight: CGFloat = 231

    func testAStandardHeaderGetsAllTheRoomItNeeds() {
        XCTAssertEqual(
            ReaderHeaderHeightPolicy.height(
                contentHeight: standardHeaderHeight,
                paneHeight: paneHeight
            ),
            standardHeaderHeight,
            "the authentication line has to fit inside the block, not below it"
        )
    }

    func testAStandardHeaderClearsTheOldFixedSlice() {
        // Guards the specific arithmetic that broke: whatever the cap is, the
        // header this size must not be clipped by it.
        XCTAssertGreaterThan(standardHeaderHeight, paneHeight * 0.15)
        XCTAssertLessThanOrEqual(
            standardHeaderHeight,
            paneHeight * ReaderHeaderHeightPolicy.maxPaneFraction
        )
    }

    func testAShortHeaderDoesNotClaimTheWholeCap() {
        XCTAssertEqual(
            ReaderHeaderHeightPolicy.height(contentHeight: 90, paneHeight: paneHeight),
            90,
            "a one-recipient header shouldn't leave a band of blank space above the body"
        )
    }

    func testASprawlingHeaderIsCappedSoTheBodySurvives() {
        let capped = ReaderHeaderHeightPolicy.height(
            contentHeight: 2_000,
            paneHeight: paneHeight
        )
        XCTAssertEqual(capped, paneHeight * ReaderHeaderHeightPolicy.maxPaneFraction)
        XCTAssertLessThan(capped, paneHeight / 2, "the reading area keeps the larger share")
    }

    func testAnUnmeasuredHeaderFallsBackToTheCapNotToZero() {
        XCTAssertEqual(
            ReaderHeaderHeightPolicy.height(contentHeight: 0, paneHeight: paneHeight),
            paneHeight * ReaderHeaderHeightPolicy.maxPaneFraction
        )
    }

    func testNoPaneYetAsksForWhatTheContentNeeds() {
        XCTAssertEqual(
            ReaderHeaderHeightPolicy.height(contentHeight: 231, paneHeight: 0),
            231
        )
        XCTAssertEqual(
            ReaderHeaderHeightPolicy.height(contentHeight: -1, paneHeight: 0),
            0
        )
    }
}
