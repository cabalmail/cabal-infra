import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The window's side of "Open in New Window" (`ComposeHandoffClaim`): its
/// composer loads the sheet's draft, then claims it once its own window is
/// in front. Until the claim the sheet can still take the draft back, so
/// the window sends, saves and closes nothing. A composer behind, as SwiftUI
/// builds for a closed window it keeps mounted (#1084), leaves the hand-off
/// and the slot it shares with the window in front alone.
@MainActor
final class ComposeWindowTakeoverTests: XCTestCase {
    /// The window loads the sheet's rich text, then waits to be in front
    /// before it claims: until the claim the sheet can still take the draft
    /// back, so the window writes nothing.
    func testTheWindowSavesNothingUntilItClaims() async throws {
        let sheet = try await TestFixtures.makeMovableComposeModel()
        await sheet.editorController.setHTML("<p>Typed in the sheet</p>")
        let handoffs = ComposeHandoffs(sleep: TestFixtures.farHandoffDeadline)
        let snapshot = try await ComposeSnapshot.capture(from: sheet)
        TestFixtures.offer(snapshot, on: handoffs)
        let window = try TestFixtures.makeMovedComposeModel(for: snapshot.draftID, from: handoffs)
        try await TestFixtures.requireEditorBridge(window)
        defer { window.stop() }

        let starting = Task { await window.start() }
        try await waitUntilOnMainActor {
            (try? await window.editorController.checked.getHTML())?.contains("Typed in the sheet") == true
        }
        let startedBehind = await holdsOnMainActor(within: 0.3) { window.autosave.isRunning }
        XCTAssertFalse(startedBehind, "a window not yet in front started saving")
        let written = try await window.draftStore.load(id: window.draftId)
        XCTAssertNil(written)
        let waiting = Task { await handoffs.outcome(for: snapshot.draftID) }

        window.handoff?.sceneIsActive = true
        await starting.value

        let outcome = await waiting.value
        XCTAssertEqual(outcome, .claimed)
        XCTAssertTrue(window.autosave.isRunning)
    }

    /// The window shows the draft before it has claimed it, but takes no
    /// Send, Cancel or Discard until it has: the sheet may still take the
    /// draft back, and would then send it a second time, or save over a
    /// server copy the window had replaced.
    func testTheWindowSendsSavesAndDiscardsNothingUntilItClaims() async throws {
        let transport = DraftRaceTransport(nextSaveUid: 786)
        let handoffs = ComposeHandoffs(sleep: TestFixtures.farHandoffDeadline)
        let snapshot = Self.snapshot(of: Draft(
            fromAddress: "daily@cabalmail.example",
            to: ["someone@example.com"],
            subject: "moving probe",
            serverUid: 785,
            serverUidValidity: 9
        ))
        TestFixtures.offer(snapshot, on: handoffs)
        var closed = 0
        let window = try TestFixtures.makeMovedComposeModel(
            for: snapshot.draftID, from: handoffs, transport: transport, onClose: { closed += 1 }
        )
        try await TestFixtures.requireEditorBridge(window)
        defer { window.stop() }
        XCTAssertEqual(window.subject, "moving probe")
        XCTAssertFalse(window.holdsDraft)
        XCTAssertFalse(window.canSend)

        let sent = await window.send()
        let cancelled = await window.cancel()
        await window.discard()

        XCTAssertFalse(sent)
        XCTAssertFalse(cancelled)
        XCTAssertEqual(closed, 0)
        let calls = await transport.calls
        XCTAssertEqual(calls, [], "no send, save or discard before the claim")
        let written = try await window.draftStore.load(id: window.draftId)
        XCTAssertNil(written)

        window.handoff?.sceneIsActive = true
        await window.start()
        XCTAssertTrue(window.holdsDraft)
        XCTAssertTrue(window.canSend)
    }

    /// Two composers for one hand-off: one in front, and one behind, as
    /// SwiftUI builds for a closed window rebuilt for the recycled slot. The
    /// one behind claims nothing, gives nothing back when its own editor
    /// fails, and does not close, which would free the slot the window in
    /// front holds and bring the main window over it.
    func testAComposerBehindLeavesTheHandoffAndItsSlotAlone() async throws {
        let handoffs = ComposeHandoffs(sleep: TestFixtures.farHandoffDeadline)
        let snapshot = Self.snapshot(of: Draft(subject: "moving probe"))
        TestFixtures.offer(snapshot, on: handoffs)
        var behindClosed = 0
        let behind = try TestFixtures.makeMovedComposeModel(
            for: snapshot.draftID, from: handoffs, onClose: { behindClosed += 1 }
        )
        let inFront = try TestFixtures.makeMovedComposeModel(for: snapshot.draftID, from: handoffs)
        try await TestFixtures.requireEditorBridge(behind)
        try await TestFixtures.requireEditorBridge(inFront)
        defer {
            behind.stop()
            inFront.stop()
        }
        // The composer behind cannot read its rich pane back, so its restore
        // fails.
        _ = try await behind.editorController.webView.evaluateJavaScript(
            "window.cabal.getHTML = function () { return 42; }; true"
        )

        let behindStarting = Task { await behind.start() }
        let gaveItBack = await holdsOnMainActor(within: 0.5) { inFront.handoff?.snapshot == nil }
        XCTAssertFalse(gaveItBack, "the composer behind gave the draft back before the window in front could claim it")
        let waiting = Task { await handoffs.outcome(for: snapshot.draftID) }
        inFront.handoff?.sceneIsActive = true
        await inFront.start()

        let outcome = await waiting.value
        XCTAssertEqual(outcome, .claimed)
        XCTAssertTrue(inFront.holdsDraft)
        await behindStarting.value
        XCTAssertFalse(behind.holdsDraft)
        XCTAssertEqual(behindClosed, 0, "the composer behind closed, freeing the slot the window in front holds")
    }

