import XCTest
@testable import CabalmailKit

/// Encode/decode coverage for `FeedRule` and `RuleSet.feedRules` against the
/// wire shape `/get_rules` and `/set_rules` speak
/// (`lambda/api/set_rules/function.py`: `FEED_DEFAULTS` is the canonical
/// key set and `FEED_FIELDS` the condition fields).
final class FeedRuleModelTests: XCTestCase {
    /// The example in `docs/mail-rules.md`, "On the wire".
    private static let ruleJSON = """
    {"id":"r-0123456789ab","name":"Releases","enabled":true,\
    "conditions":[{"field":"feed","value":"sub-1"},{"field":"title","value":"release"}],\
    "flag":false,"flags":["cabal-flag-03"],"markRead":true}
    """

    private func decode(_ json: String) throws -> FeedRule {
        try JSONDecoder().decode(FeedRule.self, from: Data(json.utf8))
    }

    private func wireObject(_ rule: FeedRule) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
    }

    func testDecodeFullRule() throws {
        let rule = try decode(Self.ruleJSON)
        XCTAssertEqual(rule.id, "r-0123456789ab")
        XCTAssertEqual(rule.name, "Releases")
        XCTAssertTrue(rule.enabled)
        XCTAssertEqual(rule.conditions.map(\.field), [.feed, .title])
        XCTAssertEqual(rule.conditions.map(\.value), ["sub-1", "release"])
        XCTAssertFalse(rule.flag)
        XCTAssertEqual(rule.flags, ["cabal-flag-03"])
        XCTAssertTrue(rule.markRead)
        XCTAssertTrue(rule.isEditable)
    }

    func testMissingKeysReadAsTheServersDefaults() throws {
        // `FEED_DEFAULTS`: enabled true, everything else empty or false.
        let rule = try decode(#"{"id":"r-0123456789ab"}"#)
        XCTAssertEqual(rule.name, "")
        XCTAssertTrue(rule.enabled)
        XCTAssertEqual(rule.conditions, [])
        XCTAssertFalse(rule.flag)
        XCTAssertEqual(rule.flags, [])
        XCTAssertFalse(rule.markRead)
    }

    /// The server refuses any key outside its seven, so what the encoder
    /// writes is the contract: exactly those keys, and a condition's local
    /// `id` never among them.
    func testEncodesExactlyTheServersKeys() throws {
        let object = try wireObject(try decode(Self.ruleJSON))
        XCTAssertEqual(
            Set(object.keys),
            ["id", "name", "enabled", "conditions", "flag", "flags", "markRead"]
        )
        let conditions = try XCTUnwrap(object["conditions"] as? [[String: Any]])
        XCTAssertEqual(conditions.map { Set($0.keys) }, [["field", "value"], ["field", "value"]])
        XCTAssertEqual(conditions.map { $0["field"] as? String }, ["feed", "title"])
    }

    /// A rule with nothing set still writes every key: unlike a mail rule's
    /// `flags`, no server that takes `feedRules` lacks one of them.
    func testABlankRuleStillEncodesEveryKey() throws {
        let object = try wireObject(FeedRule(name: "New rule", enabled: false))
        XCTAssertEqual(object["flags"] as? [String], [])
        XCTAssertEqual(object["flag"] as? Bool, false)
        XCTAssertEqual(object["markRead"] as? Bool, false)
        XCTAssertEqual(object["enabled"] as? Bool, false)
        XCTAssertEqual((object["conditions"] as? [Any])?.count, 0)
    }

    func testRoundTripPreservesEveryField() throws {
        for field in FeedRule.Field.allCases {
            let original = FeedRule(
                name: field.rawValue,
                enabled: false,
                conditions: [FeedRule.Condition(field: field, value: "x")],
                flag: true,
                flags: ["cabal-flag-20"],
                markRead: true
            )
            let decoded = try JSONDecoder().decode(FeedRule.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(decoded, original)
        }
    }

    func testFieldWireValuesAreTheServers() {
        XCTAssertEqual(FeedRule.Field.allCases.map(\.rawValue), ["feed", "title", "author", "summary"])
        XCTAssertEqual(FeedRule.Field.textCases.map(\.rawValue), ["title", "author", "summary"])
    }

    // MARK: - A field this build doesn't know

    func testUnknownFieldKeepsTheRuleOpaqueAndReEmitsIt() throws {
        let json = """
        {"id":"r-0123456789ab","name":"Later","enabled":true,\
        "conditions":[{"field":"category","value":"news"}],\
        "flag":true,"flags":[],"markRead":false}
        """
        let rule = try decode(json)
        XCTAssertEqual(rule.conditions.first?.field, .unknown("category"))
        XCTAssertEqual(rule.unknownWireValues, ["category"])
        XCTAssertFalse(rule.isEditable)
        // No picker offers the unknown field.
        XCTAssertFalse(FeedRule.Field.allCases.contains(.unknown("category")))
        // Saved back as it came.
        let conditions = try XCTUnwrap(try wireObject(rule)["conditions"] as? [[String: Any]])
        XCTAssertEqual(conditions.first?["field"] as? String, "category")
        XCTAssertEqual(conditions.first?["value"] as? String, "news")
    }

    /// One unreadable rule must not cost the editor the whole set (#1901).
    func testASetWithAnUnknownFeedFieldStillDecodes() throws {
        let json = """
        {"rules":[{"id":"r-aaaaaaaaaaaa","name":"Mail"}],\
        "feedRules":[{"id":"r-bbbbbbbbbbbb","name":"Odd",\
        "conditions":[{"field":"category","value":"x"}]},\
        {"id":"r-cccccccccccc","name":"Plain"}],"version":3}
        """
        let ruleSet = try JSONDecoder().decode(RuleSet.self, from: Data(json.utf8))
        XCTAssertEqual(ruleSet.rules.map(\.name), ["Mail"])
        XCTAssertEqual(ruleSet.feedRules.map(\.name), ["Odd", "Plain"])
        XCTAssertEqual(ruleSet.feedRules.map(\.isEditable), [false, true])
    }

    // MARK: - RuleSet

    func testRuleSetDecodesFeedRulesBesideRules() throws {
        let json = """
        {"rules":[],"feedRules":[\(Self.ruleJSON)],"version":4,\
        "updatedAt":"2026-11-19T12:00:00+00:00"}
        """
        let ruleSet = try JSONDecoder().decode(RuleSet.self, from: Data(json.utf8))
        XCTAssertEqual(ruleSet.feedRules.map(\.name), ["Releases"])
        XCTAssertEqual(ruleSet.version, 4)
    }

    /// A server from before feed rules answers no `feedRules` key.
    func testRuleSetWithoutTheKeyHasNoFeedRules() throws {
        let ruleSet = try JSONDecoder().decode(
            RuleSet.self, from: Data(#"{"rules":[],"version":2}"#.utf8)
        )
        XCTAssertEqual(ruleSet.feedRules, [])
        XCTAssertEqual(ruleSet.version, 2)
    }

    // MARK: - The feed a rule is limited to

    func testFeedSubscriptionIDReadsTheFeedCondition() throws {
        XCTAssertEqual(try decode(Self.ruleJSON).feedSubscriptionID, "sub-1")
        XCTAssertNil(FeedRule(conditions: [FeedRule.Condition(field: .title, value: "x")])
            .feedSubscriptionID)
    }

    func testSettingAFeedAddsOneConditionAtTheHead() {
        var rule = FeedRule(conditions: [FeedRule.Condition(field: .title, value: "x")])
        rule.feedSubscriptionID = "sub-2"
        XCTAssertEqual(rule.conditions.map(\.field), [.feed, .title])
        XCTAssertEqual(rule.conditions.first?.value, "sub-2")
    }

    /// Changing the feed must rewrite the one condition, never add a second:
    /// the server refuses two.
    func testChangingTheFeedRewritesTheConditionInPlace() {
        var rule = FeedRule(conditions: [
            FeedRule.Condition(field: .title, value: "x"),
            FeedRule.Condition(field: .feed, value: "sub-1"),
        ])
        rule.feedSubscriptionID = "sub-2"
        XCTAssertEqual(rule.conditions.map(\.field), [.title, .feed])
        XCTAssertEqual(rule.conditions.map(\.value), ["x", "sub-2"])
    }

    func testClearingTheFeedRemovesItsConditionAndKeepsTheOthers() {
        var rule = FeedRule(conditions: [
            FeedRule.Condition(field: .feed, value: "sub-1"),
            FeedRule.Condition(field: .author, value: "sam"),
        ])
        rule.feedSubscriptionID = nil
        XCTAssertEqual(rule.conditions.map(\.field), [.author])
        XCTAssertNil(rule.feedSubscriptionID)
    }

    func testHasActionIsAnyOfTheThreeMarks() {
        XCTAssertFalse(FeedRule().hasAction)
        XCTAssertTrue(FeedRule(flag: true).hasAction)
        XCTAssertTrue(FeedRule(flags: ["cabal-flag-01"]).hasAction)
        XCTAssertTrue(FeedRule(markRead: true).hasAction)
    }

    func testANewRuleMintsAnIDInTheServersFormat() {
        let id = FeedRule().id
        XCTAssertNotNil(id.range(of: #"^r-[0-9a-f]{12}$"#, options: .regularExpression))
    }
}
