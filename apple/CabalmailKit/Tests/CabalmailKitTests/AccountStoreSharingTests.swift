import XCTest
import CabalmailKitTestSupport
@testable import CabalmailKit

/// One set of stores per account (`AccountStoreRegistry`,
/// `docs/1.x/post-wave-3/sqlite-mail-store.md`, PR 1.1). Several clients can
/// be alive at once: the wired session's, one parked at a second-factor
/// prompt, one lent to background work. Those of one account hold the same
/// caches and one Spotlight indexer, and a sign-in that does not finish
/// takes the directory it made with it.
final class AccountStoreSharingTests: AccountDirectoryTestCase {
    // MARK: - One set of stores per account

    func testTwoClientsOfOneAccountHoldTheSameStores() async throws {
        let alice = try account("cabalmail.example", "alice")
        let first = try makeClient(alice)
        let second = try makeClient(alice)

        XCTAssertTrue(first.envelopeCache === second.envelopeCache)
        XCTAssertTrue(first.bodyCache === second.bodyCache)
        XCTAssertTrue(first.folderStateCache === second.folderStateCache)
        XCTAssertNotNil(first.spotlightIndexer)
        XCTAssertTrue(first.spotlightIndexer === second.spotlightIndexer, "one indexer per account")
        XCTAssertFalse(first === second)
    }

    /// What sharing the objects buys over two caches on one directory: a
    /// change written through one client reaches whoever listens through
    /// the other.
    func testAWriteThroughOneClientIsAnnouncedThroughTheOther() async throws {
        let alice = try account("cabalmail.example", "alice")
        let first = try makeClient(alice)
        let second = try makeClient(alice)
        let changes = await second.envelopeCache.changes()

        try await first.envelopeCache.merge(
            envelopes: [TestFixtures.makeEnvelope(uid: 7)], uidValidity: 1, uidNext: 8, into: "INBOX"
        )

        var iterator = changes.makeAsyncIterator()
        guard case .upserted(let envelopes, let folder)? = await iterator.next() else {
            return XCTFail("the second client's cache announced nothing for the first client's write")
        }
        XCTAssertEqual(envelopes.map(\.uid), [7])
        XCTAssertEqual(folder, "INBOX")
        let saved = await second.envelopeCache.snapshot(for: "INBOX")
        XCTAssertEqual(saved?.envelopes.keys.sorted(), [7])
    }

    /// One indexer has one feed, however many clients share it: a merge is
    /// given to the index once.
    func testTwoClientsOfOneAccountIndexAMergeOnce() async throws {
        let alice = try account("cabalmail.example", "alice")
        let first = try makeClient(alice)
        let second = try makeClient(alice)
        let cache = first.envelopeCache
        try await waitUntil { await cache.hasChangeObservers }
        await second.spotlightIndexer?.setSubscribedFolders(["INBOX"])

        try await cache.merge(
            envelopes: [TestFixtures.makeEnvelope(uid: 1), TestFixtures.makeEnvelope(uid: 2)],
            uidValidity: 1, uidNext: 3, into: "INBOX"
        )

        try await waitUntil { await self.index.indexedEntries.count >= 2 }
        // Long enough for a second feed, were there one, to hand the same
        // change over again.
        try await Task.sleep(nanoseconds: 200_000_000)
        let batches = await index.indexedBatches
        XCTAssertEqual(batches.map(\.count), [2])
    }

    func testUsernamesThatDifferOnlyByCaseGetTwoDirectoriesAndShareNothing() async throws {
        let lower = try account("cabalmail.example", "alice")
        let upper = try account("cabalmail.example", "Alice")
        let lowerClient = try makeClient(lower)
        let upperClient = try makeClient(upper)

        try await lowerClient.envelopeCache.merge(
            envelopes: [TestFixtures.makeEnvelope(uid: 1)], uidValidity: 1, uidNext: 2, into: "INBOX"
        )

        XCTAssertFalse(lowerClient.envelopeCache === upperClient.envelopeCache)
        XCTAssertFalse(lowerClient.bodyCache === upperClient.bodyCache)
        XCTAssertFalse(lowerClient.spotlightIndexer === upperClient.spotlightIndexer)
        let other = await upperClient.envelopeCache.snapshot(for: "INBOX")
        XCTAssertNil(other, "one account's saved list is not the other's")
        // Read back from the disk, which on a Mac ignores case: two names
        // that differed only by case would be one directory here.
        let onDisk = try names(in: root.appendingPathComponent("accounts"))
        XCTAssertEqual(onDisk, [lower.directoryName, upper.directoryName].sorted())
    }

