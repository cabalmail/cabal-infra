import XCTest
@testable import CabalmailKit

/// Corpus for `RulesValidator`, mirroring the checks in
/// `lambda/api/set_rules/function.py` — the aim is that a set passing the
/// client validator is never 400'd (or silently stripped) by the server.
final class RulesValidatorTests: XCTestCase {
    /// A rule the server accepts untouched.
    private func validRule() -> Rule {
        Rule(
            name: "Receipts",
            conditions: [Rule.Condition(field: .subject, value: "invoice")],
            action: .move,
            moveFolder: "Receipts",
            forward: ["ops@example.com"]
        )
    }

    private func issueFields(_ rule: Rule) -> [String] {
        RulesValidator.validate(rule).map(\.field)
    }

    func testValidRuleHasNoIssues() {
        XCTAssertEqual(RulesValidator.validate([validRule()]), [])
    }

    // MARK: - Name

    func testNameBounds() {
        var rule = validRule()
        rule.name = ""
        XCTAssertEqual(issueFields(rule), ["name"])
        rule.name = "   "                       // trims to empty, like .strip()
        XCTAssertEqual(issueFields(rule), ["name"])
        rule.name = String(repeating: "x", count: 100)
        XCTAssertEqual(issueFields(rule), [])
        rule.name = String(repeating: "x", count: 101)
        XCTAssertEqual(issueFields(rule), ["name"])
        rule.name = "tab\tname"                 // control character
        XCTAssertEqual(issueFields(rule), ["name"])
        rule.name = "emoji 📬 fine"             // printable Unicode is allowed
        XCTAssertEqual(issueFields(rule), [])
    }

    // MARK: - Conditions

    func testConditionValueBounds() {
        var rule = validRule()
        rule.conditions = [Rule.Condition(field: .from, value: "")]
        XCTAssertEqual(issueFields(rule), ["conditions[0].value"])
        rule.conditions = [Rule.Condition(field: .from, value: String(repeating: "v", count: 500))]
        XCTAssertEqual(issueFields(rule), [])
        rule.conditions = [Rule.Condition(field: .from, value: String(repeating: "v", count: 501))]
        XCTAssertEqual(issueFields(rule), ["conditions[0].value"])
        rule.conditions = [Rule.Condition(field: .from, value: "nul\u{0}byte")]
        XCTAssertEqual(issueFields(rule), ["conditions[0].value"])
        // Injection-corpus flavors are data here, not syntax: the client only
        // enforces the character class, the compiler escapes the rest.
        rule.conditions = [Rule.Condition(field: .body, value: "; rm -rf / $(x) `y` |z")]
        XCTAssertEqual(issueFields(rule), [])
    }

    func testConditionCountCap() {
        var rule = validRule()
        rule.conditions = (0..<11).map { Rule.Condition(field: .from, value: "v\($0)") }
        XCTAssertEqual(issueFields(rule), ["conditions"])
        // An empty conditions list is valid (matches every message).
        rule.conditions = []
        XCTAssertEqual(issueFields(rule), [])
    }

    // MARK: - Folders

    func testMoveFolderRules() {
        var rule = validRule()
        rule.moveFolder = ""                    // destination not picked yet: allowed
        XCTAssertEqual(issueFields(rule), [])
        for hostile in ["a|b", "a>b", "a`b", "/abs", "up/../and-over", "nl\nfolder"] {
            rule.moveFolder = hostile
            XCTAssertEqual(issueFields(rule), ["moveFolder"], "expected rejection for \(hostile)")
        }
        rule.moveFolder = String(repeating: "f", count: 256)
        XCTAssertEqual(issueFields(rule), ["moveFolder"])
        rule.moveFolder = "Parent/Child"        // display-form path is the wire format
        XCTAssertEqual(issueFields(rule), [])
    }

    func testCopyFolderRules() {
        var rule = validRule()
        rule.action = .copy
        rule.moveFolder = ""
        rule.copyFolders = ["Audit", "Receipts/2026"]
        XCTAssertEqual(issueFields(rule), [])
        rule.copyFolders = [""]                 // unlike moveFolder, empty is an error
        XCTAssertEqual(issueFields(rule), ["copyFolders[0]"])
        rule.copyFolders = ["ok", "bad|pipe"]
        XCTAssertEqual(issueFields(rule), ["copyFolders[1]"])
        rule.copyFolders = (0..<11).map { "F\($0)" }
        XCTAssertEqual(issueFields(rule), ["copyFolders"])
    }

    // MARK: - Forward addresses

    func testForwardAddressShapes() {
        for valid in [
            "a@b.co", "user+tag@mail.example.com", "x@sub.domain.example",
            "weird!#$%@host.tld",
        ] {
            XCTAssertTrue(RulesValidator.isValidForwardAddress(valid), valid)
        }
        for invalid in [
            "", "plain", "@example.com", "user@", "user@nodot", "two@@at.com",
            "spaced user@example.com", "user@exa mple.com", "user@.com",
            "user@com.", "a@b@c.com", "ctrl\u{1}@example.com",
            String(repeating: "a", count: 315) + "@x.com",   // 321 > 320 cap
        ] {
            XCTAssertFalse(RulesValidator.isValidForwardAddress(invalid), invalid)
        }
    }

