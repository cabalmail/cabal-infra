import XCTest
@testable import Cabalmail

/// Parsing tests for the reader's link-menu bridge payloads (the
/// dictionaries the injected `cabalLink` user script posts on primary
/// click — see `HTMLBodyView+LinkBridge`).
final class LinkMenuTargetTests: XCTestCase {
    private func payload(
        href: Any? = "https://example.com/path?q=1",
        text: Any? = "  Example link \n",
        originX: Any? = 10.0,
        originY: Any? = 20.5,
        width: Any? = 120.0,
        height: Any? = 16.0
    ) -> [String: Any] {
        var dict: [String: Any] = [:]
        dict["href"] = href
        dict["text"] = text
        dict["x"] = originX
        dict["y"] = originY
        dict["w"] = width
        dict["h"] = height
        return dict
    }

    func testParsesTapPayload() throws {
        let target = try XCTUnwrap(LinkMenuTarget(bridgePayload: payload()))
        XCTAssertEqual(target.url.absoluteString, "https://example.com/path?q=1")
        XCTAssertEqual(target.text, "Example link")
        XCTAssertEqual(target.rect, CGRect(x: 10, y: 20.5, width: 120, height: 16))
        XCTAssertTrue(target.isWebLink)
    }

    func testMissingHrefIsRejected() {
        XCTAssertNil(LinkMenuTarget(bridgePayload: payload(href: nil)))
    }

    func testUnparseableHrefIsRejected() {
        XCTAssertNil(LinkMenuTarget(bridgePayload: payload(href: "http://exa mple.com")))
    }

    func testSchemelessHrefIsRejected() {
        XCTAssertNil(LinkMenuTarget(bridgePayload: payload(href: "example.com/page")))
    }

    func testExecutableSchemesAreRejected() {
        for href in [
            "javascript:alert(1)",
            "JAVASCRIPT:alert(1)",
            "data:text/html,hi",
            "file:///etc/passwd",
            "about:blank",
            "blob:https://example.com/uuid",
        ] {
            XCTAssertNil(
                LinkMenuTarget(bridgePayload: payload(href: href)),
                "expected \(href) to be rejected"
            )
        }
    }

    func testMailtoParsesButIsNotWebLink() throws {
        let target = try XCTUnwrap(
            LinkMenuTarget(bridgePayload: payload(href: "mailto:a@b.example"))
        )
        XCTAssertFalse(target.isWebLink)
    }

    func testMissingTextAndGeometryDefaultSafely() throws {
        let target = try XCTUnwrap(
            LinkMenuTarget(bridgePayload: payload(
                text: nil, originX: nil, originY: nil, width: nil, height: nil
            ))
        )
        XCTAssertEqual(target.text, "")
        XCTAssertEqual(target.rect, .zero)
    }

    func testNonFiniteGeometryIsRejected() {
        XCTAssertNil(
            LinkMenuTarget(bridgePayload: payload(originX: Double.nan)),
            "NaN coordinates must not reach CGRect"
        )
        XCTAssertNil(LinkMenuTarget(bridgePayload: payload(width: Double.infinity)))
    }

    func testIntegerGeometryBridgesToDouble() throws {
        // JS posts whole-number coordinates as integers; NSNumber must
        // still bridge them into the rect.
        let target = try XCTUnwrap(
            LinkMenuTarget(bridgePayload: payload(originX: 10, originY: 20, width: 100, height: 16))
        )
        XCTAssertEqual(target.rect, CGRect(x: 10, y: 20, width: 100, height: 16))
    }
}
