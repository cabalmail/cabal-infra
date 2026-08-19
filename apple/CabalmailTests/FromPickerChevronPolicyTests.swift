import XCTest
@testable import Cabalmail

// Regression coverage for issue #1167: the compose From pop-up drew two
// disclosure chevrons side by side on macOS — a light `.caption` one from
// `FromPicker`'s own label, then the bold one AppKit's bordered menu adds at
// the trailing edge.
//
// The contrast that makes it a defect rather than a platform look: the same
// byte-identical `FromPicker` renders exactly one chevron on iPadOS, because
// there a `Menu` with a custom label draws only the label it is given. So the
// rule is about the platform, and that is what these pin.
final class FromPickerChevronPolicyTests: XCTestCase {

    /// The reported failure. AppKit already supplies one, so drawing our own
    /// is what put two in the capsule.
    func testMacOSMenuSuppliesItsOwnChevronSoTheLabelMustNot() {
        XCTAssertFalse(FromPickerChevronPolicy.labelDrawsChevron(on: .macOS))
    }

    /// The other half, and the reason this isn't just a deletion: on iOS the
    /// chevron is ours to supply or the control reads as static text.
    func testTouchPlatformsStillDrawTheirOwnChevron() {
        XCTAssertTrue(FromPickerChevronPolicy.labelDrawsChevron(on: .iOS))
        XCTAssertTrue(FromPickerChevronPolicy.labelDrawsChevron(on: .visionOS))
    }

    /// The policy is only worth anything if the running platform resolves to
    /// the case the rules above are written about. This suite is hosted by
    /// the macOS app target, so `.current` has to be `.macOS` here — without
    /// this, a mis-wired `#if` would leave every assertion above true and the
    /// bug still on screen.
    func testCurrentResolvesToTheHostPlatform() {
        XCTAssertEqual(HostPlatform.current, .macOS)
    }
}
