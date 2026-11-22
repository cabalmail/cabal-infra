import XCTest
@testable import CabalmailKit

/// `FlaggedList`: the Flagged view's one list from its two halves, and the
/// horizon that keeps a paged half honest. The cases are the Android kit's
/// `FlaggedListTest`, so the two platforms hold one rule.
final class FlaggedListTests: XCTestCase {
    // MARK: Order

    func testWholeHalvesInterleaveByDateAcrossMedia() {
        // The server's order is by arrival day, then folder and UID: not
        // this list's order.
        let page = whole(
            mail: [msg(3, "2026-03-05T08:00:00Z"), msg(9, "2026-03-05T21:00:00Z"), msg(1, "2026-03-01T12:00:00Z")],
            feed: [art("a", "2026-03-05T12:00:00+00:00"), art("b", "2026-03-03T00:00:00+00:00")]
        )

        XCTAssertEqual(names(page), ["m9", "a", "m3", "b", "m1"])
        XCTAssertNil(page.cutoff)
        XCTAssertNil(page.next)
        XCTAssertEqual(page.heldBack, 0)
    }

    func testAFeedDateWithAFractionAndAnOffsetIsReadAsItsInstant() {
        // 23:30 at -05:00 is 04:30 the next day in UTC, after the message.
        let page = whole(
            mail: [msg(1, "2026-03-06T01:00:00Z")],
            feed: [art("a", "2026-03-05T23:30:00.250-05:00")]
        )

        XCTAssertEqual(names(page), ["a", "m1"])
    }

    func testARowWithNoDateSortsLast() {
        let page = whole(
            mail: [msg(1, nil), msg(2, "2026-03-01T12:00:00Z")],
            feed: [art("a", ""), art("b", "2026-02-01T00:00:00+00:00")]
        )

        XCTAssertEqual(names(page), ["m2", "b", "m1", "a"])
    }

    func testRowsOfOneInstantKeepOneOrderHoweverTheyArrive() {
        let instant = "2026-03-05T12:00:00Z"
        let mail = [msg(7, instant, folder: "Archive"), msg(2, instant), msg(7, instant)]
        let feed = [art("b", instant), art("a", instant)]

        let one = names(whole(mail: mail, feed: feed))
        let other = names(whole(mail: mail.reversed(), feed: feed.reversed()))

        XCTAssertEqual(one, other)
        XCTAssertEqual(one.count, 5)
    }

    func testAMessageDeliveredByTwoPagesIsOneRow() {
        let page = whole(mail: [msg(4, "2026-03-05T12:00:00Z"), msg(4, "2026-03-05T12:00:00Z")], feed: [])

        XCTAssertEqual(names(page), ["m4"])
    }

    /// A message is placed by the date its row shows, the Date header, as
    /// in every list; the day it arrived is only what the server pages by.
    func testAMessageIsOrderedByTheDateItsRowShows() {
        let late = SearchedEnvelope(
            envelope: Envelope(
                uid: 4, date: date("2026-03-05T23:00:00Z"), from: [], flags: [.flagged],
                internalDate: date("2026-03-07T02:00:00Z")
            ),
            folder: "INBOX"
        )

        let page = whole(mail: [late], feed: [art("a", "2026-03-06T12:00:00+00:00")])

        XCTAssertEqual(names(page), ["a", "m4"])
    }

    func testOneUIDInTwoFoldersIsTwoRows() {
        let page = whole(
            mail: [msg(4, "2026-03-05T12:00:00Z"), msg(4, "2026-03-04T12:00:00Z", folder: "Archive")], feed: []
        )

        XCTAssertEqual(page.rows.map(\.ref), [
            .mail(MessageRef(folder: "INBOX", uid: 4)), .mail(MessageRef(folder: "Archive", uid: 4)),
        ])
    }

    // MARK: The mail horizon

    func testWhileMailHasMorePagesTheListEndsAtTheMidnightAfterTheLastRowsDay() {
        let mail = [msg(9, "2026-03-07T10:00:00Z"), msg(8, "2026-03-06T09:00:00Z"), msg(7, "2026-03-05T22:00:00Z")]
        let feed = [
            art("new", "2026-03-06T12:00:00+00:00"),
            // The same day as the last message loaded: more of that day may
            // be on the next page, so it waits.
            art("sameDay", "2026-03-05T23:00:00+00:00"),
            art("old", "2026-02-01T00:00:00+00:00"),
        ]

        let page = mailPaging(mail: mail, feed: feed)

        XCTAssertEqual(page.cutoff, date("2026-03-06T00:00:00Z"))
        XCTAssertEqual(names(page), ["m9", "new", "m8"])
        XCTAssertEqual(page.next, .mail)
        XCTAssertEqual(page.heldBack, 3)
    }

