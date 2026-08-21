import XCTest
import CabalmailKit
@testable import Cabalmail

// Regression coverage for issue #1163: pressing "Discard Draft" while the
// 60-second server autosave was mid-round-trip left the discarded draft on
// the server.
//
// The verification pass pinned it to a missing interlock rather than a bad
// retirement set. `ComposeViewModel.discard()` never consulted the save
// flag, and `autosaveToServer()` had no matching "a discard is running"
// flag, so both orderings stranded a copy:
//
//   1. save in flight at the press — the discard expunges the UID the model
//      holds (785), the completing save appends 786, and nothing retires it;
//   2. tick inside the discard round trip — the save replaces a UID the
//      discard just expunged, which `/save_draft` degrades to save-as-new.
//
// Reproduced 3/3 on macOS by aiming the press at the tick; unaimed presses
// miss ~97% of the time, which is why five earlier arms came back clean.
// Both orderings now go through `ServerDraftMutationQueue`.
@MainActor
final class DraftDiscardSaveRaceTests: XCTestCase {

    // MARK: - Ordering 1: a save already in flight when Discard is pressed

    /// The reported failure, driven through the real `CabalmailClient` and
    /// the real `/save_draft` endpoint with the save held open on the wire.
    ///
    /// What the server has to see is one save (landing 786) followed by a
    /// discard **of 786** — not of 785, the UID the model was holding when
    /// the user pressed the button. Before the fix the discard did not wait,
    /// so it named 785 and 786 survived: exactly the strand the verifier
    /// recorded three times.
    func testDiscardWaitsForAnInFlightSaveAndDropsTheUidItLanded() async throws {
        let transport = DraftRaceTransport(nextSaveUid: 786)
        let model = try TestFixtures.makeComposeModel(transport: transport)
        model.serverDraftRef = DraftServerRef(uid: 785, uidValidity: 9)

        await transport.holdNextSave()
        let save = Task { await model.pushDraftToServer(Self.probeMessage) }
        await transport.waitUntilSaveStarted()

        // The press lands while the save is on the wire.
        let discard = Task { await model.discard() }
        await transport.releaseHeldSave()
        _ = await save.value
        await discard.value

        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.kind), [.save, .discard])
        XCTAssertEqual(
            calls.last?.replacesUid, 786,
            "the discard has to name the UID the completing save landed, not the one it superseded"
        )
        XCTAssertTrue(model.didDiscardServerDraft)
        XCTAssertEqual(
            model.retiredDraftReplacement,
            DraftReplacement(retiredUIDs: [785, 786], survivingUID: nil),
            "both copies this session ever held are retired, and none survives"
        )
    }

    // MARK: - Ordering 2: an autosave tick inside the discard round trip

    /// The positive control for the two tests below, and the reason they
    /// mean anything: on an *open* session this same fixture really does
    /// reach `/save_draft`. Without it, "the tick issued nothing" would pass
    /// just as well against an autosave that declined for some unrelated
    /// reason (a missing From, an empty body) and would guard nothing.
    func testAnAutosaveTickOnAnOpenSessionDoesReachTheNetwork() async throws {
        let transport = DraftRaceTransport(nextSaveUid: 786)
        let model = try TestFixtures.makeComposeModel(transport: transport)
        Self.seedSavableContent(model)

        await model.autosaveToServer()

        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.kind), [.save])
        XCTAssertEqual(calls.first?.replacesUid, 785)
    }

    /// The mirror image, driven through the production autosave entry point.
    /// Once a discard has closed the session, a tick must issue nothing —
    /// its replace would target an expunged UID and degrade to save-as-new.
    func testAnAutosaveTickAfterADiscardIssuesNoRequest() async throws {
        let transport = DraftRaceTransport(nextSaveUid: 786)
        let model = try TestFixtures.makeComposeModel(transport: transport)
        Self.seedSavableContent(model)

        await model.discard()
        await model.autosaveToServer()

        let calls = await transport.calls
        XCTAssertEqual(
            calls.map(\.kind), [.discard],
            "the tick after a discard must not reach the network at all"
        )
    }

    /// And a tick that arrives *during* the discard is declined for the same
    /// reason: `close(runningDiscard:)` marks the session before its first
    /// suspension point, so there is no window between the press and the
    /// round trip in which a save can still start.
    func testAnAutosaveTickDuringTheDiscardRoundTripIsDeclined() async throws {
        let transport = DraftRaceTransport(nextSaveUid: 786)
        let model = try TestFixtures.makeComposeModel(transport: transport)
        Self.seedSavableContent(model)

        await transport.holdNextDiscard()
        let discard = Task { await model.discard() }
        await transport.waitUntilDiscardStarted()

        await model.autosaveToServer()
        await transport.releaseHeldDiscard()
        await discard.value

        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.kind), [.discard])
    }

    // MARK: - The untouched path

    /// The interlock must not cost the ordinary case anything: with nothing
    /// in flight, a discard still goes straight out against the UID the
    /// model holds.
    func testADiscardWithNothingInFlightStillDropsTheCurrentUid() async throws {
        let transport = DraftRaceTransport(nextSaveUid: 786)
        let model = try TestFixtures.makeComposeModel(transport: transport)
        model.serverDraftRef = DraftServerRef(uid: 785, uidValidity: 9)

        await model.discard()

        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.kind), [.discard])
        XCTAssertEqual(calls.first?.replacesUid, 785)
        XCTAssertTrue(model.didDiscardServerDraft)
    }

    /// A composer the debounced autosave would genuinely push: a From to
    /// authorize against, a subject so `hasDraftContent` says yes, and a
    /// server copy to replace.
    private static func seedSavableContent(_ model: ComposeViewModel) {
        model.fromAddress = "daily@cabalmail.example"
        model.subject = "f1163probe"
        model.serverDraftRef = DraftServerRef(uid: 785, uidValidity: 9)
    }

    private static let probeMessage = OutgoingMessage(
        from: EmailAddress(name: nil, mailbox: "daily", host: "cabalmail.example"),
        to: [EmailAddress(name: nil, mailbox: "someone", host: "example.com")],
        subject: "f1163probe",
        textBody: "body",
        htmlBody: nil
    )
}

