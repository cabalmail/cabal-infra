import XCTest
@testable import CabalmailKit
import CabalmailKitTestSupport

/// The sign-up calls against the contract in `docs/auth.md` ("Sign-up"),
/// which the webmail's `react/admin/src/auth/cognito.js` already follows:
/// what `SignUp`, `ConfirmSignUp` and `ResendConfirmationCode` send, how the
/// reply says whether a code is coming, and how `check_invite`'s two
/// refusals come back (auth parity plan, B1).
final class AuthServiceSignUpTests: XCTestCase {
    private func service(_ http: RecordingHTTPTransport) -> CognitoAuthService {
        CognitoAuthService(
            configuration: TestFixtures.makeConfiguration(),
            transport: http,
            secureStore: InMemorySecureStore()
        )
    }

    private static func reply(_ object: [String: Any], status: Int = 200) -> (Data, Int) {
        // swiftlint:disable:next force_try
        (try! JSONSerialization.data(withJSONObject: object), status)
    }

    private static func triggerRefusal(_ text: String) -> (Data, Int) {
        reply([
            "__type": "com.amazonaws.cognito.identity.model#UserLambdaValidationException",
            "message": "PreSignUp failed with error \(text).",
        ], status: 400)
    }

    private static let confirmedReply = reply(["UserConfirmed": true, "UserSub": "sub-1"])

    private func sentBody(_ http: RecordingHTTPTransport, at index: Int = 0) async throws -> [String: Any] {
        let request = await http.requests[index]
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func target(_ http: RecordingHTTPTransport, at index: Int = 0) async -> String? {
        await http.requests[index].value(forHTTPHeaderField: "X-Amz-Target")
    }

    // MARK: - SignUp request

    func testSignUpSendsTheContractsBody() async throws {
        let http = RecordingHTTPTransport(responses: [Self.confirmedReply])
        _ = try await service(http).signUp(
            username: "alice",
            password: "hunter2",
            email: "alice@example.net",
            phone: nil,
            invitationCode: "OPEN-SESAME"
        )
        let sentTarget = await target(http)
        XCTAssertEqual(sentTarget, "AWSCognitoIdentityProviderService.SignUp")
        let body = try await sentBody(http)
        XCTAssertEqual(body["ClientId"] as? String, "c")
        XCTAssertEqual(body["Username"] as? String, "alice")
        XCTAssertEqual(body["Password"] as? String, "hunter2")
        XCTAssertEqual(body["UserAttributes"] as? [[String: String]], [
            ["Name": "preferred_username", "Value": "alice"],
            ["Name": "email", "Value": "alice@example.net"],
        ])
        // Validation data, not a user attribute: check_invite reads it there,
        // and it is never stored on the user.
        XCTAssertEqual(body["ValidationData"] as? [[String: String]], [
            ["Name": "invitationCode", "Value": "OPEN-SESAME"],
        ])
    }

    func testNoInvitationCodeIsStillSentEmpty() async throws {
        let http = RecordingHTTPTransport(responses: [Self.confirmedReply])
        _ = try await service(http).signUp(
            username: "alice", password: "pw", email: "alice@example.net", phone: nil, invitationCode: nil
        )
        let body = try await sentBody(http)
        XCTAssertEqual(body["ValidationData"] as? [[String: String]], [["Name": "invitationCode", "Value": ""]])
    }

    func testAPhoneIsSentOnlyWhenGiven() async throws {
        let http = RecordingHTTPTransport(responses: [Self.confirmedReply, Self.confirmedReply])
        let session = service(http)
        _ = try await session.signUp(
            username: "alice", password: "pw", email: "alice@example.net", phone: "+15555550123", invitationCode: nil
        )
        _ = try await session.signUp(
            username: "bob", password: "pw", email: "bob@example.net", phone: "", invitationCode: nil
        )

        let withPhone = try await sentBody(http, at: 0)["UserAttributes"] as? [[String: String]]
        XCTAssertEqual(withPhone?.last, ["Name": "phone_number", "Value": "+15555550123"])
        let blankPhone = try await sentBody(http, at: 1)["UserAttributes"] as? [[String: String]]
        XCTAssertEqual(blankPhone?.map { $0["Name"] }, ["preferred_username", "email"])
    }

    // MARK: - SignUp reply

    func testACodeDeliveryMeansAConfirmationCodeIsComing() async throws {
        let http = RecordingHTTPTransport(responses: [
            Self.reply([
                "UserConfirmed": false,
                "UserSub": "sub-1",
                "CodeDeliveryDetails": [
                    "AttributeName": "phone_number", "DeliveryMedium": "SMS", "Destination": "+*******0123",
                ],
            ]),
            Self.reply([
                "UserConfirmed": false,
                "CodeDeliveryDetails": [
                    "AttributeName": "email", "DeliveryMedium": "EMAIL", "Destination": "a***@e***",
                ],
            ]),
        ])
        let session = service(http)
        let bySms = try await session.signUp(
            username: "alice", password: "pw", email: "alice@example.net", phone: "+15555550123", invitationCode: nil
        )
        XCTAssertEqual(bySms, .confirmationCodeSent(CodeDelivery(medium: .phone, destination: "+*******0123")))

        let byEmail = try await session.signUp(
            username: "bob", password: "pw", email: "bob@example.net", phone: nil, invitationCode: nil
        )
        XCTAssertEqual(byEmail, .confirmationCodeSent(CodeDelivery(medium: .email, destination: "a***@e***")))
    }

    /// With SMS off, `check_invite` confirms the account itself and Cognito
    /// sends no code: there is nothing to ask the user for.
    func testNoCodeDeliveryMeansTheAccountIsAlreadyConfirmed() async throws {
        let http = RecordingHTTPTransport(responses: [Self.confirmedReply])
        let result = try await service(http).signUp(
            username: "alice", password: "pw", email: "alice@example.net", phone: nil, invitationCode: nil
        )
        XCTAssertEqual(result, .confirmed)
    }

    // MARK: - check_invite refusals

    func testARefusedInvitationCodeThrowsItsOwnError() async throws {
        let http = RecordingHTTPTransport(responses: [Self.triggerRefusal("Invalid invitation code.")])
        do {
            _ = try await service(http).signUp(
                username: "alice", password: "pw", email: "alice@example.net", phone: nil, invitationCode: "WRONG"
            )
            XCTFail("Expected the invitation code to be refused")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .invalidInvitationCode)
            XCTAssertEqual(error.localizedDescription, "Invalid invitation code.")
        }
    }

