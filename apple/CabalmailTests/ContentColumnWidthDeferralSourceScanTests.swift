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
// default mode (`DesktopShell.recordContentColumnWidth`), which is after the
// mouse is up; a size change made then lays the section out normally.
//
// There is no seam for NSToolbar's layout, so this reads the source, in the
// shape the other `*SourceScanTests` set: the Mac's shell writes the width
// from inside a `.default`-mode run-loop block, not directly.
//
// The block is where the width is written, and Foundation declares it
// `NS_SWIFT_SENDABLE`, so the write also has to state the main-run-loop
// guarantee with `MainActor.assumeIsolated` (#1624) or the compiler reads it
// as touching main-actor state from a nonisolated closure. The two halves
// only work together — the deferral is what makes the isolation implicit,
// and the statement is what makes it legal — so both are pinned here.
final class ContentColumnWidthDeferralSourceScanTests: XCTestCase {

    private static let path = "CabalmailUI/Shell/DesktopShell.swift"

    func testTheMacWriteWaitsForTheDefaultRunLoopMode() throws {
        let arm = try Self.macArm(in: Self.code(in: try Self.source()))
        XCTAssertTrue(
            Self.isDeferred(arm),
            "the macOS write of contentColumnWidth needs to run inside "
                + "RunLoop.main.perform(inModes: [.default]), or a divider drag "
                + "leaves the search field over the folder menu"
        )
    }

    func testTheMacWriteStatesItsMainActorIsolation() throws {
        let arm = try Self.macArm(in: Self.code(in: try Self.source()))
        XCTAssertTrue(
            Self.statesIsolation(arm),
            "the deferred write of contentColumnWidth needs to run inside "
                + "MainActor.assumeIsolated, or the Sendable run-loop block "
                + "touches main-actor state and the macOS target warns twice"
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

    func testDetectorNeedsTheIsolationStatedInsideTheBlock() {
        let head = "#if os(macOS)\n"
        let block = "RunLoop.main.perform(inModes: [.default]) {\n"
        let stated = block + "    MainActor.assumeIsolated {\n        contentColumnWidth = width\n    }\n}\n"
        XCTAssertTrue(Self.statesIsolation(head + stated))
        XCTAssertFalse(
            Self.statesIsolation(head + block + "    contentColumnWidth = width\n}\n"),
            "the reported shape: deferred, isolation unstated"
        )
        XCTAssertFalse(
            Self.statesIsolation(
                head + "MainActor.assumeIsolated {\n" + block + "    contentColumnWidth = width\n}\n}\n"
            ),
            "stating it around the block leaves the block itself nonisolated"
        )
        XCTAssertFalse(
            Self.statesIsolation(
                head + block + "    contentColumnWidth = width\n    MainActor.assumeIsolated {\n}\n}\n"
            ),
            "a write before the statement is not covered by it"
        )
    }

    func testTheScanReadsCodeNotProse() {
        XCTAssertFalse(Self.code(in: "// RunLoop.main.perform(inModes: [.default])").contains("RunLoop"))
        XCTAssertFalse(Self.code(in: "// MainActor.assumeIsolated {").contains("assumeIsolated"))
        XCTAssertTrue(Self.code(in: "MainActor.assumeIsolated {  // states the guarantee").contains("assumeIsolated"))
    }

    /// Floor: a mis-rooted read or a renamed helper finds nothing.
    func testTheArmIsFound() throws {
        let arm = try Self.macArm(in: Self.code(in: try Self.source()))
        XCTAssertTrue(arm.contains("contentColumnWidth = width"), "the write is not in the slice")
    }

    // MARK: - Corpus

    /// The Mac's helper: from its declaration to the end of the function.
    private static func macArm(in code: String) throws -> String {
        let start = try XCTUnwrap(
            code.range(of: "func recordContentColumnWidth(_ width: CGFloat)"),
            "\(path): helper not found"
        )
        let end = try XCTUnwrap(
            code.range(of: "\n    }\n", range: start.upperBound..<code.endIndex),
            "\(path): helper's end not found"
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

    /// The write sits inside a `MainActor.assumeIsolated` that itself opens
    /// inside the run-loop block.
    private static func statesIsolation(_ arm: String) -> Bool {
        guard let block = arm.range(of: "RunLoop.main.perform(inModes: [.default]) {"),
              let stated = arm.range(of: "MainActor.assumeIsolated {", range: block.upperBound..<arm.endIndex),
              let write = arm.range(of: "contentColumnWidth = width", range: block.upperBound..<arm.endIndex)
        else { return false }
        return write.lowerBound > stated.upperBound
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