/// `/save_draft` and `/send` stand-in that can hold any leg open on the
/// wire, which is what makes these races drivable at all: the strand only
/// exists while a round trip is outstanding.
///
/// Save and discard are PUTs to the same `/save_draft` path, told apart by
/// `op` — see `URLSessionApiClient+Drafts.swift`. Send is a PUT to `/send`.
actor DraftRaceTransport: HTTPTransport {

    enum DraftOp: String, Equatable { case save, discard, send }

    struct Call: Equatable {
        let kind: DraftOp
        /// The Drafts UID this call acts on: `replaces_uid` for a save or a
        /// discard, `discard_draft_uid` for a send.
        let replacesUid: UInt32?
    }

    private(set) var calls: [Call] = []

    private let nextSaveUid: UInt32
    private var failingOps: Set<DraftOp> = []
    private var heldOp: DraftOp?
    private var release: CheckedContinuation<Void, Never>?
    private var started: [DraftOp: CheckedContinuation<Void, Never>] = [:]
    private var alreadyStarted: Set<DraftOp> = []

    init(nextSaveUid: UInt32) {
        self.nextSaveUid = nextSaveUid
    }

    func holdNextSave() { heldOp = .save }
    func holdNextDiscard() { heldOp = .discard }
    func holdNextSend() { heldOp = .send }

    func waitUntilSaveStarted() async { await waitUntilStarted(.save) }
    func waitUntilDiscardStarted() async { await waitUntilStarted(.discard) }
    func waitUntilSendStarted() async { await waitUntilStarted(.send) }

    func releaseHeldSave() { releaseHeld() }
    func releaseHeldDiscard() { releaseHeld() }
    func releaseHeldSend() { releaseHeld() }

    /// Makes `op` answer 500. A 500 is an application-level rejection, so
    /// `CabalmailClient.send` throws it rather than parking the message in
    /// the outbox — which is the arm where the composer stays open.
    func fail(_ kind: DraftOp) { failingOps.insert(kind) }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let json = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()))
            as? [String: Any] ?? [:]
        let kind: DraftOp
        let actsOn: Int?
        if request.url?.path.hasSuffix("/send") == true {
            kind = .send
            actsOn = json["discard_draft_uid"] as? Int
        } else {
            kind = (json["op"] as? String) == "discard" ? .discard : .save
            actsOn = json["replaces_uid"] as? Int
        }
        calls.append(Call(kind: kind, replacesUid: actsOn.map(UInt32.init)))

        alreadyStarted.insert(kind)
        started.removeValue(forKey: kind)?.resume()
        if heldOp == kind {
            heldOp = nil
            await withCheckedContinuation { release = $0 }
        }

        let body: [String: Any]
        switch kind {
        case .discard: body = ["status": "ok", "discarded": true]
        case .send: body = ["status": "ok"]
        case .save: body = ["status": "ok", "uid": Int(nextSaveUid), "uidvalidity": 9, "replaced": true]
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: failingOps.contains(kind) ? 500 : 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (try JSONSerialization.data(withJSONObject: body), response)
    }

    /// Waits for `kind` to reach the wire, giving up after `within` seconds,
    /// and reports whether it arrived. A bounded wait is the only way to
    /// assert a call did *not* go out while another leg is held open.
    func waitForCall(_ kind: DraftOp, within seconds: Double) async -> Bool {
        for _ in 0..<Int(seconds / 0.01) {
            if calls.contains(where: { $0.kind == kind }) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return calls.contains(where: { $0.kind == kind })
    }

    private func waitUntilStarted(_ kind: DraftOp) async {
        guard !alreadyStarted.contains(kind) else { return }
        await withCheckedContinuation { started[kind] = $0 }
    }

    private func releaseHeld() {
        release?.resume()
        release = nil
    }
}
