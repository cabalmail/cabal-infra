import XCTest
@testable import CabalmailKit

/// An auth service after `signOut()` (#1852). Every session on the device
/// keeps its tokens in one keychain item, so once the next account signs in
/// that item holds the next account's tokens. The last session's client is
/// still held by whatever work it had in flight, and before this a request
/// that work started then went out with the next account's ID token. Each
/// test stands in for the next sign-in with a second service writing to the
/// same store.
final class EndedAuthServiceTests: XCTestCase {
    private static let configuration = Configuration(
        controlDomain: "cabalmail.example",
        domains: [MailDomain(domain: "cabalmail.example")],
        invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
        cognito: .init(region: "us-east-1", userPoolId: "us-east-1_ABC", clientId: "clientX")
    )

    private let store = InMemorySecureStore()

    func testAnEndedServiceReadsNoneOfTheNextAccountsTokens() async throws {
        let last = service()
        try await last.adopt(tokens: Self.tokens("ID-ALICE"))
        try await last.signOut()
        try await service().adopt(tokens: Self.tokens("ID-BOB"))

        await assertNotSignedIn { _ = try await last.currentIdToken() }
        await assertNotSignedIn { _ = try await last.refreshIdToken(replacing: nil) }
        let tokens = await last.currentTokens()
        XCTAssertNil(tokens)
        let next = try await service().currentIdToken()
        XCTAssertEqual(next, "ID-BOB", "the next account's own service reads them")
    }

    /// The request the issue is about never reaches the network, and its
    /// failure is not announced as an expiry, which would sign the next
    /// account out.
    func testAnEndedSessionsRequestIsNeverSent() async throws {
        let http = RecordingHTTPTransport(responses: [(Data("[]".utf8), 200)])
        let monitor = SessionInvalidationMonitor()
        let announcements = monitor.events()
        let last = service()
        let api = URLSessionApiClient(
            configuration: Self.configuration, authService: last, transport: http, sessionInvalidation: monitor
        )
        try await last.adopt(tokens: Self.tokens("ID-ALICE"))
        try await last.signOut()
        try await service().adopt(tokens: Self.tokens("ID-BOB"))

        await assertNotSignedIn { _ = try await api.listAddresses() }

        let requests = await http.requests
        XCTAssertEqual(requests.count, 0)
        let count = await bufferedCount(announcements)
        XCTAssertEqual(count, 0)
    }

    /// Negative control: before the sign-out the same request goes out with
    /// the session's own token.
    func testALiveSessionsRequestCarriesItsOwnToken() async throws {
        let http = RecordingHTTPTransport(responses: [(Data(#"{"Items":[]}"#.utf8), 200)])
        let live = service()
        let api = URLSessionApiClient(configuration: Self.configuration, authService: live, transport: http)
        try await live.adopt(tokens: Self.tokens("ID-ALICE"))

        _ = try? await api.listAddresses()

        let requests = await http.requests
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "ID-ALICE")
    }

    /// A new session on the same service (the watch adopts each handoff on
    /// its service) reads tokens again.
    func testAdoptingAfterASignOutStartsTheServiceAgain() async throws {
        let session = service()
        try await session.adopt(tokens: Self.tokens("ID-ALICE"))
        try await session.signOut()

        try await session.adopt(tokens: Self.tokens("ID-CAROL"))

        let token = try await session.currentIdToken()
        XCTAssertEqual(token, "ID-CAROL")
    }

    private func service() -> CognitoAuthService {
        CognitoAuthService(configuration: Self.configuration, transport: NullHTTPTransport(), secureStore: store)
    }

    private static func tokens(_ id: String) -> AuthTokens {
        AuthTokens(
            idToken: id,
            accessToken: "access-\(id)",
            refreshToken: "refresh-\(id)",
            expiresAt: Date().addingTimeInterval(3600)
        )
    }

    private func assertNotSignedIn(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected notSignedIn", file: file, line: line)
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .notSignedIn, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}
