import XCTest
import CabalmailKitTestSupport
@testable import CabalmailKit

/// What the account-directory suites share: a cache root in a temp
/// directory, a recording Spotlight index, and clients from the factory the
/// app uses over a network that is never there, so they run on every
/// platform. Every client made here is shut down in `tearDown`.
class AccountDirectoryTestCase: XCTestCase {
    private(set) var root: URL!
    private(set) var index: FakeSearchableIndex!
    private var clients: [CabalmailClient] = []
    let files = FileManager.default

    override func setUp() async throws {
        root = files.temporaryDirectory.appendingPathComponent("account-directory-\(UUID().uuidString)")
        index = FakeSearchableIndex()
    }

    override func tearDown() async throws {
        for client in clients {
            await client.shutdown()
        }
        clients = []
        try? files.removeItem(at: root)
    }

    func account(_ controlDomain: String, _ username: String) throws -> AccountIdentity {
        try XCTUnwrap(AccountIdentity(controlDomain: controlDomain, username: username))
    }

    func makeClient(_ account: AccountIdentity?, root: URL? = nil) throws -> CabalmailClient {
        let client = try CabalmailClient.make(
            configuration: TestFixtures.makeConfiguration(),
            secureStore: InMemorySecureStore(),
            httpTransport: ScriptedHTTPTransport { _ in throw CabalmailError.network("offline") },
            cacheDirectory: root ?? self.root,
            account: account,
            searchableIndex: index
        )
        clients.append(client)
        return client
    }

    func exists(_ url: URL) -> Bool {
        files.fileExists(atPath: url.path)
    }

    func names(in directory: URL) throws -> [String] {
        try files.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// The names in the root's `accounts/`: none when it is not there.
    func accountNames() -> [String] {
        let container = root.appendingPathComponent(AccountDirectory.containerName)
        return (try? names(in: container)) ?? []
    }

    /// One message in INBOX, list and body, and a folder list.
    func seedMail(in client: CabalmailClient, uid: UInt32) async throws {
        try await client.envelopeCache.merge(
            envelopes: [TestFixtures.makeEnvelope(uid: uid)], uidValidity: 1, uidNext: uid + 1, into: "INBOX"
        )
        try await client.bodyCache.store(folder: "INBOX", uidValidity: 1, uid: uid, bytes: Data("body \(uid)".utf8))
        let generation = await client.folderStateCache.generation
        await client.folderStateCache.recordFolders(
            [Folder(path: "INBOX", isSubscribed: true)], ifUnchangedSince: generation
        )
    }

    /// The UIDs of the messages saved for INBOX, list side.
    func savedUIDs(in client: CabalmailClient) async -> [UInt32] {
        await client.envelopeCache.snapshot(for: "INBOX")?.envelopes.keys.sorted() ?? []
    }
}
