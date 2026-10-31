import XCTest
@testable import CabalmailUI

/// The tall bar's Page Up and Page Down (`ReaderPaging`).
final class ReaderPagingTests: XCTestCase {
    func testAPageMovesMostOfTheViewportAndLeavesTheLastLinesInView() {
        let down = ReaderPaging.target(from: 0, viewport: 400, content: 2_000, direction: .downward)
        let upward = ReaderPaging.target(from: 1_000, viewport: 400, content: 2_000, direction: .upward)

        XCTAssertEqual(down, 360)
        XCTAssertEqual(upward, 640)
    }

    func testAPageStopsAtEitherEnd() {
        XCTAssertEqual(ReaderPaging.target(from: 1_500, viewport: 400, content: 2_000, direction: .downward), 1_600)
        XCTAssertEqual(ReaderPaging.target(from: 100, viewport: 400, content: 2_000, direction: .upward), 0)
    }

    func testABodyShorterThanItsViewportStaysPut() {
        XCTAssertEqual(ReaderPaging.target(from: 0, viewport: 400, content: 300, direction: .downward), 0)
    }

    func testTheHTMLScriptScrollsTheWayOfThePress() {
        XCTAssertTrue(ReaderPaging.script(.downward).contains("top: Math.round(window.innerHeight * 0.9)"))
        XCTAssertTrue(ReaderPaging.script(.upward).contains("top: -Math.round(window.innerHeight * 0.9)"))
    }

    /// Each press is a new request, so a body sees each once.
    func testEveryPressAdvancesTheTick() {
        let first = ReaderPageRequest.next(after: nil, .downward)
        let second = ReaderPageRequest.next(after: first, .downward)

        XCTAssertEqual(first.tick, 1)
        XCTAssertEqual(second.tick, 2)
        XCTAssertNotEqual(first, second)
    }
}

/// Which page requests a body acts on (`ReaderPageGate`), and where a
/// scroll view pages to (`ReaderPaging.scrollTarget`).
final class ReaderPageGateTests: XCTestCase {
    func testTheFirstUpdateOnlySetsTheBaseline() {
        var gate = ReaderPageGate()
        let earlier = ReaderPageRequest(direction: .downward, tick: 3)

        XCTAssertNil(gate.admit(earlier), "a body built after a press doesn't replay it")
        XCTAssertNil(gate.admit(earlier), "the same press again is not a new one")
        let next = ReaderPageRequest(direction: .upward, tick: 4)
        XCTAssertEqual(gate.admit(next), next)
    }

    func testAFirstPressAfterNoneIsTaken() {
        var gate = ReaderPageGate()
        XCTAssertNil(gate.admit(nil))

        let press = ReaderPageRequest(direction: .downward, tick: 1)
        XCTAssertEqual(gate.admit(press), press)
        XCTAssertNil(gate.admit(press))
    }

    /// A web view's scroll view: offsets run from minus the top inset to the
    /// content's height plus the bottom inset, less the bounds.
    func testAScrollViewPagesWithinItsInsets() {
        let down = ReaderPaging.scrollTarget(from: -20, viewport: 400, minOffset: -20, maxOffset: 1_600,
                                             direction: .downward)
        XCTAssertEqual(down, 340)
        XCTAssertEqual(ReaderPaging.scrollTarget(from: 1_500, viewport: 400, minOffset: -20, maxOffset: 1_600,
                                                 direction: .downward), 1_600)
        XCTAssertEqual(ReaderPaging.scrollTarget(from: 100, viewport: 400, minOffset: -20, maxOffset: 1_600,
                                                 direction: .upward), -20)
    }

    func testAPageShorterThanItsViewportStaysPut() {
        XCTAssertEqual(ReaderPaging.scrollTarget(from: -20, viewport: 400, minOffset: -20, maxOffset: -60,
                                                 direction: .downward), -20)
    }
}
