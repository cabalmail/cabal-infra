import XCTest
@testable import Cabalmail

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

    func testDefaultFollowsTheHostPlatform() {
        XCTAssertEqual(
            ComposeSurfacePolicy.opensInWindow(supportsMultipleWindows: false),
            ComposeSurfacePolicy.platformAlwaysWindows
        )
    }
}
