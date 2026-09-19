import XCTest
@testable import Cabalmail

/// Pins the order the launch restore pushes a list and its reader. Pushing
/// both in one update leaves the compact stack showing a reader that SwiftUI
/// never runs `onAppear` for, so it never loads and sits on a spinner
/// (#1664, reproduced on the iOS 27.1 simulator). Nothing renders a stack in
/// a unit test, so this scans the two places that decide the order.
final class LaunchRestoreSequencingSourceScanTests: XCTestCase {

    func testTheFeedItemRestoreIsAppliedFromTheListNotTheScopeChange() throws {
        let body = try Self.source("Cabalmail/Views/FeedRootView.swift")
        let scopeHandler = try XCTUnwrap(Self.block(of: ".onChange(of: selectedScope)", in: body))
        XCTAssertFalse(
            scopeHandler.contains("consumeFeedItemRestore"),
            "the scope's onChange must not select the restored item in the same update"
        )
        XCTAssertFalse(body.contains("consumeFeedItemRestore"), "FeedRootView no longer consumes the restore at all")
        let list = try Self.source("Cabalmail/Views/FeedItemListView.swift")
        XCTAssertTrue(list.contains("guard hasAppeared, initialLoadComplete, selection == nil,"))
        XCTAssertTrue(list.contains("let restored = appState.navCoordinator?.consumeFeedItemRestore(for: scope)"))
        XCTAssertEqual(
            list.components(separatedBy: "applyLaunchRestoreWhenReady()").count - 1, 3,
            "declared once, called after the initial load and from onAppear"
        )
    }

    func testTheMailRestoreWaitsForTheListToAppearAndLoad() throws {
        let body = try Self.source("Cabalmail/Views/MessageListView.swift")
        XCTAssertTrue(body.contains("guard hasAppeared, initialLoadComplete, let model else { return }"))
        XCTAssertEqual(
            body.components(separatedBy: "applyPendingRestoreWhenReady()").count - 1, 3,
            "declared once, called after the initial load and from onAppear"
        )
    }

    /// The text from `marker` to the end of the brace block it opens.
    private static func block(of marker: String, in source: String) -> String? {
        guard let start = source.range(of: marker) else { return nil }
        var depth = 0
        var index = start.upperBound
        var opened = false
        while index < source.endIndex {
            let char = source[index]
            if char == "{" { depth += 1; opened = true }
            if char == "}" { depth -= 1; if opened && depth == 0 { return String(source[start.lowerBound...index]) } }
            index = source.index(after: index)
        }
        return nil
    }

    private static let apple = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CabalmailTests
        .deletingLastPathComponent()   // apple

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
