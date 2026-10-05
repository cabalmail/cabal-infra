import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Pins the wording of the failed-send banner (audit F8): a single failure
/// names the message, several are counted, and an empty subject still reads
/// as a sentence.
final class FailedSendBannerTextTests: XCTestCase {

    func testOneFailureNamesTheSubject() {
        XCTAssertEqual(
            FailedSendBanner.text(for: [Self.entry(subject: "Lunch")]),
            "Couldn't send “Lunch”."
        )
    }

    func testOneFailureWithoutASubject() {
        XCTAssertEqual(
            FailedSendBanner.text(for: [Self.entry(subject: "  ")]),
            "A message with no subject couldn't be sent."
        )
    }

    func testSeveralFailuresAreCounted() {
        let entries = [Self.entry(subject: "a"), Self.entry(subject: "b"), Self.entry(subject: "c")]
        XCTAssertEqual(FailedSendBanner.text(for: entries), "3 messages couldn't be sent.")
        XCTAssertEqual(FailedSendBanner.discardTitle(count: 3), "Discard 3 unsent messages?")
        XCTAssertEqual(FailedSendBanner.discardTitle(count: 1), "Discard the unsent message?")
    }

    private static func entry(subject: String) -> Outbox.Entry {
        Outbox.Entry(
            failedAt: Date(),
            message: OutgoingMessage(
                from: EmailAddress(name: nil, mailbox: "alice", host: "example.com"),
                to: [EmailAddress(name: nil, mailbox: "bob", host: "example.com")],
                subject: subject
            )
        )
    }
}
