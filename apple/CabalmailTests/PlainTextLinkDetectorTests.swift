import SwiftUI
import XCTest
@testable import CabalmailUI

/// Linkification of plain-text message bodies (issue #765): the `text/plain`
/// path used to render a bare `Text`, so URLs in it were inert while the HTML
/// path had the full reader link menu.
final class PlainTextLinkDetectorTests: XCTestCase {

    /// `run.link` reads the attribute through a key path into
    /// `AttributeScopes`, which is not Sendable (#1842); the attribute key
    /// reads the same value without forming one.
    private func link(of run: AttributedString.Runs.Run) -> URL? {
        run.attributes[AttributeScopes.FoundationAttributes.LinkAttribute.self]
    }

    private func links(in attributed: AttributedString) -> [URL] {
        attributed.runs.compactMap(link(of:))
    }

    private func linkedText(_ attributed: AttributedString, for url: URL) -> String? {
        for run in attributed.runs where link(of: run) == url {
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

    /// Both attributes a detected link carries, read through their keys. The
    /// detector builds them as one `AttributeContainer` (#1842), and a
    /// container that replaced the run's attributes instead of merging them,
    /// or that carried only the URL, would still linkify — so every other
    /// test here would still pass.
    func testADetectedLinkCarriesBothTheURLAndTheUnderline() throws {
        let linkKey = AttributeScopes.FoundationAttributes.LinkAttribute.self
        let underlineKey = AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self
        let scanned = PlainTextLinkDetector.scan("See https://example.com/underline-1018 now.")
        let run = try XCTUnwrap(scanned.attributed.runs.first { $0.attributes[linkKey] != nil })
        XCTAssertEqual(run.attributes[linkKey]?.absoluteString, "https://example.com/underline-1018")
        XCTAssertEqual(run.attributes[underlineKey], .single)
        XCTAssertEqual(
            String(scanned.attributed[run.range].characters),
            "https://example.com/underline-1018",
            "the run the attributes land on is the URL's own text"
        )
    }
}
