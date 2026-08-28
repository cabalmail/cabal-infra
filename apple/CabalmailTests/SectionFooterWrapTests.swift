import XCTest

/// A `Section` footer is a row of its `List`/`Form`, and on macOS that row
/// proposes one line of height: a footer wider than its container truncates
/// mid-sentence rather than wrapping (#1300). `View.sectionFooter()` is the
/// one place that opts a footer out of the single-line proposal, so what has
/// to be pinned is that every footer goes through it — the defect was a call
/// site that didn't, and nothing else can see that.
final class SectionFooterWrapTests: XCTestCase {
    /// Every `Section` footer in the app's sources, keyed by file path (not
    /// file name — two targets can carry the same name, and the clean one
    /// would silently overwrite the offending one).
    private static let footerFiles = [
        "Cabalmail/Views/RulesView.swift",
        "Cabalmail/Views/RuleEditorView.swift",
        "Cabalmail/Views/RuleEditorExtras.swift",
        "Cabalmail/Views/SettingsDetailViews.swift",
        "Cabalmail/Views/NotificationSettingsSection.swift",
        "Cabalmail/Views/SearchFiltersSheet.swift",
        "Cabalmail/Views/AcknowledgementsView.swift"
    ]

    func testEverySectionFooterOptsOutOfTheSingleLineProposal() throws {
        var offenders: [String] = []
        var total = 0
        for path in Self.footerFiles {
            let bodies = Self.footerBodies(in: try Self.source(of: path))
            XCTAssertFalse(bodies.isEmpty, "no footer found in \(path) — has it been rewritten?")
            total += bodies.count
            for body in bodies where !body.contains(".sectionFooter()") {
                offenders.append("\(path): \(Self.firstLine(of: body))")
            }
        }
        // Floor per file above, and over the corpus here: a scan that stops
        // finding footers passes everything vacuously.
        XCTAssertGreaterThanOrEqual(total, 10, "footer corpus shrank — check the scan still matches")
        XCTAssertEqual(offenders, [], "section footers that can truncate instead of wrapping (#1300)")
    }

    /// Proves the detector catches the reported shape on synthetic snippets,
    /// so a later rewrite of the real footers can't make the assertion above
    /// vacuous by making the scan match nothing.
    func testDetectorSeesAFooterWithAndWithoutTheModifier() {
        let bare = """
        Section {
            Toggle("Enabled", isOn: binding)
        } footer: {
            Text("A sentence long enough to wrap in a narrow sheet.")
        }
        """
        let wrapped = """
        Section {
            Toggle("Enabled", isOn: binding)
        } footer: {
            Text("A sentence long enough to wrap in a narrow sheet.")
                .sectionFooter()
        }
        """
        XCTAssertEqual(Self.footerBodies(in: bare).count, 1)
        XCTAssertFalse(Self.footerBodies(in: bare)[0].contains(".sectionFooter()"))
        XCTAssertEqual(Self.footerBodies(in: wrapped).count, 1)
        XCTAssertTrue(Self.footerBodies(in: wrapped)[0].contains(".sectionFooter()"))
    }

    /// Brace matching rather than line shape: a footer is a closure, and only
    /// balanced braces know where it ends. A nested `VStack` footer would fool
    /// anything that stopped at the first `}`.
    func testDetectorHandlesANestedFooterBody() {
        let nested = """
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(footerText)
            }
            .sectionFooter()
        }
        """
        let bodies = Self.footerBodies(in: nested)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies[0].contains(".sectionFooter()"))
        XCTAssertTrue(bodies[0].contains("VStack"))
    }

    // MARK: - Extraction

    private static func footerBodies(in source: String) -> [String] {
        var bodies: [String] = []
        var search = source.startIndex
        while let marker = source.range(of: "} footer: {", range: search..<source.endIndex) {
            search = marker.upperBound
            guard let end = matchingCloseBrace(in: source, openedAt: source.index(before: marker.upperBound))
            else { continue }
            bodies.append(String(source[marker.upperBound..<end]))
        }
        return bodies
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

    private static func firstLine(of body: String) -> String {
        body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("//") } ?? "(empty footer)"
    }

    private static func source(of path: String) throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        return try String(contentsOf: apple.appendingPathComponent(path), encoding: .utf8)
    }
}
