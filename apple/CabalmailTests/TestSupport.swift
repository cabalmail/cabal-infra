import Foundation
import XCTest
import CabalmailKit
@testable import CabalmailUI

// The shared test doubles (FakeImapClient, the auth and transport doubles,
// the Kit-only fixtures, waitUntil) live in
// CabalmailKit/Tests/CabalmailKitTestSupport, which this bundle compiles as
// part of its own sources (project.yml) and the Kit's tests link as a
// target. What stays here needs app types.

extension TestFixtures {
    /// View model over `folder` with the given rows already loaded, ready
    /// for selection / bulk-op calls. No lifecycle task runs — the model's
    /// init is pure assignment and `loadInitial()` is never called.
    @MainActor
    static func makeModel(
        imap: FakeImapClient,
        envelopes: [Envelope],
        folderPath: String = "INBOX",
        mailStore: MailSessionStore = AppState().mailStore
    ) throws -> MessageListViewModel {
        let model = MessageListViewModel(
            folder: Folder(path: folderPath, attributes: [], isSubscribed: true),
            client: try makeClient(imap: imap),
            preferences: Preferences(store: InMemoryPreferenceStore()),
            mailStore: mailStore
        )
        // Placed in the folder, as every path that loads rows places them.
        model.envelopes = model.placedInFolder(envelopes)
        return model
    }

    /// Compose model over the fake transport, with a scratch draft store.
    /// A real `RichTextEditorController` (and its WKWebView) comes up inside
    /// it; the bridge-health tests drive the failure hooks directly rather
    /// than depending on whether `editor.html` loads in the test host.
    /// `handoff` builds the composer of a window "Open in New Window" opened,
    /// taking over that sheet's draft.
    @MainActor
    static func makeComposeModel(
        seed: Draft = Draft(),
        imap: FakeImapClient = FakeImapClient(),
        signature: String = "",
        transport: HTTPTransport = NullHTTPTransport(),
        handoff: ComposeHandoffClaim? = nil,
        onClose: @escaping @MainActor () -> Void = {}
    ) throws -> ComposeViewModel {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-compose-tests-\(UUID().uuidString)")
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.signature = signature
        return ComposeViewModel(
            seed: seed,
            client: try makeClient(imap: imap, transport: transport),
            draftStore: try DraftStore(directory: tmp),
            preferences: preferences,
            handoff: handoff,
            onClose: onClose
        )
    }

    /// Waits for `model`'s editor bridge to boot, or skips the test with the
    /// reason it didn't: a move reads and restores the rich pane through it.
    @MainActor
    static func requireEditorBridge(_ model: ComposeViewModel) async throws {
        await model.editorController.waitUntilReady()
        try XCTSkipIf(
            model.editorController.bridgeFailure != nil,
            "editor bridge failed to boot: \(model.editorController.bridgeFailure ?? "")"
        )
    }

    /// A compose sheet's composer that may move to a window: filled in far
    /// enough to send and to save, holding a server copy, on an editor
    /// bridge that has booted, and started as `ComposeView` starts it.
    @MainActor
    static func makeMovableComposeModel(
        transport: HTTPTransport = NullHTTPTransport()
    ) async throws -> ComposeViewModel {
        let model = try makeComposeModel(transport: transport)
        model.fromAddress = "daily@cabalmail.example"
        model.subject = "moving probe"
        model.toText = "someone@example.com"
        model.serverDraftRef = DraftServerRef(uid: 785, uidValidity: 9)
        try await requireEditorBridge(model)
        model.hasStarted = true
        return model
    }

    /// A hand-off deadline (`ComposeHandoffs(sleep:)`) far past anything a
    /// test waits for: the window's editor bridge has to boot before it can
    /// claim, and a loaded runner can take longer over that than the app's
    /// eight seconds allow.
    @MainActor static let farHandoffDeadline: @MainActor (Duration) async -> Void = { _ in
        try? await Task.sleep(for: .seconds(30))
    }

    /// A hand-off as a move makes it, in one go: expected at the tap, with
    /// the move's deadline running from then, and `snapshot` sent at once,
    /// as for a window that comes after the sheet has read its draft.
    @MainActor
    static func offer(_ snapshot: ComposeSnapshot, on handoffs: ComposeHandoffs) {
        handoffs.expect(snapshot.draftID, within: ComposeWindowMove.deadline)
        handoffs.fulfil(snapshot)
    }

    /// The composer `ComposeWindowContent` builds in a window "Open in New
    /// Window" opened for `draftID`, once the hand-off no longer awaits the
    /// sheet's snapshot: its seed carries only the ID, and the hand-off
    /// brings the rest.
    @MainActor
    static func makeMovedComposeModel(
        for draftID: UUID,
        from handoffs: ComposeHandoffs,
        signature: String = "",
        transport: HTTPTransport = NullHTTPTransport(),
        onClose: @escaping @MainActor () -> Void = {}
    ) throws -> ComposeViewModel {
        try makeComposeModel(
            seed: Draft(id: draftID),
            signature: signature,
            transport: transport,
            handoff: handoffs.pending(for: draftID),
            onClose: onClose
        )
    }
}
