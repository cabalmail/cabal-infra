import XCTest
@testable import CabalmailKit

/// Characterization suite for workstream 0.8, the safety net taken before the
/// Apple client's rearchitecture: `ApiBackedImapClient.fetchBody`, the
/// production "open a message" wire path, driven end to end through
/// `URLSessionApiClient.fetchMessage` and `fetchPresignedData`.
///
/// Since #371 (73711325) a message opens in two hops: an authenticated
/// `GET /fetch_message` answering with a presigned S3 URL, then a bare GET of
/// that URL for the raw RFC 822 bytes. These pin the hop order and headers,
/// the missing-URL error, and that `ApiBackedImapClient` itself neither caches
/// nor de-duplicates body fetches. The body cache is `CabalmailClient.bodyCache`,
/// consulted above this layer by `MessageDetailViewModel.fetchBodyBytes` and
/// `MessageDrag`, and nothing here forbids it. Reply shapes follow
/// `lambda/api/fetch_message/function.py` and `lambda/api/_shared/helper.py`.
/// Where today's behaviour looks wrong the test says so and pins it anyway.
/// The failure paths (#940 message-gone, the c3037380 maintenance contract,
/// the #1703 silent refresh and once-only expiry) live in
/// `ApiBackedImapClientFetchBodyFailureTests.swift`, which shares the
/// harness at the bottom of this file.
final class ApiBackedImapClientFetchBodyTests: XCTestCase {
    func testOpeningAMessageIsAnAuthenticatedApiGetThenABarePresignedGet() async throws {
        let auth = StubAuthService()
        let harness = FetchBodyHarness(api: [.json(200, FetchBodyFixture.lambdaBody())], auth: auth)

        let message = try await harness.fetch()

        XCTAssertEqual(message.uid, FetchBodyFixture.uid)
        XCTAssertEqual(message.bytes, FetchBodyFixture.rawMessage, "bytes must arrive untranscoded")
        XCTAssertEqual(message.flags, [], "/fetch_message carries no flags, so the Kit reports none")

        let requests = await harness.wire.requests
        XCTAssertEqual(requests.count, 2)
        let api = try XCTUnwrap(requests.first)
        XCTAssertEqual(api.httpMethod, "GET")
        XCTAssertNil(api.httpBody)
        XCTAssertEqual(api.value(forHTTPHeaderField: "Authorization"), "idtoken")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(api.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "api.cabalmail.example")
        XCTAssertEqual(components.path, "/prod/fetch_message")
        // The nested folder travels slash-delimited; the Lambda dots it
        // itself. `seen` is always false on the wire. The Lambda ignores it
        // (it opens the folder read-only, or answers from its S3 cache), and
        // mark-as-read is a separate /set_flag call.
        XCTAssertEqual(components.queryItems, [
            URLQueryItem(name: "host", value: "imap.example.com"),
            URLQueryItem(name: "folder", value: "Lists/Foo"),
            URLQueryItem(name: "id", value: "7"),
            URLQueryItem(name: "seen", value: "false"),
        ])
        XCTAssertEqual(
            components.percentEncodedQuery, "host=imap.example.com&folder=Lists/Foo&id=7&seen=false",
            "encoding-level pin: a semantically equal re-encoding (\"/\" as %2F) fails here deliberately"
        )

        let presigned = try XCTUnwrap(requests.dropFirst().first, "no S3 hop")
        XCTAssertEqual(presigned.httpMethod, "GET")
        XCTAssertEqual(presigned.url?.absoluteString, FetchBodyFixture.presignedURL,
                       "the presigned URL is followed exactly as the Lambda signed it")
        XCTAssertNil(presigned.value(forHTTPHeaderField: "Authorization"), "the S3 GET carries no token")
        XCTAssertTrue((presigned.allHTTPHeaderFields ?? [:]).isEmpty,
                      "shape-level pin: today the S3 GET carries no header at all, so even a harmless one fails here")
        XCTAssertNil(presigned.httpBody)

        let tokenReads = await auth.idTokenCallCount
        let refreshes = await auth.forcedRefreshCount
        XCTAssertEqual(tokenReads, 1, "only the API hop reads a token")
        XCTAssertEqual(refreshes, 0)
    }

