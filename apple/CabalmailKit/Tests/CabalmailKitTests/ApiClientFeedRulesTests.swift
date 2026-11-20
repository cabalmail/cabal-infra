import XCTest
@testable import CabalmailKit

/// Wire-level tests for `feedRules` on the `/get_rules` / `/set_rules` pair
/// (`docs/mail-rules.md`, "On the wire"). The point that matters most is
/// the key's presence: the server reads a request without it as "leave the
/// stored feed rules alone", an empty list as "clear them", and refuses
/// null.
final class ApiClientFeedRulesTests: XCTestCase {
    private static let reply = """
    {"rules":[],"feedRules":[{"id":"r-0123456789ab","name":"Releases","enabled":true,\
    "conditions":[{"field":"feed","value":"sub-1"}],"flag":true,"flags":[],"markRead":false}],\
    "version":4,"updatedAt":"2026-11-19T12:00:01+00:00","stripped":[],"warnings":[]}
    """

    private func makeClient(_ http: RecordingHTTPTransport) -> URLSessionApiClient {
        URLSessionApiClient(
            configuration: Configuration(
                controlDomain: "cabalmail.example",
                domains: [MailDomain(domain: "cabalmail.example")],
                invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
                cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
            ),
            authService: StubAuthService(),
            transport: http
        )
    }

    /// The JSON object of the one request `http` recorded.
    private func sentBody(_ http: RecordingHTTPTransport) async throws -> [String: Any] {
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        return try XCTUnwrap(JSONSerialization.jsonObject(
            with: requests.first?.httpBody ?? Data()
        ) as? [String: Any])
    }

    func testListRulesDecodesFeedRules() async throws {
        let http = RecordingHTTPTransport(responses: [(Data(Self.reply.utf8), 200)])
        let ruleSet = try await makeClient(http).listRules()
        XCTAssertEqual(ruleSet.feedRules.map(\.name), ["Releases"])
        XCTAssertEqual(ruleSet.feedRules.first?.feedSubscriptionID, "sub-1")
        XCTAssertEqual(ruleSet.version, 4)
    }

    /// The request a build from before feed rules sends, and the one this
    /// build sends for an edit that touched only mail rules: no `feedRules`
    /// key at all, so the stored list is left as it is.
    func testSetRulesWithNoFeedRulesLeavesTheKeyOffTheRequest() async throws {
        let http = RecordingHTTPTransport(responses: [(Data(Self.reply.utf8), 200)])
        let saved = try await makeClient(http).setRules([], feedRules: nil, expectedVersion: 3)
        let body = try await sentBody(http)
        XCTAssertEqual(Set(body.keys), ["rules", "expectedVersion"])
        // The reply still says what the row holds, and is decoded.
        XCTAssertEqual(saved.feedRules.map(\.name), ["Releases"])
    }

    func testSetRulesSendsFeedRulesBesideRules() async throws {
        let http = RecordingHTTPTransport(responses: [(Data(Self.reply.utf8), 200)])
        let rule = FeedRule(
            id: "r-0123456789ab", name: "Releases",
            conditions: [FeedRule.Condition(field: .feed, value: "sub-1")], flag: true
        )
        _ = try await makeClient(http).setRules([], feedRules: [rule], expectedVersion: 3)
        let body = try await sentBody(http)
        XCTAssertEqual(Set(body.keys), ["rules", "feedRules", "expectedVersion"])
        // `rules` is required by the server even when only feed rules change.
        XCTAssertEqual((body["rules"] as? [Any])?.count, 0)
        XCTAssertEqual(body["expectedVersion"] as? Int, 3)
        let feedRules = try XCTUnwrap(body["feedRules"] as? [[String: Any]])
        XCTAssertEqual(feedRules.count, 1)
        XCTAssertEqual(
            Set(feedRules[0].keys),
            ["id", "name", "enabled", "conditions", "flag", "flags", "markRead"]
        )
        XCTAssertEqual(feedRules[0]["id"] as? String, "r-0123456789ab")
        let conditions = try XCTUnwrap(feedRules[0]["conditions"] as? [[String: Any]])
        XCTAssertEqual(conditions.first?["field"] as? String, "feed")
        XCTAssertEqual(conditions.first?["value"] as? String, "sub-1")
        XCTAssertNil(conditions.first?["id"])
    }

    /// Deleting the last feed rule has to clear the stored list, so an
    /// empty list is sent as a list, not dropped like a nil.
    func testSetRulesSendsAnEmptyFeedRulesListAsAList() async throws {
        let http = RecordingHTTPTransport(responses: [(Data(#"{"rules":[],"version":4}"#.utf8), 200)])
        _ = try await makeClient(http).setRules([], feedRules: [], expectedVersion: 3)
        let body = try await sentBody(http)
        XCTAssertEqual((body["feedRules"] as? [Any])?.count, 0)
        XCTAssertFalse(body["feedRules"] is NSNull)
    }

    /// One version guards both lists, so a feed-rule save that loses the
    /// race gets the same typed conflict as a mail-rule save.
    func testAFeedRulesSaveConflictSurfacesTheTypedError() async throws {
        let body = #"{"Error": "Rules changed on another device; reload.", "version": 9}"#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 409)])
        do {
            _ = try await makeClient(http).setRules([], feedRules: [FeedRule()], expectedVersion: 2)
            XCTFail("expected RuleSetConflictError")
        } catch let conflict as RuleSetConflictError {
            XCTAssertEqual(conflict.serverVersion, 9)
        }
    }
}
