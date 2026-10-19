import XCTest
import CabalmailKit
@testable import CabalmailUI

private typealias Fixtures = SignUpFixtures

/// `SignUpModel`'s loading and rules (auth parity plan, B2): what each
/// deployment's form asks for (plan D5) and how the fields are normalized.
@MainActor
final class SignUpModelRulesTests: XCTestCase {
    // MARK: - Loading

    func testLoadReadsTheDeploymentFromTheTrimmedDomain() async {
        var asked: [String] = []
        let model = SignUpModel(
            controlDomain: " cabalmail.example ",
            loadConfiguration: { domain in
                asked.append(domain)
                return Fixtures.configuration(sms: false, invitation: true)
            }
        )
        await model.load()

        XCTAssertEqual(asked, ["cabalmail.example"])
        XCTAssertEqual(model.step, .form)
        XCTAssertFalse(model.smsEnabled)
        XCTAssertTrue(model.invitationRequired)
    }

    func testAnUnreadableConfigurationOffersARetry() async {
        var attempts = 0
        let model = SignUpModel(controlDomain: "cabalmail.example", loadConfiguration: { _ in
            attempts += 1
            if attempts == 1 { throw CabalmailError.network("offline") }
            return Fixtures.configuration()
        })
        await model.load()
        guard case .unavailable(let message) = model.step else {
            return XCTFail("expected .unavailable, got \(model.step)")
        }
        XCTAssertTrue(message.contains("Couldn't reach this server's sign-up"))

        await model.load()
        XCTAssertEqual(model.step, .form)
    }

    // MARK: - What each deployment asks for (plan D5)

    func testWithSmsThePhoneAndConsentAreRequiredAndTheEmailIsOptional() async {
        let (model, _) = await Fixtures.loadedModel()
        Fixtures.fill(model)
        XCTAssertTrue(model.canSubmit, model.missingRequirement ?? "")

        model.smsConsent = false
        XCTAssertFalse(model.canSubmit)
        XCTAssertEqual(model.missingRequirement, "Agree to receive SMS to continue.")
        model.smsConsent = true

        model.phone = ""
        XCTAssertEqual(model.missingRequirement, "Enter your phone number.")
        model.phone = "555 123 4567"
        XCTAssertEqual(model.missingRequirement, "Enter the phone number with its country code, starting with +.")
        model.phone = "+15551234567"

        model.email = "not an address"
        XCTAssertEqual(model.missingRequirement, "That email address doesn't look right.")
        model.email = "alice@example.net"
        XCTAssertTrue(model.canSubmit)
    }

    func testWithoutSmsTheEmailIsRequiredAndNoPhoneOrConsentIsAsked() async {
        let (model, _) = await Fixtures.loadedModel(Fixtures.configuration(sms: false, invitation: false))
        model.username = "alice"
        model.password = "Correct-Horse-9"
        model.confirmPassword = "Correct-Horse-9"
        XCTAssertEqual(model.missingRequirement, "Enter a recovery email.")

        model.email = "alice@example.net"
        XCTAssertTrue(model.canSubmit, model.missingRequirement ?? "")
    }

    func testTheInvitationCodeIsRequiredOnlyWhenTheDeploymentSaysSo() async {
        let (gated, _) = await Fixtures.loadedModel()
        Fixtures.fill(gated)
        gated.invitationCode = "  "
        XCTAssertEqual(gated.missingRequirement, "Enter your invitation code.")

        let (open, _) = await Fixtures.loadedModel(Fixtures.configuration(invitation: false))
        Fixtures.fill(open)
        open.invitationCode = ""
        XCTAssertTrue(open.canSubmit)
    }

    func testPasswordsMustBeLongEnoughAndMatch() async {
        let (model, _) = await Fixtures.loadedModel()
        Fixtures.fill(model)
        model.password = "Short-9"
        model.confirmPassword = "Short-9"
        XCTAssertEqual(model.missingRequirement, "Use a password of at least 12 characters.")
        model.password = "Correct-Horse-9"
        XCTAssertEqual(model.missingRequirement, "The passwords don't match.")
    }

    func testUsernameRulesMatchCheckInvite() {
        for valid in ["abc", "a-b", "a1", "abc123", String(repeating: "a", count: 32)] where valid.count >= 3 {
            XCTAssertTrue(SignUpModel.isValidUsername(valid), valid)
        }
        for invalid in ["ab", "-abc", "abc-", "123", "a_b", "a.b", String(repeating: "a", count: 33), "ABC"] {
            XCTAssertFalse(SignUpModel.isValidUsername(invalid), invalid)
        }
    }

    func testPhoneNumbersAreSentAsE164() async {
        let (model, _) = await Fixtures.loadedModel()
        model.phone = "+1 (555) 123-4567"
        XCTAssertEqual(model.normalizedPhone, "+15551234567")
        XCTAssertTrue(model.phoneIsValid)
        model.phone = "+0 555 123 4567"
        XCTAssertFalse(model.phoneIsValid, "a country code never starts with 0")
        // Digits from other scripts are not digits Cognito accepts.
        model.phone = "+١٥٥٥١٢٣٤٥٦٧"
        XCTAssertEqual(model.normalizedPhone, "+")
    }
}
