import XCTest
@testable import CabalmailUI

/// The regular-width iOS layout drives folders through its own floating
/// panel and collapses the real sidebar column to zero width, so the
/// system sidebar toggle must be removed wherever the split view may host
/// it: the sidebar column (iPadOS 26) and the content column (iOS 27 on a
/// phone-idiom host such as iPhone Duo, #1690).
final class SidebarToggleRemovalSourceScanTests: XCTestCase {

    func testTheSystemSidebarToggleIsRemovedOnBothColumns() throws {
        let body = try Self.source("CabalmailUI/Shell/SplitShell.swift")
        XCTAssertEqual(
            body.components(separatedBy: ".toolbar(removing: .sidebarToggle)").count - 1, 2,
            "the sidebar column and the content column"
        )
    }

    private static func source(_ relativePath: String) throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
