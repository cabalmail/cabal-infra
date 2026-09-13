import XCTest
@testable import Cabalmail

// Regression coverage for #1548.
//
// Both sidebars head the feed list with an "All Feeds" row, and each used to
// build it itself. The wide sidebar synthesised a `FeedSidebarRow` and drew it
// through `FeedSidebarRowLabel`; the compact Feeds tab (iPhone, visionOS) drew
// a bare `Label("All Feeds", systemImage: "tray.full").badge(…)` instead. So
// on iPhone the row was the only one in its own list without the accent icon
// and the capsule count — SwiftUI's native `.badge` is plain trailing text,
// and a bare `Label` takes the default tint.
//
// The row now comes from `FeedSidebarRows.allFeedsRow(unread:)` and is drawn
// by the shared label in both layouts. These scans pin that: a layout that
// goes back to hand-building the row fails here, which is the failure the
// pixel difference could not produce on its own.
final class AllFeedsRowSourceScanTests: XCTestCase {

    /// The two files that draw an All Feeds row.
    private static let sidebarSources = [
        "Cabalmail/Views/FeedSidebarSection.swift",   // compact: the Feeds tab
        "Cabalmail/Views/FolderListView+Helpers.swift", // regular-width sidebar
    ]

    func testBothSidebarsAskForTheSharedRow() throws {
        for path in Self.sidebarSources {
            let body = try Self.source(path)
            XCTAssertTrue(
                body.contains("FeedSidebarRows.allFeedsRow("),
                "\(path): build the All Feeds row with FeedSidebarRows.allFeedsRow (#1548)"
            )
            XCTAssertTrue(
                body.contains("FeedSidebarRowLabel("),
                "\(path): draw it with the shared row label, which is what tints the icon (#1548)"
            )
        }
    }

    /// The row's shape lives in one place. A second copy is what let the two
    /// layouts disagree, and the literal title is how you spot one.
    func testNeitherSidebarHandBuildsTheRow() throws {
        var offenders: [String] = []
        for path in Self.sidebarSources
        where Self.code(in: try Self.source(path)).contains("\"All Feeds\"") {
            offenders.append(path)
        }
        XCTAssertEqual(offenders, [], "the All Feeds row is FeedSidebarRows' to build (#1548)")
    }

    /// Both files name the row in a doc comment explaining what it is, so the
    /// scan above has to read code rather than prose — it reported the wide
    /// sidebar as an offender until it did.
    func testTheScanReadsCodeNotProse() {
        XCTAssertFalse(Self.code(in: "/// The \"All Feeds\" row at the top").contains("\"All Feeds\""))
        XCTAssertFalse(Self.code(in: "    // named \"All Feeds\" here").contains("\"All Feeds\""))
        XCTAssertTrue(Self.code(in: "Label(\"All Feeds\", systemImage:)").contains("\"All Feeds\""))
        XCTAssertTrue(Self.code(in: "Label(\"All Feeds\") // the old row").contains("\"All Feeds\""))
    }

    /// The compact list's own defect, named: SwiftUI's `.badge` draws plain
    /// trailing text where every sibling row draws a capsule.
    func testTheCompactFeedsTabDrawsNoNativeBadge() throws {
        let body = try Self.source("Cabalmail/Views/FeedSidebarSection.swift")
        XCTAssertFalse(
            body.contains(".badge("),
            "a native badge is not the capsule the sibling rows draw (#1548)"
        )
    }

    /// Floor: a mis-rooted scan would read every file as empty and pass all
    /// three assertions above vacuously.
    func testCorpusIsReadable() throws {
        for path in Self.sidebarSources {
            XCTAssertTrue(
                try Self.source(path).contains("FeedSidebarRowLabel"),
                "\(path) did not load — the scan would be vacuous"
            )
        }
    }

    /// `body` with line comments cut, so a doc comment naming the row is not
    /// read as a declaration of one.
    private static func code(in body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
    }

    private static func source(_ relativePath: String) throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        return try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
