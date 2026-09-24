import XCTest
@testable import Cabalmail

/// Pins who may open the addresses inspector. The framework writes the
/// `.inspector(isPresented:)` binding on its own when an iPhone Duo unfolds
/// with a message open (#1663), so a `true` counts only when the `@` button
/// asked for it; a `false` always counts (#1665 is the same drift seen from
/// the other side).
final class InspectorPresentationPolicyTests: XCTestCase {
    typealias State = InspectorPresentationPolicy.State

    func testTheButtonOpensAndCloses() {
        let opened = InspectorPresentationPolicy.toggled(State(presented: false, requested: false))
        XCTAssertEqual(opened, State(presented: true, requested: true))
        let closed = InspectorPresentationPolicy.toggled(opened)
        XCTAssertEqual(closed, State(presented: false, requested: false))
    }

    func testAFrameworkPresentIsDroppedUnlessRequested() {
        // The Duo unfold: nobody tapped, the framework says "presented".
        let hidden = State(presented: false, requested: false)
        XCTAssertEqual(InspectorPresentationPolicy.framework(wrote: true, to: hidden), hidden)
    }

    func testAFrameworkPresentIsHonouredWhenRequested() {
        // The button asked; the framework confirming it changes nothing.
        let requested = State(presented: true, requested: true)
        XCTAssertEqual(InspectorPresentationPolicy.framework(wrote: true, to: requested), requested)
    }

    func testAFrameworkDismissIsAlwaysHonoured() {
        // A drag or a size change closed it: clear both flags so the next
        // framework `true` is not mistaken for the old request.
        let shown = State(presented: true, requested: true)
        XCTAssertEqual(
            InspectorPresentationPolicy.framework(wrote: false, to: shown),
            State(presented: false, requested: false)
        )
    }

    func testAFrameworkDismissOfAHiddenInspectorIsANoOp() {
        let hidden = State(presented: false, requested: false)
        XCTAssertEqual(InspectorPresentationPolicy.framework(wrote: false, to: hidden), hidden)
    }
}
