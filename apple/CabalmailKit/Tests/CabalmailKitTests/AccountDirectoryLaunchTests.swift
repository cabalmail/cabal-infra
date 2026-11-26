import XCTest
import CabalmailKitTestSupport
@testable import CabalmailKit

/// What a launch does to the cache root before the first client is built
/// (`AccountDirectory.prepareAtLaunch`,
/// `docs/1.x/post-wave-3/sqlite-mail-store.md`, PR 1.2). Caches a build
/// from before the account directory left in the root move into the
/// remembered account's directory, or are deleted when no account is
/// remembered; and every directory under `accounts/` that is not the
/// remembered account's is removed.
final class AccountDirectoryLaunchTests: AccountDirectoryTestCase {
    private var legacy: [URL] {
        ["envelopes", "bodies", "folders"].map { root.appendingPathComponent($0) }
    }

    // MARK: - What an earlier build left

    func testALaunchMovesAnEarlierBuildsCachesIntoTheRememberedAccountsDirectory() async throws {
        let alice = try account("cabalmail.example", "alice")
        try await leaveMailInTheRoot(uid: 1)
        for directory in legacy {
            XCTAssertTrue(exists(directory), "precondition: \(directory.lastPathComponent) is in the root")
        }

        await AccountDirectory.prepareAtLaunch(root: root, remembered: alice)

        for directory in legacy {
            XCTAssertFalse(exists(directory), "\(directory.lastPathComponent) is still in the root")
        }
        let client = try makeClient(alice)
        let uids = await savedUIDs(in: client)
        XCTAssertEqual(uids, [1])
        let body = await client.bodyCache.fetch(folder: "INBOX", uidValidity: 1, uid: 1)
        XCTAssertEqual(body, Data("body 1".utf8))
        let folders = await client.folderStateCache.lastKnownFolders()
        XCTAssertEqual(folders?.map(\.path), ["INBOX"])
    }

    /// The older build ran after the newer one that made the directory, so
    /// its copy is the later one.
    func testWhatAnEarlierBuildLeftReplacesWhatTheAccountsDirectoryHolds() async throws {
        let alice = try account("cabalmail.example", "alice")
        let newer = try makeClient(alice)
        try await seedMail(in: newer, uid: 5)
        await newer.shutdown()
        try await leaveMailInTheRoot(uid: 1)

        await AccountDirectory.prepareAtLaunch(root: root, remembered: alice)

        let client = try makeClient(alice)
        let uids = await savedUIDs(in: client)
        XCTAssertEqual(uids, [1])
        let replaced = await client.bodyCache.fetch(folder: "INBOX", uidValidity: 1, uid: 5)
        XCTAssertNil(replaced)
    }

    /// Nobody is remembered, so they are nobody's to keep.
    func testALaunchWithNoRememberedAccountDeletesWhatAnEarlierBuildLeft() async throws {
        try await leaveMailInTheRoot(uid: 1)

        await AccountDirectory.prepareAtLaunch(root: root, remembered: nil)

        for directory in legacy {
            XCTAssertFalse(exists(directory), "\(directory.lastPathComponent) is still in the root")
        }
        XCTAssertEqual(accountNames(), [], "and they were not moved anywhere")
    }

    func testRunningTheLaunchStepTwiceChangesNothingTheSecondTime() async throws {
        let alice = try account("cabalmail.example", "alice")
        let bob = try makeClient(try account("cabalmail.example", "bob"))
        try await seedMail(in: bob, uid: 9)
        await bob.shutdown()
        try await leaveMailInTheRoot(uid: 1)

        await AccountDirectory.prepareAtLaunch(root: root, remembered: alice)
        let afterFirst = try files.subpathsOfDirectory(atPath: root.path).sorted()
        await AccountDirectory.prepareAtLaunch(root: root, remembered: alice)

        XCTAssertEqual(try files.subpathsOfDirectory(atPath: root.path).sorted(), afterFirst)
        XCTAssertEqual(accountNames(), [alice.directoryName])
        let client = try makeClient(alice)
        let uids = await savedUIDs(in: client)
        XCTAssertEqual(uids, [1])
    }

    // MARK: - The other directories

    /// Another account's directory is there when its session ended without
    /// a wipe; one under a being-deleted name when a removal failed. The
    /// remembered account's stays, with what is in it: a launch that finds
    /// its session expired has changed nothing by then.
    func testALaunchRemovesEveryDirectoryButTheRememberedAccounts() async throws {
        let alice = try account("cabalmail.example", "alice")
        for name in ["alice", "bob"] {
            let client = try makeClient(try account("cabalmail.example", name))
            try await seedMail(in: client, uid: 1)
            await client.shutdown()
        }
        let home = AccountDirectory.url(for: alice, in: root)
        let leftover = AccountDirectory.beingDeletedURL(for: home)
        try files.createDirectory(at: leftover.appendingPathComponent("bodies"), withIntermediateDirectories: true)
        try Data("left".utf8).write(to: leftover.appendingPathComponent("bodies/left"))
        XCTAssertEqual(accountNames().count, 3, "precondition")

        await AccountDirectory.prepareAtLaunch(root: root, remembered: alice)

        XCTAssertEqual(accountNames(), [alice.directoryName])
        let client = try makeClient(alice)
        let uids = await savedUIDs(in: client)
        XCTAssertEqual(uids, [1], "the remembered account's mail is still saved")
    }

    func testALaunchWithNoRememberedAccountRemovesEveryDirectory() async throws {
        let client = try makeClient(try account("cabalmail.example", "alice"))
        try await seedMail(in: client, uid: 1)
        await client.shutdown()

        await AccountDirectory.prepareAtLaunch(root: root, remembered: nil)

        XCTAssertEqual(accountNames(), [])
    }

    /// The server is part of the account: the same username on another one
    /// is somebody else.
    func testTheSameUsernameOnAnotherServerIsNotTheRememberedAccount() async throws {
        let client = try makeClient(try account("other.example", "alice"))
        try await seedMail(in: client, uid: 1)
        await client.shutdown()

        await AccountDirectory.prepareAtLaunch(root: root, remembered: try account("cabalmail.example", "alice"))

        XCTAssertEqual(accountNames(), [])
    }

    // MARK: - Helpers

    /// Mail saved the way a build from before the account directory saved
    /// it: by a client without an account, whose caches are in the root.
    private func leaveMailInTheRoot(uid: UInt32) async throws {
        let earlier = try makeClient(nil)
        try await seedMail(in: earlier, uid: uid)
        await earlier.shutdown()
    }
}
