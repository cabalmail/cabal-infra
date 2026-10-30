import XCTest
@testable import CabalmailUI

/// Pins where compose opens and where its sheet sits. On iOS compose is a
/// sheet over the window it was asked from in every layout, iPad and an open
/// iPhone Duo included (the Duo spec's Decision 8): before, a host that could
/// open another window (`supportsMultipleWindows`, #1645) opened compose in
/// one, which on an open Duo took the whole display away from the message a
/// reply answered. The Mac and visionOS still open a window.
final class ComposeSurfacePolicyTests: XCTestCase {

    func testIOSPresentsTheSheet() {
        // iPhone, iPad and iPhone Duo, open or closed.
        XCTAssertFalse(ComposeSurfacePolicy.opensInWindow(alwaysWindows: false))
    }

    func testWindowPlatformsNeverPresentTheSheet() {
        // macOS and visionOS have no sheet path at all.
        XCTAssertTrue(ComposeSurfacePolicy.opensInWindow(alwaysWindows: true))
    }

    func testDefaultFollowsTheHostPlatform() {
        XCTAssertEqual(ComposeSurfacePolicy.opensInWindow(), ComposeSurfacePolicy.platformAlwaysWindows)
        // This suite runs on the Mac.
        XCTAssertTrue(ComposeSurfacePolicy.opensInWindow())
    }

    // MARK: What a surface does with a seed

    func testAWindowSurfaceOpensAWindowWhateverItsSheetHolds() {
        XCTAssertEqual(ComposeSurfacePolicy.offer(hasClient: true, opensInWindow: true, sheetIsUp: false), .window)
        XCTAssertEqual(ComposeSurfacePolicy.offer(hasClient: true, opensInWindow: true, sheetIsUp: true), .window)
    }

    /// An incoming mailto: never replaces the draft being typed: the seed
    /// waits until the sheet has closed. Since the sheet is every iOS
    /// window's surface, that now holds on iPad and an open Duo too.
    func testASheetSurfaceTakesOneSeedAtATime() {
        XCTAssertEqual(ComposeSurfacePolicy.offer(hasClient: true, opensInWindow: false, sheetIsUp: false), .sheet)
        XCTAssertEqual(ComposeSurfacePolicy.offer(hasClient: true, opensInWindow: false, sheetIsUp: true), .refuse)
    }

    /// A window that is signing out builds no composer, so it takes no
    /// seed: the seed is kept for the next session.
    func testASurfaceWithNoSessionTakesNothing() {
        for opensInWindow in [true, false] {
            for sheetIsUp in [true, false] {
                XCTAssertEqual(
                    ComposeSurfacePolicy.offer(hasClient: false, opensInWindow: opensInWindow, sheetIsUp: sheetIsUp),
                    .refuse
                )
            }
        }
    }

    // MARK: Open in New Window

    /// The sheet offers a window of its own only where one can open beside
    /// the window it is over, at regular width, and never where compose is a
    /// window already.
    func testOpenInNewWindowNeedsRegularWidthAndMultipleWindows() {
        func offers(multiple: Bool, regular: Bool, alwaysWindows: Bool = false) -> Bool {
            ComposeSurfacePolicy.offersNewWindow(
                supportsMultipleWindows: multiple, isRegularWidth: regular, alwaysWindows: alwaysWindows
            )
        }
        // An iPad, or an open iPhone Duo.
        XCTAssertTrue(offers(multiple: true, regular: true))
        // A large iPhone held wide: regular width, but one window.
        XCTAssertFalse(offers(multiple: false, regular: true))
        // A closed Duo, Slide Over or a narrow iPad window: compact, whatever
        // the scene supports.
        XCTAssertFalse(offers(multiple: true, regular: false))
        // An iPhone.
        XCTAssertFalse(offers(multiple: false, regular: false))
        // The Mac and visionOS.
        for multiple in [true, false] {
            for regular in [true, false] {
                XCTAssertFalse(offers(multiple: multiple, regular: regular, alwaysWindows: true))
            }
        }
        // This suite runs on the Mac.
        XCTAssertFalse(ComposeSurfacePolicy.offersNewWindow(supportsMultipleWindows: true, isRegularWidth: true))
    }
}
