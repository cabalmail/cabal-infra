import XCTest
@testable import CabalmailUI

/// `WindowPlanner` on its own: what a refresh does with the loaded window
/// for each STATUS reading, and which positions a re-read covers. How the
/// list runs the plan is in `MessageListWindowReconcileTests`.
final class WindowPlannerTests: XCTestCase {
    private func planner(
        loadedCount: Int = 300,
        windowStart: UInt32 = 0,
        hasTrimmedFront: Bool = false,
        anchor: WindowAnchor? = nil,
        visible: ClosedRange<Int>? = nil
    ) -> WindowPlanner {
        WindowPlanner(
            loadedCount: loadedCount, windowStart: windowStart, hasTrimmedFront: hasTrimmedFront,
            anchor: anchor, firstVisibleRow: visible?.lowerBound, lastVisibleRow: visible?.upperBound,
            pageSize: 50, windowCap: 600
        )
    }

    private func reading(_ total: UInt32, _ uidNext: UInt32) -> WindowReading {
        WindowReading(total: total, uidNext: uidNext, askedAt: .now)
    }

    private func anchor(_ total: UInt32, _ uidNext: UInt32) -> WindowAnchor {
        WindowAnchor(total: total, uidNext: uidNext)
    }

    func testAnUntrustedReadingTakesTheTopPageOrOnlyTheCounts() {
        XCTAssertEqual(planner().planWindow(nil), .topPage)
        XCTAssertEqual(planner(hasTrimmedFront: true).planWindow(nil), .countsOnly)
    }

    func testAnEmptiedFolderIsTheTopPagesToSettle() {
        let deep = planner(hasTrimmedFront: true, anchor: anchor(1000, 2000))

        XCTAssertEqual(deep.planWindow(reading(0, 2001)), .topPage)
    }

    func testWithoutAnAnchorASmallWindowOrFolderTakesTheTopPage() {
        XCTAssertEqual(planner(loadedCount: 50).planWindow(reading(1000, 2000)), .topPage)
        XCTAssertEqual(planner(loadedCount: 300).planWindow(reading(40, 2000)), .topPage)
    }

    func testWithoutAnAnchorALargeWindowIsReadAgainFromTheTop() {
        XCTAssertEqual(planner(loadedCount: 300).planWindow(reading(1000, 2000)), .reread(0..<250))
        XCTAssertEqual(planner(loadedCount: 120).planWindow(reading(1000, 2000)), .reread(0..<120))
    }

    func testWithoutAnAnchorATrimmedWindowIsReadAroundTheWindow() {
        let deep = planner(loadedCount: 200, windowStart: 500, hasTrimmedFront: true)

        XCTAssertEqual(deep.planWindow(reading(1000, 2000)), .reread(475..<725))
    }

    func testAReadingTheAnchorCannotExplainCountsAsNoAnchor() {
        let backwards = planner(anchor: anchor(1000, 2000))
        XCTAssertEqual(backwards.planWindow(reading(1000, 1990)), .reread(0..<250), "UIDNEXT went backwards")

        let tooMany = planner(anchor: anchor(100, 100))
        XCTAssertEqual(tooMany.planWindow(reading(105, 102)), .reread(0..<105), "more messages than UIDs arrived")
    }

    func testNothingChangedTakesTheTopPageOrOnlyTheCounts() {
        let quiet = reading(1000, 2000)

        XCTAssertEqual(planner(anchor: anchor(1000, 2000)).planWindow(quiet), .topPage)
        XCTAssertEqual(planner(hasTrimmedFront: true, anchor: anchor(1000, 2000)).planWindow(quiet), .countsOnly)
    }

    func testArrivalsAloneTakeTheTopPage() {
        XCTAssertEqual(planner(anchor: anchor(1000, 2000)).planWindow(reading(1003, 2003)), .topPage)
    }

    func testAnyChangeUnderATrimmedWindowIsReadAroundTheViewport() {
        let deep = planner(
            loadedCount: 200, windowStart: 500, hasTrimmedFront: true, anchor: anchor(1000, 2000), visible: 600...620
        )

        XCTAssertEqual(deep.planWindow(reading(1003, 2003)), .reread(485..<735))
    }

    func testRemovalsWithinTheTopPageTakeTheTopPage() {
        XCTAssertEqual(planner(loadedCount: 30, anchor: anchor(100, 200)).planWindow(reading(100, 201)), .topPage)
    }

    func testRemovalsBeyondTheTopPageReadTheCoveringRange() {
        let paged = planner(anchor: anchor(1000, 2000))

        XCTAssertEqual(paged.planWindow(reading(999, 2000)), .reread(0..<300), "one removal")
        XCTAssertEqual(paged.planWindow(reading(1001, 2002)), .reread(0..<302), "two arrivals, one removal")
    }

    func testTheCoveringRangeRunsFromTheTopWhileItFitsTheCap() {
        XCTAssertEqual(planner().coveringWindowRange(arrivals: 2, total: 1001), 0..<302)
        XCTAssertEqual(planner().coveringWindowRange(arrivals: 50, total: 320), 0..<320, "clamped to the folder")
    }

    func testPastTheCapTheCoveringRangeIsReadAroundTheViewport() {
        let full = planner(loadedCount: 600, anchor: anchor(1000, 2000), visible: 100...120)

        XCTAssertEqual(full.planWindow(reading(1004, 2005)), .reread(0..<250))
    }

    func testTheCentredRangeCentresOnTheVisibleRows() {
        XCTAssertEqual(planner(visible: 400...420).centredWindowRange(total: 1000), 285..<535)
    }

    func testTheCentredRangeFallsBackToTheWindowsMiddle() {
        let deep = planner(loadedCount: 200, windowStart: 500)

        XCTAssertEqual(deep.centredWindowRange(total: 1000), 475..<725)
    }

    func testTheCentredRangeIsClampedToTheFolder() {
        XCTAssertEqual(planner(visible: 10...20).centredWindowRange(total: 1000), 0..<250)
        XCTAssertEqual(planner(visible: 990...999).centredWindowRange(total: 1000), 750..<1000)
        XCTAssertEqual(planner(visible: 0...10).centredWindowRange(total: 100), 0..<100, "never inverted")
    }

    func testAnAnchorCountsArrivalsAndRemovalsElsewhere() {
        let base = anchor(100, 200)

        let change = base.change(toTotal: 103, uidNext: 205)
        XCTAssertEqual(change?.arrivals, 5)
        XCTAssertEqual(change?.removals, 2)
        XCTAssertNil(base.change(toTotal: 100, uidNext: 190), "UIDNEXT went backwards")
        XCTAssertNil(base.change(toTotal: 110, uidNext: 205), "more messages than UIDs arrived")
    }
}
