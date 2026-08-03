import XCTest
import CabalmailKit
@testable import Cabalmail

// Search results span folders, and an IMAP UID is unique only within one,
// so the list's row identity can't be the UID alone: two matches sharing a
// UID have to stay two rows.
final class MessageRowIdentityTests: XCTestCase {

    /// The reported mailbox: `zeta0803` UID 1 and `alpha0803/kid` UID 1,
    /// both matching one query.
    private var collidingMatches: [Envelope] {
        [
            TestFixtures.makeEnvelope(uid: 1, messageId: "<probe1@example.com>", subject: "collide0803 probe 1"),
            TestFixtures.makeEnvelope(uid: 1, messageId: "<probe2@example.com>", subject: "collide0803 probe 2"),
        ]
    }

    func testCollidingUIDsGetDistinctRowIdentities() {
        let rows = MessageRowIdentity.identify(collidingMatches)
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotEqual(
            rows[0].id, rows[1].id,
            "two search matches sharing a UID must be two rows, not one — a ForEach drops the duplicate id"
        )
    }

    func testRowsKeepTheirEnvelopesAndOrder() {
        let rows = MessageRowIdentity.identify(collidingMatches)
        XCTAssertEqual(rows.map { $0.envelope.subject }, ["collide0803 probe 1", "collide0803 probe 2"])
    }

    func testIdentityIsStableAcrossRebuilds() {
        // The same result set re-identified gives the same ids, so a redraw
        // doesn't tear down and rebuild every row.
        XCTAssertEqual(
            MessageRowIdentity.identify(collidingMatches).map { $0.id },
            MessageRowIdentity.identify(collidingMatches).map { $0.id }
        )
    }

    func testMessagelessCollisionStillYieldsTwoRows() {
        // Last-resort case: same UID and no Message-ID on either row, so
        // even the UID + Message-ID key can't tell them apart.
        let rows = MessageRowIdentity.identify([
            TestFixtures.makeEnvelope(uid: 4, subject: "no message-id 1"),
            TestFixtures.makeEnvelope(uid: 4, subject: "no message-id 2"),
        ])
        XCTAssertEqual(Set(rows.map { $0.id }).count, 2, "an indistinguishable duplicate still gets its own row")
    }

    func testDistinctUIDsAreUnaffected() {
        // The ordinary folder / broken-collision case from the report's
        // control run: nothing about identity changes when UIDs differ.
        let rows = MessageRowIdentity.identify([
            TestFixtures.makeEnvelope(uid: 1, messageId: "<probe1@example.com>"),
            TestFixtures.makeEnvelope(uid: 4, messageId: "<probe2@example.com>"),
        ])
        XCTAssertEqual(rows.map { $0.id.uid }, [1, 4])
        XCTAssertEqual(rows.map { $0.id.occurrence }, [0, 0])
    }
}
