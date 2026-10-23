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

    /// The row's switch comes from `RowSwitch`, which owns both the Mac
    /// switch style (without it the automatic toggle draws as a checkbox,
    /// #2019) and the label spelling that keeps the control speaking as a
    /// switch rather than a toggle button (#2040). A bare
    /// `Toggle(...).labelsHidden().miniSwitchStyleOnMac()` is the shape
    /// that had both bugs, so the style assertion this replaces now lives
    /// on `RowSwitch` itself.
    func testRuleEnabledToggleComesFromRowSwitch() throws {
        let source = try Self.source(of: "CabalmailUI/Rules/RulesView.swift")
        XCTAssertTrue(
            source.contains("RowSwitch(label: \"Enabled\""),
            """
            the rule's Enabled switch is no longer a RowSwitch, so it carries \
            neither the Mac switch style nor the label
            """
        )
        XCTAssertNil(
            Self.stripComments(source).range(of: #"\.labelsHidden\(\)"#, options: .regularExpression),
            "a .labelsHidden() toggle is back in the Rules pane, which on macOS reads as a toggle button (#2040)"
        )
    }

    /// `RowSwitch`'s macOS arm must keep the style *and* keep a label the
    /// control can answer to. `.labelsHidden()` there is exactly the
    /// defect, and `.accessibilityLabel` alone does not undo it: measured
    /// over thirteen spellings on macOS 27, both read "toggle button".
    func testRowSwitchKeepsTheMacSwitchStyleAndItsLabel() throws {
        let source = try Self.source(of: "CabalmailUI/Platform/ListAndFormStyles.swift")
        let macArm = try XCTUnwrap(
            Self.rowSwitchMacArm(of: Self.stripComments(source)),
            "RowSwitch has no #if os(macOS) arm"
        )
        XCTAssertTrue(
            macArm.contains(".miniSwitchStyleOnMac()"),
            "RowSwitch's Mac arm has lost its switch style and can draw as a checkbox again (#2019)"
        )
        XCTAssertTrue(
            macArm.contains(".accessibilityLabel(label)"),
            "RowSwitch's Mac arm no longer names its switch"
        )
        XCTAssertNil(
            macArm.range(of: #"\.labels(Hidden\(\)|Visibility\()"#, options: .regularExpression),
            "RowSwitch's Mac arm hides its label again, which makes the switch read as a toggle button (#2040)"
        )
    }

    /// Proves the slice is `RowSwitch`'s own Mac arm: the file holds three
    /// earlier `#if os(macOS)` blocks, and the non-Mac arm legitimately
    /// uses `.labelsHidden()`, so a slice that started too early or ran
    /// past `#else` would fail the assertions above on correct source,
    /// while one that returned nothing would pass them vacuously.
    func testRowSwitchMacArmSliceIsThatArmOnly() {
        let sample = [
            "func groupedFormStyleOnMac() -> some View {",
            "#if os(macOS)",
            "earlierHelperOnly()",
            "#endif",
            "}",
            "struct RowSwitch: View {",
            "#if os(macOS)",
            "macOnly()",
            "#else",
            "otherOnly()",
            "#endif",
            "}"
        ].joined(separator: "\n")
        let arm = Self.rowSwitchMacArm(of: sample)
        XCTAssertNotNil(arm)
        XCTAssertTrue(arm?.contains("macOnly()") == true)
        XCTAssertFalse(arm?.contains("earlierHelperOnly()") == true)
        XCTAssertFalse(arm?.contains("otherOnly()") == true)
        XCTAssertNil(Self.rowSwitchMacArm(of: "struct Other: View { noConditionalHere() }"))
        XCTAssertNil(Self.rowSwitchMacArm(of: "#if os(macOS)\nmacOnly()\n#endif"))
    }

    /// Proves the comment stripper takes `//` prose out and leaves code
    /// alone. Both scans above name `.labelsHidden()` in their own doc
    /// comments and at the call sites that explain why it is gone, so a
    /// comment-blind scan accuses the already-correct file.
    func testCommentStripperRemovesProseOnly() {
        XCTAssertEqual(Self.stripComments("a() // .labelsHidden()"), "a() ")
        XCTAssertEqual(Self.stripComments("// .labelsHidden()\nb()"), "\nb()")
        XCTAssertEqual(Self.stripComments("c().labelsHidden()"), "c().labelsHidden()")
    }

    /// `source` with its `//` comments removed. Line comments only: the
    /// two files these scans read carry none of the `/* */` form.
    private static func stripComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let marker = line.range(of: "//") else { return String(line) }
                return String(line[..<marker.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// The `#if os(macOS)` ... `#else`/`#endif` span inside `RowSwitch`,
    /// or nil when the type or the arm is gone.
    private static func rowSwitchMacArm(of source: String) -> String? {
        guard let type = source.range(of: "struct RowSwitch") else { return nil }
        let body = source[type.upperBound...]
        guard let start = body.range(of: "#if os(macOS)") else { return nil }
        let arm = body[start.upperBound...]
        guard let end = arm.range(of: "#else") ?? arm.range(of: "#endif") else { return nil }
        return String(arm[..<end.lowerBound])
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
