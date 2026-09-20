import XCTest
@testable import Cabalmail

/// The message list's swipe actions live on plain rows inside one container
/// marked `.swipeActionsContainer()` (27 SDKs). The embedded per-row `List`
/// that used to host them is what let revealed actions pile up across rows
/// and survive navigation (#901), so its absence is the thing to pin.
final class SwipeContainerSourceScanTests: XCTestCase {

    func testTheRowEmbedsNoList() throws {
        let body = try Self.source("Cabalmail/Views/SwipeActionRow.swift")
        XCTAssertFalse(body.contains("List {"), "the row must not borrow a List for its swipe")
        XCTAssertFalse(body.contains(".listRow"), "no List row modifiers without a List")
        XCTAssertEqual(body.components(separatedBy: ".swipeActions(edge:").count - 1, 2)
    }

    func testTheListScrollViewIsTheSwipeContainer() throws {
        let body = try Self.source("Cabalmail/Views/MessageListView+Selection.swift")
        // The mark closes the ScrollView expression; comments mention the
        // modifier too, so count the call site, not the token.
        XCTAssertEqual(
            body.components(separatedBy: "}\n                .swipeActionsContainer(),").count - 1, 1,
            "exactly one container mark, on the virtualized ScrollView"
        )
    }

    func testTheDeploymentTargetsCarryTheContainerAPI() throws {
        // `.swipeActionsContainer()` is iOS / macOS / visionOS 27; with no
        // pre-27 path left in the row, the targets have to say so.
        let project = try Self.source("project.yml")
        for line in ["    iOS: \"27.0\"", "    macOS: \"27.0\"", "    visionOS: \"27.0\""] {
            XCTAssertTrue(project.contains(line), line)
        }
    }

    private static func source(_ relativePath: String) throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
