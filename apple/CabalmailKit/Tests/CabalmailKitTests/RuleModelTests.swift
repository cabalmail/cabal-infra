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
    "flag":true,"flags":["cabal-flag-01","cabal-flag-07"],\
    "markRead":true,"forward":["ops@example.com"],\
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
        XCTAssertEqual(rule.flags, ["cabal-flag-01", "cabal-flag-07"])
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
        XCTAssertEqual(rule.flags, [])
        XCTAssertFalse(rule.markRead)
        XCTAssertEqual(rule.forward, [])
        XCTAssertFalse(rule.reply)
        XCTAssertEqual(rule.replyBody, "")
        XCTAssertFalse(rule.continueToNext)
        // Like the server, a missing id is minted rather than left colliding.
        XCTAssertTrue(rule.id.hasPrefix("r-"))
    }

    func testDecodeKeepsUnknownFieldAndActionOpaque() {
        // This test used to assert the opposite: an unknown `field` or
        // `action` threw, so that no coerced value could be written back.
        // #1901 kept that guarantee while dropping the cost — the value
        // decodes to `.unknown`, which re-encodes verbatim and renders
        // read-only, instead of failing the whole set's decode.
        let bccRule = #"{"conditions":[{"field":"bcc","value":"x"}]}"#
        let decodedBcc = try? JSONDecoder().decode(Rule.self, from: Data(bccRule.utf8))
        XCTAssertEqual(decodedBcc?.conditions.map(\.field), [.unknown("bcc")])
        XCTAssertEqual(decodedBcc?.isEditable, false)
        let futureAction = #"{"action":"quarantine"}"#
        let decodedAction = try? JSONDecoder().decode(Rule.self, from: Data(futureAction.utf8))
        XCTAssertEqual(decodedAction?.action, .unknown("quarantine"))
        XCTAssertEqual(decodedAction?.isEditable, false)
    }

    func testEmptyFlagsStaysOffTheWireAndNonEmptyRides() throws {
        // A server predating the `flags` key rejects unknown fields, so an
        // empty list is omitted (the server defaults it to []); a non-empty
        // list — only authorable via the palette picker — rides and
        // round-trips.
        let plain = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Rule(name: "n"))) as? [String: Any]
        XCTAssertNil(plain?["flags"])

        let tagged = Rule(name: "n", flags: ["cabal-flag-03"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(tagged)) as? [String: Any])
        XCTAssertEqual(object["flags"] as? [String], ["cabal-flag-03"])
        let decoded = try JSONDecoder().decode(
            Rule.self, from: JSONEncoder().encode(tagged))
        XCTAssertEqual(decoded, tagged)
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

    func testNormalizingLegacyContinueRewritesMoveAndArchiveToCopy() {
        // Decision 2 of the rules-composition plan: move/archive + continue
        // compiles byte-identically to copy, so editors render and save the
        // Copy it is — carrying the folder over.
        var rule = Rule(name: "n", action: .move, moveFolder: "Receipts", continueToNext: true)
        var normalized = rule.normalizingLegacyContinue()
        XCTAssertEqual(normalized.action, .copy)
        XCTAssertEqual(normalized.copyFolders, ["Receipts"])
        XCTAssertTrue(normalized.continueToNext)

        // A folderless move converts to a folderless copy (the editor
        // prompts for folders either way).
        rule.moveFolder = ""
        XCTAssertEqual(rule.normalizingLegacyContinue().copyFolders, [])

        // Archive is an implicit move to `Archive`.
        rule = Rule(name: "n", action: .archive, continueToNext: true)
        normalized = rule.normalizingLegacyContinue()
        XCTAssertEqual(normalized.action, .copy)
        XCTAssertEqual(normalized.copyFolders, ["Archive"])

        // The engine ignores Continue on Delete; the flag is dropped.
        rule = Rule(name: "n", action: .delete, continueToNext: true)
        normalized = rule.normalizingLegacyContinue()
        XCTAssertEqual(normalized.action, .delete)
        XCTAssertFalse(normalized.continueToNext)
    }

    func testNormalizingLegacyContinueLeavesTerminalAndCopyRulesAlone() {
        // Terminal rules of every action are untouched, as are continuing
        // copy/none rules — normalization is exactly the legacy shapes.
        for action in Rule.Action.allCases {
            let terminal = Rule(name: "n", action: action, moveFolder: "F")
            XCTAssertEqual(terminal.normalizingLegacyContinue(), terminal)
        }
        let copy = Rule(name: "n", action: .copy, copyFolders: ["A"], continueToNext: true)
        XCTAssertEqual(copy.normalizingLegacyContinue(), copy)
        let none = Rule(name: "n", action: .none, flag: true, continueToNext: true)
        XCTAssertEqual(none.normalizingLegacyContinue(), none)
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

    // MARK: - Values newer than this build (#1901)

    /// The issue's payload: a two-rule set whose second rule carries an
    /// action this build doesn't know.
    private static let unknownActionSetJSON = """
    {"version":7,"updatedAt":"2026-10-06T00:00:00Z","rules":[\
    {"id":"r-00000000000a","name":"Known rule",\
    "conditions":[{"field":"from","value":"aws"}],"action":"archive"},\
    {"id":"r-00000000000b","name":"Newer rule",\
    "conditions":[{"field":"from","value":"ops"}],"action":"quarantine"}]}
    """

    func testUnknownActionKeepsTheRestOfTheSetReadable() throws {
        // Before #1901 the unknown raw value threw out of `[Rule]`, so the
        // whole set failed to decode and the editor showed a load error in
        // place of every rule it did understand.
        let set = try JSONDecoder().decode(
            RuleSet.self, from: Data(Self.unknownActionSetJSON.utf8)
        )
        XCTAssertEqual(set.version, 7)
        XCTAssertEqual(set.rules.map(\.name), ["Known rule", "Newer rule"])
        XCTAssertEqual(set.rules[0].action, .archive)
        XCTAssertTrue(set.rules[0].isEditable)
        XCTAssertEqual(set.rules[1].action, .unknown("quarantine"))
        XCTAssertFalse(set.rules[1].isEditable)
        XCTAssertEqual(set.rules[1].unknownWireValues, ["quarantine"])
        // Not coerced to a known action: `none` would have made a filing
        // rule stop filing on the next save.
        XCTAssertNotEqual(set.rules[1].action, Rule.Action.none)
        XCTAssertNil(Rule.Action.allCases.first { $0 == .unknown("quarantine") })
    }

    func testUnknownConditionFieldKeepsTheRestOfTheSetReadable() throws {
        let json = """
        {"version":7,"rules":[\
        {"id":"r-00000000000a","name":"Known rule",\
        "conditions":[{"field":"list_id","value":"announce"}],"action":"copy",\
        "copyFolders":["Lists"]},\
        {"id":"r-00000000000b","name":"Plain rule",\
        "conditions":[{"field":"from","value":"ops"}],"action":"copy",\
        "copyFolders":["Ops"]}]}
        """
        let set = try JSONDecoder().decode(RuleSet.self, from: Data(json.utf8))
        XCTAssertEqual(set.rules.map(\.name), ["Known rule", "Plain rule"])
        XCTAssertEqual(set.rules[0].conditions.map(\.field), [.unknown("list_id")])
        XCTAssertFalse(set.rules[0].isEditable)
        XCTAssertEqual(set.rules[0].unknownWireValues, ["list_id"])
        // The sibling rule is untouched by its neighbour's unknown field.
        XCTAssertTrue(set.rules[1].isEditable)
        XCTAssertEqual(set.rules[1].conditions.map(\.field), [.from])
        XCTAssertNil(Rule.Field.allCases.first { $0 == .unknown("list_id") })
    }

    func testUnknownValuesRoundTripVerbatim() throws {
        // The set is re-PUT whole on the next edit of any rule, so an
        // opaque rule has to go back out carrying exactly what came in.
        let set = try JSONDecoder().decode(
            RuleSet.self, from: Data(Self.unknownActionSetJSON.utf8)
        )
        var opaque = set.rules[1]
        opaque.conditions = [Rule.Condition(field: .unknown("list_id"), value: "ops")]
        let data = try JSONEncoder().encode([set.rules[0], opaque])
        let objects = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        XCTAssertEqual(objects[0]["action"] as? String, "archive")
        XCTAssertEqual(objects[1]["action"] as? String, "quarantine")
        let conditions = try XCTUnwrap(objects[1]["conditions"] as? [[String: Any]])
        XCTAssertEqual(conditions[0]["field"] as? String, "list_id")
        // And it survives the trip home again, unchanged.
        let reread = try JSONDecoder().decode([Rule].self, from: data)
        XCTAssertEqual(reread, [set.rules[0], opaque])
    }

    func testLegacyContinueNormalizationLeavesAnUnknownActionAlone() {
        // The one transformation `load()` applies to every decoded rule
        // must not touch a rule it can't read: `copy` would be a guess.
        let opaque = Rule(
            name: "Newer rule", action: .unknown("quarantine"), continueToNext: true
        )
        XCTAssertEqual(opaque.normalizingLegacyContinue(), opaque)
    }
}
