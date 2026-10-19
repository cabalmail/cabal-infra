import XCTest
import CabalmailKit
@testable import CabalmailUI

private typealias Fixtures = SignUpFixtures

/// `SignUpModel` against a real `CognitoAuthService` over a recording
/// transport (auth parity plan, B2): what `SignUp`, `ConfirmSignUp` and
/// `ResendConfirmationCode` are sent, where each reply or refusal leaves the
/// flow, and the copy that depends on the deployment.
@MainActor
final class SignUpModelFlowTests: XCTestCase {
    // MARK: - Submitting

    func testSubmitSendsTheNormalizedFieldsAndAsksForTheCode() async throws {
        let (model, http) = await Fixtures.loadedModel(responses: [Fixtures.reply(Fixtures.smsDelivery)])
        Fixtures.fill(model)
        await model.submit()

        XCTAssertEqual(
            model.step,
            .confirm(CodeDelivery(medium: .phone, destination: "+*******4567"))
        )
        let body = try await Fixtures.sentBody(http)
        XCTAssertEqual(body["Username"] as? String, "alice")
        XCTAssertEqual(body["Password"] as? String, "Correct-Horse-9")
        // No email given, so none is sent: Cabalmail can be someone's only email.
        XCTAssertEqual(body["UserAttributes"] as? [[String: String]], [
            ["Name": "preferred_username", "Value": "alice"],
            ["Name": "phone_number", "Value": "+15551234567"],
        ])
        XCTAssertEqual(body["ValidationData"] as? [[String: String]], [
            ["Name": "invitationCode", "Value": "OPEN-SESAME"],
        ])
        XCTAssertTrue(model.password.isEmpty, "the password is not kept once sent")
    }

    func testAnAutoConfirmedAccountIsCreatedAtOnce() async {
        let (model, _) = await Fixtures.loadedModel(
            Fixtures.configuration(sms: false),
            responses: [Fixtures.reply(["UserConfirmed": true, "UserSub": "s"])]
        )
        model.username = "alice"
        model.email = "alice@example.net"
        model.invitationCode = "OPEN-SESAME"
        model.password = "Correct-Horse-9"
        model.confirmPassword = "Correct-Horse-9"
        await model.submit()

        XCTAssertEqual(model.step, .created(.autoConfirmed))
        XCTAssertEqual(model.createdUsername, "alice")
    }

    func testRefusalsStayOnTheFormWithASentence() async {
        let cases: [((Data, Int), String)] = [
            (Fixtures.refusal("UserLambdaValidationException", "PreSignUp failed with error Invalid invitation code.."),
             "Invalid invitation code."),
            (Fixtures.refusal("UserLambdaValidationException",
                          "PreSignUp failed with error That username is reserved. Choose another.."),
             "That username is reserved. Choose another."),
            (Fixtures.refusal("UsernameExistsException", "User already exists"),
             "That username is taken. Choose another."),
            (Fixtures.refusal("InvalidPasswordException",
                          "Password did not conform with policy: Password must have uppercase characters"),
             "Password must have uppercase characters."),
            (Fixtures.refusal("InvalidParameterException", "Invalid phone number format."),
             "Invalid phone number format."),
            (Fixtures.refusal("LimitExceededException", "Attempt limit exceeded"),
             "Too many attempts. Please try again later."),
        ]
        for (response, expected) in cases {
            let (model, _) = await Fixtures.loadedModel(responses: [response])
            Fixtures.fill(model)
            await model.submit()
            XCTAssertEqual(model.step, .form, expected)
            XCTAssertEqual(model.errorMessage, expected)
            XCTAssertFalse(model.password.isEmpty, "a refused form keeps what was typed")
        }
    }

    // MARK: - The code

    private func modelAtTheCode(then responses: [(Data, Int)]) async -> (SignUpModel, RecordingHTTPTransport) {
        let (model, http) = await Fixtures.loadedModel(responses: [Fixtures.reply(Fixtures.smsDelivery)] + responses)
        Fixtures.fill(model)
        await model.submit()
        return (model, http)
    }

