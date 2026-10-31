import XCTest
@testable import CabalmailUI

/// Compose in laptop pose (`ComposeLaptopPolicy`), in the Duo simulator's
/// numbers: a 669 by 951 pt window with the fold's band at y 455.5 to 495.5.
final class ComposeLaptopPolicyTests: XCTestCase {
    private typealias Policy = ComposeLaptopPolicy

    private let crease = CGRect(x: 0, y: 455.5, width: 669, height: 40)

    func testWithNoFoldEveryOutputIsTodays() {
        let keyboard = CGRect(x: 0, y: 455.5, width: 669, height: 495.5)
        let host = Policy.barHost(crease: nil, keyboard: keyboard)

        XCTAssertEqual(host, .navigationBar)
        XCTAssertTrue(host.offersWindowInTopBar)
        XCTAssertFalse(host.drawsBottomGroup)
        XCTAssertEqual(Policy.bodyFrame(crease: nil, rest: .init(bodyTop: 120, gap: 30)), .natural)
        XCTAssertNil(Policy.toastFloor(host: host, crease: nil))
        XCTAssertFalse(Policy.formattingHidden(host: host, editorFocused: false, markdownFocused: false))
    }

    /// Measured: a field's keyboard from the fold, the web view's with its
    /// accessory bar from 387.5. A hardware keyboard's bar, a hidden
    /// keyboard's end frame and none at all are down.
    func testTheSoftwareKeyboardTakesTheLowerHalf() {
        XCTAssertTrue(Policy.keyboardIsUp(CGRect(x: 0, y: 455.5, width: 669, height: 495.5), crease: crease))
        XCTAssertTrue(Policy.keyboardIsUp(CGRect(x: 0, y: 387.5, width: 669, height: 563.5), crease: crease))
        XCTAssertTrue(Policy.keyboardIsUp(CGRect(x: 0, y: 520, width: 669, height: 431), crease: crease))
        XCTAssertFalse(Policy.keyboardIsUp(CGRect(x: 0, y: 896, width: 669, height: 55), crease: crease))
        XCTAssertFalse(Policy.keyboardIsUp(CGRect(x: 0, y: 951, width: 669, height: 445), crease: crease))
        XCTAssertFalse(Policy.keyboardIsUp(CGRect(x: 0, y: 951, width: 669, height: 0), crease: crease))
        XCTAssertFalse(Policy.keyboardIsUp(nil, crease: crease))
    }

    func testBarHostsAndTheirControls() {
        let resting = Policy.barHost(crease: crease, keyboard: nil)
        let typing = Policy.barHost(crease: crease, keyboard: CGRect(x: 0, y: 455.5, width: 669, height: 495.5))

        XCTAssertEqual(resting, .laptopBottom)
        XCTAssertTrue(resting.drawsBottomGroup)
        XCTAssertFalse(resting.offersWindowInTopBar)
        XCTAssertEqual(typing, .laptopTop)
        XCTAssertFalse(typing.drawsBottomGroup)
        XCTAssertFalse(typing.offersWindowInTopBar)
    }

    /// The body reaches the fold with its row's blank above the band, and
    /// the From header lands at the band's lower edge.
    func testTheBodyFillsToTheFoldWithTheHeaderPackedBelow() {
        let frame = Policy.bodyFrame(crease: crease, rest: .init(bodyTop: 120, gap: 73), cellOutset: 11)

        XCTAssertEqual(frame, .init(height: 302.5, bridge: 0))
        XCTAssertEqual(120 + 302.5 + 73, 495.5, "the From header's top")
        XCTAssertLessThanOrEqual(120 + 302.5 + 11, 455.5, "the row's bottom")
    }

    /// Rows closer together than the band is tall: padding under the body
    /// carries the header below the band.
    func testANarrowGapIsBridged() {
        let frame = Policy.bodyFrame(crease: crease, rest: .init(bodyTop: 166, gap: 38), cellOutset: 11)

        XCTAssertEqual(frame, .init(height: 278.5, bridge: 13))
        XCTAssertEqual(166 + 278.5 + 13 + 38, 495.5)
    }

    /// Measured on the Duo simulator: the body starts at 219.3 with its row
    /// 15 pt below it and the From header 32.7 pt below that, which leaves
    /// 221 pt above the fold and 22.3 pt of padding to carry the header
    /// below it.
    func testTheSheetsMeasuredRestFitsAboveTheFold() {
        let frame = Policy.bodyFrame(crease: crease, rest: .init(bodyTop: 219.5, gap: 32.5))

        XCTAssertEqual(frame, .init(height: 221, bridge: 22.5))
        XCTAssertEqual(219.5 + 221 + 22.5 + 32.5, 495.5)
    }

    /// At large text sizes the body keeps a few lines.
    func testTheFloorHolds() {
        let frame = Policy.bodyFrame(crease: crease, rest: .init(bodyTop: 340, gap: 50), cellOutset: 11)

        XCTAssertEqual(frame, .init(height: 120, bridge: 0))
        XCTAssertEqual(Policy.bodyFrame(crease: crease, rest: nil), .natural)
    }

    func testRestMetricsRoundAndIgnoreTheBridge() {
        let rest = Policy.restMetrics(bodyFrame: CGRect(x: 0, y: 166.2, width: 669, height: 291.5), fieldsTop: 495.6)

        XCTAssertEqual(rest, .init(bodyTop: 166, gap: 38))
    }

