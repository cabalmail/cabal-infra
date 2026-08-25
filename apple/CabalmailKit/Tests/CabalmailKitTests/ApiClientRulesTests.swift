import XCTest
@testable import CabalmailKit

/// Wire-level tests for the `/get_rules` / `/set_rules` pair backing the
/// mail-rules editors (`docs/1.x/user-mail-rules-plan.md`, Phase 4).
final class ApiClientRulesTests: XCTestCase {
    private func makeConfiguration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
        )
    }

    private func makeClient(_ http: RecordingHTTPTransport) -> URLSessionApiClient {
        URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
    }

    func testListRulesDecodesWireShape() async throws {
        // Real wire shape from `lambda/api/get_rules/function.py`.
        let body = """
        {"rules":[{"id":"r-0123456789ab","name":"Receipts","enabled":true,\
        "conditions":[{"field":"subject","value":"invoice"}],"action":"move",\
        "moveFolder":"Receipts","copyFolders":[],"flag":false,"markRead":false,\
        "forward":[],"reply":false,"replyBody":"","continueToNext":false}],\
        "version":3,"updatedAt":"2026-08-25T12:00:00+00:00"}
        """
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let ruleSet = try await makeClient(http).listRules()
        XCTAssertEqual(ruleSet.version, 3)
        XCTAssertEqual(ruleSet.rules.map(\.id), ["r-0123456789ab"])
        XCTAssertEqual(ruleSet.rules.first?.action, .move)

        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertTrue(requests[0].url!.absoluteString.contains("/get_rules"))
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "idtoken")
    }

    func testListRulesEmptyUser() async throws {
        let body = #"{"rules": [], "version": 0, "updatedAt": ""}"#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let ruleSet = try await makeClient(http).listRules()
        XCTAssertEqual(ruleSet, RuleSet())
    }

    func testSetRulesPutsFullWireBody() async throws {
        let response = """
        {"rules":[{"id":"r-0123456789ab","name":"A"}],"version":4,\
        "updatedAt":"2026-08-25T12:00:01+00:00","stripped":[],"warnings":[]}
        """
        let http = RecordingHTTPTransport(responses: [(Data(response.utf8), 200)])
        let rule = Rule(
            id: "r-0123456789ab",
            name: "A",
            conditions: [Rule.Condition(field: .from, value: "aws")],
            action: .move,
            moveFolder: "Receipts"
        )
        let saved = try await makeClient(http).setRules([rule], expectedVersion: 3)
        // The 200 body's extra `stripped` / `warnings` keys must not break
        // the RuleSet decode; version propagates for the next save.
        XCTAssertEqual(saved.version, 4)

        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "PUT")
        XCTAssertTrue(requests[0].url!.absoluteString.contains("/set_rules"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(
            with: requests[0].httpBody ?? Data()
        ) as? [String: Any])
        XCTAssertEqual(payload["expectedVersion"] as? Int, 3)
        let rules = try XCTUnwrap(payload["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0]["id"] as? String, "r-0123456789ab")
        XCTAssertEqual(rules[0]["moveFolder"] as? String, "Receipts")
        let conditions = try XCTUnwrap(rules[0]["conditions"] as? [[String: Any]])
        XCTAssertEqual(conditions.first?["field"] as? String, "from")
        // Local-only condition identity must never leak onto the wire.
        XCTAssertNil(conditions.first?["id"])
    }

    func testSetRulesConflictSurfacesTypedError() async throws {
        // `set_rules` answers a lost optimistic-concurrency race with
        // 409 {"Error": ..., "version": <winner>}.
        let body = #"{"Error": "Rules changed on another device; reload.", "version": 9}"#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 409)])
        do {
            _ = try await makeClient(http).setRules([], expectedVersion: 2)
            XCTFail("expected RuleSetConflictError")
        } catch let conflict as RuleSetConflictError {
            XCTAssertEqual(conflict.serverVersion, 9)
        }
    }

    func testSetRulesValidationErrorStaysServerError() async throws {
        // A 400 (schema rejection) is not a conflict — it surfaces as the
        // regular server error carrying the Lambda's structured body.
        let body = #"{"errors": [{"rule": 0, "field": "name", "error": "Must be 1-100 characters, no control characters."}]}"#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 400)])
        do {
            _ = try await makeClient(http).setRules([Rule()], expectedVersion: 0)
            XCTFail("expected CabalmailError.server")
        } catch let CabalmailError.server(code, _) {
            XCTAssertEqual(code, "400")
        }
    }
}
