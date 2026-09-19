import XCTest
@testable import Cabalmail

/// Pins the address row's drag wiring. Nothing renders a drag in a unit
/// test, so this scans the source: every address row advertises the raw
/// address as plain text (`.draggable(address.address)`), which is what a
/// signup form in a neighbouring Split View pane accepts — on an open iPhone
/// Duo or an iPad (#1646). It must be the raw address, not the
/// zero-width-space `wrappable` rendering the row draws.
final class AddressRowDragSourceScanTests: XCTestCase {

    func testAddressRowsDragTheRawAddressAsPlainText() throws {
        let body = try Self.source("Cabalmail/Views/AddressListView.swift")
        XCTAssertTrue(
            body.contains(".draggable(address.address)"),
            "the address row is draggable as the raw address string"
        )
        XCTAssertFalse(
            body.contains(".draggable(AddressDisplay.wrappable("),
            "the drag payload must be the raw address, not the wrappable rendering"
        )
    }

    func testCorpusIsReadable() throws {
        XCTAssertTrue(
            try Self.source("Cabalmail/Views/AddressListView.swift").contains("import SwiftUI"),
            "AddressListView.swift did not load — the scan would be vacuous"
        )
    }

    private static let apple = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CabalmailTests
        .deletingLastPathComponent()   // apple

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
