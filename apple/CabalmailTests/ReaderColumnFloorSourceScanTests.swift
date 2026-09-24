import XCTest
@testable import Cabalmail

/// The reader column's floor has to reach UIKit's split controller, or it
/// applies its own (about 540 pt) and floats the list over the reader on
/// windows where the app's own policy would tile them (#1679). Nothing
/// builds a split in a unit test, so this pins the declaration.
final class ReaderColumnFloorSourceScanTests: XCTestCase {

    func testTheDetailColumnDeclaresTheReaderFloor() throws {
        let body = try Self.source("Cabalmail/Views/MailRootView.swift")
        XCTAssertTrue(
            body.contains(".navigationSplitViewColumnWidth(min: readerColumnMinWidth, ideal: readerColumnMinWidth)"),
            "the detail column carries the same floor listColumnMaxWidth keeps for it"
        )
    }

    func testTheRootFeedsTheMeasuredWidthToThePolicy() throws {
        let body = try Self.source("Cabalmail/Views/SignedInRootView.swift")
        XCTAssertTrue(body.contains("measuredWidth: measuredWidth"))
    }

    private static func source(_ relativePath: String) throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