    /// A window still behind when the sheet takes its draft back closes once
    /// it comes in front, rather than staying frozen with nothing in it.
    func testAWindowBehindWhenTheSheetKeptTheDraftClosesOnceInFront() async throws {
        let handoffs = ComposeHandoffs(sleep: { _ in })
        let snapshot = Self.snapshot(of: Draft(subject: "kept"))
        TestFixtures.offer(snapshot, on: handoffs)
        var closed = 0
        let window = try TestFixtures.makeMovedComposeModel(
            for: snapshot.draftID, from: handoffs, onClose: { closed += 1 }
        )
        try await TestFixtures.requireEditorBridge(window)
        defer { window.stop() }
        let starting = Task { await window.start() }

        let outcome = await handoffs.outcome(for: snapshot.draftID)
        await starting.value

        XCTAssertEqual(outcome, .refused)
        XCTAssertEqual(closed, 0, "closed behind, where it may be a window the user has closed already")
        window.handoff?.sceneIsActive = true
        XCTAssertEqual(closed, 1)
        XCTAssertFalse(window.autosave.isRunning)
    }

    /// A window that comes after the sheet took its draft back closes
    /// through its own close, saving nothing.
    func testAWindowThatComesTooLateClosesAndSavesNothing() async throws {
        let handoffs = ComposeHandoffs(sleep: { _ in })
        let snapshot = Self.snapshot(of: Draft(subject: "late"))
        TestFixtures.offer(snapshot, on: handoffs)
        let refused = await handoffs.outcome(for: snapshot.draftID)
        XCTAssertEqual(refused, .refused)
        var closed = 0
        let window = try TestFixtures.makeMovedComposeModel(
            for: snapshot.draftID, from: handoffs, onClose: { closed += 1 }
        )
        XCTAssertEqual(window.subject, "", "a window too late composes nothing of the draft")
        window.handoff?.sceneIsActive = true

        await window.start()

        XCTAssertEqual(closed, 1)
        XCTAssertFalse(window.autosave.isRunning)
        let written = try await window.draftStore.load(id: window.draftId)
        XCTAssertNil(written)
    }

    /// The sheet could not read its draft after the window had opened for
    /// it. The window built no composer while it waited; the one it builds
    /// once the hand-off has ended composes nothing of the draft, and closes
    /// once its window is in front, saving nothing.
    func testAWindowWhoseDraftNeverCameClosesOnceInFrontAndSavesNothing() async throws {
        let handoffs = ComposeHandoffs(sleep: TestFixtures.farHandoffDeadline)
        let draftID = UUID()
        handoffs.expect(draftID, within: ComposeWindowMove.deadline)
        XCTAssertTrue(handoffs.awaitsSnapshot(for: draftID))
        handoffs.withdraw(draftID)
        XCTAssertFalse(handoffs.awaitsSnapshot(for: draftID), "the window would wait for good")
        var closed = 0
        let window = try TestFixtures.makeMovedComposeModel(for: draftID, from: handoffs, onClose: { closed += 1 })
        defer { window.stop() }
        XCTAssertEqual(window.subject, "", "a window whose draft never came composes nothing of it")

        await window.start()

        XCTAssertEqual(closed, 0, "closed behind, where it may be a window the user has closed already")
        window.handoff?.sceneIsActive = true
        XCTAssertEqual(closed, 1)
        XCTAssertFalse(window.autosave.isRunning)
        let written = try await window.draftStore.load(id: window.draftId)
        XCTAssertNil(written)
    }

    /// The sheet's first deadline only bounds how long it waits for a window
    /// to turn up. A window that has, its composer built from the snapshot,
    /// gets the take-over deadline from then: a new WebKit content process
    /// took about ten seconds to answer on the iPadOS 27.0 simulator, and the
    /// first deadline passing while the window's editor boots must not take
    /// the draft back.
    func testAWindowThatTurnsUpGetsTheLongerDeadline() async throws {
        let deadlines = HeldDeadlines()
        defer { deadlines.releaseAll() }
        let handoffs = ComposeHandoffs(sleep: { await deadlines.sleep($0) })
        let snapshot = Self.snapshot(of: Draft(subject: "booting"))
        TestFixtures.offer(snapshot, on: handoffs)
        let window = try TestFixtures.makeMovedComposeModel(for: snapshot.draftID, from: handoffs)
        try await TestFixtures.requireEditorBridge(window)
        defer { window.stop() }

        let starting = Task { await window.start() }
        try await waitUntilOnMainActor {
            deadlines.asked == [ComposeWindowMove.deadline, ComposeWindowMove.takeOverDeadline]
        }
        deadlines.release(0)
        await Task.yield()
        XCTAssertNotNil(window.handoff?.snapshot, "the first deadline took the draft back from a window booting")

        window.handoff?.sceneIsActive = true
        await starting.value
        let outcome = await handoffs.outcome(for: snapshot.draftID)
        XCTAssertEqual(outcome, .claimed)
    }

    private static func snapshot(of seed: Draft) -> ComposeSnapshot {
        ComposeSnapshot(seed: seed, preferences: Preferences(store: InMemoryPreferenceStore()))
    }
}

/// Deadlines a test lets pass one at a time, recording what was asked.
@MainActor
private final class HeldDeadlines {
    private(set) var asked: [Duration] = []
    private var held: [CheckedContinuation<Void, Never>?] = []

    func sleep(_ deadline: Duration) async {
        asked.append(deadline)
        await withCheckedContinuation { held.append($0) }
    }

    func release(_ index: Int) {
        held[index]?.resume()
        held[index] = nil
    }

    func releaseAll() {
        for index in held.indices { release(index) }
    }
}