    /// The full 200 the Lambda sends: decoded plain/HTML bodies, the
    /// recipient, and the threading headers as `get_all` lists (or null).
    /// `fetchMessage` decodes all of it; `fetchBody` uses only `message_raw`.
    func testLambdaShaped200DecodesEveryFieldButFetchBodyFollowsOnlyMessageRaw() async throws {
        let body = FetchBodyFixture.lambdaBody()
        let harness = FetchBodyHarness(api: [.json(200, body), .json(200, body)])

        let decoded = try await harness.api.fetchMessage(host: FetchBodyFixture.host, folder: FetchBodyFixture.folder,
                                                         id: FetchBodyFixture.uid, markSeen: false)
        XCTAssertEqual(decoded.messageRaw, FetchBodyFixture.presignedURL)
        XCTAssertEqual(decoded.messageBodyPlain, "Decoded plain body\r\n")
        XCTAssertEqual(decoded.messageBodyHtml, "")
        XCTAssertEqual(decoded.recipient, "alice@mail.cabalmail.example")
        XCTAssertEqual(decoded.messageId, ["<m1@example.com>"])
        XCTAssertNil(decoded.inReplyTo, "a JSON null list decodes as nil")
        XCTAssertEqual(decoded.references, ["<r1@example.com>", "<r2@example.com>"])

        let message = try await harness.fetch()
        XCTAssertEqual(message.bytes, FetchBodyFixture.rawMessage,
                       "the raw message is fetched; the convenience bodies are never used in its place")
        let hops = await harness.wire.hops
        XCTAssertEqual(hops, ["api", "api", "s3"])
    }

