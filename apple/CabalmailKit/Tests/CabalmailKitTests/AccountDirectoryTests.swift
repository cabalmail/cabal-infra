import XCTest
import CabalmailKitTestSupport
@testable import CabalmailKit

/// The account directory (`docs/1.x/post-wave-3/sqlite-mail-store.md`,
/// PR 1.1). A client built for an account keeps its saved message lists,
/// bodies and folder state in `accounts/<name>/` under the cache root, where
/// the name is a digest of the server and the username as typed. The
/// outbox, drafts, address list and feed store stay in the root.
final class AccountDirectoryTests: AccountDirectoryTestCase {
    // MARK: - The name

    /// The name is on disk in every install. A change to how it is computed
    /// orphans every account's caches, so one is written out here.
    func testTheDirectoryNameIsTheSameInEveryRelease() throws {
        XCTAssertEqual(
            try account("cabalmail.example", "alice").directoryName,
            "3051092728c837d1d7c2036695bc2538376fe80907c605c9379162e37c1bdb54"
        )
        XCTAssertEqual(
            try account("cabalmail.example", "Alice").directoryName,
            "7d265d8215de424be8bce8e4018b8438228eca4a508cd2a802762b6cbb73ec8a"
        )
    }

    /// The user pool's usernames are case-sensitive, and the Mac's disk is
    /// not: the two names must differ by more than case.
    func testUsernamesThatDifferOnlyByCaseGetNamesThatDifferOnACaseInsensitiveDisk() throws {
        let lower = try account("cabalmail.example", "alice").directoryName
        let upper = try account("cabalmail.example", "Alice").directoryName

        XCTAssertNotEqual(lower.lowercased(), upper.lowercased())
        for name in [lower, upper] {
            XCTAssertEqual(name.count, 64)
            XCTAssertTrue(name.allSatisfy { "0123456789abcdef".contains($0) }, name)
        }
    }

    /// The sign-in form remembers the server as typed, so the same server
    /// comes back with a scheme, spaces or capitals.
    func testTheSameServerRetypedIsTheSameDirectory() throws {
        let plain = try account("cabalmail.example", "alice").directoryName

        for typed in [" https://CabalMail.Example ", "http://cabalmail.example", "CABALMAIL.EXAMPLE"] {
            XCTAssertEqual(try account(typed, "alice").directoryName, plain, typed)
        }
        XCTAssertNotEqual(try account("other.example", "alice").directoryName, plain)
    }

    /// Two identities that compare equal must not get two directories, and
    /// `String` compares the composed and decomposed spellings of a letter
    /// as equal.
    func testComposedAndDecomposedSpellingsOfAUsernameShareADirectory() throws {
        let composed = try account("cabalmail.example", "jos\u{00E9}")
        let decomposed = try account("cabalmail.example", "jose\u{0301}")

        XCTAssertEqual(composed, decomposed, "precondition: the identities are equal")
        XCTAssertEqual(composed.directoryName, decomposed.directoryName)
    }

    /// Where the server ends and the username starts is part of the input.
    func testAServerAndUsernameThatRunTogetherTheSameWayAreStillTwoAccounts() throws {
        XCTAssertNotEqual(
            try account("mail.example", "bob").directoryName,
            try account("mail.exampleb", "ob").directoryName
        )
    }

    // MARK: - The layout

    func testAnAccountsCachesOpenInItsDirectoryAndTheRestStayInTheRoot() async throws {
        let alice = try account("cabalmail.example", "alice")
        let client = try makeClient(alice)
        let home = AccountDirectory.url(for: alice, in: root)
        XCTAssertEqual(home.lastPathComponent, alice.directoryName)
        XCTAssertEqual(home.deletingLastPathComponent().lastPathComponent, "accounts")
        XCTAssertEqual(home.deletingLastPathComponent().deletingLastPathComponent().path, root.path)

        try await client.envelopeCache.merge(
            envelopes: [TestFixtures.makeEnvelope(uid: 1)], uidValidity: 1, uidNext: 2, into: "INBOX"
        )
        try await client.bodyCache.store(folder: "INBOX", uidValidity: 1, uid: 1, bytes: Data("body".utf8))
        let generation = await client.folderStateCache.generation
        await client.folderStateCache.recordFolders(
            [Folder(path: "INBOX", isSubscribed: true)], ifUnchangedSince: generation
        )

        XCTAssertFalse(try names(in: home.appendingPathComponent("envelopes")).isEmpty)
        XCTAssertFalse(try names(in: home.appendingPathComponent("bodies")).isEmpty)
        XCTAssertEqual(try names(in: home.appendingPathComponent("folders")), ["folders.json"])
        XCTAssertEqual(try names(in: home), ["bodies", "envelopes", "folders"], "nothing else moved in")
        for legacy in ["envelopes", "bodies", "folders"] {
            XCTAssertFalse(exists(root.appendingPathComponent(legacy)), "\(legacy) is not opened in the root")
        }
        XCTAssertTrue(exists(root.appendingPathComponent("rss")), "the feed store stays in the root")
        XCTAssertNotNil(client.rssStore)
    }

    /// The factory without an account is what it was: the three caches in
    /// the root, and no account directory.
    func testAClientWithoutAnAccountKeepsItsCachesInTheRoot() async throws {
        let client = try makeClient(nil)

        let bodies = await client.bodyCache.directory
        XCTAssertEqual(bodies.path, root.appendingPathComponent("bodies").path)
        XCTAssertTrue(exists(root.appendingPathComponent("envelopes")))
        XCTAssertFalse(exists(root.appendingPathComponent("accounts")))

        await client.clearLocalData()

        XCTAssertTrue(exists(root.appendingPathComponent("envelopes")), "emptied in place, as before")
        XCTAssertTrue(exists(root.appendingPathComponent("bodies")))
    }

    // MARK: - What an earlier build left

    /// A build from before the account directory kept the three caches in
    /// the root. A client with an account never opens them, so its wipe has
    /// to remove them itself, or a sign-out would leave that mail on the
    /// device.
    func testAWipeRemovesTheCachesAnEarlierBuildLeftInTheRoot() async throws {
        let legacy = ["envelopes", "bodies", "folders"].map { root.appendingPathComponent($0) }
        for directory in legacy {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("left behind".utf8).write(to: directory.appendingPathComponent("left-behind"))
        }
        let alice = try account("cabalmail.example", "alice")
        let client = try makeClient(alice)
        for directory in legacy {
            XCTAssertTrue(exists(directory), "precondition: opening the client leaves \(directory.lastPathComponent)")
        }

        await client.clearLocalData()

        for directory in legacy {
            XCTAssertFalse(exists(directory), "\(directory.lastPathComponent) is still in the root")
        }
        let home = AccountDirectory.url(for: alice, in: root)
        XCTAssertEqual(try names(in: home.appendingPathComponent("envelopes")), [], "its own are emptied in place")
    }

    func testASignOutWipeRemovesThemToo() async throws {
        let legacy = root.appendingPathComponent("bodies")
        try files.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("left behind".utf8).write(to: legacy.appendingPathComponent("left-behind"))
        let client = try makeClient(try account("cabalmail.example", "alice"))

        await client.clearLocalDataEndingSession()

        XCTAssertFalse(exists(legacy))
    }
}
