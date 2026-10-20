import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A `field` or `action` the build doesn't know decodes to `.unknown` and
/// the rule goes read-only: it lists, reorders, deletes and saves back
/// unchanged, but nothing local may edit it (#1901).
@MainActor
final class RulesOpaqueRuleTests: XCTestCase {
    private func makeModel(_ backend: FakeRulesBackend) -> RulesViewModel {
        let model = RulesViewModel(backend: backend)
        model.saveDebounce = .milliseconds(1)
        return model
    }

    private func waitForSaves(
        _ backend: FakeRulesBackend, _ count: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<200 where backend.savedSets.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(backend.savedSets.count, count, file: file, line: line)
    }

    private func sampleRule(name: String = "Receipts") -> Rule {
        Rule(
            name: name,
            conditions: [Rule.Condition(field: .subject, value: "invoice")],
            action: .move,
            moveFolder: "Receipts"
        )
    }

    /// A rule as a newer writer would leave it: an action this build
    /// doesn't know, carried verbatim.
    private func opaqueRule(name: String = "Newer rule") -> Rule {
        Rule(
            name: name,
            conditions: [Rule.Condition(field: .from, value: "ops")],
            action: .unknown("quarantine")
        )
    }

    func testOpaqueRuleLoadsBesideTheRulesTheBuildUnderstands() async {
        let backend = FakeRulesBackend()
        backend.ruleSet = RuleSet(rules: [sampleRule(), opaqueRule()], version: 3)
        let model = makeModel(backend)
        await model.load()
        XCTAssertEqual(model.rules.map(\.name), ["Receipts", "Newer rule"])
        XCTAssertNil(model.loadError)
        XCTAssertEqual(model.rules.map(\.isEditable), [true, false])
    }

    func testUpdateRefusesARuleTheBuildCannotRender() async {
        // The row has no editor to reach, but the refusal lives in the
        // model: a rewritten copy of a rule we can't read would drop
        // whatever the newer writer meant.
        let backend = FakeRulesBackend()
        backend.ruleSet = RuleSet(rules: [opaqueRule(), sampleRule()], version: 1)
        let model = makeModel(backend)
        await model.load()

        var edited = model.rules[0]
        edited.name = "Renamed"
        edited.action = .delete
        model.update(edited)
        XCTAssertEqual(model.rules[0].name, "Newer rule")
        XCTAssertEqual(model.rules[0].action, .unknown("quarantine"))
        // Enabling is an edit too, and goes through `update`.
        model.setEnabled(model.rules[0].id, false)
        XCTAssertTrue(model.rules[0].enabled)
        // Duplicating would mint a rule this build can't express.
        XCTAssertNil(model.duplicate(model.rules[0].id))
        XCTAssertEqual(model.rules.count, 2)
        // None of the four scheduled a save.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(backend.savedSets.count, 0)

        // Control: the same edits land on the sibling rule, one save each
        // (the second is scheduled only once the first has been recorded,
        // so the debounce can't coalesce them).
        var sibling = model.rules[1]
        sibling.name = "Renamed"
        model.update(sibling)
        await waitForSaves(backend, 1)
        XCTAssertEqual(model.rules[1].name, "Renamed")
        XCTAssertNotNil(model.duplicate(model.rules[1].id))
        await waitForSaves(backend, 2)
        XCTAssertEqual(model.rules.count, 3)
    }

    func testOpaqueRuleStillReordersDeletesAndSavesUnchanged() async {
        // Reorder and delete don't rewrite the rule, so they stay; what
        // goes back to the server has to be the rule as it arrived.
        let backend = FakeRulesBackend()
        backend.ruleSet = RuleSet(rules: [sampleRule(), opaqueRule()], version: 1)
        let model = makeModel(backend)
        await model.load()

        model.move(id: model.rules[1].id, by: -1)
        await waitForSaves(backend, 1)
        XCTAssertEqual(model.rules.map(\.name), ["Newer rule", "Receipts"])
        // The validator holds a save back on an issue; an opaque rule must
        // not be one, or no later edit of any rule could ever save.
        XCTAssertEqual(backend.savedSets[0].rules.map(\.name), ["Newer rule", "Receipts"])
        XCTAssertEqual(backend.savedSets[0].rules[0].action, .unknown("quarantine"))
        XCTAssertEqual(model.saveState, .saved)

        model.delete(id: model.rules[0].id)
        await waitForSaves(backend, 2)
        XCTAssertEqual(model.rules.map(\.name), ["Receipts"])
    }

    func testSummaryNamesWhatAnOpaqueRuleUses() {
        // The row can't describe conditions and a destination it can't
        // read, so it says what the rule uses instead of guessing.
        let summary = RuleSummary.describe(opaqueRule())
        XCTAssertTrue(summary.contains("quarantine"), summary)
        XCTAssertTrue(summary.contains("doesn't understand"), summary)
        // Control: a rule this build understands still reads as its rule.
        XCTAssertEqual(
            RuleSummary.describe(sampleRule()),
            "Subject contains \u{201C}invoice\u{201D} · move to Receipts"
        )
    }
}
