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
    /// every width, so outside a tall window it stays in the system
    /// navigation bar on every layout and OS generation.
    func testTheFeedReaderUsesTheSystemTopBarOutsideATallWindow() {
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

    /// The body runs under the bottom chrome at compact width alone, for
    /// both readers: flipping it rebuilds the web view (the Decision 9
    /// spike), and the strip and a tall window's own bar come and go without
    /// a shell swap. And never where the reader draws its own bar, a SwiftUI
    /// inset the web view does not see.
    func testTheBodyFollowsTheWidthAlone() {
        for medium in [ReaderToolbarPolicy.Medium.mail, .feeds] {
            for regular in [false, true] {
                let body = ReaderToolbarPolicy.bodyRunsUnderBottomBar(for: medium, isRegularWidth: regular)
                XCTAssertEqual(body, !regular, "\(medium) regular=\(regular)")
                for os27 in [false, true] {
                    for vertical in [false, true] {
                        for tall in [false, true] {
                            let placement = ReaderToolbarPolicy.placement(
                                for: medium, isRegularWidth: regular, isOS27OrLater: os27,
                                barsAreVertical: vertical, fillsTallWindow: tall
                            )
                            if placement == .ownBar { XCTAssertFalse(body, "\(medium) under its own bar") }
                        }
                    }
                }
            }
        }
    }

    /// The feed reader draws its own bar where it fills a window taller than
    /// wide, on iOS 27, at regular width, with horizontal bars: the iPhone
    /// Duo upright or in laptop pose, an iPad in portrait. A side strip, a
    /// compact window or iOS 26 keep the top bar.
    func testTheFeedReaderDrawsItsOwnBarInATallWindow() {
        func feeds(regular: Bool = true, os27: Bool = true, vertical: Bool = false, tall: Bool = true)
            -> ReaderToolbarPolicy.Placement {
            ReaderToolbarPolicy.placement(for: .feeds, isRegularWidth: regular, isOS27OrLater: os27,
                                          barsAreVertical: vertical, fillsTallWindow: tall)
        }
        XCTAssertEqual(feeds(), .ownBar)
        XCTAssertEqual(feeds(tall: false), .topBar)
        XCTAssertEqual(feeds(vertical: true), .topBar)
        XCTAssertEqual(feeds(regular: false), .topBar)
        XCTAssertEqual(feeds(os27: false), .topBar)
    }

    /// The mail reader's placement doesn't read the window's shape.
    func testTheMailPlacementIgnoresATallWindow() {
        for (regular, os27) in combos {
            for vertical in [false, true] {
                XCTAssertEqual(
                    ReaderToolbarPolicy.placement(for: .mail, isRegularWidth: regular, isOS27OrLater: os27,
                                                  barsAreVertical: vertical, fillsTallWindow: true),
                    ReaderToolbarPolicy.placement(for: .mail, isRegularWidth: regular, isOS27OrLater: os27,
                                                  barsAreVertical: vertical)
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
