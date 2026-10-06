import XCTest
@testable import CabalmailKit

/// `CabalmailClient.shutdown()` is what the app calls on a client it lets
/// go. Every client `make(...)` builds runs a send queue that drains the
/// outbox on its own (on reconnect, on a kick after a queued send), and the
/// outbox lives in the one cache directory every client is built over, so a
/// client the app had dropped could still drain the outbox the app's current
/// client drains. After `shutdown()` nothing drains; the client's own API
/// calls and the outbox keep working.
final class ClientShutdownTests: XCTestCase {
    private static let configuration = Configuration(
        controlDomain: "cabalmail.example",
        domains: [MailDomain(domain: "cabalmail.example")],
        invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
        cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
    )

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("client-shutdown-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A send that fails like an offline one is queued, and the queue is
    /// kicked. A shut-down client's queue answers nothing: the only `/send`
    /// is the send's own attempt, and the message stays queued, unattempted.
    func testAShutDownClientDrainsNothing() async throws {
        let sends = SendCounter()
        let client = try await makeSignedInClient(sends: sends)

        await client.shutdown()
        let outcome = try await client.send(Self.message())

        guard case .queued(let id) = outcome else { return XCTFail("expected the send to queue, got \(outcome)") }
        // Give a drain every chance to start before checking none did.
        try await Task.sleep(nanoseconds: 500_000_000)
        let attempts = await sends.count
        XCTAssertEqual(attempts, 1, "only the send's own attempt reached /send")
        let queued = try await client.outbox.list()
        XCTAssertEqual(queued.map(\.id), [id], "the message stays in the outbox")
        XCTAssertEqual(queued.first?.attempts, 0, "no drain attempted it")
        let isShutDown = await client.isShutDown
        XCTAssertTrue(isShutDown)
    }

    /// The control: the same send on a client that is not shut down is
    /// drained at once, so the test above would see it.
    func testALiveClientDrainsTheQueuedMessage() async throws {
        let sends = SendCounter()
        let client = try await makeSignedInClient(sends: sends)

        _ = try await client.send(Self.message())

        // The drain records its attempt on the entry once `/send` has failed.
        try await waitUntil { ((try? await client.outbox.list().first?.attempts) ?? 0) >= 1 }
        let attempts = await sends.count
        XCTAssertGreaterThanOrEqual(attempts, 2, "the send's own attempt, then the drain's")
        await client.shutdown()
    }

    /// Idempotent, and a client shut down twice still answers its API calls.
    func testShuttingDownTwiceLeavesTheClientAnswering() async throws {
        let sends = SendCounter()
        let client = try await makeSignedInClient(sends: sends)

        await client.shutdown()
        await client.shutdown()
        _ = try await client.send(Self.message())

        let attempts = await sends.count
        XCTAssertEqual(attempts, 1)
    }

    // MARK: - Helpers

    /// A client from the factory the app uses, signed in, over a network
    /// whose `/send` fails the way URLSession does with no connection.
    private func makeSignedInClient(sends: SendCounter) async throws -> CabalmailClient {
        let transport = ScriptedHTTPTransport { request in
            if request.url?.path.hasSuffix("/send") == true { await sends.bump() }
            throw CabalmailError.network("The Internet connection appears to be offline.")
        }
        let client = try CabalmailClient.make(
            configuration: Self.configuration,
            secureStore: InMemorySecureStore(),
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
        return client
    }

    private static func message() -> OutgoingMessage {
        OutgoingMessage(
            from: EmailAddress(name: nil, mailbox: "alice", host: "cabalmail.example"),
            to: [EmailAddress(name: nil, mailbox: "bob", host: "example.com")],
            subject: "queued",
            textBody: "body"
        )
    }
}

private actor SendCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}
