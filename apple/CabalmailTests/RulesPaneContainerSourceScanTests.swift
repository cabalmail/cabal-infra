import XCTest

/// The Rules pane draws in a grouped `Form`, like every other Settings
/// pane, and its Enabled toggle asks for the Mac's mini switch. On the Mac
/// the container is what gives the rows a card and the last row no
/// separator, and the toggle style is what keeps the switch from drawing as
/// a checkbox; Rules drew none of the three (#2019). What regresses is the
/// container or the style, which no behaviour test can see, so this reads
/// the source.
final class RulesPaneContainerSourceScanTests: XCTestCase {
    private static let bareList = #"\bList\s*[({]"#
    /// A `model.add(...)` call whose returned id goes nowhere: nothing but
    /// whitespace sits to its left on the line.
    private static let discardedAdd = #"(?m)^\s*model\.add\("#

    func testRulesPaneIsAGroupedFormNotABareList() throws {
        let source = try Self.source(of: "CabalmailUI/Rules/RulesView.swift")
        XCTAssertTrue(source.contains(".groupedFormStyleOnMac()"), "the rules list has lost the grouped form style")
        XCTAssertNil(
            source.range(of: Self.bareList, options: .regularExpression),
            "the rules list is a bare List again, which a Mac Settings pane can't draw like the others"
        )
    }

    func testRuleEnabledToggleKeepsTheMacSwitchStyle() throws {
        let source = try Self.source(of: "CabalmailUI/Rules/RulesView.swift")
        XCTAssertTrue(
            source.contains(".miniSwitchStyleOnMac()"),
            "the rule's Enabled toggle has lost its Mac switch style and can draw as a checkbox again"
        )
    }

    /// Every Add in the Rules pane must take the id `add` returns and push
    /// the editor with it: Add used to drop it at all four sites, so a new
    /// rule was appended to the list and the screen stayed where it was
    /// (#2031). The push is a `navigationDestination(item:)` binding, which
    /// no behaviour test over the view model can see, so this reads the
    /// source. A call whose result is discarded is the regression.
    func testEveryAddSiteTakesTheIDItIsReturned() throws {
        let source = try Self.source(of: "CabalmailUI/Rules/RulesView.swift")
        XCTAssertTrue(
            source.contains(".navigationDestination(item: $addedRuleID)"),
            "the Rules pane no longer pushes the editor for a rule Add just made"
        )
        XCTAssertNil(
            source.range(of: Self.discardedAdd, options: .regularExpression),
            "an Add site drops the id `add` returned, so the editor can't be pushed for it"
        )
    }

    /// Proves the discarded-Add pattern catches the shape it guards against
    /// and nothing else, so the scan above can't pass vacuously.
    func testDiscardedAddPatternMatchesDroppedResultsOnly() {
        XCTAssertNotNil("model.add()".range(of: Self.discardedAdd, options: .regularExpression))
        XCTAssertNotNil("    model.add(template)".range(of: Self.discardedAdd, options: .regularExpression))
        XCTAssertNil("addedRuleID = model.add()".range(of: Self.discardedAdd, options: .regularExpression))
        XCTAssertNil("addedRuleID = model.add(template)".range(of: Self.discardedAdd, options: .regularExpression))
    }

    /// Proves the pattern catches the shape it guards against and nothing
    /// else, so the scan above can't pass vacuously.
    func testBareListPatternMatchesListsOnly() {
        XCTAssertNotNil("List {".range(of: Self.bareList, options: .regularExpression))
        XCTAssertNotNil("List(selection: $s) {".range(of: Self.bareList, options: .regularExpression))
        XCTAssertNil("RulesListView(model: model)".range(of: Self.bareList, options: .regularExpression))
        XCTAssertNil("private var rulesList: some View {".range(of: Self.bareList, options: .regularExpression))
    }

    private static func source(of path: String) throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        return try String(contentsOf: apple.appendingPathComponent(path), encoding: .utf8)
    }
}
