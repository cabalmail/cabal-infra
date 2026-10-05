import XCTest
@testable import CabalmailUI

/// The redirector URL the "Open in Private Window" row hands to the browser
/// (`PrivateLinkHandoff`). The fragment has to survive
/// `decodeURIComponent` on the far side — both the redirector page and the
/// extension's background decode it that way — so the encoding is asserted
/// against a round-trip, not just against a fixed string.
final class PrivateLinkHandoffTests: XCTestCase {
    private func redirector(_ target: String, domain: String = "cabalmail.example") -> URL? {
        PrivateLinkHandoff.redirectorURL(
            for: URL(string: target)!, controlDomain: domain
        )
    }

    func testBuildsRedirectorOnTheAdminOrigin() throws {
        let url = try XCTUnwrap(redirector("https://example.com/page"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "admin.cabalmail.example")
        XCTAssertEqual(url.path, "/private-link")
        XCTAssertEqual(url.fragment, "https%3A%2F%2Fexample.com%2Fpage")
    }

    func testFragmentRoundTripsThroughDecodeURIComponent() throws {
        // Query, ampersand, a hash and non-ASCII: everything that would be
        // truncated or split if the target rode in the fragment raw.
        let target = "https://shop.example/search?q=a b&sort=price#top-ünïcode"
        let url = try XCTUnwrap(
            PrivateLinkHandoff.redirectorURL(
                for: URL(string: "https://shop.example/search?q=a%20b&sort=price#top-%C3%BCn%C3%AFcode")!,
                controlDomain: "cabalmail.example"
            )
        )
        let fragment = try XCTUnwrap(url.fragment)
        // Nothing the far side splits on may survive unencoded.
        XCTAssertFalse(fragment.contains("#"))
        XCTAssertFalse(fragment.contains("&"))
        XCTAssertFalse(fragment.contains("?"))
        // removingPercentEncoding is decodeURIComponent's Foundation twin.
        XCTAssertEqual(
            fragment.removingPercentEncoding,
            "https://shop.example/search?q=a%20b&sort=price#top-%C3%BCn%C3%AFcode"
        )
        _ = target
    }

    /// The shape that shipped broken on the stage build: the app stores the
    /// admin host the user typed at sign-in, and prefixing it again gave
    /// `admin.admin.cabalmail.net`, which nothing serves.
    func testStoredAdminHostIsNotPrefixedTwice() throws {
        let url = try XCTUnwrap(redirector("https://example.com/", domain: "admin.cabalmail.net"))
        XCTAssertEqual(url.host, "admin.cabalmail.net")
    }

    func testControlDomainInputsReduceLikeTheExtensionDoes() {
        // Same table as normalizeControlDomain's tests in controlDomain.test.ts.
        XCTAssertEqual(PrivateLinkHandoff.normalizedControlDomain("cabalmail.net"), "cabalmail.net")
        XCTAssertEqual(
            PrivateLinkHandoff.normalizedControlDomain("https://admin.cabalmail.net/"), "cabalmail.net"
        )
        XCTAssertEqual(
            PrivateLinkHandoff.normalizedControlDomain("  HTTPS://Admin.Cabalmail.NET/prod  "),
            "cabalmail.net"
        )
        XCTAssertEqual(
            PrivateLinkHandoff.normalizedControlDomain("admin.cabal-mail.example"), "cabal-mail.example"
        )
        for bad in ["", "   ", "localhost", "not a domain", "https://", ".com", "a..b", "-x.com"] {
            XCTAssertNil(PrivateLinkHandoff.normalizedControlDomain(bad), bad)
        }
    }

    func testControlDomainIsTrimmed() throws {
        let url = try XCTUnwrap(redirector("https://example.com/", domain: "  cabalmail.example \n"))
        XCTAssertEqual(url.host, "admin.cabalmail.example")
    }

    func testRejectsNonWebTargets() {
        XCTAssertNil(redirector("mailto:a@b.example"))
        XCTAssertNil(redirector("ftp://files.example/x"))
    }

    func testRejectsMissingControlDomain() {
        XCTAssertNil(redirector("https://example.com/", domain: ""))
        XCTAssertNil(redirector("https://example.com/", domain: "   "))
    }

    func testHttpTargetsAreAccepted() throws {
        let url = try XCTUnwrap(redirector("http://plain.example/"))
        XCTAssertEqual(url.fragment, "http%3A%2F%2Fplain.example%2F")
    }

    // MARK: - Fragment form (#1765)

    func testTokenFormOnlyWhenSafariIsDefaultAndOurExtensionIsEnabled() {
        // The token is resolvable only by the appex embedded in this app,
        // reached over `sendNativeMessage` from Safari. Anywhere else a
        // token would leave the fallback page with nothing to show.
        XCTAssertEqual(
            PrivateLinkHandoff.fragmentForm(isSafariDefault: true, availability: true), .token
        )
        XCTAssertEqual(
            PrivateLinkHandoff.fragmentForm(isSafariDefault: true, availability: false), .target
        )
        // `queryAvailability()` answers an optimistic `true` for a
        // non-Safari default precisely because it cannot ask; that `true`
        // must not select the token form.
        XCTAssertEqual(
            PrivateLinkHandoff.fragmentForm(isSafariDefault: false, availability: true), .target
        )
        // Cache not primed yet: the form that works everywhere.
        XCTAssertEqual(
            PrivateLinkHandoff.fragmentForm(isSafariDefault: true, availability: nil), .target
        )
    }

    func testTokenRedirectorCarriesTheTokenAndNothingElse() throws {
        let token = "0123456789abcdef0123456789abcdef"
        let url = try XCTUnwrap(
            PrivateLinkHandoff.redirectorURL(forToken: token, controlDomain: "admin.cabalmail.example")
        )
        XCTAssertEqual(url.absoluteString, "https://admin.cabalmail.example/private-link#" + token)
        XCTAssertEqual(url.fragment, token)
    }

    func testTokenRedirectorNeedsAControlDomain() {
        XCTAssertNil(
            PrivateLinkHandoff.redirectorURL(forToken: "abc", controlDomain: "not a domain")
        )
    }
}
