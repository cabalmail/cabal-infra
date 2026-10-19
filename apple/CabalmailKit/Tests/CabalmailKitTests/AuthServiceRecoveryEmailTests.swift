import XCTest
@testable import CabalmailKit
import CabalmailKitTestSupport

/// The recovery-email calls (`docs/auth.md`, "After sign-in" and "Recovery
/// email"; auth parity B4): what the check after sign-in asks under plan D5,
/// how `GetUser`'s attributes are read, and what the three writes send.
final class AuthServiceRecoveryEmailTests: XCTestCase {
    // MARK: - The check after sign-in (plan D5)

    func testAnUnverifiedEmailIsOfferedForVerificationWhateverThePhoneSays() {
        let contacts = RecoveryContacts(email: "alice@example.net", emailVerified: false, phoneVerified: true)
        XCTAssertEqual(contacts.promptAfterSignIn(smsEnabled: true), .verify("alice@example.net"))
        XCTAssertEqual(contacts.promptAfterSignIn(smsEnabled: false), .verify("alice@example.net"))
    }

    func testAVerifiedEmailAsksNothing() {
        let contacts = RecoveryContacts(email: "alice@example.net", emailVerified: true, phoneVerified: false)
        XCTAssertNil(contacts.promptAfterSignIn(smsEnabled: true))
        XCTAssertNil(contacts.promptAfterSignIn(smsEnabled: false))
    }

    /// With SMS on, a verified phone already recovers the account, so a
    /// phone-only account (Cabalmail as someone's only email) is left alone.
    func testAPhoneOnlyAccountIsNotAskedWhenTheVerifiedPhoneRecoversIt() {
        let contacts = RecoveryContacts(email: nil, emailVerified: false, phoneVerified: true)
        XCTAssertNil(contacts.promptAfterSignIn(smsEnabled: true))
    }

    func testAnAccountWithNoWayBackInIsAskedToAddAnEmail() {
        // SMS off: the phone can't recover the account, verified or not.
        let phoneOnly = RecoveryContacts(email: nil, emailVerified: false, phoneVerified: true)
        XCTAssertEqual(phoneOnly.promptAfterSignIn(smsEnabled: false), .add)
        // SMS on, but the phone was never verified.
        let unverifiedPhone = RecoveryContacts(email: nil, emailVerified: false, phoneVerified: false)
        XCTAssertEqual(unverifiedPhone.promptAfterSignIn(smsEnabled: true), .add)
        // An empty address is no address.
        XCTAssertEqual(RecoveryContacts(email: "", emailVerified: false, phoneVerified: false).email, nil)
    }

    // MARK: - The calls

    private static let tokens = AuthTokens(
        idToken: "id", accessToken: "access-1", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600)
    )

    private func signedIn(_ responses: [(Data, Int)]) async throws -> (CognitoAuthService, RecordingHTTPTransport) {
        let http = RecordingHTTPTransport(responses: responses)
        let service = CognitoAuthService(
            configuration: TestFixtures.makeConfiguration(), transport: http, secureStore: InMemorySecureStore()
        )
        try await service.adopt(tokens: Self.tokens)
        return (service, http)
    }

    private static func reply(_ object: [String: Any]) -> (Data, Int) {
        // swiftlint:disable:next force_try
        (try! JSONSerialization.data(withJSONObject: object), 200)
    }

    private func sent(_ http: RecordingHTTPTransport, at index: Int = 0) async throws -> (String?, [String: Any]) {
        let request = await http.requests[index]
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return (request.value(forHTTPHeaderField: "X-Amz-Target"), object)
    }

    func testRecoveryContactsReadsGetUsersAttributes() async throws {
        let (service, http) = try await signedIn([Self.reply([
            "Username": "alice",
            "UserAttributes": [
                ["Name": "email", "Value": "alice@example.net"],
                ["Name": "email_verified", "Value": "false"],
                ["Name": "phone_number", "Value": "+15555550123"],
                ["Name": "phone_number_verified", "Value": "true"],
            ],
        ])])
        let contacts = try await service.recoveryContacts()

        XCTAssertEqual(contacts, RecoveryContacts(email: "alice@example.net", emailVerified: false, phoneVerified: true))
        let (target, body) = try await sent(http)
        XCTAssertEqual(target, "AWSCognitoIdentityProviderService.GetUser")
        XCTAssertEqual(body as? [String: String], ["AccessToken": "access-1"])
    }

    func testTheWritesSendTheContractsBodies() async throws {
        let (service, http) = try await signedIn([Self.reply([:]), Self.reply([:]), Self.reply([:])])
        try await service.setRecoveryEmail("alice@example.net")
        try await service.sendRecoveryEmailCode()
        try await service.verifyRecoveryEmail(code: "424242")

        let (update, updateBody) = try await sent(http, at: 0)
        XCTAssertEqual(update, "AWSCognitoIdentityProviderService.UpdateUserAttributes")
        XCTAssertEqual(updateBody["AccessToken"] as? String, "access-1")
        XCTAssertEqual(updateBody["UserAttributes"] as? [[String: String]], [["Name": "email", "Value": "alice@example.net"]])

        let (code, codeBody) = try await sent(http, at: 1)
        XCTAssertEqual(code, "AWSCognitoIdentityProviderService.GetUserAttributeVerificationCode")
        XCTAssertEqual(codeBody as? [String: String], ["AccessToken": "access-1", "AttributeName": "email"])

        let (verify, verifyBody) = try await sent(http, at: 2)
        XCTAssertEqual(verify, "AWSCognitoIdentityProviderService.VerifyUserAttribute")
        XCTAssertEqual(
            verifyBody as? [String: String],
            ["AccessToken": "access-1", "AttributeName": "email", "Code": "424242"]
        )
    }

    func testAWrongCodeComesBackAsCognitosRefusal() async throws {
        let refusal = (Data(#"{"__type":"CodeMismatchException","message":"Invalid code"}"#.utf8), 400)
        let (service, _) = try await signedIn([refusal])
        do {
            try await service.verifyRecoveryEmail(code: "000000")
            XCTFail("Expected the code to be refused")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .server(code: "CodeMismatchException", message: "Invalid code"))
        }
    }

    func testSignedOutThereIsNothingToRead() async {
        let service = CognitoAuthService(
            configuration: TestFixtures.makeConfiguration(),
            transport: NullHTTPTransport(),
            secureStore: InMemorySecureStore()
        )
        do {
            _ = try await service.recoveryContacts()
            XCTFail("Expected .notSignedIn")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .notSignedIn)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
