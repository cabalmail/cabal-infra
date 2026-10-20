import XCTest
import CabalmailKit
@testable import CabalmailUI

/// `RecoveryEmailModel` and `RecoveryEmailCheck` against a signed-in
/// `CognitoAuthService` over a recording transport (auth parity B4): what
/// the settings page and the sheet after sign-in show, and where adding,
/// verifying and failing leave them.
@MainActor
final class RecoveryEmailModelTests: XCTestCase {
    private static func reply(_ object: [String: Any], status: Int = 200) -> (Data, Int) {
        // swiftlint:disable:next force_try
        (try! JSONSerialization.data(withJSONObject: object), status)
    }

    private static func user(email: String? = nil, verified: Bool = false, phoneVerified: Bool = false) -> (Data, Int) {
        var attributes: [[String: String]] = [
            ["Name": "phone_number_verified", "Value": phoneVerified ? "true" : "false"],
        ]
        if let email {
            attributes += [
                ["Name": "email", "Value": email],
                ["Name": "email_verified", "Value": verified ? "true" : "false"],
            ]
        }
        return reply(["Username": "alice", "UserAttributes": attributes])
    }

    private func auth(_ responses: [(Data, Int)]) async throws -> (CognitoAuthService, RecordingHTTPTransport) {
        let http = RecordingHTTPTransport(responses: responses)
        let service = CognitoAuthService(
            configuration: TestFixtures.makeConfiguration(),
            transport: http,
            secureStore: InMemorySecureStore()
        )
        try await service.adopt(tokens: AuthTokens(
            idToken: "id", accessToken: "access-1", refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600)
        ))
        return (service, http)
    }

    private func targets(_ http: RecordingHTTPTransport) async -> [String] {
        let requests = await http.requests
        return requests.compactMap {
            $0.value(forHTTPHeaderField: "X-Amz-Target")?
                .replacingOccurrences(of: "AWSCognitoIdentityProviderService.", with: "")
        }
    }

    // MARK: - Settings

    func testAVerifiedAddressIsShownAsSuch() async throws {
        let (service, _) = try await auth([Self.user(email: "alice@example.net", verified: true)])
        let model = RecoveryEmailModel(auth: service, smsEnabled: true)
        await model.load()

        XCTAssertEqual(model.step, .showing)
        XCTAssertEqual(model.statusText, "alice@example.net is verified and can be used to recover your account.")
    }

    /// The settings page is where a phone-only account (plan D5) adds an
    /// address, since the check after sign-in never asks it to.
    func testAPhoneOnlyAccountIsToldItsPhoneRecoversIt() async throws {
        let (service, _) = try await auth([Self.user(phoneVerified: true)])
        let model = RecoveryEmailModel(auth: service, smsEnabled: true)
        await model.load()

        XCTAssertNil(model.address)
        XCTAssertTrue(model.statusText.hasPrefix("You have no recovery email. Your phone number recovers your account"))
    }

    func testAddingAnAddressSavesItThenVerifiesIt() async throws {
        let (service, http) = try await auth([Self.user(), Self.reply([:]), Self.reply([:])])
        let model = RecoveryEmailModel(auth: service, smsEnabled: false)
        await model.load()
        XCTAssertTrue(model.statusText.hasPrefix("You have no recovery email. Add an address outside Cabalmail"))

        model.startEditing()
        model.draft = "not an address"
        XCTAssertFalse(model.canSave)
        model.draft = " alice@example.net "
        await model.save()
        XCTAssertEqual(model.step, .verifying)
        XCTAssertEqual(model.notice, "A verification code is on its way to alice@example.net.")

        model.code = "424 242"
        await model.verify()
        XCTAssertEqual(model.step, .showing)
        XCTAssertTrue(model.isVerified)
        let sent = await targets(http)
        XCTAssertEqual(sent, ["GetUser", "UpdateUserAttributes", "VerifyUserAttribute"])
        let verifyRequest = await http.requests[2]
        let verifyBody = try XCTUnwrap(verifyRequest.httpBody)
        let verify = try XCTUnwrap(JSONSerialization.jsonObject(with: verifyBody) as? [String: String])
        XCTAssertEqual(verify["Code"], "424242")
    }

    func testChangingAVerifiedAddressWarnsItStopsCounting() async throws {
        let (service, _) = try await auth([Self.user(email: "alice@example.net", verified: true)])
        let model = RecoveryEmailModel(auth: service, smsEnabled: true)
        await model.load()
        model.startEditing()

        XCTAssertEqual(
            model.editingHelp,
            "Use an address outside Cabalmail. Until you verify it, alice@example.net stops being used for recovery."
        )
    }

    func testAWrongCodeStaysOnTheCode() async throws {
        let (service, _) = try await auth([
            Self.user(email: "alice@example.net"),
            Self.reply([:]),
            Self.reply(["__type": "CodeMismatchException", "message": "Invalid code"], status: 400),
        ])
        let model = RecoveryEmailModel(auth: service, smsEnabled: true)
        await model.load()
        await model.sendCode()
        model.code = "000000"
        await model.verify()

        XCTAssertEqual(model.step, .verifying)
        XCTAssertFalse(model.isVerified)
        XCTAssertEqual(model.errorMessage, "That code did not match. Check it and try again.")
    }

    func testAnUnreadableAccountOffersARetry() async throws {
        let (service, _) = try await auth([
            Self.reply(["__type": "InternalErrorException", "message": "boom"], status: 500),
            Self.user(email: "alice@example.net", verified: true),
        ])
        let model = RecoveryEmailModel(auth: service, smsEnabled: true)
        await model.load()
        guard case .failed = model.step else { return XCTFail("expected .failed, got \(model.step)") }

        await model.load()
        XCTAssertEqual(model.step, .showing)
    }

    // MARK: - The sheet after sign-in

    func testThePromptStartsWhereItPoints() async throws {
        let (service, http) = try await auth([])
        let adding = RecoveryEmailModel(auth: service, smsEnabled: false, prompt: .add)
        XCTAssertEqual(adding.step, .editing)

        let verifying = RecoveryEmailModel(auth: service, smsEnabled: true, prompt: .verify("alice@example.net"))
        XCTAssertEqual(verifying.step, .showing)
        XCTAssertEqual(verifying.address, "alice@example.net")
        XCTAssertFalse(verifying.isVerified)
        let sent = await targets(http)
        XCTAssertEqual(sent, [], "the prompt already knows what GetUser said")
    }

    func testTheCheckAsksWhatD5Asks() async throws {
        let (phoneOnly, _) = try await auth([Self.user(phoneVerified: true), Self.user(phoneVerified: true)])
        let withSms = await RecoveryEmailCheck.prompt(auth: phoneOnly, smsEnabled: true)
        XCTAssertNil(withSms, "a verified phone recovers the account when SMS is on")
        let withoutSms = await RecoveryEmailCheck.prompt(auth: phoneOnly, smsEnabled: false)
        XCTAssertEqual(withoutSms, .add)

        let (unverified, _) = try await auth([Self.user(email: "alice@example.net", phoneVerified: true)])
        let verify = await RecoveryEmailCheck.prompt(auth: unverified, smsEnabled: true)
        XCTAssertEqual(verify, .verify("alice@example.net"))
    }

    func testAFailedCheckNeverBlocksTheSignIn() async throws {
        let (service, _) = try await auth([
            Self.reply(["__type": "InternalErrorException", "message": "boom"], status: 500),
        ])
        let prompt = await RecoveryEmailCheck.prompt(auth: service, smsEnabled: true)
        XCTAssertNil(prompt)
    }
}
