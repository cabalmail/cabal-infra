import XCTest
@testable import CabalmailKit

final class BimiUrlCacheTests: XCTestCase {
    /// Counts how many times the underlying fetch is actually invoked, so a
    /// test can assert the cache collapses repeats.
    private actor FetchCounter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    func testSecondLookupReusesCachedValueWithoutRefetching() async {
        let cache = BimiUrlCache()
        let counter = FetchCounter()
        let fetch: @Sendable (String) async -> URL? = { domain in
            await counter.bump()
            return URL(string: "https://example.com/\(domain).svg")
        }

        let first = await cache.url(forDomain: "Example.COM", fetch: fetch)
        let second = await cache.url(forDomain: "example.com", fetch: fetch)

        XCTAssertEqual(first, URL(string: "https://example.com/example.com.svg"))
        XCTAssertEqual(second, first, "case-folded domain hits the same entry")
        let calls = await counter.count
        XCTAssertEqual(calls, 1, "fetch runs once; the second lookup is served from cache")
    }

    func testMissIsCached() async {
        let cache = BimiUrlCache()
        let counter = FetchCounter()
        let fetch: @Sendable (String) async -> URL? = { _ in
            await counter.bump()
            return nil
        }

        let first = await cache.url(forDomain: "no-bimi.example", fetch: fetch)
        let second = await cache.url(forDomain: "no-bimi.example", fetch: fetch)

        XCTAssertNil(first)
        XCTAssertNil(second)
        let calls = await counter.count
        XCTAssertEqual(calls, 1, "a definite nil (no BIMI record) is cached, not re-fetched")
    }

    /// #1889: a lookup that never got an answer (offline, here) shows no
    /// logo for now and is asked again next time; the answer that lookup
    /// gets is then cached as usual. Driven through the real API client, so
    /// the error is the one `/fetch_bimi` throws, not a stand-in.
    func testAnOfflineLookupIsAskedAgainAndItsAnswerThenCached() async {
        let transport = BimiTransport([.fail(CabalmailError.network("offline")), .respond(200, Self.logoBody)])
        let cache = BimiUrlCache()
        let client = makeClient(transport)

        let offline = await cache.url(forDomain: "bimi.example", using: client)
        let online = await cache.url(forDomain: "bimi.example", using: client)
        let cached = await cache.url(forDomain: "bimi.example", using: client)

        XCTAssertNil(offline, "a failed lookup shows no logo")
        XCTAssertEqual(online, Self.logoURL, "the next lookup asks again")
        XCTAssertEqual(cached, Self.logoURL)
        let requests = await transport.requests
        XCTAssertEqual(requests, 2, "the failure left no entry; the answer that followed did")
    }

    /// Statuses the gateway or Lambda answer with when something went wrong
    /// on the way, rather than about the domain: none is cached.
    func testAFailedStatusIsAskedAgain() async {
        for status in [403, 429, 500, 502, 503] {
            let transport = BimiTransport([.respond(status, "{}"), .respond(200, Self.logoBody)])
            let cache = BimiUrlCache()
            let client = makeClient(transport)

            let failed = await cache.url(forDomain: "bimi.example", using: client)
            let retried = await cache.url(forDomain: "bimi.example", using: client)

            XCTAssertNil(failed, "\(status)")
            XCTAssertEqual(retried, Self.logoURL, "\(status) is not an answer")
        }
    }

    /// The endpoint's 400 rejects a sender host that isn't a domain: that
    /// is the sender's answer, so it is cached like a miss.
    func testARejectedDomainIsCachedAsNoLogo() async {
        let transport = BimiTransport([.respond(400, "{}"), .respond(200, Self.logoBody)])
        let cache = BimiUrlCache()
        let client = makeClient(transport)

        let first = await cache.url(forDomain: "localhost", using: client)
        let second = await cache.url(forDomain: "localhost", using: client)

        XCTAssertNil(first)
        XCTAssertNil(second)
        let requests = await transport.requests
        XCTAssertEqual(requests, 1)
    }

    /// `{"url": null}` is the endpoint's "no logo": cached.
    func testANullURLIsCachedAsNoLogo() async {
        let transport = BimiTransport([.respond(200, #"{"url": null}"#), .respond(200, Self.logoBody)])
        let cache = BimiUrlCache()
        let client = makeClient(transport)

        _ = await cache.url(forDomain: "no-bimi.example", using: client)
        let second = await cache.url(forDomain: "no-bimi.example", using: client)

        XCTAssertNil(second)
        let requests = await transport.requests
        XCTAssertEqual(requests, 1)
    }

    /// A failure is forgotten for its own domain only: another domain's
    /// cached answer stays put.
    func testFailedLookupLeavesOtherDomainsCached() async {
        let cache = BimiUrlCache()
        let counter = FetchCounter()
        let fetch: @Sendable (String) async throws -> URL? = { domain in
            await counter.bump()
            if domain == "down.example" { throw URLError(.timedOut) }
            return URL(string: "https://\(domain)/logo.svg")
        }

        _ = await cache.url(forDomain: "up.example", fetch: fetch)
        _ = await cache.url(forDomain: "down.example", fetch: fetch)
        _ = await cache.url(forDomain: "up.example", fetch: fetch)
        _ = await cache.url(forDomain: "down.example", fetch: fetch)

        let calls = await counter.count
        XCTAssertEqual(calls, 3, "up.example once; down.example on each lookup, since it never answered")
    }

    func testDistinctDomainsEachFetchOnce() async {
        let cache = BimiUrlCache()
        let counter = FetchCounter()
        let fetch: @Sendable (String) async -> URL? = { domain in
            await counter.bump()
            return URL(string: "https://\(domain)/logo.svg")
        }

        _ = await cache.url(forDomain: "a.example", fetch: fetch)
        _ = await cache.url(forDomain: "b.example", fetch: fetch)
        _ = await cache.url(forDomain: "a.example", fetch: fetch)

        let calls = await counter.count
        XCTAssertEqual(calls, 2, "one fetch per distinct domain")
    }

    // MARK: - Helpers

    private static let logoURL = URL(string: "https://logos.example/bimi.png")
    private static let logoBody = #"{"url": "https://logos.example/bimi.png"}"#

    private func makeClient(_ transport: BimiTransport) -> URLSessionApiClient {
        URLSessionApiClient(
            configuration: Configuration(
                controlDomain: "cabalmail.example",
                domains: [MailDomain(domain: "cabalmail.example")],
                invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
                cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
            ),
            authService: StubAuthService(),
            transport: transport
        )
    }
}

/// Answers `/fetch_bimi` requests from a script, one step per request, and
/// counts them. A step either throws (the request never got an answer) or
/// responds with a status and body.
private actor BimiTransport: HTTPTransport {
    enum Step: Sendable {
        case fail(CabalmailError)
        case respond(Int, String)
    }

    private var steps: [Step]
    private(set) var requests = 0

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        guard !steps.isEmpty else { throw CabalmailError.transport("BimiTransport: unscripted request") }
        switch steps.removeFirst() {
        case .fail(let error):
            throw error
        case .respond(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }
}
