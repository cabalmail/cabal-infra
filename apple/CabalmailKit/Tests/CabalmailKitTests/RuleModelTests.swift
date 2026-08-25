import XCTest
@testable import CabalmailKit

/// Encode/decode coverage for `Rule` / `RuleSet` against the wire shape the
/// `/get_rules` and `/set_rules` Lambdas speak
/// (`lambda/api/set_rules/function.py` `DEFAULTS` is the canonical key set).
final class RuleModelTests: XCTestCase {
    /// A rule exercising every field at once.
    private static let fullRuleJSON = """
    {"id":"r-0123456789ab","name":"Receipts","enabled":true,\
    "conditions":[{"field":"subject","value":"invoice"},{"field":"from","value":"aws"}],\
    "action":"move","moveFolder":"Receipts/2026","copyFolders":["Audit"],\
    "flag":true,"markRead":true,"forward":["ops@example.com"],\
    "reply":true,"replyBody":"On vacation.","continueToNext":true}
    """

    func testDecodeFullRule() throws {
        let rule = try JSONDecoder().decode(Rule.self, from: Data(Self.fullRuleJSON.utf8))
        XCTAssertEqual(rule.id, "r-0123456789ab")
        XCTAssertEqual(rule.name, "Receipts")
        XCTAssertTrue(rule.enabled)
        XCTAssertEqual(rule.conditions.map(\.field), [.subject, .from])
        XCTAssertEqual(rule.conditions.map(\.value), ["invoice", "aws"])
        XCTAssertEqual(rule.action, .move)
        XCTAssertEqual(rule.moveFolder, "Receipts/2026")
        XCTAssertEqual(rule.copyFolders, ["Audit"])
        XCTAssertTrue(rule.flag)
        XCTAssertTrue(rule.markRead)
        XCTAssertEqual(rule.forward, ["ops@example.com"])
        XCTAssertTrue(rule.reply)
        XCTAssertEqual(rule.replyBody, "On vacation.")
        XCTAssertTrue(rule.continueToNext)
    }

    func testRoundTripPreservesEveryActionAndField() throws {
        // Every destination action crossed with every condition field — the
        // whole enum surface must survive a round trip byte-exactly.
        for action in Rule.Action.allCases {
            for field in Rule.Field.allCases {
                let original = Rule(
                    name: "\(action.rawValue)-\(field.rawValue)",
                    conditions: [Rule.Condition(field: field, value: "x")],
                    action: action
                )
                let data = try JSONEncoder().encode(original)
                let decoded = try JSONDecoder().decode(Rule.self, from: data)
                XCTAssertEqual(decoded, original)
            }
        }
    }

    func testEncodedRuleCarriesEveryWireKey() throws {
        // The Lambda replaces the whole row per save; a dropped key would
        // read back as its default and silently reset that setting.
        let data = try JSONEncoder().encode(Rule(name: "n"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let expected: Set<String> = [
            "id", "name", "enabled", "conditions", "action", "moveFolder",
            "copyFolders", "flag", "markRead", "forward", "reply", "replyBody",
            "continueToNext",
        ]
        XCTAssertEqual(Set(object.keys), expected)
    }

    func testDecodeAppliesLambdaDefaultsForMissingKeys() throws {
        // Absent keys read as the same defaults the Lambda's normalizer
        // fills in, so a minimal or older row never fails the whole set.
        let rule = try JSONDecoder().decode(Rule.self, from: Data("{}".utf8))
        XCTAssertEqual(rule.name, "")
        XCTAssertTrue(rule.enabled)
        XCTAssertEqual(rule.conditions, [])
        XCTAssertEqual(rule.action, .none)
        XCTAssertEqual(rule.moveFolder, "")
        XCTAssertEqual(rule.copyFolders, [])
        XCTAssertFalse(rule.flag)
        XCTAssertFalse(rule.markRead)
        XCTAssertEqual(rule.forward, [])
        XCTAssertFalse(rule.reply)
        XCTAssertEqual(rule.replyBody, "")
        XCTAssertFalse(rule.continueToNext)
        // Like the server, a missing id is minted rather than left colliding.
        XCTAssertTrue(rule.id.hasPrefix("r-"))
    }

    func testDecodeRejectsUnknownFieldAndAction() {
        // A `bcc` condition or a future action must fail the decode rather
        // than be silently coerced (and rewritten on the next save).
        let bccRule = #"{"conditions":[{"field":"bcc","value":"x"}]}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(Rule.self, from: Data(bccRule.utf8))
        )
        let futureAction = #"{"action":"quarantine"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(Rule.self, from: Data(futureAction.utf8))
        )
    }

    func testConditionIdentityIsLocalOnly() throws {
        // The wire has no condition id: it must not be encoded, and equality
        // must compare content so decoded sets equal their re-decodes.
        let condition = Rule.Condition(field: .from, value: "aws")
        let data = try JSONEncoder().encode(condition)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["field", "value"])
        let decodedTwice = try (
            JSONDecoder().decode(Rule.Condition.self, from: data),
            JSONDecoder().decode(Rule.Condition.self, from: data)
        )
        XCTAssertEqual(decodedTwice.0, decodedTwice.1)
        XCTAssertNotEqual(decodedTwice.0.id, decodedTwice.1.id)
    }

    func testRuleSetDecodesWireShapeAndDefaults() throws {
        let body = """
        {"rules":[{"id":"r-0123456789ab","name":"A"}],"version":7,\
        "updatedAt":"2026-08-25T00:00:00+00:00"}
        """
        let ruleSet = try JSONDecoder().decode(RuleSet.self, from: Data(body.utf8))
        XCTAssertEqual(ruleSet.rules.count, 1)
        XCTAssertEqual(ruleSet.version, 7)
        XCTAssertEqual(ruleSet.updatedAt, "2026-08-25T00:00:00+00:00")

        // A user with no saved row: `{rules: [], version: 0, updatedAt: ""}`
        // per `lambda/api/get_rules/function.py` — and a fully-empty body
        // reads the same rather than erroring.
        let empty = try JSONDecoder().decode(RuleSet.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, RuleSet())
    }

    func testMintIDMatchesServerFormat() {
        // The Lambda keeps client ids matching ^r-[0-9a-f]{12}$ and re-mints
        // anything else; a drifting local format would re-id every rule on
        // each save (breaking stable editing).
        for _ in 0..<100 {
            let id = Rule.mintID()
            XCTAssertEqual(id.count, 14)
            XCTAssertTrue(id.hasPrefix("r-"))
            XCTAssertTrue(id.dropFirst(2).allSatisfy { "0123456789abcdef".contains($0) })
        }
        XCTAssertNotEqual(Rule.mintID(), Rule.mintID())
    }
}
