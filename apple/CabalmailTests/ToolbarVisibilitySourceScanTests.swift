import XCTest
@testable import Cabalmail

/// Pins which toolbar items ask the bar to keep them when it overflows —
/// on an iPhone Duo's vertical strip, or a crowded macOS window. Nothing
/// renders a bar in a unit test, so this scans the source for the
/// `keepsInBar()` wiring (#1647).
final class ToolbarVisibilitySourceScanTests: XCTestCase {

    func testComposeKeepsItsPlaceInTheListBar() throws {
        let body = try Self.source("Cabalmail/Views/MessageListView.swift")
        // One per platform branch: the macOS Compose + Reload group and the
        // touch platforms' lone Compose item.
        XCTAssertEqual(
            body.components(separatedBy: ".keepsInBar()").count - 1, 2,
            "both New Message toolbar declarations carry keepsInBar()"
        )
    }

    func testTheHelperIsAvailabilityGuarded() throws {
        // `.high` does not exist before iOS 27 / macOS 26.1 and is
        // unavailable on visionOS; the helper must degrade to the item
        // itself rather than gate the call sites one by one.
        let body = try Self.source("Cabalmail/Views/ToolbarVisibility.swift")
        XCTAssertTrue(body.contains("if #available(iOS 27.0, macOS 26.1, *)"))
        XCTAssertTrue(body.contains("visibilityPriority(.high)"))
        XCTAssertTrue(body.contains("#if os(iOS) || os(macOS)"))
    }

    private static let apple = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CabalmailTests
        .deletingLastPathComponent()   // apple

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
