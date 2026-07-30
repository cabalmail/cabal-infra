import XCTest
@testable import Cabalmail

/// Linkification of plain-text message bodies (issue #765): the `text/plain`
/// path used to render a bare `Text`, so URLs in it were inert while the HTML
/// path had the full reader link menu.
final class PlainTextLinkDetectorTests: XCTestCase {

    private func links(in attributed: AttributedString) -> [URL] {
        attributed.runs.compactMap { $0.link }
    }

    private func linkedText(_ attributed: AttributedString, for url: URL) -> String? {
        for run in attributed.runs where run.link == url {
            return String(attributed[run.range].characters)
        }
        return nil
    }

    func testBareURLBecomesALink() {
        let scanned = PlainTextLinkDetector.scan(
            "See https://example.com/plain-link-0730 for details."
        )
        XCTAssertEqual(
            links(in: scanned.attributed).map(\.absoluteString),
            ["https://example.com/plain-link-0730"]
        )
        XCTAssertEqual(
            linkedText(scanned.attributed, for: URL(string: "https://example.com/plain-link-0730")!),
            "https://example.com/plain-link-0730"
        )
    }

    func testEmailAddressBecomesAMailtoLink() {
        let scanned = PlainTextLinkDetector.scan("Write to someone@example.com any time.")
        XCTAssertEqual(
            links(in: scanned.attributed).map(\.absoluteString),
            ["mailto:someone@example.com"]
        )
    }

    func testSeveralLinksAreAllDetected() {
        let scanned = PlainTextLinkDetector.scan(
            """
            First: https://one.example.com/a
            Second: http://two.example.com/b
            """
        )
        XCTAssertEqual(
            Set(links(in: scanned.attributed).map(\.absoluteString)),
            ["https://one.example.com/a", "http://two.example.com/b"]
        )
    }

    func testProseWithoutURLsGetsNoLinks() {
        let scanned = PlainTextLinkDetector.scan("Nothing to see here, thanks.")
        XCTAssertTrue(links(in: scanned.attributed).isEmpty)
    }

    func testCharacterContentIsUnchanged() {
        // The reader restores plain-text scroll by exact content offset, so
        // linkification must not add, drop, or rewrite a single character.
        let plain = "Top line\n\nhttps://example.com/x?q=1&r=2\n\nTrailing line\n"
        let scanned = PlainTextLinkDetector.scan(plain)
        XCTAssertEqual(String(scanned.attributed.characters), plain)
    }

    func testMenuTargetDropsALabelIdenticalToTheAddress() throws {
        let scanned = PlainTextLinkDetector.scan("Go to https://example.com/x now")
        let url = try XCTUnwrap(links(in: scanned.attributed).first)
        let target = try XCTUnwrap(
            PlainTextLinkDetector.menuTarget(for: url, labels: scanned.labels)
        )
        XCTAssertEqual(target.url, url)
        // "Copy Link Text" would duplicate "Copy Link Address" here, and the
        // menu hides that row for an empty label.
        XCTAssertEqual(target.text, "")
    }

    func testMenuTargetKeepsALabelThatDiffersFromTheAddress() throws {
        // NSDataDetector completes a bare host into a scheme-qualified URL, so
        // the text the user saw and the destination are not the same string.
        let scanned = PlainTextLinkDetector.scan("Visit www.example.com today")
        let url = try XCTUnwrap(links(in: scanned.attributed).first)
        let target = try XCTUnwrap(
            PlainTextLinkDetector.menuTarget(for: url, labels: scanned.labels)
        )
        XCTAssertEqual(target.text, "www.example.com")
    }

    func testMenuTargetRejectsAnExecutableScheme() {
        let url = URL(string: "javascript:alert(1)")!
        XCTAssertNil(PlainTextLinkDetector.menuTarget(for: url, labels: [:]))
    }
}