    func testTheSameAccountInAnotherCacheRootSharesNothing() async throws {
        let alice = try account("cabalmail.example", "alice")
        let here = try makeClient(alice)
        let there = try makeClient(alice, root: root.appendingPathComponent("another-root"))

        XCTAssertFalse(here.envelopeCache === there.envelopeCache)
        XCTAssertFalse(here.spotlightIndexer === there.spotlightIndexer)
    }

    /// A client stops sharing when it is shut down. The stores stay shared
    /// while any client of the account is still running, and the account's
    /// next client after the last one has gone opens them afresh: a
    /// sign-out stops its indexer for good, and the next session needs one
    /// that works.
    func testTheStoresAreSharedUntilTheLastClientOfTheAccountShutsDown() async throws {
        let alice = try account("cabalmail.example", "alice")
        let first = try makeClient(alice)
        let second = try makeClient(alice)

        await first.shutdown()
        let third = try makeClient(alice)
        XCTAssertTrue(third.envelopeCache === second.envelopeCache, "the second client still holds them")
        XCTAssertTrue(third.spotlightIndexer === second.spotlightIndexer)

        await second.shutdown()
        await third.shutdown()
        let fourth = try makeClient(alice)
        XCTAssertFalse(fourth.envelopeCache === second.envelopeCache, "opened afresh")
        XCTAssertFalse(fourth.spotlightIndexer === second.spotlightIndexer)
    }

    // MARK: - A sign-in that does not finish

    func testAnAbandonedSignInRemovesTheDirectoryItMade() async throws {
        let alice = try account("cabalmail.example", "alice")
        let home = AccountDirectory.url(for: alice, in: root)
        let client = try makeClient(alice)
        XCTAssertTrue(exists(home), "precondition: building the client made it")

        await client.abandonSignIn()

        XCTAssertFalse(exists(home))
        let isShutDown = await client.isShutDown
        XCTAssertTrue(isShutDown, "an abandoned client is shut down too")
    }

    /// A wrong password for an account that has been here before must not
    /// cost it its saved mail.
    func testAnAbandonedSignInLeavesADirectoryThatWasAlreadyThere() async throws {
        let alice = try account("cabalmail.example", "alice")
        let home = AccountDirectory.url(for: alice, in: root)
        let kept = home.appendingPathComponent("kept")
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("saved".utf8).write(to: kept)
        let client = try makeClient(alice)

        await client.abandonSignIn()

        XCTAssertTrue(exists(kept))
    }

    /// The stored account's client is lent to background work while the
    /// sign-in form is up. A failed sign-in to that same account leaves the
    /// directory the lent client is using.
    func testAnAbandonedSignInLeavesADirectoryAnotherClientHolds() async throws {
        let alice = try account("cabalmail.example", "alice")
        let home = AccountDirectory.url(for: alice, in: root)
        let lent = try makeClient(alice)
        let signingIn = try makeClient(alice)

        await signingIn.abandonSignIn()
        XCTAssertTrue(exists(home), "the lent client still holds it")

        await lent.shutdown()
        XCTAssertTrue(exists(home), "an ordinary shutdown removes nothing")
    }

    func testTheLastOfTwoAbandonedSignInsRemovesTheDirectory() async throws {
        let alice = try account("cabalmail.example", "alice")
        let home = AccountDirectory.url(for: alice, in: root)
        let first = try makeClient(alice)
        let retry = try makeClient(alice)

        await first.abandonSignIn()
        XCTAssertTrue(exists(home), "the retry still holds it")
        await retry.abandonSignIn()

        XCTAssertFalse(exists(home))
    }

    func testAShutDownClientLeavesItsDirectory() async throws {
        let alice = try account("cabalmail.example", "alice")
        let client = try makeClient(alice)

        await client.shutdown()

        XCTAssertTrue(exists(AccountDirectory.url(for: alice, in: root)))
    }

    func testASignInAfterAnAbandonedOneGetsItsDirectoryBack() async throws {
        let alice = try account("cabalmail.example", "alice")
        let home = AccountDirectory.url(for: alice, in: root)
        let abandoned = try makeClient(alice)
        await abandoned.abandonSignIn()

        let client = try makeClient(alice)
        try await client.envelopeCache.merge(
            envelopes: [TestFixtures.makeEnvelope(uid: 1)], uidValidity: 1, uidNext: 2, into: "INBOX"
        )

        XCTAssertFalse(client.envelopeCache === abandoned.envelopeCache)
        XCTAssertFalse(try names(in: home.appendingPathComponent("envelopes")).isEmpty)
    }
}
