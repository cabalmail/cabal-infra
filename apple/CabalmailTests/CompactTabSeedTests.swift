import XCTest
import CabalmailKit
@testable import Cabalmail

/// The tab the compact section tree opens on. It is seeded from the resume
/// session every time the tree is built — at launch and again whenever the
/// layout swaps back from the regular split (closing an iPhone Duo, narrowing
/// an iPad window) — so the mapping is the whole contract (#1644).
final class CompactTabSeedTests: XCTestCase {

    func testFeedsSessionOpensTheFeedsTab() {
        XCTAssertEqual(CompactTab.initial(for: .feeds), .feeds)
    }

    func testMailSessionOpensTheMailTab() {
        XCTAssertEqual(CompactTab.initial(for: .mail), .mail)
    }

    func testNoSessionOpensTheMailTab() {
        // A fresh install, or a coordinator that has not loaded a session.
        XCTAssertEqual(CompactTab.initial(for: nil), .mail)
    }

    func testOnlyTheContentTabsAreSections() {
        // The utility tabs never move the resume session, so a tree rebuilt
        // while one of them was showing lands on a content tab instead.
        XCTAssertEqual(CompactTab.mail.resumeSection, .mail)
        XCTAssertEqual(CompactTab.feeds.resumeSection, .feeds)
        XCTAssertNil(CompactTab.addresses.resumeSection)
        XCTAssertNil(CompactTab.settings.resumeSection)
        XCTAssertNil(CompactTab.search.resumeSection)
    }

    func testContentTabsRoundTripThroughTheSession() {
        for tab in [CompactTab.mail, .feeds] {
            XCTAssertEqual(CompactTab.initial(for: tab.resumeSection), tab)
        }
    }
}
