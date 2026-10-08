import XCTest
@testable import CabalmailUI

/// `RefreshFlight` on its own: which asks a pass answers. How the list
/// parks and resumes refreshes on it is in
/// `MessageListRefreshCharacterizationTests`.
final class RefreshFlightTests: XCTestCase {
    func testAPassAnswersTheAsksMadeBeforeItBeganOnceItFinishes() {
        var flight = RefreshFlight()
        let early = flight.ask()
        let pass = flight.begin()
        let late = flight.ask()
        XCTAssertEqual(flight.current, pass)
        XCTAssertFalse(flight.hasAnswered(early), "not while the pass is out")

        XCTAssertTrue(flight.end(pass, finished: true).isEmpty, "nothing was parked")

        XCTAssertNil(flight.current)
        XCTAssertTrue(flight.hasAnswered(early))
        XCTAssertFalse(flight.hasAnswered(late), "asked after the pass began, so its STATUS may predate it")
    }

    func testACancelledPassAnswersNothing() {
        var flight = RefreshFlight()
        let ask = flight.ask()
        let pass = flight.begin()

        _ = flight.end(pass, finished: false)

        XCTAssertNil(flight.current)
        XCTAssertFalse(flight.hasAnswered(ask))
    }

    /// A reset's pass is handed the STATUS its probe asked for, so it answers
    /// only the asks made before that probe; one made while the probe was
    /// out still gets a pass that asks afresh.
    func testAPassHandedAnEarlierStatusAnswersOnlyTheAsksBeforeIt() {
        var flight = RefreshFlight()
        let probe = flight.ask()
        let meanwhile = flight.ask()
        let reset = flight.begin(answeringThrough: probe)

        _ = flight.end(reset, finished: true)

        XCTAssertTrue(flight.hasAnswered(probe))
        XCTAssertFalse(flight.hasAnswered(meanwhile))
    }

    func testASupersededPassAnswersNothingAndTheNewerOneAnswersForBoth() {
        var flight = RefreshFlight()
        let background = flight.ask()
        let old = flight.begin()
        let reset = flight.ask()
        let newer = flight.begin()

        _ = flight.end(old, finished: true)
        XCTAssertEqual(flight.current, newer, "the old pass ending leaves the newer one in flight")
        XCTAssertFalse(flight.hasAnswered(background))

        _ = flight.end(newer, finished: true)
        XCTAssertTrue(flight.hasAnswered(background))
        XCTAssertTrue(flight.hasAnswered(reset))
    }
}
