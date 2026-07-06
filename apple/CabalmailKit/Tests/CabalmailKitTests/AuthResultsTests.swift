import XCTest
@testable import CabalmailKit

/// Phase 4 of docs/0.10.x/inbound-auth-verification-plan.md: decoding the
/// `auth_results` envelope field and bucketing verdicts into the three
/// display states. The load-bearing invariant throughout: absent data must
/// NEVER render as pass.
final class AuthResultsTests: XCTestCase {

    // MARK: - Wire decoding

    private func decodeEnvelope(authResultsJson: String?) throws -> ApiEnvelope {
        let field = authResultsJson.map { ", \"auth_results\": \($0)" } ?? ""
        let json = """
        {
          "id": 7, "date": "2026-07-01 10:30:45+00:00", "subject": "hi",
          "from": ["a@x.com"], "to": ["b@y.com"], "cc": [], "flags": []\(field)
        }
        """
        return try JSONDecoder().decode(ApiEnvelope.self, from: Data(json.utf8))
    }

    func testDecodesAuthResultsWhenPresent() throws {
        let env = try decodeEnvelope(
            authResultsJson: #"{"spf": "pass", "dkim": "pass", "dmarc": "fail"}"#
        )
        XCTAssertEqual(env.authResults?.spf, "pass")
        XCTAssertEqual(env.authResults?.dkim, "pass")
        XCTAssertEqual(env.authResults?.dmarc, "fail")
    }

    func testDecodesAbsentKeyAsNil() throws {
        let env = try decodeEnvelope(authResultsJson: nil)
        XCTAssertNil(env.authResults)
        XCTAssertEqual(AuthVerificationState(env.authResults), .notVerified)
    }

    func testDecodesJsonNullAsNil() throws {
        let env = try decodeEnvelope(authResultsJson: "null")
        XCTAssertNil(env.authResults)
        XCTAssertEqual(AuthVerificationState(env.authResults), .notVerified)
    }

    func testDecodesPartialMethods() throws {
        let env = try decodeEnvelope(authResultsJson: #"{"dkim": "pass"}"#)
        XCTAssertNil(env.authResults?.spf)
        XCTAssertEqual(env.authResults?.dkim, "pass")
        XCTAssertNil(env.authResults?.dmarc)
        XCTAssertEqual(env.authResults?.isEmpty, false)
    }

    func testMakeEnvelopeCarriesAuthResults() throws {
        let raw = try decodeEnvelope(
            authResultsJson: #"{"spf": "fail", "dkim": "fail"}"#
        )
        let envelope = ApiBackedImapClient.makeEnvelope(raw)
        XCTAssertEqual(envelope.authResults, AuthResults(spf: "fail", dkim: "fail"))
        XCTAssertEqual(envelope.authVerification, .warning)
    }

    func testSearchEnvelopeDecodesAuthResults() throws {
        let json = """
        {
          "id": 3, "from": [], "to": [], "cc": [], "flags": [],
          "folder": "INBOX", "auth_results": {"dmarc": "pass"}
        }
        """
        let env = try JSONDecoder().decode(ApiSearchEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(env.authResults?.dmarc, "pass")
    }

    // MARK: - Envelope cache compatibility

    func testEnvelopeSnapshotWithoutFieldDecodesAsNotVerified() throws {
        // A cache snapshot written before the field existed: encode with a
        // pre-field shape by stripping the key from a fresh encode.
        let encoded = try JSONEncoder().encode(Envelope(uid: 9))
        var dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        dict.removeValue(forKey: "authResults")
        let legacy = try JSONSerialization.data(withJSONObject: dict)
        let envelope = try JSONDecoder().decode(Envelope.self, from: legacy)
        XCTAssertNil(envelope.authResults)
        XCTAssertEqual(envelope.authVerification, .notVerified)
    }

    func testWithThreadingPreservesAuthResults() {
        let results = AuthResults(spf: "pass", dkim: "pass", dmarc: "pass")
        let envelope = Envelope(uid: 4, authResults: results)
            .withThreading(messageId: "<m@x>", inReplyTo: nil, references: [])
        XCTAssertEqual(envelope.authResults, results)
    }

    // MARK: - State bucketing

    func testDmarcPassIsVerifiedOk() {
        let state = AuthVerificationState(AuthResults(spf: "fail", dkim: "none", dmarc: "pass"))
        XCTAssertEqual(state, .verifiedOk)
    }

    func testDmarcHardFailureIsWarning() {
        XCTAssertEqual(AuthVerificationState(AuthResults(dmarc: "fail")), .warning)
        XCTAssertEqual(AuthVerificationState(AuthResults(dmarc: "permerror")), .warning)
    }

    func testDmarcAbsentWithBothMethodsFailingIsWarning() {
        let state = AuthVerificationState(AuthResults(spf: "fail", dkim: "fail"))
        XCTAssertEqual(state, .warning)
    }

    func testAbsentDataIsNotVerified() {
        XCTAssertEqual(AuthVerificationState(nil), .notVerified)
        XCTAssertEqual(AuthVerificationState(AuthResults()), .notVerified)
    }

    func testMiddleGroundVerdictsAreNotVerified() {
        // Data exists but is neither a pass nor a hard failure: the quiet
        // default, not a warning and definitely not a pass.
        XCTAssertEqual(AuthVerificationState(AuthResults(spf: "pass", dkim: "pass", dmarc: "none")), .notVerified)
        XCTAssertEqual(AuthVerificationState(AuthResults(spf: "softfail", dkim: "fail")), .notVerified)
        XCTAssertEqual(AuthVerificationState(AuthResults(dmarc: "temperror")), .notVerified)
    }

    func testAbsentNeverPasses() {
        // The invariant by construction: nothing nil-shaped may bucket ok.
        XCTAssertNotEqual(AuthVerificationState(nil), .verifiedOk)
        XCTAssertNotEqual(AuthVerificationState(AuthResults()), .verifiedOk)
        XCTAssertNotEqual(AuthVerificationState(AuthResults(spf: "pass", dkim: "pass")), .verifiedOk)
        XCTAssertNotEqual(AuthMethodSeverity(token: nil), .ok)
    }

    // MARK: - Per-method chip severity

    func testMethodSeverityBuckets() {
        XCTAssertEqual(AuthMethodSeverity(token: "pass"), .ok)
        XCTAssertEqual(AuthMethodSeverity(token: "fail"), .bad)
        XCTAssertEqual(AuthMethodSeverity(token: "permerror"), .bad)
        XCTAssertEqual(AuthMethodSeverity(token: "none"), .neutral)
        XCTAssertEqual(AuthMethodSeverity(token: "neutral"), .neutral)
        XCTAssertEqual(AuthMethodSeverity(token: "softfail"), .neutral)
        XCTAssertEqual(AuthMethodSeverity(token: "temperror"), .neutral)
        XCTAssertEqual(AuthMethodSeverity(token: "policy"), .neutral)
        XCTAssertEqual(AuthMethodSeverity(token: nil), .neutral)
    }
}
