import XCTest
@testable import CabalmailUI

// The compact iPhone tab bar heads every tab's root screen with the Cabalmail
// mark in place of a text title, the way the Mail tab's folder list always
// has. The mark is applied per root through `compactBrandMarkTitle`, gated on
// the `showsCompactBrandMark` environment flag the tab bar sets, so the same
// bodies keep their text titles in the iPad settings sheet and the wide
// sidebar's inspector.
//
// Nothing renders the mark in a unit test, so these scans pin the wiring: the
// tab bar sets the flag, each root opts in, and the pushed screens (settings
// categories, feed item lists and readers) do not — the mark belongs to the
// outermost screen of a tab only.
final class CompactBrandMarkSourceScanTests: XCTestCase {

    /// One root screen per compact tab, with the title the mark stands in for.
    private static let tabRoots: [(path: String, title: String)] = [
        ("CabalmailUI/Feeds/Sidebar/FeedSidebarSection.swift", "Feeds"),
        ("CabalmailUI/Addresses/AddressListView.swift", "Addresses"),
        ("CabalmailUI/Settings/SettingsView.swift", "Settings"),
        ("CabalmailUI/Mail/Search/SearchView.swift", "Search"),
    ]

    /// Screens reached by pushing from a tab root. They title themselves and
    /// must not take the mark.
    private static let pushedScreens = [
        "CabalmailUI/Settings/SettingsDetailViews.swift",
        "CabalmailUI/Feeds/ItemList/FeedItemListView.swift",
        "CabalmailUI/Feeds/Reader/FeedItemDetailView.swift",
        "CabalmailUI/Mail/MessageList/MessageListView.swift",
        "CabalmailUI/Mail/Reader/MessageDetailView.swift",
    ]

    func testTheCompactTabBarTurnsTheMarkOn() throws {
        let body = try Self.source("CabalmailUI/Shell/CompactSectionTabs.swift")
        XCTAssertTrue(
            body.contains(".environment(\\.showsCompactBrandMark, true)"),
            "CompactSectionTabs' TabView sets showsCompactBrandMark for its tabs"
        )
    }

    func testEveryTabRootOptsInWithItsOwnTitle() throws {
        for root in Self.tabRoots {
            let body = try Self.source(root.path)
            XCTAssertTrue(
                body.contains(".compactBrandMarkTitle(accessibilityTitle: \"\(root.title)\")"),
                "\(root.path): the compact tab root heads itself with the mark, read as \"\(root.title)\""
            )
            XCTAssertTrue(
                body.contains(".navigationTitle(\"\(root.title)\")"),
                "\(root.path): the text title stays for VoiceOver and the back button"
            )
        }
    }

    /// The Mail tab's folder list is the original: unconditional on every
    /// non-macOS layout, so it takes the ungated modifier rather than the
    /// environment-gated one.
    func testTheMailSidebarKeepsTheUnconditionalMark() throws {
        let body = try Self.source("Cabalmail/Views/MailRootView.swift")
        XCTAssertTrue(body.contains(".brandMarkTitle(size:"), "MailRootView's sidebar applies brandMarkTitle")
        XCTAssertFalse(body.contains(".compactBrandMarkTitle("), "the Mail sidebar is not environment-gated")
    }

    func testPushedScreensKeepTheirTextTitles() throws {
        for path in Self.pushedScreens {
            let body = try Self.source(path)
            XCTAssertFalse(
                body.contains("BrandMarkTitle("),
                "\(path): only a tab's outermost screen takes the mark"
            )
        }
    }

    /// The mark lives in one place. A second toolbar block building it by
    /// hand is what would let a tab drift from the others.
    func testOnlyTheSharedModifierBuildsTheToolbarItem() throws {
        var offenders: [String] = []
        let viewsDir = Self.apple.appendingPathComponent("CabalmailUI").path
        let views = try XCTUnwrap(FileManager.default.subpaths(atPath: viewsDir))
        for file in views
        where file.hasSuffix(".swift") && (file as NSString).lastPathComponent != "SidebarBranding.swift" {
            let body = try Self.source("CabalmailUI/\(file)")
            // The macOS sidebar hosts the mark directly (no toolbar), which is
            // the one hand-placed CabalmailMark that is not a title stand-in.
            if body.contains("ToolbarItem(placement: .principal)") && body.contains("CabalmailMark(") {
                offenders.append(file)
            }
        }
        XCTAssertEqual(offenders, [], "build the mark-as-title through brandMarkTitle / compactBrandMarkTitle")
    }

    /// Floor: a mis-rooted scan would read every file as empty and pass the
    /// negative assertions above vacuously.
    func testCorpusIsReadable() throws {
        for path in Self.pushedScreens + Self.tabRoots.map(\.path) {
            XCTAssertTrue(
                try Self.source(path).contains("import SwiftUI"),
                "\(path) did not load — the scan would be vacuous"
            )
        }
    }

    private static let apple = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CabalmailTests
        .deletingLastPathComponent()   // apple

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
