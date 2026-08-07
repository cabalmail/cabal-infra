import XCTest
import CabalmailKit
@testable import Cabalmail

// Regression coverage for issues #845 and #897: a composer that opens
// populated was titled "New Message". #845 covered the resumed Drafts copy
// (sending it replaces that draft rather than creating a second one) and
// left replies on the generic title; #897 reported the reply case as the
// one that was missed — the sheet says "New Message" over a filled-in To,
// a "Re: " subject, and the quoted original. The title now keys off the
// server-side Drafts copy first, then the compose intent.
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

    func testReplySaysReply() throws {
        // The reported composer: opened from the reader's Reply menu, so it
        // comes up with the recipient, "Re: <subject>", and the quoted body
        // already filled in (#897). It used to say "New Message".
        let model = try TestFixtures.makeComposeModel(
            seed: Draft(subject: "Re: hello", inReplyTo: "<abc@example.com>", composeIntent: .reply)
        )

        XCTAssertEqual(model.navigationTitle, "Reply")
    }

    func testReplyAllSaysReplyAll() throws {
        let model = try TestFixtures.makeComposeModel(
            seed: Draft(subject: "Re: hello", inReplyTo: "<abc@example.com>", composeIntent: .replyAll)
        )

        XCTAssertEqual(model.navigationTitle, "Reply All")
    }

    func testForwardSaysForward() throws {
        let model = try TestFixtures.makeComposeModel(
            seed: Draft(subject: "Fwd: hello", composeIntent: .forward)
        )

        XCTAssertEqual(model.navigationTitle, "Forward")
    }

    func testAResumedDraftSaysDraftEvenWhenItBeganAsAReply() throws {
        // Precedence: what the user reopened is a draft, whatever it was
        // first composed as.
        let model = try TestFixtures.makeComposeModel(
            seed: Draft(
                subject: "Re: hello",
                inReplyTo: "<abc@example.com>",
                composeIntent: .reply,
                serverUid: 42,
                serverUidValidity: 9
            )
        )

        XCTAssertEqual(model.navigationTitle, "Draft")
    }

    func testAutosavingAFreshComposeDoesNotRetitleIt() throws {
        let model = try TestFixtures.makeComposeModel()

        // The first `/save_draft` round trip of a brand-new compose records a
        // server ref; the title must keep describing what the user opened.
        model.serverDraftRef = DraftServerRef(uid: 7, uidValidity: 9)

        XCTAssertEqual(model.navigationTitle, "New Message")
    }
}
