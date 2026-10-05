import XCTest
@testable import CabalmailKit

/// Characterization suite for workstream 0.8 (the app-layer rearchitecture
/// that moves sign-in into a per-account session). It pins the Kit behaviour
/// the session entry points chain, beside the restore pipeline in
/// `RestorePipelineCharacterizationTests`:
///
/// - the second-factor half of interactive sign-in in `CognitoAuthService`
///   (identity plan Phase 1). `AppState.submitMfaCode` keeps the code form up
///   only for `.server(code: "CodeMismatchException")`, matched on that exact
///   string, and cannot be tested yet because its parked challenge is private;
/// - the `ConfigLoader` cache (#1779) cases `ConfigLoaderTests` leaves open;
/// - the `SessionInvalidationMonitor` fan-out (#1703).
///
/// `AuthServiceMfaTests` already covers the TOTP happy path, a submit with no
/// challenge, and an unknown challenge; none of that is repeated here. A case
/// that pins behaviour that looks wrong says so.
final class AuthMfaCharacterizationTests: XCTestCase {
    private static let configuration = Configuration(
        controlDomain: "cabalmail.example",
        domains: [MailDomain(domain: "cabalmail.example")],
        invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
        cognito: .init(region: "us-east-1", userPoolId: "us-east-1_ABC", clientId: "clientX")
    )

