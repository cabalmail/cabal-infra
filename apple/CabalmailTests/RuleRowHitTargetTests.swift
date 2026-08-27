import XCTest

/// A `NavigationLink`'s label is a single hit target on macOS: SwiftUI folds
/// any control nested inside it into the link itself (the control survives
/// only as an accessibility custom action), so clicks land on the link. That
/// is what made the rules list's Enabled toggle and `⋯` menu unusable —
/// every click in a row pushed the rule editor instead (#1299).
///
/// The fix is structural, so the test is too: it reads the source the macOS
/// compiler sees and asserts no interactive control sits inside a
/// `NavigationLink` label there. `RulesViewModelTests` already covers the
/// behaviour behind those controls; what regressed was where they were
/// mounted, which nothing else can see.
final class RuleRowHitTargetTests: XCTestCase {
    /// Controls that must not appear inside a macOS `NavigationLink` label.
    /// Named properties count: hoisting the toggle out of the row body is
    /// exactly how the shape hides from a naive `Toggle(` grep.
    private static let controls = ["Toggle(", "Menu {", "Button(", "Button {", "enabledToggle"]

    func testMacRulesRowKeepsItsControlsOutOfTheLinkLabel() throws {
        let source = try Self.macOSSource(of: "Cabalmail/Views/RulesView.swift")
        let labels = Self.navigationLinkLabels(in: source)
        XCTAssertFalse(labels.isEmpty, "no NavigationLink label found — has the rules list been rewritten?")
        for label in labels {
            for control in Self.controls {
                XCTAssertFalse(
                    label.contains(control),
                    "\(control) sits inside a macOS NavigationLink label, where it cannot be clicked (#1299)"
                )
            }
        }
    }

    /// Proves the detector catches the reported shape, on synthetic snippets
    /// rather than on the corpus — so a future rewrite of the row can't
    /// quietly make the assertion above vacuous.
    func testDetectorCatchesTheReportedShape() {
        let broken = """
        NavigationLink {
            RuleEditorView(model: model, ruleID: rule.id)
        } label: {
            HStack(spacing: 12) {
                Toggle("Enabled", isOn: binding)
                summary
            }
        }
        """
        let fixed = """
        HStack(spacing: 12) {
            Toggle("Enabled", isOn: binding)
            NavigationLink {
                RuleEditorView(model: model, ruleID: rule.id)
            } label: {
                summary
            }
        }
        """
        XCTAssertEqual(Self.navigationLinkLabels(in: broken).count, 1)
        XCTAssertTrue(Self.navigationLinkLabels(in: broken)[0].contains("Toggle("))
        XCTAssertEqual(Self.navigationLinkLabels(in: fixed).count, 1)
        XCTAssertFalse(Self.navigationLinkLabels(in: fixed)[0].contains("Toggle("))
    }

    /// The preprocessor has to be right about which arm is macOS's, or the
    /// scan reads the iOS row — where a toggle inside the label is the
    /// shipped shape — and passes for the wrong reason.
    func testMacOSSourceKeepsTheMacArmAndDropsTheOthers() throws {
        let stripped = try Self.strippingInactiveArms(
            """
            #if os(macOS)
            mac
            #else
            other
            #endif
            #if os(iOS) || os(visionOS)
            phone
            #endif
            """
        )
        XCTAssertTrue(stripped.contains("mac"))
        XCTAssertFalse(stripped.contains("other"))
        XCTAssertFalse(stripped.contains("phone"))
    }

    // MARK: - Extraction

    /// Bodies of every `} label: {` closure that closes a `NavigationLink`,
    /// found by brace matching rather than by line shape — the label of a
    /// link is a nested closure, and only balancing braces knows where it
    /// ends.
    private static func navigationLinkLabels(in source: String) -> [String] {
        var labels: [String] = []
        var search = source.startIndex
        while let marker = source.range(of: "} label: {", range: search..<source.endIndex) {
            search = marker.upperBound
            // The `{` before this `}` opens the link's destination closure;
            // walk back over it to check what this label belongs to.
            guard let opener = matchingOpenBrace(in: source, closedAt: marker.lowerBound),
                  source[source.startIndex..<opener].hasSuffix("NavigationLink ") else { continue }
            guard let end = matchingCloseBrace(in: source, openedAt: source.index(before: marker.upperBound))
            else { continue }
            labels.append(String(source[marker.upperBound..<end]))
        }
        return labels
    }

    private static func matchingCloseBrace(in source: String, openedAt open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func matchingOpenBrace(in source: String, closedAt close: String.Index) -> String.Index? {
        var depth = 0
        var index = close
        while true {
            if source[index] == "}" { depth += 1 }
            if source[index] == "{" {
                depth -= 1
                if depth == 0 { return index }
            }
            if index == source.startIndex { return nil }
            index = source.index(before: index)
        }
    }

    // MARK: - Corpus

    /// The named file as the macOS compiler sees it: `#if os(macOS)` arms
    /// kept, their `#else` arms and any other-platform block dropped.
    private static func macOSSource(of path: String) throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        let url = apple.appendingPathComponent(path)
        return try strippingInactiveArms(String(contentsOf: url, encoding: .utf8))
    }

    /// Deliberately narrow: it understands the plain `#if` / `#else` /
    /// `#endif` forms this corpus uses and fails loudly on anything else,
    /// rather than guessing an arm wrong and scanning the wrong platform.
    private static func strippingInactiveArms(_ source: String) throws -> String {
        var active: [Bool] = []
        var kept: [String] = []
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") {
                active.append(trimmed.contains("os(macOS)"))
            } else if trimmed == "#else" {
                guard let last = active.popLast() else { throw Unsupported(line: trimmed) }
                active.append(!last)
            } else if trimmed == "#endif" {
                guard active.popLast() != nil else { throw Unsupported(line: trimmed) }
            } else if trimmed.hasPrefix("#if") || trimmed.hasPrefix("#elseif") {
                throw Unsupported(line: trimmed)
            } else if active.allSatisfy({ $0 }) {
                kept.append(line)
            }
        }
        return kept.joined(separator: "\n")
    }

    private struct Unsupported: Error { let line: String }
}
