import XCTest
import CabalmailKit
@testable import Cabalmail

// Regression coverage for issue #1198: a Send that coincided with the
// 60-second server autosave left the autosaved Drafts copy on the server
// forever — the message delivered, and Drafts kept a full, re-sendable copy
// of it.
//
// This is the Send-path analogue of #1163, which #1169 fixed for Discard
// only. `/send` carries `discardingDraft:` and so ends the session's server
// copy exactly as a discard does, but `send()` went round
// `ServerDraftMutationQueue` entirely: it read `serverDraftRef` and called
// the endpoint directly. Both of the orderings that type's doc comment
// enumerates were therefore live on Send —
//
//   1. a save already in flight at the tap — `/send` names the UID the model
//      is holding, the completing save appends a fresh one, and nothing
//      retires it;
//   2. a tick landing *inside* the send round trip — the tick cleared
//      `guard !isSending, acceptsAutosave` and then suspended for a second in
//      `computeMessageBodies()`, so it resumed after the send had consumed
//      the ref and replaced a UID that was already gone, which
//      `/save_draft` degrades to save-as-new.
//
// The tester hit ordering 2 unaimed on 2 of 8 iPhone arms; the six
// non-coincident controls all pruned cleanly. Send now runs through
// `close(runningThrowing:)`.
@MainActor
final class DraftSendSaveRaceTests: XCTestCase {

    // MARK: - Ordering 1: a save already in flight when Send is tapped

