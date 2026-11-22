import XCTest
import CabalmailKitTestSupport
@testable import CabalmailKit

/// When an account's directory goes
/// (`docs/1.x/post-wave-3/sqlite-mail-store.md`, PR 1.2): at its sign-out,
/// and when another account has signed in. Its stores are closed first, for
/// every client that shares them, so one still held cannot put the mail
/// back; and the directory is renamed before it is removed, so a removal
/// that fails leaves nothing under the account's name.
final class AccountDirectoryRemovalTests: AccountDirectoryTestCase {
    // MARK: - Sign-out

    func testASignOutRemovesTheAccountsDirectory() async throws {
        let alice = try account("cabalmail.example", "alice")
        let client = try makeClient(alice)
        try await seedMail(in: client, uid: 1)
        XCTAssertEqual(accountNames(), [alice.directoryName], "precondition")

        await client.clearLocalDataEndingSession()

        XCTAssertEqual(accountNames(), [], "nothing is left, under the account's name or a being-deleted one")
        XCTAssertTrue(exists(root.appendingPathComponent("rss")), "what is shared stays where it is")
        XCTAssertTrue(exists(root.appendingPathComponent("outbox")))
    }

    /// A lent client, or a view that kept the session's, outlives the
    /// sign-out. Two of the caches make their directory on a write.
    func testAClientHeldPastSignOutCannotPutTheDirectoryBack() async throws {
        let alice = try account("cabalmail.example", "alice")
        let ended = try makeClient(alice)
        let held = try makeClient(alice)
        try await seedMail(in: ended, uid: 1)

        await ended.clearLocalDataEndingSession()

        for client in [ended, held] {
            do {
                try await client.bodyCache.store(folder: "INBOX", uidValidity: 1, uid: 2, bytes: Data("late".utf8))
                XCTFail("a closed body cache took a write")
            } catch {}
            do {
                try await client.envelopeCache.merge(
                    envelopes: [TestFixtures.makeEnvelope(uid: 2)], uidValidity: 1, uidNext: 3, into: "INBOX"
                )
                XCTFail("a closed envelope cache took a write")
            } catch {}
            let generation = await client.folderStateCache.generation
            await client.folderStateCache.recordFolders(
                [Folder(path: "INBOX", isSubscribed: true)], ifUnchangedSince: generation
            )
        }
        XCTAssertEqual(accountNames(), [], "a write after the sign-out made the directory again")
    }

    /// Sign Out, then Sign In as the same account, while the ended
    /// session's client is still alive: the new client's stores are new.
    func testASignInRightAfterASignOutGetsOpenStores() async throws {
        let alice = try account("cabalmail.example", "alice")
        let ended = try makeClient(alice)
        try await seedMail(in: ended, uid: 1)
        await ended.clearLocalDataEndingSession()

        let next = try makeClient(alice)

        XCTAssertFalse(next.envelopeCache === ended.envelopeCache)
        XCTAssertFalse(next.bodyCache === ended.bodyCache)
        XCTAssertFalse(next.folderStateCache === ended.folderStateCache)
        XCTAssertFalse(next.spotlightIndexer === ended.spotlightIndexer, "the ended session's is stopped for good")
        let before = await savedUIDs(in: next)
        XCTAssertEqual(before, [], "it starts empty")
        try await seedMail(in: next, uid: 7)
        // The ended session's client goes at last: its lease was on stores
        // that are retired, so it takes nothing of the new session's.
        await ended.shutdown()
        let after = await savedUIDs(in: next)
        XCTAssertEqual(after, [7])
        let sharing = try makeClient(alice)
        XCTAssertTrue(sharing.envelopeCache === next.envelopeCache, "the new stores are still the account's")
    }

    /// The removal fails half way: here, a directory the bodies cannot be
    /// unlinked from. The rename has happened by then, so the account's
    /// name is free, the failure is reported, and the next launch removes
    /// what is left.
    func testASignOutWhoseRemovalFailsSaysSoAndTheNextLaunchRemovesWhatIsLeft() async throws {
        let alice = try account("cabalmail.example", "alice")
        let client = try makeClient(alice)
        try await seedMail(in: client, uid: 1)
        let locked = "bodies/\(FolderCacheName.component(for: "INBOX"))/1"
        let home = AccountDirectory.url(for: alice, in: root)
        try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.appendingPathComponent(locked).path)
        let before = Set(wipeLines().map(\.id))

