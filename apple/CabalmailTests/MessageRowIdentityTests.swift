import XCTest
import CabalmailKit
@testable import CabalmailUI

// Search results span folders, and an IMAP UID is unique only within one,
// so the list's row identity can't be the UID alone: two matches sharing a
// UID have to stay two rows. The identity is the row's `MessageRef` (folder
// plus UID) and its replacement generation.
final class MessageRowIdentityTests: XCTestCase {

    /// The reported mailbox: `zeta0803` UID 1 and `alpha0803/kid` UID 1,
    /// both matching one query.
    private var collidingMatches: [Envelope] {
        [
            TestFixtures.makeEnvelope(uid: 1, messageId: "<probe1@example.com>", subject: "collide0803 probe 1")
                .inFolder("zeta0803"),
            TestFixtures.makeEnvelope(uid: 1, messageId: "<probe2@example.com>", subject: "collide0803 probe 2")
                .inFolder("alpha0803/kid"),
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

    func testOneMessageFiledInTwoFoldersIsTwoRows() {
        // Mail you send yourself: one Message-ID, one UID, INBOX and Sent.
        // Nothing in the envelope tells the copies apart; the folder does.
        let copy = TestFixtures.makeEnvelope(uid: 9, messageId: "<note@example.com>")
        let rows = MessageRowIdentity.identify([copy.inFolder("Sent"), copy.inFolder("INBOX")])
        XCTAssertEqual(rows.map(\.id.ref), [MessageRef(folder: "Sent", uid: 9), MessageRef(folder: "INBOX", uid: 9)])
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
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

    func testAReplacedRowGetsANewIdentityAndNoOtherRowDoes() {
        // A destructive full swipe that leaves its message in place (a failed
        // archive, a cancelled Delete Forever) holds the row open; the model
        // bumps the message's generation so the list builds it a new row.
        // The other row sharing its UID is a different message and keeps its
        // identity.
        let before = MessageRowIdentity.identify(collidingMatches).map(\.id)
        let after = MessageRowIdentity.identify(
            collidingMatches,
            generations: [MessageRef(folder: "alpha0803/kid", uid: 1): 1]
        ).map(\.id)
        XCTAssertEqual(after[0], before[0], "zeta0803 UID 1 is not the replaced message")
        XCTAssertNotEqual(after[1], before[1], "the replaced message's row must not keep its identity")
    }

    func testTheIdentityIsTheRowsRef() {
        let rows = MessageRowIdentity.identify([
            TestFixtures.makeEnvelope(uid: 1, messageId: "<probe1@example.com>").inFolder("INBOX"),
            TestFixtures.makeEnvelope(uid: 4, messageId: "<probe2@example.com>").inFolder("INBOX"),
        ])
        XCTAssertEqual(rows.map(\.id.ref), [MessageRef(folder: "INBOX", uid: 1), MessageRef(folder: "INBOX", uid: 4)])
        XCTAssertEqual(rows.map(\.id.generation), [0, 0])
    }
}
