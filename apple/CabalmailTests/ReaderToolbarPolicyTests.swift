import XCTest
@testable import CabalmailUI

/// The reader toolbar's shared placement (`ReaderToolbarPolicy`): which bar
/// carries each reader's touch actions. The mail reader's lists and the
/// budgets themselves are `ReaderToolbarLayoutTests`'.
final class ReaderToolbarPolicyTests: XCTestCase {

    private static let combinations: [(regular: Bool, os27: Bool)] = [
        (false, false), (false, true), (true, false), (true, true)
    ]

    /// The feed reader's set is three items, inside the top bar's budget at
    /// every width, so it stays in the system navigation bar on every layout
    /// and OS generation.
    func testTheFeedReaderAlwaysUsesTheSystemTopBar() {
        for combo in Self.combinations {
            XCTAssertEqual(
                ReaderToolbarPolicy.placement(for: .feeds, isRegularWidth: combo.regular, isOS27OrLater: combo.os27),
                .topBar,
                "feeds at regular=\(combo.regular), iOS 27=\(combo.os27)"
            )
        }
    }

    /// The mail reader: the navigation bar at compact width, the system
    /// bottom bar at regular width before iOS 27, its own pane bar after.
    func testTheMailReaderMovesToTheBottomAtRegularWidth() {
        func mail(regular: Bool, os27: Bool) -> ReaderToolbarPolicy.Placement {
            ReaderToolbarPolicy.placement(for: .mail, isRegularWidth: regular, isOS27OrLater: os27)
        }
        XCTAssertEqual(mail(regular: false, os27: false), .topBar)
        XCTAssertEqual(mail(regular: false, os27: true), .topBar)
        XCTAssertEqual(mail(regular: true, os27: false), .bottomBar)
        XCTAssertEqual(mail(regular: true, os27: true), .ownBar)
    }

    /// The mail layout's own names answer what the policy does for mail, so
    /// the mail reader and its tests read the shared numbers.
    func testTheMailLayoutForwardsToThePolicy() {
        for combo in Self.combinations {
            XCTAssertEqual(
                ReaderToolbarLayout.placement(isRegularWidth: combo.regular, isOS27OrLater: combo.os27),
                ReaderToolbarPolicy.placement(for: .mail, isRegularWidth: combo.regular, isOS27OrLater: combo.os27)
            )
        }
        XCTAssertEqual(ReaderToolbarLayout.capacity, ReaderToolbarPolicy.capacity)
        XCTAssertEqual(ReaderToolbarLayout.topBarCapacity, ReaderToolbarPolicy.topBarCapacity)
        XCTAssertEqual(ReaderToolbarLayout.fullSetMinWidth, ReaderToolbarPolicy.fullSetMinWidth)
    }

    // MARK: - The side strip

    private let combos = [(false, false), (false, true), (true, false), (true, true)]

    /// Where the system draws the bars in a strip, the mail actions are
    /// bottom items, which join it near the thumb and the tabs.
    func testVerticalBarsPutTheMailActionsInBottomItems() {
        for (regular, os27) in combos {
            XCTAssertEqual(
                ReaderToolbarPolicy.placement(for: .mail, isRegularWidth: regular, isOS27OrLater: os27,
                                              barsAreVertical: true),
                .bottomItems
            )
        }
    }

    /// Without a strip every placement is what it was; a laptop fold is a
    /// tall window, whose bars are horizontal, so it is this case.
    func testWithoutAStripNothingMoves() {
        for (regular, os27) in combos {
            let before = ReaderToolbarPolicy.placement(for: .mail, isRegularWidth: regular, isOS27OrLater: os27)
            XCTAssertEqual(
                ReaderToolbarPolicy.placement(for: .mail, isRegularWidth: regular, isOS27OrLater: os27,
                                              barsAreVertical: false),
                before
            )
            XCTAssertNotEqual(before, .bottomItems)
        }
    }

    func testTheFeedReaderIgnoresTheStrip() {
        for (regular, os27) in combos {
            for vertical in [false, true] {
                XCTAssertEqual(
                    ReaderToolbarPolicy.placement(for: .feeds, isRegularWidth: regular, isOS27OrLater: os27,
                                                  barsAreVertical: vertical),
                    .topBar
                )
            }
        }
    }

    /// The spec's "never top placement in a tall window": at regular width
    /// the mail reader is never on the top bar.
    func testTheMailReaderIsNeverOnTheTopBarAtRegularWidth() {
        for os27 in [false, true] {
            for vertical in [false, true] {
                XCTAssertNotEqual(
                    ReaderToolbarPolicy.placement(for: .mail, isRegularWidth: true, isOS27OrLater: os27,
                                                  barsAreVertical: vertical),
                    .topBar
                )
            }
        }
    }

    /// The body runs under the bottom chrome by width alone, as it did before
    /// the strip had a say in the placement: flipping it rebuilds the web
    /// view (the Decision 9 spike), and the strip changes without a shell
    /// swap.
    func testTheBodyFollowsTheWidthAlone() {
        for medium in [ReaderToolbarPolicy.Medium.mail, .feeds] {
            for (regular, os27) in combos {
                XCTAssertEqual(
                    ReaderToolbarPolicy.bodyRunsUnderBottomBar(for: medium, isRegularWidth: regular),
                    ReaderToolbarPolicy.placement(for: medium, isRegularWidth: regular, isOS27OrLater: os27) == .topBar
                )
            }
        }
    }

    func testTheMailLayoutForwardsTheStrip() {
        for (regular, os27) in combos {
            for vertical in [false, true] {
                XCTAssertEqual(
                    ReaderToolbarLayout.placement(isRegularWidth: regular, isOS27OrLater: os27,
                                                  barsAreVertical: vertical),
                    ReaderToolbarPolicy.placement(for: .mail, isRegularWidth: regular, isOS27OrLater: os27,
                                                  barsAreVertical: vertical)
                )
            }
        }
    }
}
