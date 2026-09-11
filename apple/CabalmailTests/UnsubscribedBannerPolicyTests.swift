import XCTest
import CabalmailKit
@testable import Cabalmail

/// The unsubscribed-folder banner used to gate on the selected `Folder`
/// value's `isSubscribed`, which is a default — not a fact — whenever the
/// selection was made from a stand-in `Folder(path:)` (resume toast, push
/// tap, Spotlight, Siri). It therefore called subscribed folders
/// unsubscribed on every one of those routes. The policy reads the
/// published LSUB set instead.
final class UnsubscribedBannerPolicyTests: XCTestCase {
    func testAStandInForASubscribedFolderShowsNoBanner() {
        // Navigate requests construct exactly this: path only, flag defaulted.
        let standIn = Folder(path: "GitHub")
        XCTAssertFalse(standIn.isSubscribed, "precondition: the stand-in's flag is the default")
        XCTAssertFalse(UnsubscribedBannerPolicy.shouldShow(
            folder: standIn, subscribedPaths: ["INBOX", "GitHub"]
        ))
    }

    func testAFolderAbsentFromTheSetShowsTheBannerEvenIfItsValueSaysSubscribed() {
        // The selection can also hold a value that is stale the other way:
        // unsubscribed from the sidebar while the folder is open.
        let stale = Folder(path: "Newsletters", isSubscribed: true)
        XCTAssertTrue(UnsubscribedBannerPolicy.shouldShow(
            folder: stale, subscribedPaths: ["INBOX"]
        ))
    }

    func testBeforeAnyListLandsTheValueFlagIsTrusted() {
        let provisionalInbox = Folder(path: "INBOX", isSubscribed: true)
        XCTAssertFalse(UnsubscribedBannerPolicy.shouldShow(folder: provisionalInbox, subscribedPaths: nil))
        XCTAssertTrue(UnsubscribedBannerPolicy.shouldShow(folder: Folder(path: "Archive"), subscribedPaths: nil))
    }

    func testAnEmptySetIsKnownAndMeansNothingIsSubscribed() {
        XCTAssertTrue(UnsubscribedBannerPolicy.shouldShow(
            folder: Folder(path: "INBOX", isSubscribed: true), subscribedPaths: []
        ))
    }
}
