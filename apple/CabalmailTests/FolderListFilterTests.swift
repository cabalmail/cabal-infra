import XCTest
import CabalmailKit
@testable import Cabalmail

// The mail sidebar's filter pills replaced the Subscribed / All folders
// sections. These pin the pill semantics (two independent toggles; both
// off is every folder, with no All pill to say so), the predicate, and the
// two exemptions.
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
        XCTAssertFalse(FolderListFilter.defaultForMail.isOn(.unread))
    }

    func testEveryFolderIsTheStateWithNeitherToggleOnAndThereIsNoAllPill() {
        XCTAssertTrue(FolderListFilter.unfiltered.isAll)
        XCTAssertFalse(FolderListFilter(subscribed: false, unread: true).isAll)
        XCTAssertEqual(FolderListFilter.Pill.allCases, [.subscribed, .unread],
                       "turning both toggles off is the whole of \"All\"; a third pill only restated it")
    }

    func testTogglingBothOffReachesEveryFolderAndTheOthersFlipThemselves() {
        let both = FolderListFilter(subscribed: true, unread: true)
        XCTAssertTrue(both.toggled(.subscribed).toggled(.unread).isAll)
        XCTAssertEqual(both.toggled(.subscribed), FolderListFilter(subscribed: false, unread: true))
        XCTAssertEqual(both.toggled(.unread), FolderListFilter(subscribed: true, unread: false))
        XCTAssertEqual(
            FolderListFilter.defaultForMail.toggled(.unread),
            FolderListFilter(subscribed: true, unread: true),
            "Subscribed and Unread combine; picking one does not drop the other"
        )
    }

    func testNoPillDrawsEveryFolder() {
        let all = FolderListFilter.unfiltered
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

    // MARK: - The hint when a find loses to a pill (#1662)

    /// The tree's own pipeline, in the order `FolderListView.filteredFolders`
    /// runs it: pills first, then the needle. Composed from the same two
    /// primitives that view calls, so only the composition is restated here.
    private func visible(_ filter: FolderListFilter, needle: String, selection: String? = nil) -> [Folder] {
        let byPills = filter.apply(to: folders, unreadCounts: counts, selection: selection)
        let trimmed = needle.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return byPills }
        return byPills.filter { FolderListFilter.matches($0, needle: trimmed) }
    }

    func testANeedleTheFilterHidesEntirelyIsCountedAndNamed() {
        // The reported case: `beta` exists, is unsubscribed, and the
        // Subscribed pill drew nothing at all for it.
        let subscribed = FolderListFilter.defaultForMail
        let drawn = visible(subscribed, needle: "beta")
        XCTAssertEqual(drawn.map(\.path), [], "the reported symptom: the tree is empty")
        let hint = subscribed.hint(for: folders, visible: drawn, needle: "beta")
        XCTAssertEqual(hint, FolderListFilter.Hint(suppressed: 1, anyVisible: false))
        XCTAssertEqual(hint?.label, "Show 1 hidden match in all folders")
    }

    func testANeedleTheFilterHidesOnlyPartlyCountsTheRest() {
        let subscribed = FolderListFilter.defaultForMail
        let drawn = visible(subscribed, needle: "alpha")
        XCTAssertEqual(drawn.map(\.path), ["alpha"])
        XCTAssertEqual(subscribed.hint(for: folders, visible: drawn, needle: "alpha")?.label,
                       "Show 1 more match in all folders",
                       "a drawn row does not excuse the ones the pill took")
        let wide = visible(subscribed, needle: "a")
        XCTAssertEqual(subscribed.hint(for: folders, visible: wide, needle: "a")?.label,
                       "Show 3 more matches in all folders")
    }

    func testThereIsNothingToSayWhenNothingIsSuppressed() {
        let subscribed = FolderListFilter.defaultForMail
        XCTAssertNil(subscribed.hint(for: folders, visible: visible(subscribed, needle: ""), needle: ""),
                     "no needle is browsing, not finding")
        XCTAssertNil(subscribed.hint(for: folders, visible: visible(subscribed, needle: "  "), needle: "  "))
        XCTAssertNil(subscribed.hint(for: folders, visible: visible(subscribed, needle: "inbox"), needle: "inbox"),
                     "every match is already drawn")
        let all = FolderListFilter(subscribed: false, unread: false)
        XCTAssertNil(all.hint(for: folders, visible: visible(all, needle: "beta"), needle: "beta"),
                     "no pill suppresses nothing, so it can hide nothing")
    }

    func testTheOpenFolderExemptionDoesNotRaiseAHint() {
        let subscribed = FolderListFilter.defaultForMail
        let drawn = visible(subscribed, needle: "trash", selection: "Trash")
        XCTAssertEqual(drawn.map(\.path), ["Trash"], "the open folder is exempt from the pills")
        XCTAssertNil(subscribed.hint(for: folders, visible: drawn, needle: "trash"),
                     "the row the exemption drew is a match, not a suppression")
    }
}