    func testARowExactlyAtTheHorizonShows() {
        let page = mailPaging(
            mail: [msg(9, "2026-03-07T10:00:00Z"), msg(7, "2026-03-05T22:00:00Z")],
            feed: [art("atMidnight", "2026-03-06T00:00:00+00:00"), art("justBefore", "2026-03-05T23:59:59+00:00")]
        )

        XCTAssertEqual(names(page), ["m9", "atMidnight"])
    }

    func testTheNextPageReleasesWhatTheHorizonHeldBack() {
        let first = [msg(9, "2026-03-07T10:00:00Z"), msg(7, "2026-03-05T22:00:00Z")]
        let second = [msg(6, "2026-03-05T08:00:00Z"), msg(5, "2026-03-01T08:00:00Z")]
        let feed = [art("held", "2026-03-05T12:00:00+00:00"), art("old", "2026-02-01T00:00:00+00:00")]

        XCTAssertEqual(names(mailPaging(mail: first, feed: feed)), ["m9"])
        let page = whole(mail: first + second, feed: feed)

        XCTAssertEqual(names(page), ["m9", "m7", "held", "m6", "m5", "old"])
        XCTAssertEqual(page.heldBack, 0)
    }

    func testAPageThatIsAllOneDayShowsNoneOfItYet() {
        let page = mailPaging(
            mail: [msg(3, "2026-03-05T20:00:00Z"), msg(2, "2026-03-05T08:00:00Z")],
            feed: [art("a", "2026-03-05T12:00:00+00:00")]
        )

        XCTAssertEqual(names(page), [])
        XCTAssertEqual(page.heldBack, 3)
        XCTAssertEqual(page.next, .mail)
    }

    func testTheHorizonReadsPastALastRowThatHasNoDate() {
        let cutoff = FlaggedList.mailCutoff(
            loaded: [msg(9, "2026-03-07T10:00:00Z"), msg(1, nil)].map(\.envelope), hasMore: true
        )

        XCTAssertEqual(cutoff, date("2026-03-08T00:00:00Z"))
    }

    func testTheHorizonIsTheDayAMessageArrivedWhereTheEnvelopeCarriesIt() {
        // Sent late on the 5th, delivered early on the 7th: the server
        // pages it with the 7th.
        let late = Envelope(
            uid: 4, date: date("2026-03-05T23:00:00Z"), from: [], flags: [.flagged],
            internalDate: date("2026-03-07T02:00:00Z")
        )

        XCTAssertEqual(FlaggedList.mailCutoff(loaded: [late], hasMore: true), date("2026-03-08T00:00:00Z"))
    }

    func testWithPagesLeftAndNoDatedMessageNothingIsVouchedFor() {
        let page = mailPaging(mail: [msg(1, nil)], feed: [art("a", "2026-03-05T12:00:00+00:00")])

        XCTAssertEqual(page.cutoff, FlaggedList.nothingYet)
        XCTAssertEqual(names(page), [])
        XCTAssertEqual(page.next, .mail)

        // Before the first page lands, the same: nothing from either half.
        let before = mailPaging(mail: [], feed: [art("a", "2026-03-05T12:00:00+00:00")])
        XCTAssertEqual(names(before), [])
        XCTAssertEqual(before.heldBack, 1)
    }

    func testMailWithNoMorePagesHasNoHorizon() {
        XCTAssertNil(FlaggedList.mailCutoff(loaded: [msg(1, "2026-03-07T10:00:00Z")].map(\.envelope), hasMore: false))
        XCTAssertNil(FlaggedList.mailCutoff(loaded: [], hasMore: false))
    }

    func testMailThatNeverLoadedLeavesTheFeedHalfWhole() {
        // The search failed with nothing on screen: no claim is made about
        // mail, and the feed half stands alone.
        let page = whole(mail: [], feed: [art("a", "2026-03-05T12:00:00+00:00"), art("b", "2026-01-01T00:00:00+00:00")])

        XCTAssertEqual(names(page), ["a", "b"])
        XCTAssertNil(page.next)
    }

