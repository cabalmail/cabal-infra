import XCTest
@testable import Cabalmail

// Regression coverage for #1626, second pass.
//
// The first fix evicted the Settings gear from the message-list column's bar
// and the retest (2026-09-27) found the slot already spent: the More menu had
// landed on 09-24, the bar was back to five occupants, and at the column's
// 300 pt floor — one drag of the resize handle from the default 360 — UIKit
// folded Addresses and More into a system `OverflowBarButtonItem` that never
// presents. So the bar was never made width-independent, which is the property
// #1059's own doc comment argued for.
//
// The rule these tests hold: the folder switch is not bar furniture on a
// column-scoped bar, and what is left in that bar is either ranked to stay or
// has a second home. Nothing renders a UIKit navigation bar in a unit test, so
// the policy is tested directly and its wiring by source scan (#1201).
final class FolderSwitchPlacementTests: XCTestCase {

    // MARK: - The policy

    func testAColumnScopedBarHostsTheSwitchInTheColumn() {
        XCTAssertEqual(
            FolderSwitchPlacement.host(isWideSidebar: true, columnScopedToolbar: true),
            .columnHeader,
            "regular-width iPad: the bar has no room for a title menu (#1626)"
        )
    }

    func testAWindowWideBarKeepsTheSystemTitleMenu() {
        // visionOS: wide, but its bar is ornament-hosted rather than scoped to
        // the list column, so the title menu costs the list nothing.
        XCTAssertEqual(
            FolderSwitchPlacement.host(isWideSidebar: true, columnScopedToolbar: false),
            .titleMenu
        )
    }

    func testCompactKeepsTheSystemTitleMenuEitherWay() {
        // Compact iPhone draws one full-width column: there is no neighbouring
        // pane to lose width to, and the title menu is the platform idiom.
        XCTAssertEqual(
            FolderSwitchPlacement.host(isWideSidebar: false, columnScopedToolbar: true),
            .titleMenu
        )
        XCTAssertEqual(
            FolderSwitchPlacement.host(isWideSidebar: false, columnScopedToolbar: false),
            .titleMenu
        )
    }

    // MARK: - The wiring

    /// Both hosts are drawn, and the column-header one takes the bar's title
    /// with it: the header *is* the folder name, and the title region is the
    /// width this fix reclaims.
    func testTheTouchBranchDrawsBothHosts() throws {
        let body = try Self.source("Cabalmail/Views/MessageListView+FolderSwitch.swift")
        XCTAssertTrue(body.contains("switch folderSwitchHost {"))
        let titleMenu = "case .titleMenu:\n"
            + "                content.toolbarTitleMenu { folderSwitchMenuItems }"
        XCTAssertTrue(body.contains(titleMenu))
        let columnHeader = try Self.slice(
            body, from: "case .columnHeader:", to: "            }\n            #endif"
        )
        XCTAssertTrue(columnHeader.contains("folderSwitchHeaderMenu"))
        XCTAssertTrue(
            columnHeader.contains(".toolbar(removing: .title)"),
            "a title left in the bar costs the width the menu just gave back (#1626)"
        )
    }

    /// The header menu is the Mac's menu with a different host, so a driver
    /// (and an assistive client) reads one affordance on both.
    func testTheHeaderMenuMatchesTheMacsIdentity() throws {
        let body = try Self.source("Cabalmail/Views/MessageListView+FolderSwitch.swift")
        XCTAssertEqual(
            body.components(separatedBy: #"accessibilityIdentifier("list.folderSwitch")"#).count - 1, 2,
            "the iPad header menu and the Mac toolbar menu share the identifier"
        )
        XCTAssertEqual(
            body.components(separatedBy: #"accessibilityHint("Switch folder")"#).count - 1, 2
        )
    }

    /// The other half of the invariant: the More menu is the only item the
    /// system overflow may take, because Mark All as Read has two other routes.
    /// If that ever stops being true, the bar needs a fourth ranked item.
    func testMarkAllAsReadHasARouteOffTheBar() throws {
        let sidebar = try Self.source("Cabalmail/Views/FolderListView+Helpers.swift")
        XCTAssertTrue(
            sidebar.contains("markAllRead(folderPath: folder.path)"),
            "the folder list's own menu is the More menu's second home (#1626)"
        )
        let signals = try Self.source("Cabalmail/AppStateSignals.swift")
        XCTAssertTrue(signals.contains("func requestMarkFolderRead()"), "⌥⌘T is the third route")
    }

    /// Floor: a mis-rooted read finds nothing and passes everything above.
    func testTheSourceIsReadable() throws {
        let body = try Self.source("Cabalmail/Views/MessageListView+FolderSwitch.swift")
        XCTAssertTrue(body.contains("extension MessageListView {"))
    }

    // MARK: - Corpus

    private static func slice(_ body: String, from start: String, to end: String) throws -> String {
        guard let lower = body.range(of: start),
              let upper = body.range(of: end, range: lower.upperBound..<body.endIndex) else {
            XCTFail("the landmarks this scan reads are gone")
            return ""
        }
        return String(body[lower.upperBound..<upper.lowerBound])
    }

    private static let apple = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
