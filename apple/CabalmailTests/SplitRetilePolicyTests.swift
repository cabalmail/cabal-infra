import XCTest
@testable import CabalmailUI

/// `SplitRetilePolicy`: the iPad split is built again when UIKit chose its
/// column layout against a width the window had already left.
///
/// Zooming a window back from compact lays the split view out once at an
/// intermediate width (534 pt inside an 834 pt window, iPadOS 27) before the
/// real one arrives. At that width the pinned list and the reader's floor
/// cannot sit side by side, so UIKit floats the list over a full-width
/// reader and keeps that decision at full width — the list left floating
/// over a dimmed reader, with the reader's content running underneath it
/// (#1988).
final class SplitRetilePolicyTests: XCTestCase {

    /// The window's real width, and the width the split is first laid out at
    /// on the rounds that float, both measured on an iPad Pro 11-inch.
    private let wide: CGFloat = 834
    private let narrowFirstLayout: CGFloat = 534

    /// The tiled rounds: the split's first layout is already the window's
    /// width, so nothing is rebuilt. A rebuild here would throw the reader
    /// away on every widening.
    func testAFirstLayoutWideEnoughToTileNeverRebuilds() {
        var policy = SplitRetilePolicy()
        policy.recordLayout(width: wide)
        XCTAssertEqual(policy.generation, 0)
        XCTAssertFalse(policy.isArmed)
        policy.recordLayout(width: wide)
        XCTAssertEqual(policy.generation, 0, "a second layout at the same width is not a swap")
    }

    /// The floating rounds: a too-narrow first layout, then the real width.
    func testATooNarrowFirstLayoutRebuildsAtTheRealWidth() {
        var policy = SplitRetilePolicy()
        policy.recordLayout(width: narrowFirstLayout)
        XCTAssertEqual(policy.generation, 0, "nothing to rebuild until a width that can tile arrives")
        XCTAssertTrue(policy.isArmed)
        policy.recordLayout(width: wide)
        XCTAssertEqual(policy.generation, 1)
        XCTAssertFalse(policy.isArmed)
    }

    /// One shot. The rebuild re-lays the split out, which feeds the policy
    /// again; bumping once per wide layout would rebuild the split forever.
    func testTheRebuildIsAskedForOnce() {
        var policy = SplitRetilePolicy()
        policy.recordLayout(width: narrowFirstLayout)
        policy.recordLayout(width: wide)
        for _ in 0..<5 { policy.recordLayout(width: wide) }
        XCTAssertEqual(policy.generation, 1)
    }

    /// Only the *first* layout arms it. A narrow layout later is a resize,
    /// which the shell swap handles (`SectionLayoutPolicy`); rebuilding on
    /// one would throw the reader away mid-drag.
    func testALaterNarrowLayoutNeverArmsIt() {
        var policy = SplitRetilePolicy()
        policy.recordLayout(width: wide)
        policy.recordLayout(width: narrowFirstLayout)
        XCTAssertFalse(policy.isArmed)
        policy.recordLayout(width: wide)
        XCTAssertEqual(policy.generation, 0)
    }

    /// And not after the rebuild either: the split that re-tiled stays.
    func testANarrowLayoutAfterTheRebuildNeverArmsItAgain() {
        var policy = SplitRetilePolicy()
        policy.recordLayout(width: narrowFirstLayout)
        policy.recordLayout(width: wide)
        policy.recordLayout(width: narrowFirstLayout)
        policy.recordLayout(width: wide)
        XCTAssertEqual(policy.generation, 1)
    }

    /// `onGeometryChange` reports a zero width before the split has bounds.
    /// Reading that as the narrow first layout would rebuild the split on
    /// every launch.
    func testAZeroWidthIsNotAMeasurement() {
        var policy = SplitRetilePolicy()
        policy.recordLayout(width: 0)
        policy.recordLayout(width: -1)
        XCTAssertFalse(policy.isArmed)
        policy.recordLayout(width: wide)
        XCTAssertEqual(policy.generation, 0, "the first measurement was the wide one")
    }

    /// Several narrow layouts before the real width still buy one rebuild.
    func testRepeatedNarrowLayoutsBuyOneRebuild() {
        var policy = SplitRetilePolicy()
        policy.recordLayout(width: narrowFirstLayout)
        policy.recordLayout(width: 420)
        policy.recordLayout(width: 599)
        XCTAssertTrue(policy.isArmed)
        policy.recordLayout(width: wide)
        XCTAssertEqual(policy.generation, 1)
    }

    /// The threshold is the one the shells already split on, so the policy
    /// cannot ask for a rebuild at a width the tab layout would hold.
    func testTheThresholdIsTheShellsOwnRegularWidthFloor() {
        var atFloor = SplitRetilePolicy()
        atFloor.recordLayout(width: SectionLayoutPolicy.regularWidthFloor)
        XCTAssertFalse(atFloor.isArmed, "the floor itself tiles")

        var underFloor = SplitRetilePolicy()
        underFloor.recordLayout(width: SectionLayoutPolicy.regularWidthFloor - 1)
        XCTAssertTrue(underFloor.isArmed)
        underFloor.recordLayout(width: SectionLayoutPolicy.regularWidthFloor)
        XCTAssertEqual(underFloor.generation, 1)
    }

    /// The generation is the split's identity, so a fresh shell starts where
    /// the last one did rather than inheriting a bump.
    func testEachShellStartsAtGenerationZero() {
        var first = SplitRetilePolicy()
        first.recordLayout(width: narrowFirstLayout)
        first.recordLayout(width: wide)
        XCTAssertEqual(first.generation, 1)
        XCTAssertEqual(SplitRetilePolicy().generation, 0)
        XCTAssertFalse(SplitRetilePolicy().isArmed)
    }

    /// The whole floating sequence, as the simulator delivers it: the shell
    /// mounts at the intermediate width and the window's own width follows
    /// about 240 ms later.
    func testTheMeasuredZoomSequenceAsksForOneRebuild() {
        var policy = SplitRetilePolicy()
        for width in [0, narrowFirstLayout, narrowFirstLayout, wide, wide] {
            policy.recordLayout(width: width)
        }
        XCTAssertEqual(policy.generation, 1)
        XCTAssertFalse(policy.isArmed)
    }

    /// And the tiled sequence, which must look exactly like no defect.
    func testTheMeasuredTiledSequenceAsksForNothing() {
        var policy = SplitRetilePolicy()
        for width in [0, wide, wide, wide] {
            policy.recordLayout(width: width)
        }
        XCTAssertEqual(policy.generation, 0)
    }
}
