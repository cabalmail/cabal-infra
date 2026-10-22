import XCTest
@testable import CabalmailUI

/// `ReadingPaneSelectionPolicy.reopens` is inert unless the tap asks it, and
/// it has to ask BEFORE the tap writes `selectedRefs` — the rule's whole
/// input is the set as it stood (#2033, #2034). Nothing renders a wide list
/// in a unit test, so the pairing is pinned here: the policy's own tests say
/// what the rule answers, this says the one call site still asks it, with the
/// set unwritten and the pane's row passed in.
final class EqualSelectionReopenSourceScanTests: XCTestCase {

    private static let file = "CabalmailUI/Mail/MessageList/MessageListView+Selection.swift"

    func testTheTapAsksThePolicyBeforeItWritesTheSelectionSet() throws {
        let body = try Self.declaration("func selectRow(", in: Self.source(Self.file))
        guard let asks = body.range(of: "ReadingPaneSelectionPolicy.reopens("),
              let writes = body.range(of: "model.selectedRefs = [ref]") else {
            return XCTFail("selectRow must ask the policy and then write the set")
        }
        XCTAssertTrue(
            asks.lowerBound < writes.lowerBound,
            "the rule reads the set as it stood, so the ask comes before the write"
        )
    }

    func testTheTapPassesThePanesRowAndSelectModeToThePolicy() throws {
        let body = try Self.declaration("func selectRow(", in: Self.source(Self.file))
        XCTAssertTrue(
            body.contains("paneShowing: selection.map { model.rowRef(for: $0) }"),
            "the pane's own row is what the rule compares against"
        )
        XCTAssertTrue(body.contains("bulkMode: model.bulkMode"))
        XCTAssertTrue(
            body.contains("selection = envelope"),
            "and the re-open writes the pane"
        )
    }

    /// Detector self-test: the slice is the declaration and not the file, so
    /// a sibling function's call cannot stand in for `selectRow`'s.
    func testTheSliceIsOneDeclaration() throws {
        let source = try Self.source(Self.file)
        let body = try Self.declaration("func selectRow(", in: source)
        XCTAssertTrue(body.contains("func selectRow("))
        XCTAssertFalse(body.contains("func applyRangeSelection("))
        XCTAssertLessThan(body.count, source.count / 2)

        let synthetic = """
            extension A {
                func selectRow(_ e: E) {
                    if ReadingPaneSelectionPolicy.reopens() { selection = e }
                }

                func other() {
                    nothing()
                }
            }
            """
        let slice = try Self.declaration("func selectRow(", in: synthetic)
        XCTAssertTrue(slice.contains("ReadingPaneSelectionPolicy.reopens()"))
        XCTAssertFalse(slice.contains("nothing()"))
    }

    /// `source` from the opening line of `declaration` to the line that is
    /// its own indent plus `}` — the declaration's body, not the file's.
    /// A missing anchor FAILS rather than skips: a rename must not turn this
    /// scan into a silent no-op.
    private struct AnchorGone: Error, CustomStringConvertible {
        let description: String
    }

    private static func declaration(_ opener: String, in source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(opener) }) else {
            throw AnchorGone(description: "no declaration matching \(opener)")
        }
        let indent = String(lines[start].prefix(while: { $0 == " " }))
        guard let end = lines[(start + 1)...].firstIndex(where: { $0 == indent + "}" }) else {
            throw AnchorGone(description: "unterminated declaration \(opener)")
        }
        return lines[start...end].joined(separator: "\n")
    }

    private static func source(_ relativePath: String) throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
