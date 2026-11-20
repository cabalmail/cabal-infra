import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The feed list's own edits (`FeedRulesEditor` over `RuleList`), the row
/// summary, the template and the editor's footers. The save path these
/// edits feed is `FeedRulesViewModelTests`'.
@MainActor
final class FeedRulesEditorTests: XCTestCase {
    /// An editor holding `rules` as the server's list, counting the edits
    /// it reports.
    private func makeEditor(_ rules: [FeedRule] = []) -> (FeedRulesEditor, () -> Int) {
        let editor = FeedRulesEditor()
        editor.load(rules)
        var changes = 0
        editor.onChange = { changes += 1 }
        return (editor, { changes })
    }

    private func rule(_ name: String) -> FeedRule {
        FeedRule(name: name, conditions: [FeedRule.Condition(field: .title, value: "x")], flag: true)
    }

    private func opaqueRule() -> FeedRule {
        FeedRule(
            name: "Later",
            conditions: [FeedRule.Condition(field: .unknown("category"), value: "news")],
            flag: true
        )
    }

    // MARK: - Edits

    /// A blank rule has no conditions, so it matches every new item in
    /// every feed, and it is saved within a debounce of being added. It
    /// arrives switched off, as a blank mail rule does (#2031).
    func testABlankFeedRuleIsAddedDisabled() throws {
        let (editor, changes) = makeEditor()
        let id = try XCTUnwrap(editor.add())
        let added = try XCTUnwrap(editor.rule(withID: id))
        XCTAssertFalse(added.enabled)
        XCTAssertEqual(added.name, "New rule")
        XCTAssertEqual(added.conditions, [])
        XCTAssertEqual(changes(), 1)
        XCTAssertTrue(editor.hasUnsavedChanges)
    }

    func testAddRefusesBeyondTheServersCap() {
        let (editor, changes) = makeEditor((0..<100).map { rule("r\($0)") })
        XCTAssertTrue(editor.isFull)
        XCTAssertNil(editor.add())
        XCTAssertNil(editor.duplicate(editor.rules[0].id))
        XCTAssertEqual(editor.rules.count, 100)
        XCTAssertEqual(changes(), 0)
    }