    private static func challenge(_ name: String, session: String) -> (Data, Int) {
        (Data(#"{"ChallengeName":"\#(name)","Session":"\#(session)","ChallengeParameters":{}}"#.utf8), 200)
    }

    private static let signedIn = (
        Data(#"{"AuthenticationResult":{"IdToken":"I","AccessToken":"A","RefreshToken":"R","ExpiresIn":3600}}"#.utf8),
        200
    )

    private static func refusal(_ type: String, _ message: String) -> (Data, Int) {
        (Data(#"{"__type":"\#(type)","message":"\#(message)"}"#.utf8), 400)
    }

    private func makeService(_ http: RecordingHTTPTransport) -> CognitoAuthService {
        CognitoAuthService(configuration: Self.configuration, transport: http, secureStore: InMemorySecureStore())
    }

    /// The JSON body of request `index`; a missing request fails the test
    /// instead of trapping on the subscript.
    private func body(_ requests: [URLRequest], _ index: Int) throws -> [String: Any] {
        let request = try XCTUnwrap(requests.indices.contains(index) ? requests[index] : nil, "no request \(index)")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    }

    private func assertThrows(
        _ expected: CabalmailError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ call: () async throws -> Void
    ) async {
        do {
            try await call()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as CabalmailError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    func testCodeMismatchSurfacesTheExactServerCodeAndKeepsTheChallenge() async throws {
        let http = RecordingHTTPTransport(responses: [
            Self.challenge("SOFTWARE_TOKEN_MFA", session: "sess-1"),
            Self.refusal("CodeMismatchException", "Invalid code received for user"),
            Self.signedIn,
        ])
        let service = makeService(http)
        let result = try await service.signIn(username: "user-one", password: "pw")
        XCTAssertEqual(result, .mfaCodeRequired(.totp))

        await assertThrows(.server(code: "CodeMismatchException", message: "Invalid code received for user")) {
            try await service.submitMfaCode("000000")
        }
        let afterMismatch = await service.currentTokens()
        XCTAssertNil(afterMismatch, "a wrong code stores nothing")

        try await service.submitMfaCode("123456")

        let requests = await http.requests
        XCTAssertEqual(requests.count, 3)
        let retry = try body(requests, 2)
        XCTAssertEqual(retry["Session"] as? String, "sess-1", "the retry answers the same challenge")
        XCTAssertEqual((retry["ChallengeResponses"] as? [String: String])?["SOFTWARE_TOKEN_MFA_CODE"], "123456")
        let token = try await service.currentIdToken()
        XCTAssertEqual(token, "I")
    }

    /// Cognito answers a code sent after the challenge session expired (it
    /// allows three minutes) with `NotAuthorizedException`. The password was
    /// already accepted, so the service reports `.authExpired`, which
    /// `AppState.submitMfaCode` shows as "Session expired. Please sign in
    /// again." Before #1807 it reported `.invalidCredentials`, and the form
    /// said "Incorrect username or password."
    ///
    /// The second submit re-sending `sess-1` is not a defect: `submitMfaCode`
    /// keeps the challenge until success by design (Cognito allows a bounded
    /// number of retries per session; see the comment in `submitMfaCode` and
    /// the `AuthService` protocol doc). It is harmless for an expired session,
    /// and AppState never reaches it, because on any error but
    /// `CodeMismatchException` it drops its parked client and returns to the
    /// password form.
    func testNotAuthorizedOnTheChallengeResponseReadsAsAnExpiredSession() async throws {
        let expired = Self.refusal("NotAuthorizedException", "Invalid session for the user, session is expired.")
        let http = RecordingHTTPTransport(responses: [
            Self.challenge("SOFTWARE_TOKEN_MFA", session: "sess-1"), expired, expired,
        ])
        let service = makeService(http)
        _ = try await service.signIn(username: "user-one", password: "pw")

        await assertThrows(.authExpired) { try await service.submitMfaCode("123456") }
        await assertThrows(.authExpired) { try await service.submitMfaCode("123456") }

        let requests = await http.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(try body(requests, 2)["Session"] as? String, "sess-1")
    }

    func testSmsChallengeAnswersWithTheSmsCodeKey() async throws {
        let http = RecordingHTTPTransport(responses: [
            Self.challenge("SMS_MFA", session: "sms-sess"),
            Self.signedIn,
        ])
        let service = makeService(http)

        let result = try await service.signIn(username: "user-one", password: "pw")
        XCTAssertEqual(result, .mfaCodeRequired(.sms))
        try await service.submitMfaCode("654321")

        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        let answer = try body(requests, 1)
        XCTAssertEqual(
            requests.last?.value(forHTTPHeaderField: "X-Amz-Target"),
            "AWSCognitoIdentityProviderService.RespondToAuthChallenge"
        )
        XCTAssertEqual(answer["ChallengeName"] as? String, "SMS_MFA")
        XCTAssertEqual(answer["Session"] as? String, "sms-sess")
        XCTAssertEqual(
            answer["ChallengeResponses"] as? [String: String],
            ["USERNAME": "user-one", "SMS_MFA_CODE": "654321"]
        )
    }

    func testSignOutDiscardsThePendingChallenge() async throws {
        let http = RecordingHTTPTransport(responses: [Self.challenge("SOFTWARE_TOKEN_MFA", session: "sess-1")])
        let service = makeService(http)
        _ = try await service.signIn(username: "user-one", password: "pw")

        try await service.signOut()

        await assertThrows(.notSignedIn) { try await service.submitMfaCode("123456") }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1, "nothing is sent for a discarded challenge")
    }

    func testNewSignInReplacesThePendingChallengeSession() async throws {
        let http = RecordingHTTPTransport(responses: [
            Self.challenge("SOFTWARE_TOKEN_MFA", session: "sess-1"),
            Self.challenge("SOFTWARE_TOKEN_MFA", session: "sess-2"),
            Self.signedIn,
        ])
        let service = makeService(http)
        _ = try await service.signIn(username: "user-one", password: "pw")
        _ = try await service.signIn(username: "user-two", password: "pw")

        try await service.submitMfaCode("123456")

        let requests = await http.requests
        let answer = try body(requests, 2)
        XCTAssertEqual(answer["Session"] as? String, "sess-2")
        XCTAssertEqual((answer["ChallengeResponses"] as? [String: String])?["USERNAME"], "user-two")
    }

    /// `signIn` drops the old challenge before it sends anything, so even a
    /// second attempt that fails leaves no challenge to answer.
    func testFailedSignInStillDropsTheEarlierChallenge() async throws {
        let http = RecordingHTTPTransport(responses: [
            Self.challenge("SOFTWARE_TOKEN_MFA", session: "sess-1"),
            Self.refusal("NotAuthorizedException", "Incorrect username or password."),
        ])
        let service = makeService(http)
        _ = try await service.signIn(username: "user-one", password: "pw")
        await assertThrows(.invalidCredentials) {
            _ = try await service.signIn(username: "user-one", password: "wrong")
        }

        await assertThrows(.notSignedIn) { try await service.submitMfaCode("123456") }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
    }

    /// A known MFA challenge with no `Session` cannot be answered, so it is
    /// reported the same way as a challenge the app does not handle.
    func testChallengeWithoutASessionIsUnhandled() async throws {
        let bare = (Data(#"{"ChallengeName":"SOFTWARE_TOKEN_MFA"}"#.utf8), 200)
        let service = makeService(RecordingHTTPTransport(responses: [bare]))

        await assertThrows(.protocolError("Unhandled challenge: SOFTWARE_TOKEN_MFA")) {
            _ = try await service.signIn(username: "user-one", password: "pw")
        }
        await assertThrows(.notSignedIn) { try await service.submitMfaCode("123456") }
    }
}

/// The offline `config.json` cache of #1779: the parts of `ConfigLoader`'s
/// cache that `ConfigLoaderTests` leaves open: the key's case folding, which
/// failures fall back, and which do not.
final class ConfigLoaderCacheCharacterizationTests: XCTestCase {
    private static let configJSON = Data("""
    {
      "control_domain": "mail.example.com",
      "domains": [{"domain": "example.com", "zone_id": "Z1", "name_servers": []}],
      "invokeUrl": "https://api.example.com/prod",
      "cognitoConfig": {"region": "us-east-1", "poolData": {"UserPoolId": "us-east-1_pool", "ClientId": "client123"}}
    }
    """.utf8)

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var cache: ConfigurationCache!

    override func setUp() {
        super.setUp()
        suiteName = "ConfigLoaderCacheCharacterizationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        cache = ConfigurationCache(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private static func answering(_ status: Int) -> ScriptedHTTPTransport {
        ScriptedHTTPTransport { request in
            let body = status == 200 ? configJSON : Data("upstream error".utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private static func failing(with error: Error) -> ScriptedHTTPTransport {
        ScriptedHTTPTransport { _ in throw error }
    }

    private func load(
        _ domain: String = "mail.example.com",
        over transport: ScriptedHTTPTransport
    ) async throws -> Configuration {
        try await ConfigLoader.load(controlDomain: domain, transport: transport, cache: cache)
    }

    func testCacheKeyIsTheLowerCasedDomain() async throws {
        let online = try await load("  Mail.Example.COM\n", over: Self.answering(200))

        XCTAssertNotNil(defaults.data(forKey: "cabalmail.config.mail.example.com"))
        XCTAssertEqual(cache.load(controlDomain: "mail.example.com"), online)
        let offline = try await load("MAIL.EXAMPLE.COM", over: Self.failing(with: CabalmailError.network("offline")))
        XCTAssertEqual(offline, online)
    }

    func testServerErrorsAndTransportFailuresFallBackToTheCachedCopy() async throws {
        let online = try await load(over: Self.answering(200))
        let transports: [(String, ScriptedHTTPTransport)] = [
            ("404", Self.answering(404)),
            ("500", Self.answering(500)),
            ("503", Self.answering(503)),
            ("transport", Self.failing(with: CabalmailError.transport("Non-HTTP response"))),
        ]
        for (name, transport) in transports {
            let loaded = try await load(over: transport)
            XCTAssertEqual(loaded, online, name)
        }
    }

    func testServerErrorWithNothingCachedRethrowsIt() async {
        do {
            _ = try await load(over: Self.answering(503))
            XCTFail("expected a server error")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .server(code: "503", message: "Failed to fetch config.json from mail.example.com"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// Only "no answer", a non-2xx and an undecodable body fall back. Any
    /// other error is rethrown even with a good copy cached, and an error
    /// that is not a `CabalmailError` passes through raw.
    ///
    /// Both errors here come only from a custom transport. The production
    /// `URLSessionHTTPTransport` turns every `URLError`, a cooperative cancel
    /// included, into `.network`, which does fall back; so a cancelled launch
    /// still gets the cached config. This guards the `default` branch.
    func testOtherErrorsDoNotFallBack() async throws {
        _ = try await load(over: Self.answering(200))
        do {
            _ = try await load(over: Self.failing(with: CabalmailError.cancelled))
            XCTFail("expected .cancelled")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .cancelled)
        }
        do {
            _ = try await load(over: Self.failing(with: URLError(.badURL)))
            XCTFail("expected the raw URLError")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badURL)
        }
    }

    func testUndecodableCachedEntryCountsAsNothingCached() async {
        defaults.set(Data("not json".utf8), forKey: "cabalmail.config.mail.example.com")
        do {
            _ = try await load(over: Self.failing(with: CabalmailError.network("offline")))
            XCTFail("expected the network error")
        } catch CabalmailError.network {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

/// `SessionInvalidationMonitor`'s own contract (#1703), which the app relies
/// on when it subscribes in `wireSession`, after restore has already run.
/// `SessionInvalidationTests` covers which call sites announce; this covers
/// who hears it.
final class SessionInvalidationMonitorCharacterizationTests: XCTestCase {
    /// No replay: expiry is an event, so a stream made after an announcement
    /// never hears it, though it does hear the next one.
    func testLateSubscriberGetsNoReplay() async {
        let monitor = SessionInvalidationMonitor()
        let early = monitor.events()
        monitor.sessionDidExpire()
        let late = monitor.events()
        monitor.sessionDidExpire()

        let earlyCount = await bufferedCount(early)
        let lateCount = await bufferedCount(late)
        XCTAssertEqual(earlyCount, 2)
        XCTAssertEqual(lateCount, 1)
    }

    func testEverySubscriberReceivesEverySignal() async {
        let monitor = SessionInvalidationMonitor()
        let streams = [monitor.events(), monitor.events(), monitor.events()]
        monitor.sessionDidExpire()
        monitor.sessionDidExpire()

        for stream in streams {
            let count = await bufferedCount(stream)
            XCTAssertEqual(count, 2)
        }
    }

    func testEndedSubscriptionsUnregister() async {
        let monitor = SessionInvalidationMonitor()
        let stream = monitor.events()
        XCTAssertEqual(registeredStreams(monitor), 1)

        let consumer = Task { for await _ in stream {} }
        consumer.cancel()
        await consumer.value
        XCTAssertEqual(registeredStreams(monitor), 0, "a cancelled consumer unregisters")

        _ = monitor.events()
        XCTAssertEqual(registeredStreams(monitor), 0, "a stream nobody keeps unregisters at once")
    }

    /// #1809, fixed in workstream 0.7. The stream's termination handler holds
    /// the monitor weakly, so a subscriber keeps only its stream: releasing the
    /// monitor's last owner frees it, and its `deinit` finishes every live
    /// stream, so the subscriber's loop ends rather than outliving the
    /// session. Until 0.7 this pinned the reverse (the subscription held the
    /// monitor until the subscriber cancelled), as `Reachability` did.
    func testLiveSubscriptionDoesNotKeepTheMonitorAlive() async {
        weak var subscribed: SessionInvalidationMonitor?
        let stream: AsyncStream<Void>
        do {
            let monitor = SessionInvalidationMonitor()
            subscribed = monitor
            stream = monitor.events()
        }
        XCTAssertNil(subscribed, "the subscription held its monitor (#1809)")
        let finishedByTheMonitor = await finishesWithoutCancelling(stream)
        XCTAssertTrue(finishedByTheMonitor, "releasing the monitor did not finish its live stream")
    }

    /// Read through the monitor's test-only count. A failure right after the
    /// storage is reshaped means this probe needs rewriting against the new
    /// storage, not that unregistration broke; never just edit it to pass.
    private func registeredStreams(_ monitor: SessionInvalidationMonitor) -> Int {
        monitor.subscriberCount
    }
}