    /// What the server has to see is one save (landing 786) followed by a
    /// send naming **786** — not 785, the UID the model was holding when the
    /// user tapped. Before the fix the send did not wait, so it named 785
    /// and 786 survived as the orphan.
    ///
    /// The bounded wait in the middle is the load-bearing assertion, and it
    /// is why this reads as a race rather than a coincidence: pre-fix the
    /// send goes on the wire *while the save is held there*, and the only
    /// reason it usually names the right UID anyway is that
    /// `buildOutgoingMessage` spends a WebKit round trip first, which is
    /// long enough for a real network save to land. That is luck, not an
    /// interlock — assert the ordering directly instead of waiting for the
    /// day the bridge answers faster than the network.
    func testSendWaitsForAnInFlightSaveAndDiscardsTheUidItLanded() async throws {
        let transport = DraftRaceTransport(nextSaveUid: 786)
        let model = try Self.makeSendableModel(transport: transport)

        await transport.holdNextSave()
        let save = Task { await model.pushDraftToServer(Self.probeMessage) }
        await transport.waitUntilSaveStarted()

        // The tap lands while the save is on the wire.
        let send = Task { await model.send() }
        let wentOutDuringTheSave = await transport.waitForCall(.send, within: 0.5)
        XCTAssertFalse(
            wentOutDuringTheSave,
            "/send must not reach the server while a /save_draft is still outstanding"
        )

        await transport.releaseHeldSave()
        _ = await save.value
        let sent = await send.value

        XCTAssertTrue(sent)
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.kind), [.save, .send])
        XCTAssertEqual(
            calls.last?.replacesUid, 786,
            "the send has to expunge the UID the completing save landed, not the one it superseded"
        )
    }

    // MARK: - Ordering 2: an autosave tick inside the send round trip

    /// A tick that *starts* while `/send` is on the wire must issue nothing.
    ///
    /// This one held before the fix too, and says so deliberately: the old
    /// `guard !isSending` already covered a tick that reaches its guard
    /// mid-send. It is here as the boundary of that guard — the case it does
    /// *not* cover is the test below.
    func testAnAutosaveTickDuringTheSendRoundTripIsDeclined() async throws {
        let transport = DraftRaceTransport(nextSaveUid: 786)
        let model = try Self.makeSendableModel(transport: transport)

        await transport.holdNextSend()
        let send = Task { await model.send() }
        await transport.waitUntilSendStarted()

        await model.autosaveToServer()
        await transport.releaseHeldSend()
        _ = await send.value

        let calls = await transport.calls
        XCTAssertEqual(
            calls.map(\.kind), [.send],
            "the tick inside the send round trip must not reach the network at all"
        )
    }

    /// **The reported failure.** `guard !isSending` is checked once, at the
    /// top of the tick, and the tick then spends about a second suspended in
    /// `computeMessageBodies()`. So the guard it passed is stale by the time
    /// it decides to write, and the state it resumes into is exactly this
    /// one: the send has been and gone, `isSending` is back to false, and
    /// `serverDraftRef` names a UID `/send` has expunged. Driving the tick
    /// from here models the resume, which is the moment that matters — a
    /// replace against that UID is what `/save_draft` degrades to
    /// save-as-new, landing the orphan the tester found.
    ///
    /// The composer is gone by then (`send()` calls `stop()` and `onClose()`
    /// on success), so the copy it writes is unreachable from the UI and
    /// sits in Drafts until the user deletes it by hand.
    func testAnAutosaveTickAfterASendIssuesNoRequest() async throws {
        let transport = DraftRaceTransport(nextSaveUid: 786)
        let model = try Self.makeSendableModel(transport: transport)

        _ = await model.send()
        await model.autosaveToServer()

        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.kind), [.send])
    }

    /// The positive control for the two tests above, and the reason they mean
    /// anything: this same fixture really does reach `/save_draft` when
    /// nothing has closed the session. Without it, "the tick issued nothing"
    /// would pass just as well against an autosave declining for an unrelated
    /// reason — a missing From, an empty body — and would guard nothing.
    func testAnAutosaveTickBeforeAnySendDoesReachTheNetwork() async throws {
        let transport = DraftRaceTransport(nextSaveUid: 786)
        let model = try Self.makeSendableModel(transport: transport)

        await model.autosaveToServer()

        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.kind), [.save])
        XCTAssertEqual(calls.first?.replacesUid, 785)
    }

    // MARK: - The untouched paths

    /// The interlock must not cost the ordinary send anything: with nothing
    /// in flight it still goes straight out against the UID the model holds,
    /// and still reports the outcome the dismiss toast reads.
    func testASendWithNothingInFlightStillNamesTheCurrentUid() async throws {
        let transport = DraftRaceTransport(nextSaveUid: 786)
        let model = try Self.makeSendableModel(transport: transport)

        let sent = await model.send()

        XCTAssertTrue(sent)
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.kind), [.send])
        XCTAssertEqual(calls.first?.replacesUid, 785)
        XCTAssertEqual(model.lastSendOutcome, .sent)
    }

    /// A send that *fails* leaves the composer up with the message still in
    /// it, so the session has to reopen. Closing it permanently would be a
    /// worse bug than the one being fixed: every later autosave, and the
    /// close-without-send push that is the durability story for a draft the
    /// user gives up on, would silently stop reaching the server.
    func testAFailedSendLeavesTheSessionOpenForTheCloseWithoutSendPush() async throws {
        let transport = DraftRaceTransport(nextSaveUid: 786)
        let model = try Self.makeSendableModel(transport: transport)
        await transport.fail(.send)

        let sent = await model.send()
        XCTAssertFalse(sent, "a 500 from /send is an application-level rejection, not a queue")
        XCTAssertNotNil(model.errorMessage)

        let saved = await model.pushDraftToServer(Self.probeMessage)

        XCTAssertTrue(saved)
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.kind), [.send, .save])
    }

    // MARK: - Fixtures

    /// A composer filled in far enough to send, holding a server copy the
    /// send is expected to name.
    private static func makeSendableModel(
        transport: DraftRaceTransport
    ) throws -> ComposeViewModel {
        let model = try TestFixtures.makeComposeModel(transport: transport)
        model.fromAddress = "daily@cabalmail.example"
        model.subject = "f1198probe"
        model.toText = "someone@example.com"
        model.serverDraftRef = DraftServerRef(uid: 785, uidValidity: 9)
        return model
    }

    private static let probeMessage = OutgoingMessage(
        from: EmailAddress(name: nil, mailbox: "daily", host: "cabalmail.example"),
        to: [EmailAddress(name: nil, mailbox: "someone", host: "example.com")],
        subject: "f1198probe",
        textBody: "body",
        htmlBody: nil
    )
}
