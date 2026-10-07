import XCTest
@testable import CabalmailKit

/// Characterization suite for workstream 0.8, the safety net taken before the
/// Apple client's rearchitecture: every way the two hops of
/// `ApiBackedImapClient.fetchBody` (an authenticated `GET /fetch_message`,
/// then a bare GET of the presigned S3 URL it returns, since #371) can fail,
/// and what each one throws to the reader. It pins the 404 message-gone
/// sentence (#940), the maintenance 503 contract (c3037380), the silent 401
/// refresh and once-only expiry announcement (#1703), and the presigned GET's
/// bypass of all of them. The happy path and the shared wire harness
/// (`FetchBodyHarness`) are in `ApiBackedImapClientFetchBodyTests.swift`.
final class ApiBackedImapClientFetchBodyFailureTests: XCTestCase {
    /// #940: the reader shows the server's own sentence. The Lambda names the
    /// leaf of the dotted folder, so a nested folder reads as its last part.
    func testMessageGone404ThrowsHttpWithTheServersSentence() async throws {
        let body = #"{"status": "That message is no longer in Foo", "folder": "Lists.Foo", "id": 7}"#
        let harness = FetchBodyHarness(api: [.json(404, body)])

        let error = await harness.fetchError()

        XCTAssertEqual(error as? CabalmailError, .http(status: 404, body: body))
        XCTAssertEqual(error?.localizedDescription, "That message is no longer in Foo.")
        let hops = await harness.wire.hops
        XCTAssertEqual(hops, ["api"])
    }

    func testMaintenance503ThrowsMaintenanceWithoutTheS3Hop() async throws {
        let copy = "Email access is temporarily unavailable due to planned maintenance."
        let withMessage = #"{"status": "maintenance", "message": "Back in five minutes.", "retry_after": 30}"#
        let withoutMessage = #"{"status": "maintenance", "retry_after": 30}"#
        let cases: [(body: String, expected: String)] = [(withMessage, "Back in five minutes."), (withoutMessage, copy)]
        for (body, expected) in cases {
            let harness = FetchBodyHarness(api: [.json(503, body)])
            let error = await harness.fetchError()
            XCTAssertEqual(error as? CabalmailError, .maintenance(message: expected), expected)
            XCTAssertEqual(error?.localizedDescription, expected, expected)
            let hops = await harness.wire.hops
            XCTAssertEqual(hops, ["api"], "\(expected): no retry, no S3 hop")
        }
    }

