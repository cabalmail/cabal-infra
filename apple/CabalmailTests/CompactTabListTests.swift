import XCTest
@testable import CabalmailUI

/// The tab lists the tab shells draw (`CompactTab.tabs(for:)`). The phone's
/// bar and visionOS's ornament were two hand-written `TabView`s; now each
/// draws the list for its layout, pinned here on the Mac host (visionOS is
/// build-only on a PR).
final class CompactTabListTests: XCTestCase {

    func testThePhoneBarIsMailFeedsAddressesSettingsSearch() {
        XCTAssertEqual(CompactTab.tabs(for: .tabs), [.mail, .feeds, .addresses, .settings, .search])
    }

    /// visionOS's Mail tab has no folder sidebar, so Folders is a tab of its
    /// own, right after Mail.
    func testVisionKeepsFoldersSecond() {
        XCTAssertEqual(
            CompactTab.tabs(for: .ornament),
            [.mail, .folders, .feeds, .addresses, .settings, .search]
        )
    }

    /// The phone's Search tab detaches and morphs into the field; visionOS
    /// keeps a plain Search tab in its ornament. No other tab has a role.
    func testOnlyThePhonesSearchTakesTheSearchRole() {
        for layout in [ShellLayout.desktop, .split, .tabs, .ornament] {
            for tab in [CompactTab.mail, .folders, .feeds, .addresses, .settings, .search] {
                let expected: CompactTab.Role? = (layout == .tabs && tab == .search) ? .search : nil
                XCTAssertEqual(tab.role(in: layout), expected, "\(tab) on \(layout)")
            }
        }
    }

    func testTheWideLayoutsHaveNoTabBar() {
        XCTAssertTrue(CompactTab.tabs(for: .desktop).isEmpty)
        XCTAssertTrue(CompactTab.tabs(for: .split).isEmpty)
    }

    /// The titles and symbols the two bars drew when they were written out.
    func testTitlesAndSymbolsAreTheOnesTheBarsDrew() {
        let titles: [CompactTab: String] = [
            .mail: "Mail", .folders: "Folders", .feeds: "Feeds",
            .addresses: "Addresses", .settings: "Settings", .search: "Search",
        ]
        let symbols: [CompactTab: String] = [
            .mail: "tray", .folders: "folder", .feeds: "dot.radiowaves.up.forward",
            .addresses: "at", .settings: "gear", .search: "magnifyingglass",
        ]
        for tab in CompactTab.tabs(for: .ornament) {
            XCTAssertEqual(tab.title, titles[tab])
            XCTAssertEqual(tab.systemImage, symbols[tab])
        }
    }

    /// Every tab a bar draws is one the session can be on, and the content
    /// tabs keep their sections.
    func testTheListsKeepTheSessionsSections() {
        XCTAssertEqual(CompactTab.tabs(for: .tabs).compactMap(\.resumeSection), [.mail, .feeds])
        XCTAssertEqual(CompactTab.tabs(for: .ornament).compactMap(\.resumeSection), [.mail, .mail, .feeds])
    }
}