    func testConfirmSendsTheCodeForTheUsernameThatWasSubmitted() async throws {
        let (model, http) = await modelAtTheCode(then: [Fixtures.reply([:])])
        model.username = "someone-else"
        model.code = " 123 456 "
        XCTAssertTrue(model.canConfirm)
        await model.confirm()

        XCTAssertEqual(model.step, .created(.confirmedByCode(.phone)))
        XCTAssertEqual(model.createdUsername, "alice")
        let body = try await Fixtures.sentBody(http, at: 1)
        XCTAssertEqual(body as? [String: String], ["ClientId": "c", "Username": "alice", "ConfirmationCode": "123456"])
    }

    func testAWrongCodeStaysOnTheCode() async {
        let (model, _) = await modelAtTheCode(then: [Fixtures.refusal("CodeMismatchException", "Invalid code")])
        model.code = "000000"
        await model.confirm()

        XCTAssertEqual(model.step, .confirm(CodeDelivery(medium: .phone, destination: "+*******4567")))
        XCTAssertEqual(model.errorMessage, "That code did not match. Check it and try again.")
    }

    /// Cognito answers a second confirmation with NotAuthorizedException
    /// ("Current status is CONFIRMED"): the account exists either way.
    func testAnAlreadyConfirmedAccountCountsAsCreated() async {
        let (model, _) = await modelAtTheCode(then: [
            Fixtures.refusal("NotAuthorizedException", "User cannot be confirmed. Current status is CONFIRMED"),
        ])
        model.code = "123456"
        await model.confirm()

        XCTAssertEqual(model.step, .created(.confirmedByCode(.phone)))
    }

    func testResendSaysWhereTheCodeWentAndStopsWhenCognitoLimitsIt() async throws {
        let (model, http) = await modelAtTheCode(then: [
            Fixtures.reply(["CodeDeliveryDetails": ["DeliveryMedium": "SMS", "Destination": "+*******9999"]]),
            Fixtures.refusal("LimitExceededException", "Attempt limit exceeded, please try after some time."),
        ])
        await model.resend()
        XCTAssertEqual(model.notice, "A new code is on its way to your phone (+*******9999).")
        XCTAssertEqual(model.step, .confirm(CodeDelivery(medium: .phone, destination: "+*******9999")))
        let body = try await Fixtures.sentBody(http, at: 1)
        XCTAssertEqual(body as? [String: String], ["ClientId": "c", "Username": "alice"])

        await model.resend()
        XCTAssertFalse(model.canResend)
        XCTAssertEqual(model.errorMessage, "Too many attempts. Please try again later.")
    }

    // MARK: - Deployment copy

    /// The checkbox text is the webmail's, word for word; the brand names the
    /// operator only when `config.json` does (`scripts/tests` pins the rest
    /// of the text to the webmail's).
    func testTheConsentTextNamesTheOperatorWhenTheDeploymentDoes() async {
        let (named, _) = await Fixtures.loadedModel(Fixtures.configuration(operatorName: "Example Operator LLC"))
        XCTAssertTrue(named.smsConsentText.hasPrefix(
            "I agree to receive transactional SMS from Cabalmail (Example Operator LLC) — signup verification"
        ))

        let (unnamed, _) = await Fixtures.loadedModel()
        XCTAssertTrue(unnamed.smsConsentText.hasPrefix(
            "I agree to receive transactional SMS from Cabalmail — signup verification"
        ))
    }

    func testTheLegalLinksPointAtTheDeploymentsFrontDoor() async {
        let (model, _) = await Fixtures.loadedModel()
        XCTAssertEqual(model.termsURL?.absoluteString, "https://www.cabalmail.example/terms.html")
        XCTAssertEqual(model.privacyURL?.absoluteString, "https://www.cabalmail.example/privacy.html")
    }
}
