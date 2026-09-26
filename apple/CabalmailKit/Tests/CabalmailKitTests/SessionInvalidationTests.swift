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

    /// Collects yields off the monitor's stream. The observation task is
    /// started before the exercise and drained after it, so a signal that
    /// never arrives fails as a count rather than hanging the suite.
    private actor Collector {
        private(set) var count = 0
        func record() { count += 1 }
    }

    private func observe(_ monitor: SessionInvalidationMonitor) -> (Collector, Task<Void, Never>) {
        let collector = Collector()
        let task = Task {
            for await _ in monitor.events() {
                await collector.record()
            }
        }
        return (collector, task)
    }

    /// Gives the observation task a turn to consume what was yielded. The
    /// stream is unbuffered from the yielding side's perspective, so a plain
    /// read of `count` immediately after the throw can race.
    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    func testSecondUnauthorizedAnnouncesOnceAndStillThrows() async throws {
        let monitor = SessionInvalidationMonitor()
        let (collector, task) = observe(monitor)
        await settle()

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

        await settle()
        let count = await collector.count
        XCTAssertEqual(count, 1)
        task.cancel()
    }

    func testRefreshedUnauthorizedDoesNotAnnounce() async throws {
        let monitor = SessionInvalidationMonitor()
        let (collector, task) = observe(monitor)
        await settle()

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

        await settle()
        let count = await collector.count
        XCTAssertEqual(count, 0)
        task.cancel()
    }

    /// The common case: the request dies before it is ever sent, because
    /// minting the token is what Cognito refuses (#1288 mapped that refusal to
    /// `.authExpired`; this is the announcement riding on it).
    func testRefusedRefreshAnnounces() async throws {
        let monitor = SessionInvalidationMonitor()
        let (collector, task) = observe(monitor)
        await settle()

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
        await settle()
        let afterSignIn = await collector.count
        XCTAssertEqual(afterSignIn, 0, "A live sign-in must not announce an expiry")

        do {
            _ = try await service.currentIdToken()
            XCTFail("Expected the refused refresh to surface as an expired session")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .authExpired)
        }

        await settle()
        let count = await collector.count
        XCTAssertEqual(count, 1)
        task.cancel()
    }

    /// A fresh token needs no refresh, so nothing announces — the guard that
    /// keeps the signal off every ordinary request.
    func testLiveSessionNeverAnnounces() async throws {
        let monitor = SessionInvalidationMonitor()
        let (collector, task) = observe(monitor)
        await settle()

        let http = RecordingHTTPTransport(responses: [(Data("[]".utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http,
            sessionInvalidation: monitor
        )
        _ = try await client.listAddresses()

        await settle()
        let count = await collector.count
        XCTAssertEqual(count, 0)
        task.cancel()
    }
}