        await client.clearLocalDataEndingSession()

        XCTAssertFalse(exists(home), "the account's name still holds its mail")
        let left = accountNames()
        XCTAssertEqual(left.count, 1, "\(left)")
        let name = try XCTUnwrap(left.first)
        XCTAssertTrue(name.hasPrefix(alice.directoryName + AccountDirectory.beingDeletedMarker), name)
        let leftover = home.deletingLastPathComponent().appendingPathComponent(name)
        XCTAssertTrue(exists(leftover.appendingPathComponent(locked + "/1.eml")), "precondition: the removal failed")
        let new = wipeLines().filter { !before.contains($0.id) }
        XCTAssertEqual(new.count, 1, "\(new.map(\.message))")
        XCTAssertEqual(new.first?.level, .error)
        XCTAssertTrue(new.first?.message.contains("not cleared") ?? false, "\(new.map(\.message))")

        // Whatever stopped the removal is over by the next launch. Alice is
        // still the remembered account: Sign Out keeps the pair.
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: leftover.appendingPathComponent(locked).path)
        await AccountDirectory.prepareAtLaunch(root: root, remembered: alice)

        XCTAssertEqual(accountNames(), [])
    }

    // MARK: - Another account's sign-in

    /// Alice's session ended without its wipe (a force quit, or a launch
    /// whose refresh was refused), and her directory is still there. A
    /// sign-in as someone else that is refused leaves it; one that succeeds
    /// removes it.
    func testAnotherAccountsDirectorySurvivesARefusedSignInAndGoesAfterASuccessfulOne() async throws {
        let alice = try account("cabalmail.example", "alice")
        let bob = try account("cabalmail.example", "bob")
        let unwiped = try makeClient(alice)
        try await seedMail(in: unwiped, uid: 1)
        await unwiped.shutdown()

        let refused = try makeClient(bob)
        await refused.abandonSignIn()

        XCTAssertEqual(accountNames(), [alice.directoryName], "the refused sign-in took only what it made")
        let kept = try makeClient(alice)
        let uids = await savedUIDs(in: kept)
        XCTAssertEqual(uids, [1])
        await kept.shutdown()

        let signedIn = try makeClient(bob)
        try await seedMail(in: signedIn, uid: 4)
        await signedIn.removeOtherAccountsData()

        XCTAssertEqual(accountNames(), [bob.directoryName])
        let own = await savedUIDs(in: signedIn)
        XCTAssertEqual(own, [4], "its own mail is untouched")
    }

    /// The last account's client can still be alive when the next account
    /// signs in: it was lent to background work, and is let go in a task of
    /// its own.
    func testRemovingAnotherAccountsDirectoryClosesTheStoresAClientStillHolds() async throws {
        let alice = try account("cabalmail.example", "alice")
        let bob = try account("cabalmail.example", "bob")
        let lent = try makeClient(alice)
        try await seedMail(in: lent, uid: 1)
        let signedIn = try makeClient(bob)

        await signedIn.removeOtherAccountsData()

        do {
            try await lent.bodyCache.store(folder: "INBOX", uidValidity: 1, uid: 2, bytes: Data("late".utf8))
            XCTFail("the other account's body cache took a write")
        } catch {}
        XCTAssertEqual(accountNames(), [bob.directoryName])
        await lent.shutdown()
        XCTAssertEqual(accountNames(), [bob.directoryName], "letting the old client go changed nothing")
    }

    /// A client without an account directory has no other directories to
    /// know about.
    func testAClientWithoutAnAccountRemovesNoDirectory() async throws {
        let alice = try account("cabalmail.example", "alice")
        let saved = try makeClient(alice)
        try await seedMail(in: saved, uid: 1)
        await saved.shutdown()
        let plain = try makeClient(nil)

        await plain.removeOtherAccountsData()

        XCTAssertEqual(accountNames(), [alice.directoryName])
    }

    // MARK: - Helpers

    private func wipeLines() -> [DebugLogStore.Entry] {
        DebugLogStore.shared.snapshot().filter { $0.category == WipeReport.category }
    }
}