    /// Any other non-2xx from the API hop: `.http` with the raw body, one
    /// request, no retry, no S3 hop.
    func testOtherApiFailuresThrowHttpWithTheRawBodyAndNoRetry() async throws {
        // #1410 named the 400; API Gateway's own 502 and a plain 503 use
        // `message`; an empty 500 falls back to the status code.
        let cases: [Int: (body: String, copy: String)] = [
            400: (#"{"status": "Invalid input: missing required parameter(s): folder"}"#,
                  "Invalid input: missing required parameter(s): folder."),
            502: (#"{"message": "Internal server error"}"#, "Internal server error."),
            503: (#"{"message": "Service Unavailable"}"#, "Service Unavailable."),
            500: ("", "The server couldn't complete that request (500)."),
        ]
        for (status, expected) in cases.sorted(by: { $0.key < $1.key }) {
            let harness = FetchBodyHarness(api: [.json(status, expected.body)])
            let error = await harness.fetchError()
            XCTAssertEqual(error as? CabalmailError, .http(status: status, body: expected.body), "\(status)")
            XCTAssertEqual(error?.localizedDescription, expected.copy, "\(status)")
            let hops = await harness.wire.hops
            XCTAssertEqual(hops, ["api"], "\(status)")
        }
    }

    /// A 200 the client can't parse is `.decoding` naming the endpoint, and
    /// the reader says "Couldn't read the server's reply." (#1805). Before,
    /// `fetchMessage` decoded with a bare `JSONDecoder`, so `Swift.DecodingError`
    /// escaped the package and the reader showed Foundation's "The data
    /// couldn't be read because it isn't in the correct format." Every other
    /// endpoint's unparseable 200 is covered by `ApiClientDecodeFailureTests`.
    func testUnparseable200ThrowsDecodingNamingTheEndpointWithoutTheS3Hop() async throws {
        let bodies = [
            "<html><body>Bad Gateway</body></html>",
            "",
            "[]",
            #"{"message_raw": 42}"#,
        ]
        for body in bodies {
            let harness = FetchBodyHarness(api: [.json(200, body)])
            let error = await harness.fetchError()
            XCTAssertFalse(error is DecodingError, "\(body): got \(String(describing: error))")
            XCTAssertEqual(error as? CabalmailError, .decoding("fetch_message returned an unexpected reply"), body)
            XCTAssertEqual(
                error?.localizedDescription,
                "Couldn't read the server's reply. fetch_message returned an unexpected reply.",
                body
            )
            let hops = await harness.wire.hops
            XCTAssertEqual(hops, ["api"], body)
        }
    }

    /// The presigned GET bypasses `send`: a non-2xx is `.http` with the raw
    /// body whatever the status. A presigned URL carries its own signature,
    /// so even a 401 from it triggers no token refresh and no replay, and
    /// S3's 503 SlowDown is not retried.
    func testPresignedFailuresThrowHttpWithoutRefreshOrRetry() async throws {
        let accessDenied = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            + "<Error><Code>AccessDenied</Code><Message>Access Denied</Message><RequestId>R1</RequestId></Error>"
        let slowDown = "<Error><Code>SlowDown</Code><Message>Please reduce your request rate.</Message></Error>"
        let cases: [(status: Int, body: String)] = [(403, accessDenied), (401, "Unauthorized"), (503, slowDown)]
        for (status, body) in cases {
            let auth = StubAuthService()
            let harness = FetchBodyHarness(
                api: [.json(200, FetchBodyFixture.lambdaBody())],
                presigned: .json(status, body),
                auth: auth
            )
            let error = await harness.fetchError()
            XCTAssertEqual(error as? CabalmailError, .http(status: status, body: body), "\(status)")
            XCTAssertEqual(error?.localizedDescription, "The server couldn't complete that request (\(status)).",
                           "\(status)")
            let hops = await harness.wire.hops
            XCTAssertEqual(hops, ["api", "s3"], "\(status)")
            let refreshes = await auth.forcedRefreshCount
            XCTAssertEqual(refreshes, 0, "\(status)")
        }
    }

    func testTransportErrorsPassThroughUnchanged() async throws {
        let offline = CabalmailError.network("The Internet connection appears to be offline.")

        let s3Offline = FetchBodyHarness(api: [.json(200, FetchBodyFixture.lambdaBody())], presigned: .fail(offline))
        let s3Error = await s3Offline.fetchError()
        XCTAssertEqual(s3Error as? CabalmailError, offline)
        let s3Hops = await s3Offline.wire.hops
        XCTAssertEqual(s3Hops, ["api", "s3"])

        let foreign = FetchBodyUnroutedRequest(url: "not a CabalmailError")
        let s3Foreign = FetchBodyHarness(api: [.json(200, FetchBodyFixture.lambdaBody())], presigned: .fail(foreign))
        let foreignError = await s3Foreign.fetchError()
        XCTAssertEqual(foreignError as? FetchBodyUnroutedRequest, foreign, "a non-Cabalmail error is not wrapped")

        let apiOffline = FetchBodyHarness(api: [.fail(offline)])
        let apiError = await apiOffline.fetchError()
        XCTAssertEqual(apiError as? CabalmailError, offline)
        let apiHops = await apiOffline.wire.hops
        XCTAssertEqual(apiHops, ["api"], "no retry at this layer and no S3 hop")
    }
}

/// The token half of the fetch-body failures (#1703): the API hop's one-shot
/// 401 refresh and replay, the once-only expiry announcement, and the paths
/// where no token is to be had. The S3 hop never takes part in any of it.
final class ApiBackedImapClientFetchBodyAuthTests: XCTestCase {
    /// A 401 the refresh cures stays silent: the API hop is replayed once
    /// with the refreshed token, and the S3 hop still carries none.
    func testOne401RefreshesReplaysWithTheNewTokenAndStaysSilent() async throws {
        let auth = RotatingAuthService()
        let harness = FetchBodyHarness(
            api: [.json(401, #"{"message": "Unauthorized"}"#), .json(200, FetchBodyFixture.lambdaBody())],
            auth: auth
        )
        let expiries = harness.monitor.events()

        let message = try await harness.fetch()

        XCTAssertEqual(message.bytes, FetchBodyFixture.rawMessage)
        let hops = await harness.wire.hops
        XCTAssertEqual(hops, ["api", "api", "s3"])
        let requests = await harness.wire.requests
        guard requests.count == 3 else {
            return XCTFail("expected the first attempt, the replay and the S3 GET; got \(hops)")
        }
        XCTAssertEqual(requests[0].url, requests[1].url, "the replay is the same request")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "idtoken-before")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "idtoken-after")
        XCTAssertNil(requests[2].value(forHTTPHeaderField: "Authorization"))
        let rejected = await auth.rejectedTokens
        XCTAssertEqual(rejected, ["idtoken-before"], "one forced refresh, naming the rejected token")
        let announced = await bufferedCount(expiries)
        XCTAssertEqual(announced, 0, "a cured 401 must not end the session")
    }

    func testSecond401ThrowsAuthExpiredAnnouncesOnceAndSkipsS3() async throws {
        let auth = StubAuthService()
        let unauthorized = #"{"message": "Unauthorized"}"#
        let harness = FetchBodyHarness(api: [.json(401, unauthorized), .json(401, unauthorized)], auth: auth)
        let expiries = harness.monitor.events()

        let error = await harness.fetchError()

        XCTAssertEqual(error as? CabalmailError, .authExpired)
        XCTAssertEqual(error?.localizedDescription, "Your session expired. Sign in again.")
        let hops = await harness.wire.hops
        XCTAssertEqual(hops, ["api", "api"], "no third attempt and no S3 hop")
        let refreshes = await auth.forcedRefreshCount
        XCTAssertEqual(refreshes, 1)
        let announced = await bufferedCount(expiries)
        XCTAssertEqual(announced, 1, "the expiry is announced exactly once")
    }

    /// The replay keeps its own copy of `send`'s non-2xx mapping: after a
    /// cured 401, a 404 is still `.server` with the server's sentence and a
    /// maintenance 503 is still `.maintenance`. No announcement, no S3 hop.
    func testA401ThenANon2xxReplayMapsLikeAFirstAttempt() async throws {
        let unauthorized = FetchBodyReply.json(401, #"{"message": "Unauthorized"}"#)
        let gone = #"{"status": "That message is no longer in Foo", "folder": "Lists.Foo", "id": 7}"#
        let maintenance = #"{"status": "maintenance", "message": "Back in five minutes.", "retry_after": 30}"#
        let cases: [String: (replay: FetchBodyReply, expected: CabalmailError)] = [
            "404": (.json(404, gone), .http(status: 404, body: gone)),
            "maintenance": (.json(503, maintenance), .maintenance(message: "Back in five minutes.")),
        ]
        for (label, scripted) in cases.sorted(by: { $0.key < $1.key }) {
            let (replay, expected) = scripted
            let auth = StubAuthService()
            let harness = FetchBodyHarness(api: [unauthorized, replay], auth: auth)
            let expiries = harness.monitor.events()
            let error = await harness.fetchError()
            XCTAssertEqual(error as? CabalmailError, expected, label)
            let hops = await harness.wire.hops
            XCTAssertEqual(hops, ["api", "api"], label)
            let refreshes = await auth.forcedRefreshCount
            XCTAssertEqual(refreshes, 1, label)
            let announced = await bufferedCount(expiries)
            XCTAssertEqual(announced, 0, "\(label): only a second 401 ends the session")
        }
    }

    func testSignedOutThrowsNotSignedInBeforeAnyRequest() async throws {
        let signedOut = StubAuthService(tokens: nil)
        let harness = FetchBodyHarness(api: [.json(200, FetchBodyFixture.lambdaBody())], auth: signedOut)
        let expiries = harness.monitor.events()

        let error = await harness.fetchError()

        XCTAssertEqual(error as? CabalmailError, .notSignedIn)
        let hops = await harness.wire.hops
        XCTAssertEqual(hops, [], "no token, no request")
        let announced = await bufferedCount(expiries)
        XCTAssertEqual(announced, 0, "URLSessionApiClient announces nothing for a missing token")
    }

    /// A refresh that itself fails after the first 401 passes its error
    /// through: no replay, no S3 hop, and no announcement from this layer.
    func testRefreshFailureAfterA401PassesThroughWithoutReplayOrAnnouncement() async throws {
        let offline = CabalmailError.network("The Internet connection appears to be offline.")
        let auth = RotatingAuthService(refreshFailure: offline)
        let harness = FetchBodyHarness(
            api: [.json(401, #"{"message": "Unauthorized"}"#), .json(200, FetchBodyFixture.lambdaBody())],
            auth: auth
        )
        let expiries = harness.monitor.events()

        let error = await harness.fetchError()

        XCTAssertEqual(error as? CabalmailError, offline)
        let hops = await harness.wire.hops
        XCTAssertEqual(hops, ["api"])
        let rejected = await auth.rejectedTokens
        XCTAssertEqual(rejected, ["idtoken-before"])
        let announced = await bufferedCount(expiries)
        XCTAssertEqual(announced, 0)
    }
}

// MARK: - Auth doubles

/// Auth double whose refresh hands back a different token, so the replay's
/// header is told apart from the first attempt's; records each rejected
/// token. With `refreshFailure` the refresh throws that error instead.
private actor RotatingAuthService: AuthService {
    private var token = "idtoken-before"
    private let refreshFailure: CabalmailError?
    private(set) var rejectedTokens: [String?] = []

    init(refreshFailure: CabalmailError? = nil) {
        self.refreshFailure = refreshFailure
    }

    func currentIdToken() async throws -> String { token }

    func refreshIdToken(replacing rejected: String?) async throws -> String {
        rejectedTokens.append(rejected)
        if let refreshFailure { throw refreshFailure }
        token = "idtoken-after"
        return token
    }

    func currentTokens() async -> AuthTokens? { nil }
    func signIn(username: String, password: String) async throws -> SignInResult { .signedIn }
    func submitMfaCode(_ code: String) async throws {}
    func totpEnabled() async throws -> Bool { false }
    func beginTotpEnrollment() async throws -> String { "ROTATINGSECRET" }
    func confirmTotpEnrollment(code: String) async throws {}
    func disableTotp() async throws {}
    func signUp(username: String, password: String, email: String?, phone: String?) async throws {}
    func confirmSignUp(username: String, code: String) async throws {}
    func resendConfirmationCode(username: String) async throws {}
    func forgotPassword(username: String) async throws {}
    func confirmForgotPassword(username: String, code: String, newPassword: String) async throws {}
    func signOut() async throws {}
}
