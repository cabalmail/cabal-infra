import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The iOS Check Inbox intent borrows the session's client, asks the server
/// for INBOX's STATUS and writes the unread count to the app badge. It used
/// to write it straight to `MailCounts`, so a STATUS that answered after a
/// sign-out (or after another account signed in) put the signed-out
/// account's count back on the badge (#1892). The intent lives in the iOS
/// app target, which this suite can't compile, so these drive the store
/// call it now makes, `MailSessionStore.setInboxUnread(_:fetchedThrough:)`;
/// the plain `MailCounts.setInboxUnread` it used is no longer public, so the
/// app target can't skip the gate.
///
/// Each test writes 7 through a client the way the intent's late answer
/// would, and checks what the badge count shows.
@MainActor
final class InboxCountGateTests: XCTestCase {
    private var harness: SessionHarness!

    private var manager: SessionManager { harness.appState.sessionManager }
    private var counts: MailCounts { harness.appState.mailStore.counts }

    override func setUp() async throws {
        harness = try SessionHarness()
    }

    override func tearDown() async throws {
        harness.appState.mailStore.counts.setInboxUnread(0)
        await harness?.tearDown()
        harness = nil
    }

    /// The control: a count fetched through the session's own client lands.
    func testACountFromTheSignedInSessionIsWritten() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let client = try XCTUnwrap(harness.appState.client)

        harness.appState.mailStore.setInboxUnread(7, fetchedThrough: client)

        XCTAssertEqual(counts.inboxUnreadCount, 7)
    }

    func testACountAnsweringAfterASignOutIsDropped() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let client = try XCTUnwrap(harness.appState.client)

        await harness.appState.signOut()
        harness.appState.mailStore.setInboxUnread(7, fetchedThrough: client)

        XCTAssertEqual(counts.inboxUnreadCount, 0, "the sign-out's reset stands")
    }

    /// The sign-out awaits the push deregistration before the Intents bridge
    /// lets go of the app state, so an answer can land while it's waiting.
    /// The session's client is already ended by then.
    func testACountAnsweringWhileTheSignOutIsStillRunningIsDropped() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let client = try XCTUnwrap(harness.appState.client)
        let store = harness.appState.mailStore
        manager.sessionEnvironment.hooks.sessionWillEnd = {
            store.setInboxUnread(7, fetchedThrough: client)
        }

        await harness.appState.signOut()

        XCTAssertEqual(counts.inboxUnreadCount, 0)
    }

    func testACountFromTheLastAccountIsDroppedOnceAnotherSignsIn() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let alice = try XCTUnwrap(harness.appState.client)
        await harness.appState.signOut()
        await signIn(as: "bob")
        let bob = try XCTUnwrap(harness.appState.client)
        harness.appState.mailStore.setInboxUnread(2, fetchedThrough: bob)

        harness.appState.mailStore.setInboxUnread(7, fetchedThrough: alice)

        XCTAssertEqual(counts.inboxUnreadCount, 2, "bob's count stays")
    }

    // MARK: - A client lent with no session wired

    /// On a cold launch the intent borrows the stored account's client
    /// before any session is wired; its count still lands, so the gate
    /// doesn't stop that case.
    func testACountFromTheLentClientIsWritten() async throws {
        let lent = try await borrowStoredAccountsClient()

        harness.appState.mailStore.setInboxUnread(7, fetchedThrough: lent)

        XCTAssertEqual(counts.inboxUnreadCount, 7)
    }

    /// Another account signs in while that client is lent: the manager lets
    /// it go, and its late count no longer lands on the new account's badge.
    func testACountFromALentClientIsDroppedOnceAnotherAccountSignsIn() async throws {
        let lent = try await borrowStoredAccountsClient()
        await signIn(as: "bob")
        let bob = try XCTUnwrap(harness.appState.client)
        XCTAssertFalse(bob === lent, "precondition: bob's session has its own client")
        harness.appState.mailStore.setInboxUnread(2, fetchedThrough: bob)

        harness.appState.mailStore.setInboxUnread(7, fetchedThrough: lent)

        XCTAssertEqual(counts.inboxUnreadCount, 2)
    }

    /// A sign-out with no session wired lets the lent client go too.
    func testACountFromALentClientIsDroppedAfterASignOut() async throws {
        let lent = try await borrowStoredAccountsClient()

        await harness.appState.signOut()
        harness.appState.mailStore.setInboxUnread(7, fetchedThrough: lent)

        XCTAssertEqual(counts.inboxUnreadCount, 0)
    }

    // MARK: - Helpers

    private func signIn(as username: String) async {
        await harness.cognito.script(.passwordSignIn, .tokens(id: "ID-\(username)"))
        await harness.appState.signIn(
            controlDomain: SignInScript.domain, username: username, password: SignInScript.password
        )
        XCTAssertEqual(harness.appState.status, .signedIn, "precondition: \(username) signed in")
    }

    /// The stored account's client, lent with no session wired: a cold
    /// background launch.
    private func borrowStoredAccountsClient() async throws -> CabalmailClient {
        harness.seedLastSession(username: "alice")
        try await harness.seedTokens()
        let borrowed = try await manager.borrowClient()
        XCTAssertNil(harness.appState.client, "precondition: no session is wired")
        return try XCTUnwrap(borrowed)
    }
}
