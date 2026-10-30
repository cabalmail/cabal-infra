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
