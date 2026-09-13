import XCTest
@testable import Cabalmail

/// `FeedItemDate` swapped its two hoisted `ISO8601DateFormatter`s for
/// `Date.ISO8601FormatStyle` to clear the Swift 6 concurrency-safety error a
/// static non-Sendable reference type raises (#1507). The formatters are the
/// only thing every feed row and the reader header go through to render a
/// date, so these pin the parse itself: the swap is supposed to be a
/// concurrency change and not a parsing change.
final class FeedItemDateParsingTests: XCTestCase {
    private func seconds(_ iso8601: String) -> TimeInterval? {
        FeedItemDate.date(iso8601)?.timeIntervalSince1970
    }

    func testParsesPlainInternetDateTime() {
        XCTAssertEqual(try XCTUnwrap(seconds("2026-09-13T14:30:00Z")), 1_789_309_800, accuracy: 0.0005)
    }

    func testParsesFractionalSeconds() {
        // The fractional branch is the second attempt: the plain style
        // rejects the string, and the fallback is what has to catch it.
        XCTAssertEqual(try XCTUnwrap(seconds("2026-09-13T14:30:00.123Z")), 1_789_309_800.123, accuracy: 0.0005)
    }

    func testHonoursANonZuluOffset() {
        XCTAssertEqual(try XCTUnwrap(seconds("2026-09-13T14:30:00+02:00")), 1_789_302_600, accuracy: 0.0005)
        XCTAssertEqual(try XCTUnwrap(seconds("2026-09-13T14:30:00.500-05:00")), 1_789_327_800.5, accuracy: 0.0005)
    }

    func testRejectsWhatItAlwaysRejected() {
        // A date with no time, an RFC 822 date (the other shape an RSS feed
        // publishes -- normalised upstream, never handed to this function),
        // an empty string and plain rubbish all returned nil before the swap.
        for rejected in ["2026-09-13", "Sat, 13 Sep 2026 14:30:00 GMT", "", "not a date"] {
            XCTAssertNil(FeedItemDate.date(rejected), "expected nil for \(rejected.isEmpty ? "(empty)" : rejected)")
        }
    }

    func testRenderersReturnEmptyForAnUnparseableDate() {
        XCTAssertEqual(FeedItemDate.relative("not a date"), "")
        XCTAssertEqual(FeedItemDate.absolute("not a date"), "")
    }
}
