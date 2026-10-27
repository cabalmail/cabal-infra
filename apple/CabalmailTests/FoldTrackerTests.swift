import CoreGraphics
import XCTest
@testable import CabalmailUI

/// `FoldTracker`, the glue `foldGeometry()` publishes from: layout passes go
/// through the two-pass rule into the hinge hold, and a held fold ends on
/// its own once its grace runs out. The rules themselves are pinned in
/// `FoldHoldTests`; these pin that the tracker waits for each of them.
@MainActor
final class FoldTrackerTests: XCTestCase {
    private let wide = CGSize(width: 951, height: 669)
    private let crease = CGRect(x: 455.5, y: 0, width: 40, height: 669)

    func testASettledRegionFoldsTheWindow() async throws {
        let tracker = FoldTracker(confirmDelay: .milliseconds(10))
        tracker.layoutPass(FoldSample(region: crease, windowSize: wide))
        XCTAssertEqual(tracker.state, .none, "one pass is not enough")
        try await waitUntilOnMainActor { tracker.state == .vertical(crease: crease) }
    }

    /// A stale first frame: the region a newer pass replaced before its
    /// confirmation never reaches the window.
    func testARegionReplacedBeforeItsConfirmationNeverFolds() async throws {
        let tracker = FoldTracker(confirmDelay: .milliseconds(10))
        var seen: [FoldState] = []
        tracker.layoutPass(FoldSample(region: crease, windowSize: wide))
        tracker.layoutPass(FoldSample(region: nil, windowSize: wide))
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(10))
            seen.append(tracker.state)
        }
        XCTAssertEqual(Set(seen.map(\.isFolded)), [false])
    }

    /// The fold can end no sooner than the confirming pass plus the grace,
    /// and `Task.sleep` never wakes early, so the lower bound cannot flake.
    func testAHeldFoldEndsWhenItsGraceRunsOut() async throws {
        let tracker = FoldTracker(confirmDelay: .milliseconds(10), grace: 0.05)
        tracker.layoutPass(FoldSample(region: crease, windowSize: wide))
        try await waitUntilOnMainActor { tracker.state.isFolded }
        let lost = ContinuousClock.now
        tracker.layoutPass(FoldSample(region: nil, windowSize: wide))
        try await waitUntilOnMainActor { tracker.state == .none }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - lost, .milliseconds(50), "the fold holds through its grace")
    }

    func testAFullyOpenHingeEndsAHeldFold() async throws {
        let tracker = FoldTracker(confirmDelay: .milliseconds(10))
        tracker.layoutPass(FoldSample(region: crease, windowSize: wide))
        try await waitUntilOnMainActor { tracker.state.isFolded }
        tracker.layoutPass(FoldSample(region: nil, windowSize: wide))
        try await waitUntilOnMainActor { !tracker.isSettling }
        XCTAssertTrue(tracker.state.isFolded, "held through the grace, 0.6 s by default")
        tracker.hingeChanged(HingeReading(status: .fullyOpen, angle: 180))
        XCTAssertEqual(tracker.state, .none)
    }

    /// What `onFoldPiecesChange(_:)` waits on: a reading counts as settling
    /// from the pass that reads it until its confirming pass.
    func testANewReadingIsSettlingUntilItsConfirmingPass() async throws {
        let tracker = FoldTracker(confirmDelay: .milliseconds(10))
        tracker.layoutPass(FoldSample(region: crease, windowSize: wide))
        XCTAssertTrue(tracker.isSettling)
        try await waitUntilOnMainActor { !tracker.isSettling }
        XCTAssertTrue(tracker.state.isFolded)
    }

    /// Flat, the division settles into `division` and the window stays
    /// unfolded; a pass at the closed display's size drops it.
    func testAnInactiveDivisionIsPublishedWithoutFolding() async throws {
        let tracker = FoldTracker(confirmDelay: .milliseconds(10))
        tracker.layoutPass(FoldSample(region: nil, windowSize: wide, division: crease))
        try await waitUntilOnMainActor { tracker.division == crease }
        XCTAssertEqual(tracker.state, .none)
        tracker.layoutPass(FoldSample(region: nil, windowSize: CGSize(width: 466, height: 678)))
        try await waitUntilOnMainActor { tracker.division == nil }
    }
}
