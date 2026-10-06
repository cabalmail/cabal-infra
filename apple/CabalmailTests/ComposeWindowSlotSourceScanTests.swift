import XCTest
@testable import CabalmailUI

// Regression coverage for the macOS Drafts loop found in the 2026-10 stage
// soak.
//
// A compose window this process did not open — one macOS restored at launch
// (it comes back with no value) or one spawned for a mailto: link — fell
// back to slot 0. SwiftUI keeps a dismissed window mounted, so every such
// window the user had closed rebuilt and started a hidden composer whenever
// slot 0 was handed out again, and the mailto: handler's reseed of slot 0
// did the same to a closed window that really held it. Each hidden composer
// saved its draft to Drafts every minute until the app quit.
//
// Signing back in after a sign-out (an expired session forces one) rebuilt
// the composer of every closed window, also hidden, from the seed it closed
// on.
//
// `ComposeSlotRegistryTests` proves the two rules: `seed(forWindowWith:
// ownSeed:)` keeps a slotless window on its own seed, and `mayCompose(_:
// closedOn:)` keeps a closed window empty across a sign-out. The scene
// itself cannot be exercised in a unit test, so this pins that the window
// and the sign-out use them. Restoring `slot ?? ComposeSlot(index: 0)` fails
// `testSlotlessWindowsHaveNoSlotFallback` by name.
final class ComposeWindowSlotSourceScanTests: XCTestCase {

    func testClosedWindowsAskBeforeComposingAcrossASignOut() throws {
        let scene = try Self.code(Self.source("CabalmailUI/Compose/Windows/ComposeWindowScene.swift"))
        XCTAssertTrue(
            scene.contains("appState.composeSlots.mayCompose(seed, closedOn: closedOn)"),
            "the composer must be gated on the window's close"
        )
        XCTAssertTrue(
            scene.contains("closedOn = appState.composeSlots.closedCompose(for: seed)"),
            "onClose must record the close"
        )
        let signOut = try Self.code(Self.source("CabalmailUI/App/AppState.swift"))
        XCTAssertTrue(signOut.contains("composeSlots.endSession()"), "sign-out must end the compose session")
    }

    func testSlotlessWindowsHaveNoSlotFallback() throws {
        let scene = try Self.code(Self.source("CabalmailUI/Compose/Windows/ComposeWindowScene.swift"))
        XCTAssertEqual(
            try Self.slotLiterals(in: scene), 0,
            "a window without a slot must not borrow one: it would follow that slot's seed while closed"
        )
        XCTAssertTrue(
            scene.contains("seed(forWindowWith: slot, ownSeed: ownSeed)"),
            "the window must ask the registry's rule for its seed"
        )
        XCTAssertTrue(scene.contains("ownSeed = mailto.draft()"), "a mailto: window keeps its seed itself")
        XCTAssertTrue(
            scene.contains("if let slot { appState.composeSlots.release(slot) }"),
            "a window without a slot must not free one"
        )
    }

    /// Proves the detector catches the shipped shape, so a rewrite of the
    /// scene cannot quietly make the scan above vacuous.
    func testDetectorCatchesTheReportedShape() throws {
        let shipped = "            ComposeWindowContent(slot: slot ?? ComposeSlot(index: 0))"
        XCTAssertEqual(try Self.slotLiterals(in: Self.code(shipped)), 1)
        let shippedReseed = "                            slot ?? ComposeSlot(index: 0),"
        XCTAssertEqual(try Self.slotLiterals(in: Self.code(shippedReseed)), 1)
        XCTAssertEqual(try Self.slotLiterals(in: Self.code("ComposeWindowContent(slot: slot ?? .init(index: 0))")), 1)
        XCTAssertEqual(try Self.slotLiterals(in: Self.code("    /// used to fall back to `ComposeSlot(index: 0)`")), 0)
    }

    private static func slotLiterals(in code: String) throws -> Int {
        try code.ranges(of: Regex(#"(\bComposeSlot(\.init)?|\.init)\(\s*index:"#)).count
    }

    /// Line comments cut first: prose about the old fallback is not one.
    private static func code(_ body: String) -> String {
        body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
    }

    private static func source(_ relativePath: String) throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
