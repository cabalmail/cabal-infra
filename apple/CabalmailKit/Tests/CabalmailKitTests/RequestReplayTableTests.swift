import XCTest
@testable import CabalmailKit

/// Every request the Kit makes, driven through the real transport over a
/// connection that drops once (`URLError.networkConnectionLost`, -1005): a
/// request `docs/request-replay.md` marks replay-safe is sent a second time,
/// and any other is sent once and fails as a network error. The rows here
/// and that table say the same thing; change both together.
final class RequestReplayTableTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ScriptedURLProtocol.reset()
    }

    override func tearDown() {
        ScriptedURLProtocol.reset()
        super.tearDown()
    }

    func testEachApiRequestIsSentAgainOnlyWhenTheTableSaysSo() async throws {
        let client = Self.apiClient()
        for row in RequestReplayRows.api {
            let attempts = await Self.attempts { try await row.call(client) }
            XCTAssertEqual(attempts, row.verdict.attempts, "\(row.endpoint): \(row.verdict.description)")
        }
    }

    func testEachCognitoOperationIsSentAgainOnlyWhenTheTableSaysSo() async throws {
        for row in RequestReplayRows.cognito {
            let service = try await Self.cognitoService(signedIn: row.needsSession)
            if row.needsChallenge {
                ScriptedURLProtocol.script(responses: [(Data(Self.mfaChallenge.utf8), 200)])
                _ = try await service.signIn(username: "alice", password: "pw")
            }
            let attempts = await Self.attempts { try await row.call(service) }
            XCTAssertEqual(attempts, row.verdict.attempts, "\(row.operation): \(row.verdict.description)")
        }
    }

    /// A write added to the client without a row here would be sent once by
    /// default; this makes adding it a decision, with its row in the doc.
    func testEveryWriteTheClientSendsHasARow() throws {
        let sources = try Self.apiSources()
        let pattern = try NSRegularExpression(pattern: #"\b(?:post|put|delete)\("/?([a-z_]+)""#)
        var written = Set<String>()
        for source in sources {
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                written.insert(String(source[Range(match.range(at: 1), in: source)!]))
            }
        }
        XCTAssertFalse(written.isEmpty, "found no writes under API/; the pattern no longer matches the client")
        let tabled = Set(RequestReplayRows.api.map(\.endpoint))
        XCTAssertEqual(written.subtracting(tabled), [], "writes with no row in the replay table")
        // And the policy names no endpoint the table has dropped.
        XCTAssertEqual(RequestReplayPolicy.replaySafeWrites.subtracting(tabled), [], "policy entries with no row")
    }

    /// The same for the Cognito operations `CognitoAuthService` calls.
    func testEveryCognitoOperationHasARow() throws {
        let source = try String(contentsOf: Self.kitSources.appendingPathComponent("Auth/AuthService.swift"),
                                encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"\bcall\("([A-Za-z]+)""#)
        let range = NSRange(source.startIndex..., in: source)
        let called = Set(pattern.matches(in: source, range: range).map {
            String(source[Range($0.range(at: 1), in: source)!])
        })
        XCTAssertFalse(called.isEmpty, "found no Cognito calls; the pattern no longer matches AuthService")
        let tabled = Set(RequestReplayRows.cognito.map(\.operation))
        XCTAssertEqual(called.subtracting(tabled), [], "operations with no row")
        let safe = RequestReplayPolicy.replaySafeCognitoOperations
        XCTAssertEqual(safe.subtracting(tabled), [], "policy entries with no row")
    }

    /// A presigned URL's last path component is the user's file name; one
    /// that spells an endpoint must not borrow its verdict.
    func testAPresignedUploadIsRecognisedBeforeItsFileName() async throws {
        let client = Self.apiClient()
        let url = try XCTUnwrap(URL(string:
            "https://cabal-cache.s3.amazonaws.com/outbound/alice/1/new_folder?X-Amz-Signature=abc"))
        let upload = await Self.attempts {
            try await client.uploadAttachment(url: url, mimeType: "text/plain", data: Data("x".utf8))
        }
        let fetch = await Self.attempts { _ = try await client.fetchPresignedData(url: url) }
        XCTAssertEqual(upload, 2)
        XCTAssertEqual(fetch, 2)
    }

    // MARK: - Harness

    /// Runs `call` with the first attempt dropped and the second answered
    /// 200, and returns how many attempts reached the network.
    private static func attempts(_ call: () async throws -> Void) async -> Int {
        ScriptedURLProtocol.script(
            failures: [URLError(.networkConnectionLost)],
            responses: [(Data("{}".utf8), 200)]
        )
        // The 200's "{}" doesn't decode as every reply; only the count matters.
        _ = try? await call()
        return ScriptedURLProtocol.callCount
    }

    private static func transport() -> URLSessionHTTPTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedURLProtocol.self]
        return URLSessionHTTPTransport(session: URLSession(configuration: config))
    }

    private static func apiClient() -> URLSessionApiClient {
        URLSessionApiClient(
            configuration: TestFixtures.makeConfiguration(),
            authService: StubAuthService(),
            transport: transport()
        )
    }

    private static func cognitoService(signedIn: Bool) async throws -> CognitoAuthService {
        let service = CognitoAuthService(
            configuration: TestFixtures.makeConfiguration(),
            transport: transport(),
            secureStore: InMemorySecureStore()
        )
        if signedIn {
            try await service.adopt(tokens: AuthTokens(
                idToken: "id", accessToken: "access", refreshToken: "refresh",
                expiresAt: Date().addingTimeInterval(3600)
            ))
        }
        return service
    }

    private static let mfaChallenge = #"{"ChallengeName": "SOFTWARE_TOKEN_MFA", "Session": "s"}"#

    private static let kitSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/CabalmailKit")

    private static func apiSources() throws -> [String] {
        let directory = kitSources.appendingPathComponent("API")
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
    }
}
