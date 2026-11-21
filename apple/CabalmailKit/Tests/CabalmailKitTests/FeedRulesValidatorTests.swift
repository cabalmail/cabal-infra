import XCTest
@testable import CabalmailKit

/// Corpus for `FeedRulesValidator`, mirroring `_normalize_feed_rules` in
/// `lambda/api/set_rules/function.py` limit for limit: a list that passes
/// here is never 400'd by the server for a reason this build can see.
final class FeedRulesValidatorTests: XCTestCase {
    /// A feed rule the server accepts untouched.
    private func validRule() -> FeedRule {
        FeedRule(
            name: "Releases",
            conditions: [
                FeedRule.Condition(field: .feed, value: "sub-1"),
                FeedRule.Condition(field: .title, value: "release"),
            ],
            flags: ["cabal-flag-03"]
        )
    }

    private func issueFields(_ rule: FeedRule) -> [String] {
        FeedRulesValidator.validate(rule).map(\.field)
    }

    func testValidRuleHasNoIssues() {
        XCTAssertEqual(FeedRulesValidator.validate([validRule()]), [])
    }

    /// The server accepts a rule with no conditions (it matches every new
    /// item) and one with no action (it does nothing); neither holds a save.
    func testNoConditionsAndNoActionAreBothAccepted() {
        XCTAssertEqual(FeedRulesValidator.validate(FeedRule(name: "New rule", enabled: false)), [])
    }

    func testEveryIssueNamesTheFeedRulesList() {
        var rule = validRule()
        rule.name = ""
        rule.flags = ["nope"]
        rule.conditions.append(FeedRule.Condition(field: .title, value: ""))
        let issues = FeedRulesValidator.validate([validRule(), rule])
        XCTAssertEqual(issues.count, 3)
        XCTAssertEqual(Set(issues.map(\.list)), ["feedRules"])
        XCTAssertEqual(Set(issues.map(\.ruleIndex)), [1])
        // Mail issues carry no list, as the server's do not.
        XCTAssertNil(RulesValidator.validate(Rule(name: "")).first?.list)
    }

    // MARK: - List

    func testAtMostAHundredFeedRules() {
        let hundred = (0..<100).map { _ in validRule() }
        XCTAssertEqual(FeedRulesValidator.validate(hundred), [])
        let issues = FeedRulesValidator.validate(hundred + [validRule()])
        XCTAssertEqual(issues.map(\.field), ["feedRules"])
        XCTAssertEqual(issues.first?.message, "At most 100 feed rules.")
        XCTAssertNil(issues.first?.ruleIndex)
    }

    // MARK: - Name

    func testNameBounds() {
        var rule = validRule()
        rule.name = ""
        XCTAssertEqual(issueFields(rule), ["name"])
        rule.name = "   "
        XCTAssertEqual(issueFields(rule), ["name"])
        rule.name = String(repeating: "x", count: 100)
        XCTAssertEqual(issueFields(rule), [])
        rule.name = String(repeating: "x", count: 101)
        XCTAssertEqual(issueFields(rule), ["name"])
        rule.name = "tab\tname"
        XCTAssertEqual(issueFields(rule), ["name"])
    }

    // MARK: - Conditions

    func testAtMostTenConditions() {
        var rule = validRule()
        rule.conditions = (0..<10).map { FeedRule.Condition(field: .title, value: "v\($0)") }
        XCTAssertEqual(issueFields(rule), [])
        rule.conditions.append(FeedRule.Condition(field: .author, value: "x"))
        XCTAssertEqual(issueFields(rule), ["conditions"])
        XCTAssertEqual(
            FeedRulesValidator.validate(rule).first?.message, "At most 10 conditions per rule."
        )
    }

