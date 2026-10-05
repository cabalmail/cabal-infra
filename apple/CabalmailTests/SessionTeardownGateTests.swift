import XCTest
@testable import Cabalmail

/// `SessionTeardownGate`'s record of ended sessions (#1848): what it
/// remembers, and that it never keeps a session alive.
@MainActor
final class SessionTeardownGateTests: XCTestCase {
    private final class Session {}

    func testAMarkedSessionHasEndedAndAnotherHasNot() {
        let gate = SessionTeardownGate()
        let ended = Session()
        let live = Session()

        gate.markEnded(ended)

        XCTAssertTrue(gate.hasEnded(ended))
        XCTAssertFalse(gate.hasEnded(live))
    }

    /// Weak: marking a session does not keep it alive, so the record can
    /// never outlast the client whose late replies it exists to drop.
    func testTheRecordDoesNotRetainTheSession() {
        let gate = SessionTeardownGate()
        weak var released: Session?
        do {
            let session = Session()
            released = session
            gate.markEnded(session)
        }
        XCTAssertNil(released)
        XCTAssertFalse(gate.hasEnded(Session()))
    }
}
