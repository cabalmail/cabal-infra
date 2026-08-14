import XCTest
@testable import CabalmailKit

/// Guards the polling budget the async suites share. The failure this covers
/// was a CI one: a drain that takes under a second locally took 8.8 s on a
/// loaded runner and blew a hard-coded 2 s ceiling, so the forward-compat job
/// reported a timing artefact as a product failure.
final class WaitUntilTests: XCTestCase {
    func testDefaultBudgetOutlastsALoadedRunner() {
        XCTAssertGreaterThanOrEqual(
            defaultWaitTimeout, 20,
            "a slow runner has already been measured at 8.8s for a sub-second drain"
        )
    }

    func testConditionSatisfiedAfterTheOldTwoSecondCeilingStillPasses() async throws {
        let flipsAt = Date().addingTimeInterval(2.2)
        try await waitUntil { Date() >= flipsAt }
    }

    func testReturnsAsSoonAsTheConditionHoldsRatherThanSpendingTheBudget() async throws {
        let started = Date()
        try await waitUntil { true }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }
}
