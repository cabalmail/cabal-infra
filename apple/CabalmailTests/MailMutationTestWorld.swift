import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A store with INBOX at 5 unread of 20 and Archive at 2 of 9, a client
/// over the fake, and a recorder hearing every event.
@MainActor
struct ServiceWorld {
    let appState: AppState
    let client: CabalmailClient
    let recorder: MailEventRecorder

    var store: MailSessionStore { appState.mailStore }
    var mutations: MailMutationService { appState.mailStore.mutations }
    var composer: MailWriter { .composer(through: client) }

    init(_ imap: FakeImapClient, fixture: MessageDetailLoadFixture) async throws {
        appState = AppState()
        appState.mailStore.counts.setFolderCounts(folderPath: "INBOX", unread: 5, total: 20)
        appState.mailStore.counts.setFolderCounts(folderPath: "Archive", unread: 2, total: 9)
        client = try await fixture.makeClient(imap: imap)
        recorder = MailEventRecorder(appState.mailStore)
    }

    func unread(_ folder: String) -> Int? {
        store.counts.folderUnreadCounts[folder]
    }

    /// The session that made the writes ends, and the next account's counts
    /// arrive, as a sign-out and sign-in leave them.
    func signOutAndIn() {
        appState.sessionManager.teardownGate.markEnded(client)
        store.forgetAccount()
        store.counts.setFolderCounts(folderPath: "INBOX", unread: 7, total: 30)
    }
}
