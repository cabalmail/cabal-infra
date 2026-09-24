import XCTest
@testable import Cabalmail

/// The regular-width iOS layout drives folders through its own floating
/// panel and collapses the real sidebar column to zero width, so the
/// system sidebar toggle must be removed wherever the split view may host
/// it: the sidebar column (iPadOS 26) and the content column (iOS 27 on a
/// phone-idiom host such as iPhone Duo, #1690).
final class SidebarToggleRemovalSourceScanTests: XCTestCase {

    func testTheSystemSidebarToggleIsRemovedOnBothColumns() throws {
        let body = try Self.source("Cabalmail/Views/MailRootView.swift")
        XCTAssertTrue(body.contains(".toolbar(removing: .sidebarToggle)"), "sidebar column")
        XCTAssertTrue(body.contains(".toolbar(removing: isWideSidebar ? .sidebarToggle : nil)"), "content column")
    }

    private static func source(_ relativePath: String) throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
