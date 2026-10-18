import XCTest
@testable import CabalmailKit
import CabalmailKitTestSupport

/// Admin recognition reads the ID token's `cognito:groups` claim the way the
/// server's `admin_limits.is_admin` does: the `admin` group as a whole
/// element, in the JSON-array form Cognito issues and in the string forms
/// API Gateway renders (auth parity plan, C1; `docs/auth.md`).
final class IdTokenClaimsTests: XCTestCase {
    private func token(_ claims: [String: Any]) -> String {
        TestFixtures.idToken(claims: claims)
    }

    func testTheAdminGroupAloneOrAmongOthers() {
        XCTAssertTrue(IdTokenClaims(idToken: token(["cognito:groups": ["admin"]])).isAdmin)
        XCTAssertTrue(IdTokenClaims(idToken: token(["cognito:groups": ["users", "admin"]])).isAdmin)
        XCTAssertEqual(IdTokenClaims(idToken: token(["cognito:groups": ["users", "admin"]])).groups, ["users", "admin"])
    }

    func testNoGroupsClaimIsNotAdmin() {
        let claims = IdTokenClaims(idToken: token(["cognito:username": "alice"]))
        XCTAssertFalse(claims.isAdmin)
        XCTAssertEqual(claims.groups, [])
    }

    /// The trap a substring test falls into: these are other groups.
    func testAGroupWhoseNameOnlyContainsAdminIsNotTheAdminGroup() {
        XCTAssertFalse(IdTokenClaims(idToken: token(["cognito:groups": ["nonadmin", "admin-readonly"]])).isAdmin)
        XCTAssertFalse(IdTokenClaims(idToken: token(["cognito:groups": "admin-readonly"])).isAdmin)
        XCTAssertFalse(IdTokenClaims(idToken: token(["cognito:groups": "[nonadmin users]"])).isAdmin)
    }

    func testTheStringRenderingsAdminLimitsAccepts() {
        for rendering in ["admin", "admin,users", "users,admin", "[admin users]", "[users admin]", " admin "] {
            XCTAssertTrue(
                IdTokenClaims(idToken: token(["cognito:groups": rendering])).isAdmin,
                "\(rendering) names the admin group"
            )
        }
        XCTAssertEqual(IdTokenClaims(idToken: token(["cognito:groups": "[admin users]"])).groups, ["admin", "users"])
    }

    /// base64url maps 62 and 63 to `-` and `_`, which plain base64 decoding
    /// rejects. Three `~` and three `?` in a row guarantee one of each lands
    /// on the byte position that encodes alone. An email address can hold
    /// either character.
    func testABase64urlPayloadWithDashAndUnderscoreDecodes() throws {
        let jwt = token(["email": "a~~~b???@example.com", "cognito:groups": ["admin"]])
        let segment = try XCTUnwrap(jwt.split(separator: ".").dropFirst().first.map(String.init))
        XCTAssertTrue(segment.contains("-"), "precondition: the segment carries '-'")
        XCTAssertTrue(segment.contains("_"), "precondition: the segment carries '_'")
        XCTAssertNil(Data(base64Encoded: segment), "negative control: plain base64 decoding refuses it")
        XCTAssertTrue(IdTokenClaims(idToken: jwt).isAdmin)
    }

    func testUTF8ClaimsDecode() {
        let claims = IdTokenClaims(idToken: token(["name": "Zoë Ångström", "cognito:groups": ["admin"]]))
        XCTAssertTrue(claims.isAdmin)
    }

    func testMalformedTokensAreNotAdmin() {
        for malformed in ["", "no-dots", "a.!!!.c", "a..c", "a.\(Data("[\"admin\"]".utf8).base64EncodedString()).c"] {
            XCTAssertFalse(IdTokenClaims(idToken: malformed).isAdmin, "\(malformed)")
        }
    }

    func testNonStringGroupEntriesAreSkipped() {
        XCTAssertEqual(IdTokenClaims(idToken: token(["cognito:groups": [5, "admin", NSNull()]])).groups, ["admin"])
    }

    func testAuthTokensReadsItsIdToken() {
        let admin = AuthTokens(
            idToken: token(["cognito:groups": ["admin"]]),
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600)
        )
        XCTAssertTrue(admin.isAdmin)
        let user = AuthTokens(idToken: token([:]), accessToken: "a", refreshToken: nil, expiresAt: Date())
        XCTAssertFalse(user.isAdmin)
    }
}