    func testMissingPresignedURLThrowsDecodingErrorAfterOneRequest() async throws {
        let cases: [(label: String, body: String)] = [
            ("null", FetchBodyFixture.lambdaBody(messageRawToken: "null")),
            ("absent", #"{"message_body_plain": "x", "recipient": ""}"#),
            ("empty string", FetchBodyFixture.lambdaBody(messageRawToken: #""""#)),
        ]
        for (label, body) in cases {
            let harness = FetchBodyHarness(api: [.json(200, body)])
            let error = await harness.fetchError()
            XCTAssertEqual(error as? CabalmailError, .decoding("fetch_message returned no presigned URL"), label)
            XCTAssertEqual(
                error?.localizedDescription,
                "Couldn't read the server's reply. fetch_message returned no presigned URL.",
                label
            )
            let hops = await harness.wire.hops
            XCTAssertEqual(hops, ["api"], "\(label): no S3 hop without a URL")
        }
    }

    /// When S3 signing fails, `sign_url` answers the literal string "Error"
    /// in `message_raw`. It reads as no presigned URL: one request, the
    /// missing-URL copy, and no second GET (#1804). Before, `URL(string:
    /// "Error")` parsed as a relative URL and the Kit followed it with a
    /// host-less GET, which `URLSessionHTTPTransport` refused as
    /// `unsupportedURL`, so the reader said "Couldn't reach the server.
    /// unsupported URL." for a server-side signing failure. Scheme-less,
    /// host-less and non-HTTP strings read the same way.
    func testSignFailureMarkerReadsAsAMissingURLWithoutASecondRequest() async throws {
        for token in [#""Error""#, #""/relative/path""#, #""https:///no-host""#, #""ftp://s3.example/raw""#] {
            let harness = FetchBodyHarness(api: [.json(200, FetchBodyFixture.lambdaBody(messageRawToken: token))])

            let error = await harness.fetchError()

            XCTAssertEqual(error as? CabalmailError, .decoding("fetch_message returned no presigned URL"), token)
            XCTAssertEqual(
                error?.localizedDescription,
                "Couldn't read the server's reply. fetch_message returned no presigned URL.",
                token
            )
            let requests = await harness.wire.requests
            XCTAssertEqual(requests.count, 1, "\(token): no second GET")
        }
    }

    func testSequentialFetchesRepeatBothHopsBelowTheBodyCache() async throws {
        let body = FetchBodyFixture.lambdaBody()
        let harness = FetchBodyHarness(api: [.json(200, body), .json(200, body)])

        let first = try await harness.fetch()
        let second = try await harness.fetch()

        XCTAssertEqual(first, second)
        let hops = await harness.wire.hops
        XCTAssertEqual(hops, ["api", "s3", "api", "s3"], "ApiBackedImapClient sends the second open back to the wire")
    }

    /// The first open's API reply is held, so the second open provably
    /// starts while the first is in flight. Today the second makes its own
    /// round trip and finishes under the hold. A client that parked the
    /// second open on the first's request (de-duplication) or behind it
    /// (serialization) never sends the second API hop, so the wait fails at
    /// its ceiling instead of passing on scheduling luck.
    func testConcurrentFetchesOfOneMessageAreNotDeduplicated() async throws {
        let body = FetchBodyFixture.lambdaBody()
        let harness = FetchBodyHarness(api: [.json(200, body), .json(200, body)], holdFirstApiReply: true)

        let first = Task { try await harness.fetch() }
        try await waitUntil { await harness.wire.isHoldingApiReply }
        let second = Task { try await harness.fetch() }
        try await waitUntil { await harness.wire.hops == ["api", "api", "s3"] }
        let underTheHold = await harness.wire.hops
        await harness.wire.releaseHeldApiReply()
        let one = try await first.value
        let two = try await second.value

        XCTAssertEqual(underTheHold, ["api", "api", "s3"], "the second open's round trip runs while the first is held")
        XCTAssertEqual([one.bytes, two.bytes], [FetchBodyFixture.rawMessage, FetchBodyFixture.rawMessage])
        let hops = await harness.wire.hops
        XCTAssertEqual(hops, ["api", "api", "s3", "s3"], "both opens make both hops")
    }
}

// MARK: - Fixture and wire harness (shared with the failure suites)

enum FetchBodyFixture {
    static let host = "imap.example.com"
    static let folder = "Lists/Foo"
    static let uid: UInt32 = 7
    static let presignedHost = "cabal-cache.s3.example"
    /// Shaped like boto3's `generate_presigned_url`, including escapes in
    /// the signature that must survive untouched.
    static let presignedURL = "https://cabal-cache.s3.example/alice/Lists/Foo/7/raw"
        + "?AWSAccessKeyId=AKIAEXAMPLE&Signature=ab%2Bcd%2Fef%3D&Expires=1790000000"
    /// CRLF line ends plus one 8-bit byte (Latin-1 e-acute), so any
    /// transcoding on the path would change the bytes.
    static let rawMessage = Data("From: sender@example.com\r\nSubject: Caf".utf8) + Data([0xE9])
        + Data("\r\nContent-Type: text/plain; charset=iso-8859-1\r\n\r\nBody\r\n".utf8)

    /// A `/fetch_message` 200 as `function.py` builds it. `messageRawToken`
    /// is the raw JSON value for `message_raw` (a quoted string or `null`).
    static func lambdaBody(messageRawToken: String = "\"\(presignedURL)\"") -> String {
        """
        {"message_raw": \(messageRawToken), "message_body_plain": "Decoded plain body\\r\\n", \
        "message_body_html": "", "recipient": "alice@mail.cabalmail.example", \
        "message_id": ["<m1@example.com>"], "in_reply_to": null, \
        "references": ["<r1@example.com>", "<r2@example.com>"]}
        """
    }
}

/// One scripted reply for a hop: an HTTP response, or a thrown error.
enum FetchBodyReply: Sendable {
    case respond(status: Int, body: Data)
    case fail(any Error)

    static func json(_ status: Int, _ body: String) -> FetchBodyReply {
        .respond(status: status, body: Data(body.utf8))
    }
}

/// The wire's error for an unrouted request; also a non-`CabalmailError` failure.
struct FetchBodyUnroutedRequest: Error, Equatable {
    let url: String
}

/// Scripted wire for both hops, recording every request in arrival order:
/// `/fetch_message` answers from a FIFO, the presigned host one fixed reply.
/// With `holdFirstApiReply` the first API reply is parked until
/// `releaseHeldApiReply()`; the request is recorded before it parks.
actor FetchBodyWire {
    private(set) var requests: [URLRequest] = []
    private var apiReplies: [FetchBodyReply]
    private let presignedReply: FetchBodyReply
    private var holdNextApiReply: Bool
    private var heldApiReply: CheckedContinuation<Void, Never>?

    init(api: [FetchBodyReply], presigned: FetchBodyReply, holdFirstApiReply: Bool = false) {
        apiReplies = api
        presignedReply = presigned
        holdNextApiReply = holdFirstApiReply
    }

    nonisolated var transport: ScriptedHTTPTransport {
        ScriptedHTTPTransport { request in try await self.perform(request) }
    }

    /// Each request reduced to its hop: "api", "s3", or the URL itself.
    var hops: [String] {
        requests.map { request in
            guard let url = request.url else { return "no URL" }
            if url.path.hasSuffix("/fetch_message") { return "api" }
            return url.host == FetchBodyFixture.presignedHost ? "s3" : url.absoluteString
        }
    }

    /// True while an API reply is parked by the hold.
    var isHoldingApiReply: Bool { heldApiReply != nil }

    /// Lets the parked API reply answer. A request that has not arrived yet
    /// is no longer held either, so a failed wait can never strand one.
    func releaseHeldApiReply() {
        holdNextApiReply = false
        heldApiReply?.resume()
        heldApiReply = nil
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let url = request.url else { throw FetchBodyUnroutedRequest(url: "no URL") }
        let reply: FetchBodyReply
        if url.path.hasSuffix("/fetch_message"), !apiReplies.isEmpty {
            reply = apiReplies.removeFirst()
            if holdNextApiReply {
                holdNextApiReply = false
                await withCheckedContinuation { heldApiReply = $0 }
            }
        } else if url.host == FetchBodyFixture.presignedHost {
            reply = presignedReply
        } else {
            throw FetchBodyUnroutedRequest(url: url.absoluteString)
        }
        switch reply {
        case .respond(let status, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
            guard let response else { throw FetchBodyUnroutedRequest(url: "no response for \(url)") }
            return (body, response)
        case .fail(let error):
            throw error
        }
    }
}

/// `ApiBackedImapClient` over a real `URLSessionApiClient` over the scripted
/// wire, with an expiry monitor attached as the app attaches one.
struct FetchBodyHarness {
    let wire: FetchBodyWire
    let monitor: SessionInvalidationMonitor
    let api: URLSessionApiClient
    let client: ApiBackedImapClient

    init(
        api replies: [FetchBodyReply],
        presigned: FetchBodyReply = .respond(status: 200, body: FetchBodyFixture.rawMessage),
        auth: AuthService = StubAuthService(),
        holdFirstApiReply: Bool = false
    ) {
        let wire = FetchBodyWire(api: replies, presigned: presigned, holdFirstApiReply: holdFirstApiReply)
        let monitor = SessionInvalidationMonitor()
        let api = URLSessionApiClient(
            configuration: TestFixtures.makeConfiguration(),
            authService: auth,
            transport: wire.transport,
            sessionInvalidation: monitor
        )
        self.wire = wire
        self.monitor = monitor
        self.api = api
        self.client = ApiBackedImapClient(api: api, host: FetchBodyFixture.host)
    }

    func fetch() async throws -> RawMessage {
        try await client.fetchBody(folder: FetchBodyFixture.folder, uid: FetchBodyFixture.uid)
    }

    func fetchError() async -> Error? {
        do {
            _ = try await fetch()
            return nil
        } catch {
            return error
        }
    }
}
