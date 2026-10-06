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

    /// #1889: a lookup that fails (offline, say) is not an answer. It reads
    /// as no logo for now, and the next lookup asks again; the answer that
    /// lookup gets is then cached as usual.
    func testFailedLookupIsRetriedAndItsAnswerThenCached() async {
        let cache = BimiUrlCache()
        let counter = FetchCounter()
        let fetch: @Sendable (String) async throws -> URL? = { domain in
            await counter.bump()
            if await counter.count == 1 { throw URLError(.notConnectedToInternet) }
            return URL(string: "https://example.com/\(domain).svg")
        }

        let offline = await cache.url(forDomain: "bimi.example", fetch: fetch)
        let online = await cache.url(forDomain: "bimi.example", fetch: fetch)
        let cached = await cache.url(forDomain: "bimi.example", fetch: fetch)

        XCTAssertNil(offline, "a failed lookup shows no logo")
        XCTAssertEqual(online, URL(string: "https://example.com/bimi.example.svg"), "the next lookup asks again")
        XCTAssertEqual(cached, online)
        let calls = await counter.count
        XCTAssertEqual(calls, 2, "the failure left no entry; the answer that followed did")
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
}
