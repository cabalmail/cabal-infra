import Synchronization
import XCTest
@testable import CabalmailKit

/// The keychain reports its failures as `.storage` (#1808), no longer as the
/// wire's `.transport`. A send whose token can't be read from the keychain
/// (the reachable case is a launch before the first unlock after a restart)
/// still lands in the outbox, as it did while the failure read as
/// `.transport`, and never reaches the API.
final class StorageErrorQueueTests: XCTestCase {
    private static let configuration = Configuration(
        controlDomain: "cabalmail.example",
        domains: [MailDomain(domain: "cabalmail.example")],
        invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
        cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
    )

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-error-queue-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testASendWhoseTokenCannotBeReadIsQueuedWithoutReachingTheApi() async throws {
        let store = ReadFailingSecureStore(failure: .storage("Keychain read failed: -25308"))
        let requests = RequestCounter()
        let client = try await makeSignedInClient(store: store, requests: requests)
        store.failReads = true

        let outcome = try await client.send(Self.message())

        guard case .queued(let id) = outcome else { return XCTFail("expected the send to queue, got \(outcome)") }
        let queued = try await client.outbox.list()
        XCTAssertEqual(queued.map(\.id), [id])
        let sent = await requests.count
        XCTAssertEqual(sent, 0, "no token, no request")
    }

    /// The control: the same unreadable token with an error the outbox does
    /// not take is thrown to the caller and queues nothing, so the test above
    /// is measuring the queue decision for `.storage`.
    func testAnErrorTheOutboxDoesNotTakeIsThrownInstead() async throws {
        let store = ReadFailingSecureStore(failure: .protocolError("not a queueable failure"))
        let requests = RequestCounter()
        let client = try await makeSignedInClient(store: store, requests: requests)
        store.failReads = true

        do {
            _ = try await client.send(Self.message())
            XCTFail("expected the send to throw")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .protocolError("not a queueable failure"))
        }
        let queued = try await client.outbox.list()
        XCTAssertTrue(queued.isEmpty)
    }

    // MARK: - Helpers

    /// A client from the factory the app uses, signed in and already shut
    /// down, so the only attempt at a queued message is the send's own.
    private func makeSignedInClient(
        store: ReadFailingSecureStore,
        requests: RequestCounter
    ) async throws -> CabalmailClient {
        let transport = ScriptedHTTPTransport { request in
            await requests.bump()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: nil)!
            return (Data("{}".utf8), response)
        }
        let client = try CabalmailClient.make(
            configuration: Self.configuration,
            secureStore: store,
            httpTransport: transport,
            cacheDirectory: root
        )
        let auth = try XCTUnwrap(client.authService as? CognitoAuthService)
        try await auth.adopt(
            tokens: AuthTokens(
                idToken: "ID", accessToken: "ACCESS", refreshToken: "REFRESH",
                tokenType: "Bearer", expiresAt: Date().addingTimeInterval(3600)
            )
        )
        await client.shutdown()
        return client
    }

    private static func message() -> OutgoingMessage {
        OutgoingMessage(
            from: EmailAddress(name: nil, mailbox: "alice", host: "cabalmail.example"),
            to: [EmailAddress(name: nil, mailbox: "bob", host: "example.com")],
            subject: "keychain locked",
            textBody: "body"
        )
    }
}

/// A keychain whose reads can be made to fail with a given error, as a
/// data-protection keychain's do before the first unlock; writes reach the
/// store it wraps.
private final class ReadFailingSecureStore: SecureStore {
    private let base = InMemorySecureStore()
    private let failure: CabalmailError
    private let failing = Mutex(false)

    init(failure: CabalmailError) {
        self.failure = failure
    }

    var failReads: Bool {
        get { failing.withLock { $0 } }
        set { failing.withLock { $0 = newValue } }
    }

    func set(_ value: Data, forKey key: String) throws { try base.set(value, forKey: key) }

    func get(_ key: String) throws -> Data? {
        if failReads { throw failure }
        return try base.get(key)
    }

    func remove(_ key: String) throws { try base.remove(key) }
}

private actor RequestCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}