    /// A refused username is the same exception. It keeps the trigger's own
    /// sentence, which the screens show as written.
    func testARefusedUsernameKeepsTheTriggersSentence() async throws {
        let http = RecordingHTTPTransport(responses: [
            Self.triggerRefusal("That username is reserved. Choose another."),
        ])
        do {
            _ = try await service(http).signUp(
                username: "postmaster", password: "pw", email: "a@example.net", phone: nil, invitationCode: "OK"
            )
            XCTFail("Expected the username to be refused")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .server(
                code: "UserLambdaValidationException",
                message: "That username is reserved. Choose another."
            ))
        }
    }

    func testOtherCognitoRefusalsPassThrough() async throws {
        let http = RecordingHTTPTransport(responses: [
            Self.reply(["__type": "UsernameExistsException", "message": "User already exists"], status: 400),
        ])
        do {
            _ = try await service(http).signUp(
                username: "alice", password: "pw", email: "alice@example.net", phone: nil, invitationCode: nil
            )
            XCTFail("Expected the duplicate to be refused")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .server(code: "UsernameExistsException", message: "User already exists"))
        }
    }

    // MARK: - Confirm and resend

    func testConfirmSignUpSendsTheCode() async throws {
        let http = RecordingHTTPTransport(responses: [Self.reply([:])])
        try await service(http).confirmSignUp(username: "alice", code: "123456")
        let sentTarget = await target(http)
        XCTAssertEqual(sentTarget, "AWSCognitoIdentityProviderService.ConfirmSignUp")
        let body = try await sentBody(http)
        XCTAssertEqual(body as? [String: String], ["ClientId": "c", "Username": "alice", "ConfirmationCode": "123456"])
    }

    func testResendSaysWhereTheNewCodeWent() async throws {
        let http = RecordingHTTPTransport(responses: [
            Self.reply(["CodeDeliveryDetails": [
                "AttributeName": "email", "DeliveryMedium": "EMAIL", "Destination": "a***@e***",
            ]]),
            Self.reply([:]),
        ])
        let session = service(http)
        let delivery = try await session.resendConfirmationCode(username: "alice")
        XCTAssertEqual(delivery, CodeDelivery(medium: .email, destination: "a***@e***"))
        let sentTarget = await target(http)
        XCTAssertEqual(sentTarget, "AWSCognitoIdentityProviderService.ResendConfirmationCode")
        let body = try await sentBody(http)
        XCTAssertEqual(body as? [String: String], ["ClientId": "c", "Username": "alice"])

        let unsaid = try await session.resendConfirmationCode(username: "alice")
        XCTAssertNil(unsaid)
    }
}
