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
        XCTAssertEqual(calls, 1, "a nil (no-BIMI / failed) result is cached, not re-fetched")
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
