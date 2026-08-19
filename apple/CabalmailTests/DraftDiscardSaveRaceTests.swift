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

/// `/save_draft` stand-in that can hold either leg open on the wire, which
/// is what makes the race drivable at all: the strand only exists while a
/// round trip is outstanding.
///
/// Both save and discard are PUTs to the same path, told apart by `op` —
/// see `URLSessionApiClient+Drafts.swift`.
actor DraftRaceTransport: HTTPTransport {

    enum DraftOp: String, Equatable { case save, discard }

    struct Call: Equatable {
        let kind: DraftOp
        let replacesUid: UInt32?
    }

    private(set) var calls: [Call] = []

    private let nextSaveUid: UInt32
    private var heldOp: DraftOp?
    private var release: CheckedContinuation<Void, Never>?
    private var started: [DraftOp: CheckedContinuation<Void, Never>] = [:]
    private var alreadyStarted: Set<DraftOp> = []

    init(nextSaveUid: UInt32) {
        self.nextSaveUid = nextSaveUid
    }

    func holdNextSave() { heldOp = .save }
    func holdNextDiscard() { heldOp = .discard }

    func waitUntilSaveStarted() async { await waitUntilStarted(.save) }
    func waitUntilDiscardStarted() async { await waitUntilStarted(.discard) }

    func releaseHeldSave() { releaseHeld() }
    func releaseHeldDiscard() { releaseHeld() }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let json = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()))
            as? [String: Any] ?? [:]
        let kind: DraftOp = (json["op"] as? String) == "discard" ? .discard : .save
        calls.append(Call(kind: kind, replacesUid: (json["replaces_uid"] as? Int).map(UInt32.init)))

        alreadyStarted.insert(kind)
        started.removeValue(forKey: kind)?.resume()
        if heldOp == kind {
            heldOp = nil
            await withCheckedContinuation { release = $0 }
        }

        let body: [String: Any] = kind == .discard
            ? ["status": "ok", "discarded": true]
            : ["status": "ok", "uid": Int(nextSaveUid), "uidvalidity": 9, "replaced": true]
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (try JSONSerialization.data(withJSONObject: body), response)
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
