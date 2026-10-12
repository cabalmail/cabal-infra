import XCTest
@testable import CabalmailUI

/// Pins the rule behind "window or sheet" for compose. It used to be the
/// device idiom (iPad → window, iPhone → sheet), which Apple's iPhone Duo
/// guidance rules out: Duo is a phone whose inner display hosts multiple
/// windows and whose outer display cannot create one. The environment's
/// `supportsMultipleWindows` is the value that tracks that, so it is the
/// only input on iOS (#1645).
final class ComposeSurfacePolicyTests: XCTestCase {

    func testMultiWindowHostOpensAWindow() {
        // iPad, or iPhone Duo open.
        XCTAssertTrue(ComposeSurfacePolicy.opensInWindow(supportsMultipleWindows: true, alwaysWindows: false))
    }

    func testSingleWindowHostPresentsTheSheet() {
        // Any other iPhone, or iPhone Duo closed — measured false on the
        // iOS 27.1 simulator's outer display.
        XCTAssertFalse(ComposeSurfacePolicy.opensInWindow(supportsMultipleWindows: false, alwaysWindows: false))
    }

    func testWindowPlatformsNeverPresentTheSheet() {
        // macOS and visionOS have no sheet path at all.
        XCTAssertTrue(ComposeSurfacePolicy.opensInWindow(supportsMultipleWindows: false, alwaysWindows: true))
        XCTAssertTrue(ComposeSurfacePolicy.opensInWindow(supportsMultipleWindows: true, alwaysWindows: true))
    }

    // MARK: What a surface does with a seed

    func testAMultiWindowSurfaceOpensAWindowWhateverItsSheetHolds() {
        XCTAssertEqual(ComposeSurfacePolicy.offer(hasClient: true, opensInWindow: true, sheetIsUp: false), .window)
        // A Duo unfolded with its sheet still up from before: a window.
        XCTAssertEqual(ComposeSurfacePolicy.offer(hasClient: true, opensInWindow: true, sheetIsUp: true), .window)
    }

    /// An incoming mailto: never replaces the draft being typed: the seed
    /// waits until the sheet has closed.
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

    func testDefaultFollowsTheHostPlatform() {
        XCTAssertEqual(
            ComposeSurfacePolicy.opensInWindow(supportsMultipleWindows: false),
            ComposeSurfacePolicy.platformAlwaysWindows
        )
    }
}
