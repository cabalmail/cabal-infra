import XCTest

// Regression coverage for the macOS search field growing over the
// folder-switch menu after a divider drag.
//
// Dragging the split view's divider runs in AppKit's mouse-tracking loop,
// and NSToolbar loses the section re-layout a toolbar item's size change
// asks for while that loop is running: the search field, sized from the
// column's measured width, took its new width centred on its old frame and
// grew leftward over the menu while the buttons after it stayed put. The
// width is therefore recorded only once the main run loop is back in its
// default mode (`MailRootView.recordContentColumnWidth`), which is after the
// mouse is up; a size change made then lays the section out normally.
//
// There is no seam for NSToolbar's layout, so this reads the source, in the
// shape the other `*SourceScanTests` set: the macOS arm writes the width
// from inside a `.default`-mode run-loop block, not directly.
final class ContentColumnWidthDeferralSourceScanTests: XCTestCase {

    private static let path = "Cabalmail/Views/MailRootView.swift"

    func testTheMacWriteWaitsForTheDefaultRunLoopMode() throws {
        let arm = try Self.macArm(in: Self.code(in: try Self.source()))
        XCTAssertTrue(
            Self.isDeferred(arm),
            "the macOS write of contentColumnWidth needs to run inside "
                + "RunLoop.main.perform(inModes: [.default]), or a divider drag "
                + "leaves the search field over the folder menu"
        )
    }

    /// The detector on synthetic snippets.
    func testDetectorNeedsTheWriteInsideTheBlock() {
        let head = "#if os(macOS)\n"
        let block = "RunLoop.main.perform(inModes: [.default]) {\n    contentColumnWidth = width\n}\n"
        XCTAssertTrue(Self.isDeferred(head + block))
        XCTAssertFalse(Self.isDeferred(head + "contentColumnWidth = width\n"), "the reported shape")
        XCTAssertFalse(
            Self.isDeferred(head + "contentColumnWidth = width\nRunLoop.main.perform(inModes: [.default]) {\n}\n"),
            "a write before the block is not deferred"
        )
        XCTAssertFalse(
            Self.isDeferred(head + "RunLoop.main.perform(inModes: [.common]) {\n    contentColumnWidth = width\n}\n"),
            "the common modes include the tracking loop"
        )
    }

    func testTheScanReadsCodeNotProse() {
        XCTAssertFalse(Self.code(in: "// RunLoop.main.perform(inModes: [.default])").contains("RunLoop"))
    }

    /// Floor: a mis-rooted read or a renamed helper finds nothing.
    func testTheArmIsFound() throws {
        let arm = try Self.macArm(in: Self.code(in: try Self.source()))
        XCTAssertTrue(arm.contains("contentColumnWidth = width"), "the write is not in the slice")
    }

    // MARK: - Corpus

    /// The helper's macOS arm: from its declaration to the `#else`.
    private static func macArm(in code: String) throws -> String {
        let start = try XCTUnwrap(
            code.range(of: "func recordContentColumnWidth(_ width: CGFloat)"),
            "\(path): helper not found"
        )
        let end = try XCTUnwrap(
            code.range(of: "#else", range: start.upperBound..<code.endIndex),
            "\(path): helper has no #else arm"
        )
        return String(code[start.lowerBound..<end.lowerBound])
    }

    /// The write sits after the block opens, inside a `.default`-mode block.
    private static func isDeferred(_ arm: String) -> Bool {
        guard let block = arm.range(of: "RunLoop.main.perform(inModes: [.default]) {"),
              let write = arm.range(of: "contentColumnWidth = width") else { return false }
        return write.lowerBound > block.upperBound
            && !arm[arm.startIndex..<block.lowerBound].contains("contentColumnWidth = width")
    }

    /// `body` with line comments cut.
    private static func code(in body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
    }

    private static func source() throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        return try String(contentsOf: apple.appendingPathComponent(path), encoding: .utf8)
    }
}