    func testConditionValueBounds() {
        var rule = validRule()
        rule.conditions = [FeedRule.Condition(field: .summary, value: "")]
        XCTAssertEqual(issueFields(rule), ["conditions[0].value"])
        rule.conditions = [FeedRule.Condition(field: .summary, value: String(repeating: "x", count: 500))]
        XCTAssertEqual(issueFields(rule), [])
        rule.conditions = [FeedRule.Condition(field: .summary, value: String(repeating: "x", count: 501))]
        XCTAssertEqual(issueFields(rule), ["conditions[0].value"])
        rule.conditions = [
            FeedRule.Condition(field: .title, value: "fine"),
            FeedRule.Condition(field: .author, value: "line\nbreak"),
        ]
        XCTAssertEqual(issueFields(rule), ["conditions[1].value"])
    }

    /// Length is the server's: Python's `len()` counts code points, so a
    /// 500-scalar value of two-scalar graphemes is at the cap, not under it.
    func testConditionValueLengthCountsCodePoints() {
        var rule = validRule()
        let flag = "\u{1F1FA}\u{1F1F8}"     // one grapheme, two scalars
        rule.conditions = [FeedRule.Condition(field: .title, value: String(repeating: flag, count: 250))]
        XCTAssertEqual(issueFields(rule), [])
        rule.conditions = [FeedRule.Condition(field: .title, value: String(repeating: flag, count: 251))]
        XCTAssertEqual(issueFields(rule), ["conditions[0].value"])
    }

    /// A feed condition's value is a subscription id, held to the same
    /// shape rule as any other value: an empty one is refused.
    func testAnEmptyFeedConditionIsRefused() {
        var rule = validRule()
        rule.conditions = [FeedRule.Condition(field: .feed, value: "")]
        XCTAssertEqual(issueFields(rule), ["conditions[0].value"])
    }

    func testAtMostOneFeedCondition() {
        var rule = validRule()
        rule.conditions.append(FeedRule.Condition(field: .feed, value: "sub-2"))
        let issues = FeedRulesValidator.validate(rule)
        XCTAssertEqual(issues.map(\.field), ["conditions"])
        XCTAssertEqual(issues.first?.message, "At most one feed condition per rule.")
    }

    /// The server reports the shape errors alone when there are any, and
    /// counts the feed conditions only once they pass.
    func testShapeIssuesComeBeforeTheFeedCount() {
        var rule = validRule()
        rule.conditions = [
            FeedRule.Condition(field: .feed, value: "sub-1"),
            FeedRule.Condition(field: .feed, value: ""),
        ]
        XCTAssertEqual(issueFields(rule), ["conditions[1].value"])
    }

    // MARK: - Flags

    func testFlagSlotsShapeDuplicatesAndCount() {
        var rule = validRule()
        rule.flags = ["cabal-flag-01", "cabal-flag-20"]
        XCTAssertEqual(issueFields(rule), [])
        rule.flags = ["cabal-flag-00", "cabal-flag-21", "\\Flagged", "cabal-flag-01\n"]
        XCTAssertEqual(issueFields(rule), ["flags[0]", "flags[1]", "flags[2]", "flags[3]"])
        rule.flags = ["cabal-flag-02", "cabal-flag-02"]
        XCTAssertEqual(issueFields(rule), ["flags[1]"])
        XCTAssertEqual(FeedRulesValidator.validate(rule).first?.message, "Duplicate flag slot.")
        rule.flags = (1...20).map { String(format: "cabal-flag-%02d", $0) } + ["cabal-flag-01"]
        XCTAssertEqual(issueFields(rule), ["flags"])
    }

    // MARK: - A rule this build can't render

    /// It is saved back unchanged and the server that wrote it owns its
    /// validation, so nothing about it may hold the set's save (#1901).
    func testAnOpaqueRuleIsNeverAnIssue() {
        let opaque = FeedRule(
            name: "",
            conditions: [FeedRule.Condition(field: .unknown("category"), value: "")],
            flags: ["nope"]
        )
        XCTAssertEqual(FeedRulesValidator.validate([opaque]), [])
    }
}
