import XCTest
import CabalmailKit
@testable import CabalmailUI

/// `EnvelopeOrder` on its own: which row a folder list shows first under
/// each sort criterion, and how ties and missing keys fall.
final class EnvelopeOrderTests: XCTestCase {
    private let early = Date(timeIntervalSince1970: 1_700_000_000)
    private let middle = Date(timeIntervalSince1970: 1_700_100_000)
    private let late = Date(timeIntervalSince1970: 1_700_200_000)

    private func row(
        _ uid: UInt32,
        date: Date? = nil,
        arrived: Date? = nil,
        subject: String? = nil,
        from: EmailAddress? = nil
    ) -> Envelope {
        Envelope(uid: uid, date: date, subject: subject, from: from.map { [$0] } ?? [], internalDate: arrived)
    }

    private func uids(
        _ rows: [Envelope],
        _ field: SortCriterion.Field,
        _ direction: SortCriterion.Direction
    ) -> [UInt32] {
        rows.sorted(by: EnvelopeOrder(SortCriterion(field: field, direction: direction)).precedes).map(\.uid)
    }

    func testTheDefaultOrderListsTheNewestArrivalFirst() {
        let rows = [row(1, arrived: middle), row(2, arrived: early), row(3, arrived: late)]

        XCTAssertEqual(rows.sorted(by: EnvelopeOrder(.default).precedes).map(\.uid), [3, 1, 2])
    }

    func testDateReceivedPrefersTheArrivalDateOverTheDateHeader() {
        let rows = [row(1, date: early, arrived: late), row(2, date: late, arrived: early)]

        XCTAssertEqual(uids(rows, .dateReceived, .descending), [1, 2])
    }

    func testDateReceivedFallsBackToTheDateHeaderWithoutAnArrivalDate() {
        let rows = [row(1, arrived: middle), row(2, date: late)]

        XCTAssertEqual(uids(rows, .dateReceived, .descending), [2, 1])
    }

    func testDateSentReadsTheDateHeaderOnly() {
        let rows = [row(1, date: early, arrived: late), row(2, date: middle, arrived: early)]

        XCTAssertEqual(uids(rows, .dateSent, .descending), [2, 1])
    }

    func testAscendingReversesEveryField() {
        func sender(_ name: String) -> EmailAddress { EmailAddress(name: name, mailbox: "m", host: "x") }
        let rows = [
            row(1, date: early, arrived: early, subject: "alpha", from: sender("Ann")),
            row(2, date: middle, arrived: middle, subject: "bravo", from: sender("Ben")),
            row(3, date: late, arrived: late, subject: "charlie", from: sender("Cal")),
        ]
        for field in SortCriterion.Field.allCases {
            XCTAssertEqual(uids(rows, field, .ascending), uids(rows, field, .descending).reversed(), "\(field)")
        }
    }

    func testAMessageWithoutADateSortsLastInEitherDirection() {
        let rows = [row(1), row(2, date: early), row(3, date: late)]

        XCTAssertEqual(uids(rows, .dateSent, .descending), [3, 2, 1])
        XCTAssertEqual(uids(rows, .dateSent, .ascending), [2, 3, 1])
    }

    func testEqualKeysFallBackToTheHigherUIDInEitherDirection() {
        let sender = EmailAddress(name: "Same", mailbox: "s", host: "x")
        let sameDate = [row(5, date: middle), row(9, date: middle)]
        let noDate = [row(5), row(9)]
        let sameSender = [row(5, from: sender), row(9, from: sender)]
        let sameSubject = [row(5, subject: "Hello"), row(9, subject: "Hello")]
        for direction in SortCriterion.Direction.allCases {
            XCTAssertEqual(uids(sameDate, .dateSent, direction), [9, 5], "equal dates, \(direction)")
            XCTAssertEqual(uids(noDate, .dateSent, direction), [9, 5], "no dates, \(direction)")
            XCTAssertEqual(uids(sameSender, .from, direction), [9, 5], "equal senders, \(direction)")
            XCTAssertEqual(uids(sameSubject, .subject, direction), [9, 5], "equal subjects, \(direction)")
        }
    }

    func testFromSortsByDisplayNameAndFallsBackToTheAddress() {
        let rows = [
            row(1, from: EmailAddress(name: "\"Zed\"", mailbox: "z", host: "x")),
            row(2, from: EmailAddress(name: "", mailbox: "alice", host: "b.com")),
            row(3),
            row(4, from: EmailAddress(name: "Bob", mailbox: "q", host: "x")),
        ]

        XCTAssertEqual(uids(rows, .from, .ascending), [3, 2, 4, 1], "none, alice@b.com, Bob, Zed")
    }

    func testFromAndSubjectIgnoreCase() {
        let rows = [
            row(1, subject: "cherry", from: EmailAddress(name: "cherry", mailbox: "c", host: "x")),
            row(2, subject: "apple", from: EmailAddress(name: "apple", mailbox: "a", host: "x")),
            row(3, subject: "Banana", from: EmailAddress(name: "Banana", mailbox: "b", host: "x")),
        ]

        XCTAssertEqual(uids(rows, .from, .ascending), [2, 3, 1])
        XCTAssertEqual(uids(rows, .subject, .ascending), [2, 3, 1])
    }

    func testSubjectIgnoresReplyAndForwardPrefixes() {
        let rows = [
            row(1, subject: "Re: FWD: re:  x"),
            row(2, subject: "x"),
            row(3, subject: "w"),
            row(4, subject: "y"),
            row(5, subject: "Fw: a"),
        ]

        XCTAssertEqual(uids(rows, .subject, .ascending), [5, 3, 2, 1, 4], "a, w, x (twice, higher UID first), y")
    }

    func testAMissingOrBlankSubjectSortsAsEmpty() {
        let rows = [row(1), row(2, subject: "   "), row(3, subject: "a")]

        XCTAssertEqual(uids(rows, .subject, .ascending), [2, 1, 3])
        XCTAssertEqual(uids(rows, .subject, .descending), [3, 2, 1])
    }

    /// `sort(by:)` needs a strict weak order: no row before itself, and no
    /// two rows each before the other.
    func testTheOrderIsIrreflexiveAndAsymmetricUnderEveryCriterion() {
        let sender = EmailAddress(name: "Same", mailbox: "s", host: "x")
        let rows = [
            row(1),
            row(2, date: early, arrived: late, subject: "Re: x", from: sender),
            row(3, date: early, arrived: late, subject: "x", from: sender),
            row(4, date: late, subject: "y", from: EmailAddress(name: nil, mailbox: "m", host: "h")),
            row(5, arrived: early, subject: "  "),
        ]
        for field in SortCriterion.Field.allCases {
            for direction in SortCriterion.Direction.allCases {
                let order = EnvelopeOrder(SortCriterion(field: field, direction: direction))
                for lhs in rows {
                    XCTAssertFalse(order.precedes(lhs, lhs), "\(field) \(direction): \(lhs.uid) before itself")
                    for rhs in rows where rhs.uid != lhs.uid {
                        XCTAssertFalse(
                            order.precedes(lhs, rhs) && order.precedes(rhs, lhs),
                            "\(field) \(direction): \(lhs.uid) and \(rhs.uid) each before the other"
                        )
                    }
                }
            }
        }
    }
}
