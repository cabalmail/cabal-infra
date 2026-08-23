import XCTest

/// #1238: `tap xy:` and `drag` killed the runner on visionOS rather than
/// answering an error. Both the platform resolution and the rule it feeds are
/// pure values, so both are testable without a simulator — which matters more
/// than usual here, because the first cut of this fix asked the compiler
/// (`#if os(visionOS)`) a question only the host can answer.
final class CoordinateAnchorTests: XCTestCase {

    // MARK: - The rule

    func testVisionOSIsRefused() {
        XCTAssertNotNil(
            CoordinateAnchor.refusal(on: .visionOS),
            "a coordinate on visionOS unwinds the run; it has to be refused"
        )
    }

    func testCoordinateCapableHostsAreServed() {
        XCTAssertNil(
            CoordinateAnchor.refusal(on: .coordinateCapable),
            "iOS and iPadOS deliver coordinates; refusing there would remove the "
                + "only way to reach an element the tree does not name"
        )
    }

    /// The refusal is what a recipe author reads at the moment their command
    /// stops working, so it has to name the way out, not just the wall.
    func testTheRefusalNamesTheAlternative() throws {
        let refusal = try XCTUnwrap(CoordinateAnchor.refusal(on: .visionOS))
        XCTAssertTrue(refusal.contains("id:"), "the message does not name element addressing")
        XCTAssertTrue(refusal.contains("scroll"), "the message does not name the gesture route")
        XCTAssertTrue(refusal.contains("#1238"), "the message does not cite the measurement")
    }

    // MARK: - The resolution

    /// The literals the host script actually writes. `platform_for_udid`
    /// emits exactly these two, and they are what `-destination platform=`
    /// consumes, so a change to one is a change to both.
    func testTheHostsOwnPlatformStrings() {
        XCTAssertEqual(DriveHost.resolve(hostPlatform: "visionOS Simulator"), .visionOS)
        XCTAssertEqual(DriveHost.resolve(hostPlatform: "iOS Simulator"), .coordinateCapable)
    }

    /// `xrOS` is the same platform under its build-system name, and the match
    /// is case-insensitive, so neither spelling silently resolves to the
    /// capable case and re-arms the crash.
    func testTheOtherSpellings() {
        XCTAssertEqual(DriveHost.resolve(hostPlatform: "xrOS Simulator"), .visionOS)
        XCTAssertEqual(DriveHost.resolve(hostPlatform: "visionos simulator"), .visionOS)
    }

    /// A stale rendezvous file or a hand-started runner: unknown must not cost
    /// the platforms where `xy:` works. This is the control the fix must not
    /// break, so it is asserted rather than assumed.
    func testUnknownResolvesToTheCapableCase() {
        XCTAssertEqual(DriveHost.resolve(hostPlatform: nil), .coordinateCapable)
        XCTAssertEqual(DriveHost.resolve(hostPlatform: ""), .coordinateCapable)
        XCTAssertEqual(DriveHost.resolve(hostPlatform: "tvOS Simulator"), .coordinateCapable)
    }
}
