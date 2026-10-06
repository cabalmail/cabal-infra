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
        appState: AppState = AppState()
    ) throws -> MessageListViewModel {
        let model = MessageListViewModel(
            folder: Folder(path: folderPath, attributes: [], isSubscribed: true),
            client: try makeClient(imap: imap),
            preferences: Preferences(store: InMemoryPreferenceStore()),
            appState: appState
        )
        // Placed in the folder, as every path that loads rows places them.
        model.envelopes = model.placedInFolder(envelopes)
        return model
    }

    /// Compose model over the fake transport, with a scratch draft store.
    /// A real `RichTextEditorController` (and its WKWebView) comes up inside
    /// it; the bridge-health tests drive the failure hooks directly rather
    /// than depending on whether `editor.html` loads in the test host.
    @MainActor
    static func makeComposeModel(
        seed: Draft = Draft(),
        imap: FakeImapClient = FakeImapClient(),
        signature: String = "",
        transport: HTTPTransport = NullHTTPTransport()
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
            onClose: {}
        )
    }
}
