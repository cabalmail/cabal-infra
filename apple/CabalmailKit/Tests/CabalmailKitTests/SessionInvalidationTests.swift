import XCTest
@testable import CabalmailKit

/// Issue #1703: an expiry that happens while the app is running has to leave
/// the call stack. Before this, both production sites only threw, so the fact
/// landed in whichever view model made the call and the session stayed nominally
/// signed in. These pin the two sites that announce, and — more importantly —
/// the one that must not: a 401 a refresh cures is an ordinary silent refresh,
/// and announcing there would sign the user out mid-session.
final class SessionInvalidationTests: XCTestCase {
    private func makeConfiguration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "us-east-1_ABC", clientId: "clientX")
        )
    }

    // Each test subscribes to the monitor before the exercise and counts what
    // the stream has buffered afterwards (`bufferedCount`). `sessionDidExpire`
    // yields before the throw it accompanies, so the count is exact once the
    // call has returned. An observer task that had to be given turns (ten
    // `Task.yield()`s) to consume the yield raced the assertion on a loaded CI
    // runner and read 0 for a signal that had been sent.

    func testSecondUnauthorizedAnnouncesOnceAndStillThrows() async throws {
        let monitor = SessionInvalidationMonitor()
        let events = monitor.events()

        let http = RecordingHTTPTransport(responses: [
            (Data("unauth".utf8), 401),
            (Data("unauth".utf8), 401),
        ])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http,
            sessionInvalidation: monitor
        )

        do {
            _ = try await client.listAddresses()
            XCTFail("Expected the second 401 to surface as an expired session")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .authExpired)
        }

        let count = await bufferedCount(events)
        XCTAssertEqual(count, 1)
    }

    func testRefreshedUnauthorizedDoesNotAnnounce() async throws {
        let monitor = SessionInvalidationMonitor()
        let events = monitor.events()

        // 401 then 200: the refresh worked and the replay succeeded. This is
        // the ordinary silent-refresh path and it must stay silent.
        let http = RecordingHTTPTransport(responses: [
            (Data("unauth".utf8), 401),
            (Data("[]".utf8), 200),
        ])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http,
            sessionInvalidation: monitor
        )

        let addresses = try await client.listAddresses()
        XCTAssertTrue(addresses.isEmpty)

        let count = await bufferedCount(events)
        XCTAssertEqual(count, 0)
    }

    /// The common case: the request dies before it is ever sent, because
    /// minting the token is what Cognito refuses (#1288 mapped that refusal to
    /// `.authExpired`; this is the announcement riding on it).
    func testRefusedRefreshAnnounces() async throws {
        let monitor = SessionInvalidationMonitor()
        let events = monitor.events()

        let initialTokens = """
        {
          "AuthenticationResult": {
            "IdToken": "OLD-ID",
            "AccessToken": "OLD-ACCESS",
            "RefreshToken": "REFRESH",
            "ExpiresIn": 1,
            "TokenType": "Bearer"
          }
        }
        """
        let errorType = "com.amazonaws.cognito.identity.model#NotAuthorizedException"
        let refusal = """
        {"__type":"\(errorType)","message":"Refresh Token has been revoked"}
        """
        let http = RecordingHTTPTransport(responses: [
            (Data(initialTokens.utf8), 200),
            (Data(refusal.utf8), 400),
        ])
        let clockRef = ClockReference(value: Date(timeIntervalSince1970: 1_000))
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: http,
            secureStore: InMemorySecureStore(),
            clock: { clockRef.value },
            sessionInvalidation: monitor
        )

        _ = try await service.signIn(username: "alice", password: "hunter2")
        clockRef.value = Date(timeIntervalSince1970: 1_100)
        let afterSignIn = await bufferedCount(events)
        XCTAssertEqual(afterSignIn, 0, "A live sign-in must not announce an expiry")
        let refreshEvents = monitor.events()

        do {
            _ = try await service.currentIdToken()
            XCTFail("Expected the refused refresh to surface as an expired session")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .authExpired)
        }

        let count = await bufferedCount(refreshEvents)
        XCTAssertEqual(count, 1)
    }

    /// A fresh token needs no refresh, so nothing announces — the guard that
    /// keeps the signal off every ordinary request.
    func testLiveSessionNeverAnnounces() async throws {
        let monitor = SessionInvalidationMonitor()
        let events = monitor.events()

        let http = RecordingHTTPTransport(responses: [(Data("[]".utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http,
            sessionInvalidation: monitor
        )
        _ = try await client.listAddresses()

        let count = await bufferedCount(events)
        XCTAssertEqual(count, 0)
    }
}