    /// The layout reads back half a point either side of a height; only a
    /// real move replaces the metrics, or the two would chase each other.
    func testOnlyAMoveOfMoreThanAPointReplacesTheRest() {
        let rest = Policy.RestMetrics(bodyTop: 219.5, gap: 42.5)

        XCTAssertTrue(Policy.restMoved(from: nil, to: rest))
        XCTAssertFalse(Policy.restMoved(from: rest, to: .init(bodyTop: 219.5, gap: 43)))
        XCTAssertTrue(Policy.restMoved(from: rest, to: .init(bodyTop: 219.5, gap: 32.5)))
        XCTAssertTrue(Policy.restMoved(from: rest, to: .init(bodyTop: 179.5, gap: 42.5)))
    }

    func testRestIsSampledOnlyIdleAtTheTopWithTheBarsBelow() {
        XCTAssertTrue(Policy.samplesRest(host: .laptopBottom, isScrolling: false, scrolledFromRest: 0.3))
        XCTAssertFalse(Policy.samplesRest(host: .laptopBottom, isScrolling: true, scrolledFromRest: 0))
        XCTAssertFalse(Policy.samplesRest(host: .laptopBottom, isScrolling: false, scrolledFromRest: 40))
        XCTAssertFalse(Policy.samplesRest(host: .laptopTop, isScrolling: false, scrolledFromRest: 0))
        XCTAssertFalse(Policy.samplesRest(host: .navigationBar, isScrolling: false, scrolledFromRest: 0))
    }

    func testTheFormattingControlsFoldAwayOnlyAtRestInLaptop() {
        XCTAssertTrue(Policy.formattingHidden(host: .laptopBottom, editorFocused: false, markdownFocused: false))
        XCTAssertFalse(Policy.formattingHidden(host: .laptopBottom, editorFocused: true, markdownFocused: false))
        XCTAssertFalse(Policy.formattingHidden(host: .laptopBottom, editorFocused: false, markdownFocused: true))
        XCTAssertFalse(Policy.formattingHidden(host: .laptopTop, editorFocused: false, markdownFocused: false))
    }

    /// The user's own scroll is left where they put it.
    func testTheFormReturnsToRestUnlessTheUserJustScrolled() {
        XCTAssertTrue(Policy.returnsToRest(host: .laptopBottom, isScrolling: false, sinceUserScroll: nil))
        XCTAssertTrue(Policy.returnsToRest(host: .laptopBottom, isScrolling: false, sinceUserScroll: 1))
        XCTAssertFalse(Policy.returnsToRest(host: .laptopBottom, isScrolling: false, sinceUserScroll: 0.3))
        XCTAssertFalse(Policy.returnsToRest(host: .laptopBottom, isScrolling: true, sinceUserScroll: nil))
        XCTAssertFalse(Policy.returnsToRest(host: .laptopTop, isScrolling: false, sinceUserScroll: nil))
    }

    func testTheToastSitsBelowTheFoldOnlyAtRest() {
        XCTAssertEqual(Policy.toastFloor(host: .laptopBottom, crease: crease), 495.5)
        XCTAssertNil(Policy.toastFloor(host: .laptopTop, crease: crease))
        XCTAssertEqual(ToastPlacement.topPadding(below: nil, safeTop: 110), 6)
        XCTAssertEqual(ToastPlacement.topPadding(below: 495.5, safeTop: 110), 391.5)
        XCTAssertEqual(ToastPlacement.topPadding(below: 50, safeTop: 110), 6)
    }

    func testEditMessageNeedsAStartedHeldDraftAndAnEditor() {
        XCTAssertTrue(Policy.mayEditMessage(
            hasStarted: true, holdsDraft: true, isSending: false, isMarkdown: false, editorDown: false
        ))
        XCTAssertFalse(Policy.mayEditMessage(
            hasStarted: false, holdsDraft: true, isSending: false, isMarkdown: false, editorDown: false
        ))
        XCTAssertFalse(Policy.mayEditMessage(
            hasStarted: true, holdsDraft: true, isSending: true, isMarkdown: false, editorDown: false
        ))
        XCTAssertFalse(Policy.mayEditMessage(
            hasStarted: true, holdsDraft: false, isSending: false, isMarkdown: false, editorDown: false
        ))
        XCTAssertFalse(Policy.mayEditMessage(
            hasStarted: true, holdsDraft: true, isSending: false, isMarkdown: false, editorDown: true
        ))
        XCTAssertTrue(Policy.mayEditMessage(
            hasStarted: true, holdsDraft: true, isSending: false, isMarkdown: true, editorDown: true
        ))
    }

    // MARK: The form's order

    func testOutsideLaptopTheOrderIsTheCaseOrder() {
        XCTAssertEqual(ComposeFormSection.order(inLaptop: false), ComposeFormSection.allCases)
    }

    func testInLaptopTheBodyLeadsThenTodaysFields() {
        XCTAssertEqual(ComposeFormSection.order(inLaptop: true), [.message, .from, .recipients, .subject, .attachments])
    }

    /// Each section once in each order: a fold moves rows and rebuilds none.
    func testBothOrdersHoldTheSameSectionsOnce() {
        for laptop in [true, false] {
            let order = ComposeFormSection.order(inLaptop: laptop)
            XCTAssertEqual(order.count, ComposeFormSection.allCases.count)
            XCTAssertEqual(Set(order.map { "\($0)" }), Set(ComposeFormSection.allCases.map { "\($0)" }))
        }
    }

    func testTheBodyIsNotScrolledWhileTheBarsAreBelowAFold() {
        XCTAssertFalse(ComposeBodyScrollPolicy.scrollsBodyIntoView(barsBelowFold: true))
        XCTAssertTrue(ComposeBodyScrollPolicy.scrollsBodyIntoView(barsBelowFold: false))
    }
}
