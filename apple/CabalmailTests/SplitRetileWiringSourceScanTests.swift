import XCTest

// The iPad split's end of the re-tile (`SplitRetilePolicy`, #1988). The
// shell is `#if os(iOS)`, so nothing in this target compiles it and there is
// no seam for `onGeometryChange` either; this reads the source, in the shape
// the other `*SourceScanTests` set.
//
// Three things have to hold together, and each is useless alone:
//
//   - the split's own width feeds the policy, which means `splitWidth` — the
//     width the reporting modifier measures ON the split. Measured: during a
//     Zoom the split is laid out at 534 pt inside an 834 pt window, and a
//     geometry reader hung one modifier further out, outside the shell's own
//     modifiers, reads 834 throughout and never sees it. That narrow pass is
//     the whole signal, so a reader in the wrong place silently disarms the
//     policy — the shape this scan exists to catch.
//   - the generation is the split's `.id`. Without it the policy counts and
//     nothing is rebuilt, so UIKit keeps the floating layout it chose.
//   - the rebuild takes a new tree. The navigator hands a rebuilt tree the
//     route and gates out writes from the list it replaces (`TreeGate`);
//     reusing the tree lets the fresh list's empty selection reach the
//     navigator and clear the open message, which is the same loss by
//     another road.
final class SplitRetileWiringSourceScanTests: XCTestCase {

    private static let path = "CabalmailUI/Shell/SplitShell.swift"
    private static let listPath = "CabalmailUI/Mail/MessageList/MessageListView.swift"

    func testTheSplitsOwnWidthFeedsThePolicy() throws {
        let body = try Self.shellBody()
        XCTAssertTrue(
            Self.feedsPolicy(body),
            "SplitShell has to feed retile.recordLayout(width:) from mailState.splitWidth — the width measured "
                + "ON the split. A geometry reader outside the shell's modifiers measures 834 throughout and "
                + "never sees the 534 the Zoom lays the split out at, which disarms the policy silently"
        )
    }

    func testTheGenerationIsTheSplitsIdentity() throws {
        let body = try Self.shellBody()
        XCTAssertTrue(
            body.contains(".id(retile.generation)"),
            "the policy's generation has to be the split's .id, or nothing is rebuilt and the list stays floating"
        )
    }

    func testTheRebuildTakesANewTree() throws {
        let body = try Self.shellBody()
        XCTAssertTrue(
            body.contains("mailState.tree = UUID()"),
            "the rebuilt split has to be a new tree of the window's, or the list it replaces clears the open message"
        )
    }

    func testTheListAsksBeforeTakingARestore() throws {
        let code = Self.code(in: try Self.source(at: Self.listPath))
        let start = try XCTUnwrap(
            code.range(of: "private func applyPendingRestore(model: MessageListViewModel)"),
            "\(Self.listPath): the consume is not where this expects it"
        )
        let end = try XCTUnwrap(
            code.range(of: "\n    }\n", range: start.upperBound..<code.endIndex), "\(Self.listPath): no end"
        )
        let arm = String(code[start.lowerBound..<end.lowerBound])
        let asked = try XCTUnwrap(arm.range(of: "listMayTakeRestore(in: mailTree)"), "the list has to ask its tree")
        let consumed = try XCTUnwrap(arm.range(of: "consumePendingRestore(for:"), "the consume is gone")
        XCTAssertLessThan(
            asked.lowerBound, consumed.lowerBound,
            "the question has to come before the consume: the slot is pop-once, so asking after it "
                + "has already taken the restore is no guard at all"
        )
    }

    /// The detector on synthetic snippets: it is the call that counts, not
    /// the words.
    func testDetectorNeedsTheFeedToComeFromSplitWidth() {
        let good = ".onChange(of: mailState.splitWidth) { _, newWidth in\nretile.recordLayout(width: newWidth)\n}\n"
        XCTAssertTrue(Self.feedsPolicy(good))
        XCTAssertFalse(
            Self.feedsPolicy(".onGeometryChange(for: CGFloat.self) { proxy in\nproxy.size.width\n"
                + "} action: { newWidth in\nretile.recordLayout(width: newWidth)\n}\n"),
            "the shape that measured 834 throughout: a reader hung outside the shell's modifiers"
        )
        XCTAssertFalse(
            Self.feedsPolicy(".onChange(of: mailState.splitWidth) { _, newWidth in\nprint(newWidth)\n}\n"),
            "watching the width and feeding nothing"
        )
        XCTAssertFalse(Self.feedsPolicy("retile.recordLayout(width: 834)\n"), "nothing watching the width")
    }

    func testTheScanReadsCodeNotProse() throws {
        XCTAssertFalse(Self.code(in: "// .id(retile.generation)").contains("retile.generation"))
        XCTAssertTrue(Self.code(in: ".id(retile.generation)  // #1988").contains("retile.generation"))
    }

    /// Floor: a renamed shell or a mis-rooted read finds nothing.
    func testTheShellBodyIsFound() throws {
        XCTAssertTrue(try Self.shellBody().contains("NavigationSplitView"), "the split is not in the slice")
    }

    // MARK: - Corpus

    /// `SplitShell.body`, from its declaration to the floating folder panel
    /// that follows it.
    private static func shellBody() throws -> String {
        let code = code(in: try source())
        let start = try XCTUnwrap(code.range(of: "var body: some View {"), "\(path): body not found")
        let end = try XCTUnwrap(
            code.range(of: "private func columnHeaderSearchField", range: start.upperBound..<code.endIndex),
            "\(path): body's end not found"
        )
        return String(code[start.lowerBound..<end.lowerBound])
    }

    /// The split's own measured width, watched, and feeding the policy.
    private static func feedsPolicy(_ body: String) -> Bool {
        guard let watch = body.range(of: ".onChange(of: mailState.splitWidth)") else { return false }
        return body.range(of: "retile.recordLayout(width:", range: watch.upperBound..<body.endIndex) != nil
    }

    /// `body` with line comments cut.
    private static func code(in body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
    }

    private static func source() throws -> String { try source(at: path) }

    private static func source(at relative: String) throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: apple.appendingPathComponent(relative), encoding: .utf8)
    }
}