    // MARK: The feed horizon

    func testAFeedHalfStillBeingReadEndsJustPastItsLastRow() throws {
        let feed = [art("a", "2026-03-07T00:00:00+00:00"), art("b", "2026-03-05T12:00:00+00:00")]
        let cutoff = try XCTUnwrap(FlaggedList.feedCutoff(loaded: feed, hasMore: true))
        let page = FlaggedList.merge(
            mail: [msg(9, "2026-03-06T00:00:00Z"), msg(8, "2026-03-05T12:00:00Z"), msg(7, "2026-03-01T00:00:00Z")],
            mailCutoff: nil, feed: feed, feedCutoff: cutoff
        )

        XCTAssertGreaterThan(cutoff, try XCTUnwrap(date("2026-03-05T12:00:00Z")))
        XCTAssertLessThan(cutoff, try XCTUnwrap(date("2026-03-05T12:00:01Z")))
        // The last row read and a message of the same instant both wait: an
        // item published in that instant may be on the next read.
        XCTAssertEqual(names(page), ["a", "m9"])
        XCTAssertEqual(page.next, .feed)
        XCTAssertEqual(page.heldBack, 3)
    }

    func testAFeedHalfWithNoMoreHasNoHorizon() {
        XCTAssertNil(FlaggedList.feedCutoff(loaded: [art("a", "2026-03-07T00:00:00+00:00")], hasMore: false))
    }

    func testWithBothHalvesLoadingTheLaterHorizonBindsAndNamesWhatToLoad() {
        let mail = [msg(9, "2026-03-07T10:00:00Z"), msg(8, "2026-03-03T10:00:00Z")]
        let feed = [art("a", "2026-03-06T00:00:00+00:00"), art("b", "2026-03-05T00:00:00+00:00")]

        // Mail is whole down to 4 March, the feed half down to 5 March.
        let page = FlaggedList.merge(
            mail: mail, mailCutoff: FlaggedList.mailCutoff(loaded: mail.map(\.envelope), hasMore: true),
            feed: feed, feedCutoff: FlaggedList.feedCutoff(loaded: feed, hasMore: true)
        )
        XCTAssertEqual(page.next, .feed)
        XCTAssertEqual(names(page), ["m9", "a"])

        // And the other way round.
        let lateMail = [msg(9, "2026-03-07T10:00:00Z"), msg(8, "2026-03-06T10:00:00Z")]
        let other = FlaggedList.merge(
            mail: lateMail, mailCutoff: FlaggedList.mailCutoff(loaded: lateMail.map(\.envelope), hasMore: true),
            feed: feed, feedCutoff: FlaggedList.feedCutoff(loaded: feed, hasMore: true)
        )
        XCTAssertEqual(other.next, .mail)
        XCTAssertEqual(names(other), ["m9"])
    }

    // MARK: Fixtures

    private func whole(mail: [SearchedEnvelope], feed: [RssItem]) -> FlaggedPage {
        FlaggedList.merge(mail: mail, mailCutoff: nil, feed: feed, feedCutoff: nil)
    }

    private func mailPaging(mail: [SearchedEnvelope], feed: [RssItem]) -> FlaggedPage {
        FlaggedList.merge(
            mail: mail, mailCutoff: FlaggedList.mailCutoff(loaded: mail.map(\.envelope), hasMore: true),
            feed: feed, feedCutoff: nil
        )
    }

    private func msg(_ uid: UInt32, _ sent: String?, folder: String = "INBOX") -> SearchedEnvelope {
        let sent = sent.flatMap(date)
        return SearchedEnvelope(
            envelope: Envelope(uid: uid, date: sent, from: [], flags: [.flagged], internalDate: sent),
            folder: folder
        )
    }

    private func art(_ key: String, _ published: String) -> RssItem {
        RssItem(feedId: "f", itemId: key, sortKey: key, publishedAt: published, isFavorite: true)
    }

    private func date(_ iso: String) -> Date? {
        try? Date.ISO8601FormatStyle().parse(iso)
    }

    private func names(_ page: FlaggedPage) -> [String] {
        page.rows.map { row in
            switch row {
            case .mail(let envelope, _): return "m\(envelope.uid)"
            case .feed(let item): return item.sortKey
            }
        }
    }
}
