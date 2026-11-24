import XCTest
@testable import CabalmailKit

/// The one rule for "is this the same account": the server normalized, the
/// username exact (account-isolation.md, PR B; #2560).
final class AccountIdentityTests: XCTestCase {
    private func identity(_ controlDomain: String, _ username: String) -> AccountIdentity? {
        AccountIdentity(controlDomain: controlDomain, username: username)
    }

    func testTheSameServerAndUsernameAreTheSameAccount() {
        XCTAssertEqual(identity("cabalmail.example", "alice"), identity("cabalmail.example", "alice"))
    }

    func testTheSameUsernameOnAnotherServerIsAnotherAccount() {
        XCTAssertNotEqual(identity("cabalmail.example", "alice"), identity("other.example", "alice"))
    }

    func testAnotherUsernameOnTheSameServerIsAnotherAccount() {
        XCTAssertNotEqual(identity("cabalmail.example", "alice"), identity("cabalmail.example", "bob"))
    }

    /// The sign-in form remembers the server as typed, so the same server
    /// can come back with a scheme, spaces or capitals.
    func testTheSameServerRetypedIsTheSameAccount() {
        let plain = identity("cabalmail.example", "alice")
        for typed in [
            " cabalmail.example ", "https://cabalmail.example", " https://cabalmail.example ",
            "http://cabalmail.example", "CabalMail.Example", "HTTPS://CABALMAIL.EXAMPLE", "cabalmail.example\n",
        ] {
            XCTAssertEqual(identity(typed, "alice"), plain, "typed as \"\(typed)\"")
        }
    }

    /// The user pool's usernames are case-sensitive: two accounts.
    func testAUsernameThatDiffersOnlyInCaseIsAnotherAccount() {
        XCTAssertNotEqual(identity("cabalmail.example", "alice"), identity("cabalmail.example", "Alice"))
    }

    /// The username is not trimmed either: it is what Cognito was sent.
    func testTheUsernameIsComparedExactlyAsTyped() {
        XCTAssertNotEqual(identity("cabalmail.example", "alice"), identity("cabalmail.example", "alice "))
        XCTAssertEqual(identity("cabalmail.example", "alice")?.username, "alice")
    }

    func testNoUsernameIsNoAccount() {
        XCTAssertNil(identity("cabalmail.example", ""))
        XCTAssertNil(identity("", ""))
    }

    func testTheServerIsNormalized() {
        XCTAssertEqual(AccountIdentity.normalizedServer(" https://CabalMail.Example "), "cabalmail.example")
        XCTAssertEqual(AccountIdentity.normalizedServer("http://cabalmail.example"), "cabalmail.example")
        XCTAssertEqual(AccountIdentity.normalizedServer("cabalmail.example"), "cabalmail.example")
        XCTAssertEqual(AccountIdentity.normalizedServer(""), "")
        // Only a leading scheme goes; nothing else is rewritten.
        XCTAssertEqual(AccountIdentity.normalizedServer("mail.https.example"), "mail.https.example")
    }
}