    func testListEdits() throws {
        let (editor, changes) = makeEditor([rule("A"), rule("B"), rule("C")])
        let ids = editor.rules.map(\.id)

        let copyID = try XCTUnwrap(editor.duplicate(ids[0]))
        XCTAssertEqual(editor.rules.map(\.name), ["A", "A copy", "B", "C"])
        XCTAssertNotEqual(copyID, ids[0])
        XCTAssertNotNil(copyID.range(of: #"^r-[0-9a-f]{12}$"#, options: .regularExpression))

        editor.delete(id: copyID)
        XCTAssertEqual(editor.rules.map(\.name), ["A", "B", "C"])

        editor.move(id: ids[2], by: -1)
        XCTAssertEqual(editor.rules.map(\.name), ["A", "C", "B"])
        editor.move(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(editor.rules.map(\.name), ["C", "B", "A"])

        editor.setEnabled(ids[1], false)
        XCTAssertEqual(editor.rule(withID: ids[1])?.enabled, false)

        editor.delete(at: IndexSet(integer: 0))
        XCTAssertEqual(editor.rules.map(\.name), ["B", "A"])
        XCTAssertEqual(changes(), 6)
    }

    /// An edit that changes nothing, or names a rule that is gone, is not a
    /// change: no save is asked for.
    func testEditsThatChangeNothingReportNothing() {
        let (editor, changes) = makeEditor([rule("A"), rule("B")])
        let ids = editor.rules.map(\.id)
        editor.update(editor.rules[0])
        editor.setEnabled(ids[0], true)
        editor.move(id: ids[0], by: -1)
        editor.move(id: ids[1], by: 1)
        editor.move(id: ids[0], by: 0)
        editor.delete(id: "r-000000000000")
        editor.update(rule("Stranger"))
        XCTAssertEqual(editor.rules.map(\.name), ["A", "B"])
        XCTAssertEqual(changes(), 0)
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertFalse(editor.canMove(id: ids[0], by: -1))
        XCTAssertTrue(editor.canMove(id: ids[0], by: 1))
        XCTAssertFalse(editor.canMove(id: ids[1], by: 1))
    }

    /// Putting an edit back leaves the list as the server holds it, so the
    /// next save has no feed rules to send.
    func testUndoingAnEditLeavesNothingUnsaved() throws {
        let (editor, _) = makeEditor([rule("A")])
        var edited = try XCTUnwrap(editor.rules.first)
        edited.markRead = true
        editor.update(edited)
        XCTAssertTrue(editor.hasUnsavedChanges)
        edited.markRead = false
        editor.update(edited)
        XCTAssertFalse(editor.hasUnsavedChanges)
    }

    // MARK: - A rule this build can't render (#1901)

    func testAnOpaqueFeedRuleIsNeverRewrittenOrCopied() throws {
        let (editor, changes) = makeEditor([opaqueRule(), rule("Plain")])
        let id = editor.rules[0].id
        var edited = editor.rules[0]
        edited.name = "Renamed"
        edited.conditions = []
        editor.update(edited)
        editor.setEnabled(id, false)
        XCTAssertNil(editor.duplicate(id))
        XCTAssertEqual(editor.rules[0], opaqueRuleWith(id: id))
        XCTAssertEqual(changes(), 0)

        // Reorder and delete rewrite nothing, so both still apply.
        editor.move(id: id, by: 1)
        XCTAssertEqual(editor.rules.map(\.name), ["Plain", "Later"])
        editor.delete(id: id)
        XCTAssertEqual(editor.rules.map(\.name), ["Plain"])
        XCTAssertEqual(changes(), 2)
    }

    private func opaqueRuleWith(id: String) -> FeedRule {
        var rule = opaqueRule()
        rule.id = id
        return rule
    }

    func testSummaryNamesWhatAnOpaqueFeedRuleUses() {
        let summary = FeedRuleSummary.describe(opaqueRule(), feedTitle: nil)
        XCTAssertTrue(summary.contains("category"))
        XCTAssertTrue(summary.contains("kept unchanged"))
    }

    // MARK: - The server's answer

    func testAdoptTakesTheServersListWhenNothingChangedMidFlight() {
        let (editor, _) = makeEditor()
        let local = rule("A")
        editor.add(local)
        var canonical = local
        canonical.id = "r-0123456789ab"       // an id the server re-minted
        editor.adopt(saved: [canonical], sentAs: [local])
        XCTAssertEqual(editor.rules.map(\.id), ["r-0123456789ab"])
        XCTAssertFalse(editor.hasUnsavedChanges)
    }

    func testAdoptKeepsAnEditMadeMidFlightAndLeavesItUnsaved() {
        let (editor, _) = makeEditor()
        let first = rule("A")
        editor.add(first)
        let sent = editor.rules
        editor.add(rule("B"))
        editor.adopt(saved: [first], sentAs: sent)
        XCTAssertEqual(editor.rules.map(\.name), ["A", "B"])
        XCTAssertTrue(editor.hasUnsavedChanges)
    }

    // MARK: - Summary

    func testSummaryReadsScopeConditionsAndActions() {
        var rule = FeedRule(
            name: "Releases",
            conditions: [
                FeedRule.Condition(field: .feed, value: "sub-1"),
                FeedRule.Condition(field: .title, value: "release"),
                FeedRule.Condition(field: .author, value: "sam"),
            ],
            flag: true, flags: ["cabal-flag-03"], markRead: true
        )
        XCTAssertEqual(
            FeedRuleSummary.describe(rule, feedTitle: "Swift Blog"),
            "Title contains “release” + 1 more in Swift Blog · flag · 1 custom flag · mark read"
        )
        // A feed this device can't name is still said to be one feed, not
        // every feed.
        XCTAssertTrue(FeedRuleSummary.describe(rule, feedTitle: nil).contains("in one feed"))

        rule.conditions = [FeedRule.Condition(field: .feed, value: "sub-1")]
        XCTAssertTrue(
            FeedRuleSummary.describe(rule, feedTitle: "Swift Blog").hasPrefix("Every new item in Swift Blog")
        )
        rule.conditions = []
        XCTAssertTrue(FeedRuleSummary.describe(rule, feedTitle: nil).hasPrefix("Every new item · "))
    }

    func testSummarySaysWhenARuleDoesNothing() {
        let idle = FeedRule(name: "New rule", enabled: false)
        XCTAssertEqual(FeedRuleSummary.describe(idle, feedTitle: nil), "Every new item · no action yet")
        XCTAssertFalse(FeedRuleSummary.describe(rule("A"), feedTitle: nil).contains("no action"))
    }

    // MARK: - Template

    /// The template arrives switched off and is one the server takes as it
    /// is, so adding it saves cleanly before the user has touched it.
    func testTheFeedTemplateIsDisabledValidAndFlags() throws {
        let template = RuleTemplates.flagMatchingItems()
        XCTAssertFalse(template.enabled)
        XCTAssertTrue(template.flag)
        XCTAssertNil(template.feedSubscriptionID)
        XCTAssertEqual(template.conditions.map(\.field), [.title])
        XCTAssertEqual(FeedRulesValidator.validate([template]), [])

        let (editor, _) = makeEditor()
        let id = try XCTUnwrap(editor.add(template))
        XCTAssertEqual(editor.rule(withID: id), template)
    }

    // MARK: - The editor's footers

    func testScopeFooterSaysWhichFeedsAndFlagsAFeedThatIsGone() {
        let subscriptions = [RssSubscription(subscriptionId: "sub-1", feedId: "f1")]
        var rule = FeedRule(name: "A")
        XCTAssertTrue(
            FeedRuleEditorText.scopeFooter(for: rule, subscriptions: subscriptions).contains("every feed")
        )
        rule.feedSubscriptionID = "sub-1"
        XCTAssertTrue(
            FeedRuleEditorText.scopeFooter(for: rule, subscriptions: subscriptions).contains("this feed only")
        )
        rule.feedSubscriptionID = "gone"
        XCTAssertTrue(
            FeedRuleEditorText.scopeFooter(for: rule, subscriptions: subscriptions)
                .contains("no longer subscribe")
        )
        // No subscriptions at all usually means they haven't loaded here:
        // the footer must not call the rule's feed unsubscribed.
        XCTAssertFalse(
            FeedRuleEditorText.scopeFooter(for: rule, subscriptions: []).contains("no longer subscribe")
        )
    }

    func testConditionsFooterTreatsTheFeedAsScopeNotAsACondition() {
        var rule = FeedRule(name: "A")
        XCTAssertTrue(FeedRuleEditorText.conditionsFooter(for: rule).contains("every new item in every feed"))
        rule.feedSubscriptionID = "sub-1"
        XCTAssertTrue(FeedRuleEditorText.conditionsFooter(for: rule).contains("every new item in this feed"))
        rule.conditions.append(FeedRule.Condition(field: .summary, value: "x"))
        XCTAssertTrue(FeedRuleEditorText.conditionsFooter(for: rule).hasPrefix("All conditions must match"))
    }

    func testActionsFooterWarnsOfADeletedFlagThenOfNoAction() {
        let idle = FeedRule(name: "A")
        XCTAssertTrue(
            FeedRuleEditorText.actionsFooter(for: idle, hasDeletedFlag: false).contains("does nothing yet")
        )
        XCTAssertTrue(
            FeedRuleEditorText.actionsFooter(for: rule("A"), hasDeletedFlag: true).contains("was deleted")
        )
        XCTAssertTrue(
            FeedRuleEditorText.actionsFooter(for: rule("A"), hasDeletedFlag: false).hasPrefix("Applied once")
        )
    }

    /// The flag switches both editors draw: the palette's slots in its
    /// order, then any slot the rule sets whose flag was deleted, which is
    /// how the user clears the slot that has the rule skipped.
    func testFlagTogglesListThePaletteThenTheRulesStraySlots() {
        let palette = [
            FlagPaletteEntry(slot: FlagPalette.systemSlot, label: "Flagged", color: "red"),
            FlagPaletteEntry(slot: "cabal-flag-02", label: "Later", color: "blue"),
        ]
        let flags = ["cabal-flag-07", "cabal-flag-02"]
        XCTAssertEqual(
            RuleFlagToggles.pickerSlots(palette: palette, flags: flags),
            [FlagPalette.systemSlot, "cabal-flag-02", "cabal-flag-07"]
        )
        XCTAssertEqual(RuleFlagToggles.straySlots(palette: palette, flags: flags), ["cabal-flag-07"])
        XCTAssertEqual(RuleFlagToggles.straySlots(palette: palette, flags: ["cabal-flag-02"]), [])
    }
}