    func testForwardListIssues() {
        var rule = validRule()
        rule.forward = ["ok@example.com", "not-an-email"]
        XCTAssertEqual(issueFields(rule), ["forward[1]"])
        rule.forward = (0..<11).map { "user\($0)@example.com" }
        XCTAssertEqual(issueFields(rule), ["forward"])
    }

    // MARK: - Reply

    func testReplyBodyRules() {
        var rule = validRule()
        rule.reply = true
        rule.replyBody = ""
        XCTAssertEqual(issueFields(rule), ["replyBody"])
        rule.replyBody = "Away until Monday.\nBack then."   // newlines allowed
        XCTAssertEqual(issueFields(rule), [])
        rule.replyBody = "CR\r\nis a control"                // \r is not
        XCTAssertEqual(issueFields(rule), ["replyBody"])
        rule.replyBody = String(repeating: "b", count: 4001)
        XCTAssertEqual(issueFields(rule), ["replyBody"])
        // Body length caps count code points like the server's len(), not
        // grapheme clusters: 2001 combining sequences (e + U+0301) are 2001
        // characters to Swift but 4002 code points to the server.
        rule.replyBody = String(repeating: "e\u{301}", count: 2001)
        XCTAssertEqual(issueFields(rule), ["replyBody"])
        rule.reply = false
        rule.replyBody = ""                     // not required when reply is off
        XCTAssertEqual(issueFields(rule), [])
    }

    // MARK: - Custom-flag slots

    func testRuleFlagsShapeIssues() {
        var rule = validRule()
        rule.flags = ["cabal-flag-01", "cabal-flag-20"]
        XCTAssertEqual(issueFields(rule), [])
        rule.flags = ["cabal-flag-21"]
        XCTAssertEqual(issueFields(rule), ["flags[0]"])
        rule.flags = ["cabal-flag-01", "cabal-flag-01"]
        XCTAssertEqual(issueFields(rule), ["flags[1]"])
        rule.flags = ["not-a-slot"]
        XCTAssertEqual(issueFields(rule), ["flags[0]"])
        rule.flags = (1...20).map { String(format: "cabal-flag-%02d", $0) }
        XCTAssertEqual(issueFields(rule), [])
    }

    func testCustomFlagsGiveAContinuingRuleAnEffect() {
        var rule = validRule()
        rule.action = .none
        rule.moveFolder = ""
        rule.forward = []
        rule.continueToNext = true
        rule.flags = ["cabal-flag-01"]
        XCTAssertFalse(RulesValidator.hasNoEffect(rule))
        XCTAssertEqual(issueFields(rule), [])
    }

    // MARK: - No-effect rules (client-strict; the server stays permissive)

    func testContinuingRuleWithoutAnEffectIsAnIssue() {
        // Destination None + Continue + nothing outbound compiles to an
        // empty procmail block (`no_effect`) and would silently evaporate.
        var rule = validRule()
        rule.action = .none
        rule.moveFolder = ""
        rule.forward = []
        rule.continueToNext = true
        XCTAssertTrue(RulesValidator.hasNoEffect(rule))
        XCTAssertEqual(issueFields(rule), ["continueToNext"])

        // A continuing copy with no folders picked yet is the same trap.
        rule = validRule()
        rule.action = .copy
        rule.moveFolder = ""
        rule.forward = []
        rule.copyFolders = []
        rule.continueToNext = true
        XCTAssertEqual(issueFields(rule), ["continueToNext"])
    }

    func testEffectfulAndTerminalRulesAreNotNoEffect() {
        // Flag / mark-as-read decorate: the compiler's pending state
        // (rules-composition plan, decision 3) carries them into whatever
        // delivery ends up happening, so a decorate-only rule is saveable.
        var rule = validRule()
        rule.action = .none
        rule.moveFolder = ""
        rule.forward = []
        rule.continueToNext = true
        rule.flag = true
        XCTAssertEqual(issueFields(rule), [])
        rule.flag = false
        rule.markRead = true
        XCTAssertEqual(issueFields(rule), [])
        rule.markRead = false

        // Forward or reply gives a continuing None rule an effect.
        rule.forward = ["ops@example.com"]
        XCTAssertEqual(issueFields(rule), [])
        rule.forward = []
        rule.reply = true
        rule.replyBody = "Away."
        XCTAssertEqual(issueFields(rule), [])

        // A terminal None rule stops processing — that is an effect.
        rule = validRule()
        rule.action = .none
        rule.moveFolder = ""
        rule.forward = []
        rule.continueToNext = false
        XCTAssertEqual(issueFields(rule), [])

        // A continuing copy with folders delivers.
        rule.action = .copy
        rule.copyFolders = ["Audit"]
        rule.continueToNext = true
        XCTAssertEqual(issueFields(rule), [])
    }

    // MARK: - Set level

    func testRuleCountCap() {
        let many = (0..<101).map { Rule(name: "r\($0)") }
        let issues = RulesValidator.validate(many)
        XCTAssertTrue(issues.contains(
            RulesValidator.Issue(ruleIndex: nil, field: "rules", message: "At most 100 rules.")
        ))
        XCTAssertEqual(RulesValidator.validate(Array(many.prefix(100))), [])
    }

    func testIssuesCarryRuleIndex() {
        var second = validRule()
        second.name = ""
        let issues = RulesValidator.validate([validRule(), second])
        XCTAssertEqual(issues.map(\.ruleIndex), [1])
    }
}
