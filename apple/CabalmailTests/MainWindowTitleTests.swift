import XCTest
@testable import CabalmailUI

/// What a main window calls itself in the Window menu and the app switcher
/// (`MainWindowTitle`). Before #2036 the iPad `WindowGroup` had no title of
/// its own and inherited the trailing inspector's "Addresses", so every
/// window was called that whatever folder it showed; the rule here is what
/// `SignedInRootView` writes onto the scene instead.
final class MainWindowTitleTests: XCTestCase {

    /// The reported defect, as a rule: a wide window on a folder is called
    /// that folder, never "Addresses". The inspector's own navigation title
    /// is untouched, so nothing in the rule may produce it from mail.
    func testTheWideSplitOnAFolderIsCalledTheFolder() {
        for folder in ["INBOX", "Archive", "Sent"] {
            XCTAssertEqual(
                MainWindowTitle.title(
                    isWide: true, splitShowsFeeds: false, compactTab: .mail, folderName: folder
                ),
                folder
            )
        }
    }

    /// The feed side of the wide split names itself, and the mail folder
    /// behind it does not leak through.
    func testTheWideSplitShowingFeedsIsCalledFeeds() {
        XCTAssertEqual(
            MainWindowTitle.title(
                isWide: true, splitShowsFeeds: true, compactTab: .mail, folderName: "INBOX"
            ),
            "Feeds"
        )
    }

    /// `splitShowsFeeds` is the feeds section *with a list open*, so a
    /// window whose feeds section has no scope is still showing mail. The
    /// rule must read that flag rather than the tab, which the wide split
    /// does not draw.
    func testTheWideSplitIgnoresTheCompactTab() {
        XCTAssertEqual(
            MainWindowTitle.title(
                isWide: true, splitShowsFeeds: false, compactTab: .feeds, folderName: "Archive"
            ),
            "Archive"
        )
    }

    /// A window that has not landed on a folder has nothing more specific to
    /// report, so it takes the app's name — not an empty title, and not the
    /// inspector's.
    func testMailWithNoFolderIsCalledTheApp() {
        for folderName in [nil, ""] as [String?] {
            XCTAssertEqual(
                MainWindowTitle.title(
                    isWide: true, splitShowsFeeds: false, compactTab: .mail, folderName: folderName
                ),
                "Cabalmail"
            )
            XCTAssertEqual(
                MainWindowTitle.title(
                    isWide: false, splitShowsFeeds: false, compactTab: .mail, folderName: folderName
                ),
                "Cabalmail"
            )
        }
    }

    /// On a tab bar the window really is showing the tab that is up, so the
    /// utility tabs name themselves — including Addresses, which is the one
    /// title the defect produced everywhere and is correct in exactly this
    /// one place.
    func testTheTabBarsUtilityTabsNameThemselves() {
        for tab in [CompactTab.folders, .addresses, .settings, .search] {
            XCTAssertEqual(
                MainWindowTitle.title(
                    isWide: false, splitShowsFeeds: false, compactTab: tab, folderName: "INBOX"
                ),
                tab.title,
                "\(tab)"
            )
        }
    }

    /// The compact Mail and Feeds tabs take the folder and the feed reader,
    /// as their wide counterparts do.
    func testTheTabBarsContentTabsFollowTheirSection() {
        XCTAssertEqual(
            MainWindowTitle.title(
                isWide: false, splitShowsFeeds: false, compactTab: .mail, folderName: "Archive"
            ),
            "Archive"
        )
        XCTAssertEqual(
            MainWindowTitle.title(
                isWide: false, splitShowsFeeds: false, compactTab: .feeds, folderName: "Archive"
            ),
            "Feeds"
        )
    }

    /// Negative control for the whole rule: no combination of inputs the
    /// mail side can take produces "Addresses", which is what the window was
    /// called before the fix. Only the Addresses *tab* may, and it is the
    /// one input excluded here.
    func testNoMailStateIsEverCalledAddresses() {
        for isWide in [true, false] {
            for showsFeeds in [true, false] {
                for tab in [CompactTab.mail, .folders, .feeds, .settings, .search] {
                    for folder in [nil, "INBOX", "Addresses"] as [String?] {
                        let title = MainWindowTitle.title(
                            isWide: isWide, splitShowsFeeds: showsFeeds,
                            compactTab: tab, folderName: folder
                        )
                        if folder == "Addresses" && title == "Addresses" {
                            // A folder a user really named "Addresses" is
                            // its own name, not the inspector's.
                            XCTAssertTrue(tab == .mail || isWide, "\(tab) \(isWide)")
                            continue
                        }
                        XCTAssertNotEqual(title, "Addresses", "\(isWide) \(showsFeeds) \(tab) \(folder ?? "nil")")
                    }
                }
            }
        }
    }
}
