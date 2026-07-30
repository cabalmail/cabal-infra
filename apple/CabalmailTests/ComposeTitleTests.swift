import XCTest
import CabalmailKit
@testable import Cabalmail

// Regression coverage for issue #845: tapping Edit Draft on a saved draft
// put up a composer titled "New Message", on both iPhone and iPad. It isn't
// a new message — the form comes up populated from the draft, and sending it
// replaces that draft rather than creating a second one. The title now keys
// off whether the surface opened on an existing server-side Drafts copy.
@MainActor
final class ComposeTitleTests: XCTestCase {

    func testEditingASavedDraftSaysDraft() throws {
        // What `DraftResume.seed` produces: an ordinary compose seed carrying
        // the Drafts-folder coordinates of the copy being resumed.
        let model = try TestFixtures.makeComposeModel(
            seed: Draft(subject: "Half-written", serverUid: 42, serverUidValidity: 9)
        )

        XCTAssertEqual(model.navigationTitle, "Draft")
    }

    func testFreshComposeSaysNewMessage() throws {
        let model = try TestFixtures.makeComposeModel()

        XCTAssertEqual(model.navigationTitle, "New Message")
    }

    func testReplyIsStillANewMessage() throws {
        let model = try TestFixtures.makeComposeModel(
            seed: Draft(subject: "Re: hello", inReplyTo: "<abc@example.com>", composeIntent: .reply)
        )

        XCTAssertEqual(
            model.navigationTitle, "New Message",
            "a reply really is a new message — only a resumed Drafts copy isn't"
        )
    }

    func testAutosavingAFreshComposeDoesNotRetitleIt() throws {
        let model = try TestFixtures.makeComposeModel()

        // The first `/save_draft` round trip of a brand-new compose records a
        // server ref; the title must keep describing what the user opened.
        model.serverDraftRef = DraftServerRef(uid: 7, uidValidity: 9)

        XCTAssertEqual(model.navigationTitle, "New Message")
    }
}
