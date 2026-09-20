import XCTest
@testable import Cabalmail

/// Message rows carry their drag on every layout (#1681): a compact window
/// (an iPhone, or an iPhone Duo's Split View half) has no sidebar to drop
/// on, but the payload can still leave the app as an `.eml`. Nothing lifts
/// a drag in a unit test, so this pins the wiring.
final class CompactRowDragSourceScanTests: XCTestCase {

    func testTheRowDragIsNotGatedOnTheWideLayout() throws {
        let body = try Self.source("Cabalmail/Views/MessageListView+Rows.swift")
        let start = try XCTUnwrap(body.range(of: "func draggableRow("))
        let scope = body[start.lowerBound...]
        let end = try XCTUnwrap(scope.range(of: "private func dragPayload("))
        let draggable = scope[..<end.lowerBound]
        XCTAssertTrue(draggable.contains("if !items.isEmpty {"))
        XCTAssertFalse(draggable.contains("isWideLayout"), "compact rows drag too")
        XCTAssertTrue(draggable.contains(".draggable(dragPayload(items, envelope: envelope, model: model))"))
    }

    private static func source(_ relativePath: String) throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
