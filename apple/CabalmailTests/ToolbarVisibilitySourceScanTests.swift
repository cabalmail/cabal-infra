import XCTest
@testable import CabalmailUI

/// Pins which toolbar items ask the bar to keep them when it overflows —
/// on an iPhone Duo's vertical strip, or a crowded macOS window. Nothing
/// renders a bar in a unit test, so this scans the source for the
/// `keepsInBar()` wiring (#1647).
final class ToolbarVisibilitySourceScanTests: XCTestCase {

    func testComposeKeepsItsPlaceInTheListBar() throws {
        let body = try Self.source("CabalmailUI/Mail/MessageList/MessageListView.swift")
        // One per platform branch: the macOS Compose + Reload group and the
        // touch platforms' lone Compose item.
        XCTAssertEqual(
            body.components(separatedBy: ".keepsInBar()").count - 1, 2,
            "both New Message toolbar declarations carry keepsInBar()"
        )
    }

    func testTheOpenInspectorsToggleOutranksCompose() throws {
        // With the inspector open, `@` is the one item that can close it, so
        // it takes the priority above `keepsInBar()`; closed, it is unranked.
        let body = try Self.source("CabalmailUI/Shell/WideMail.swift")
        let ranked = "if addressInspectorPresented {\n"
            + "            ToolbarItem(placement: .primaryAction) { addressInspectorToggle }\n"
            + "                .keepsInBarFirst()"
        XCTAssertTrue(body.contains(ranked))
        XCTAssertEqual(body.components(separatedBy: ".keepsInBarFirst()").count - 1, 1)
        let helper = try Self.source("CabalmailUI/Shared/Chrome/ToolbarVisibility.swift")
        XCTAssertTrue(helper.contains("ToolbarItemVisibilityPriority(higherThan: .high)"))
        XCTAssertEqual(
            helper.components(separatedBy: "#if (os(iOS) || os(macOS)) && compiler(>=6.4)").count - 1, 2,
            "both helpers carry the toolchain guard"
        )
    }

    func testTheClosedInspectorToggleRanksWithCompose() throws {
        // Closed, `@` is still the only entry point to addresses on the wide
        // layout, so it ranks with Compose rather than below it: at the list
        // column's 300 pt floor the bar can seat two trailing items, and the
        // pair that must survive is Compose and `@` (#1626).
        let body = try Self.source("CabalmailUI/Shell/WideMail.swift")
        let ranked = "} else {\n"
            + "            ToolbarItem(placement: .primaryAction) { addressInspectorToggle }\n"
            + "                .keepsInBar()"
        XCTAssertTrue(body.contains(ranked))
    }

    func testTheHelperIsAvailabilityGuarded() throws {
        // `.high` does not exist before iOS 27 / macOS 26.1 and is
        // unavailable on visionOS; the helper must degrade to the item
        // itself rather than gate the call sites one by one.
        let body = try Self.source("CabalmailUI/Shared/Chrome/ToolbarVisibility.swift")
        XCTAssertTrue(body.contains("if #available(iOS 27.0, macOS 26.1, *)"))
        XCTAssertTrue(body.contains("visibilityPriority(.high)"))
        // Both guards: the runtime `#available` and the toolchain `#if`,
        // because an Xcode 26 toolchain's SDK has no `visibilityPriority`
        // at all.
        XCTAssertTrue(body.contains("#if (os(iOS) || os(macOS)) && compiler(>=6.4)"))
    }

    private static let apple = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CabalmailTests
        .deletingLastPathComponent()   // apple

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
