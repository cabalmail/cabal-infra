import XCTest
import CabalmailKit
@testable import Cabalmail

// The mail sidebar's filter pills replaced the Subscribed / All folders
// sections. These pin the pill semantics (All is "neither toggle", the
// other two are independent), the predicate, and the two exemptions.
final class FolderListFilterTests: XCTestCase {

    private func folder(_ path: String, subscribed: Bool = true) -> Folder {
        Folder(path: path, attributes: [], isSubscribed: subscribed)
    }

    private var folders: [Folder] {
        [folder("INBOX"), folder("alpha"), folder("alpha/kid", subscribed: false),
         folder("beta", subscribed: false), folder("Trash", subscribed: false)]
    }

    private let counts = ["INBOX": 3, "alpha/kid": 1, "beta": 2]

    func testFreshInstallOpensOnSubscribed() {
        XCTAssertEqual(FolderListFilter.defaultForMail, FolderListFilter(subscribed: true, unread: false))
        XCTAssertTrue(FolderListFilter.defaultForMail.isOn(.subscribed))
        XCTAssertFalse(FolderListFilter.defaultForMail.isOn(.all))
    }

    func testAllIsTheStateWithNeitherToggleOn() {
        let all = FolderListFilter(subscribed: false, unread: false)
        XCTAssertTrue(all.isAll)
        XCTAssertTrue(all.isOn(.all))
        XCTAssertFalse(FolderListFilter(subscribed: false, unread: true).isOn(.all))
    }

    func testTappingAllClearsBothTogglesAndTheOthersFlipThemselves() {
        let both = FolderListFilter(subscribed: true, unread: true)
        XCTAssertTrue(both.toggled(.all).isAll)
        XCTAssertEqual(both.toggled(.subscribed), FolderListFilter(subscribed: false, unread: true))
        XCTAssertEqual(both.toggled(.unread), FolderListFilter(subscribed: true, unread: false))
        XCTAssertEqual(
            FolderListFilter.defaultForMail.toggled(.unread),
            FolderListFilter(subscribed: true, unread: true),
            "Subscribed and Unread combine; picking one does not drop the other"
        )
    }

    func testAllDrawsEveryFolder() {
        let all = FolderListFilter(subscribed: false, unread: false)
        XCTAssertEqual(all.apply(to: folders, unreadCounts: counts, selection: nil).map(\.path),
                       folders.map(\.path))
    }

    func testSubscribedDrawsTheSubscribedSubset() {
        let rows = FolderListFilter.defaultForMail.apply(to: folders, unreadCounts: counts, selection: nil)
        XCTAssertEqual(rows.map(\.path), ["INBOX", "alpha"])
    }

    func testUnreadDrawsFoldersWithAKnownPositiveCount() {
        let unread = FolderListFilter(subscribed: false, unread: true)
        XCTAssertEqual(unread.apply(to: folders, unreadCounts: counts, selection: nil).map(\.path),
                       ["INBOX", "alpha/kid", "beta"],
                       "an unknown count reads as no unread — the walk fills it in, the row appears then")
    }

    func testSubscribedAndUnreadIntersect() {
        let both = FolderListFilter(subscribed: true, unread: true)
        XCTAssertEqual(both.apply(to: folders, unreadCounts: counts, selection: nil).map(\.path), ["INBOX"])
    }

    func testTheOpenFolderIsExemptFromTheFilter() {
        let both = FolderListFilter(subscribed: true, unread: true)
        XCTAssertEqual(both.apply(to: folders, unreadCounts: counts, selection: "Trash").map(\.path),
                       ["INBOX", "Trash"],
                       "the folder being read never vanishes from under the user")
    }

    func testOnlyUnreadWithoutSubscribedNeedsEveryCount() {
        XCTAssertTrue(FolderListFilter(subscribed: false, unread: true).needsEveryCount)
        XCTAssertFalse(FolderListFilter(subscribed: true, unread: true).needsEveryCount,
                       "subscribed folders' counts are already fetched proactively")
        XCTAssertFalse(FolderListFilter.defaultForMail.needsEveryCount)
        XCTAssertFalse(FolderListFilter(subscribed: false, unread: false).needsEveryCount)
    }
}
