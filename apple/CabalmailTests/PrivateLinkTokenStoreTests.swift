import XCTest
@testable import Cabalmail

/// The App Group row table behind the opaque-token form of the
/// private-link handoff (#1765). The container itself is unavailable to
/// the test runner (unsigned bundle, no App Group), which is exactly why
/// the table algebra is pure: expiry, the cap and resolution are the parts
/// that can be wrong, and they are asserted here rather than inferred from
/// a live round-trip.
final class PrivateLinkTokenStoreTests: XCTestCase {
    private let now: TimeInterval = 1_000_000

    /// `UserDefaults(suiteName:)` is not nil in the runner: an unentitled
    /// build gets a plain preferences domain rather than nothing, so the
    /// container path runs for real here (`testRoundTripThroughTheContainer`).
    /// It is shared account state all the same, so whatever the key held
    /// before this suite ran goes back when it is done.
    private var suite: UserDefaults? { UserDefaults(suiteName: PrivateLinkTokenStore.appGroupID) }
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = suite?.object(forKey: PrivateLinkTokenStore.defaultsKey)
        suite?.removeObject(forKey: PrivateLinkTokenStore.defaultsKey)
    }

    override func tearDown() {
        if let saved {
            suite?.set(saved, forKey: PrivateLinkTokenStore.defaultsKey)
        } else {
            suite?.removeObject(forKey: PrivateLinkTokenStore.defaultsKey)
        }
        super.tearDown()
    }

    private func row(_ url: String, minted: TimeInterval) -> [String: Any] {
        [PrivateLinkTokenStore.urlKey: url, PrivateLinkTokenStore.mintedAtKey: minted]
    }

    func testTokenIsThirtyTwoLowerCaseHexCharacters() {
        // The redirector page and the extension both tell a token from a
        // percent-encoded target by this exact shape, so it is a contract
        // with two other files, not an implementation detail.
        for _ in 0..<32 {
            let token = PrivateLinkTokenStore.newToken()
            XCTAssertEqual(token.count, 32, token)
            XCTAssertNotNil(
                token.range(of: "^[0-9a-f]{32}$", options: .regularExpression), token
            )
        }
        XCTAssertNotEqual(
            PrivateLinkTokenStore.newToken(), PrivateLinkTokenStore.newToken()
        )
    }

    func testInsertedRowResolves() {
        let table = PrivateLinkTokenStore.inserting(
            "https://example.com/a", token: "t1", into: [:], now: now
        )
        XCTAssertEqual(
            PrivateLinkTokenStore.resolving("t1", in: table, now: now),
            "https://example.com/a"
        )
        XCTAssertNil(PrivateLinkTokenStore.resolving("t2", in: table, now: now))
    }

    func testRowExpiresAfterTheTTL() {
        let table = PrivateLinkTokenStore.inserting(
            "https://example.com/a", token: "t1", into: [:], now: now
        )
        let justInside = now + PrivateLinkTokenStore.ttl - 1
        XCTAssertNotNil(PrivateLinkTokenStore.resolving("t1", in: table, now: justInside))
        let justOutside = now + PrivateLinkTokenStore.ttl
        XCTAssertNil(PrivateLinkTokenStore.resolving("t1", in: table, now: justOutside))
    }

    func testPruneDropsExpiredAndMalformedRows() {
        let table: PrivateLinkTokenStore.Table = [
            "live": row("https://example.com/live", minted: now),
            "stale": row("https://example.com/stale", minted: now - PrivateLinkTokenStore.ttl),
            // A clock that went backwards, and a row from another writer:
            // neither is resolvable, and neither may be kept.
            "future": row("https://example.com/future", minted: now + 60),
            "junk": ["url": "https://example.com/junk"],
        ]
        XCTAssertEqual(
            Set(PrivateLinkTokenStore.pruned(table, now: now).keys), ["live"]
        )
    }

    func testTableIsCappedAtTheNewestRows() {
        var table: PrivateLinkTokenStore.Table = [:]
        let overflow = PrivateLinkTokenStore.capacity + 3
        for index in 0..<overflow {
            table = PrivateLinkTokenStore.inserting(
                "https://example.com/\(index)",
                token: "t\(index)",
                // One second apart so "newest" is well defined.
                into: table,
                now: now + TimeInterval(index)
            )
        }
        let kept = PrivateLinkTokenStore.pruned(table, now: now + TimeInterval(overflow))
        XCTAssertEqual(kept.count, PrivateLinkTokenStore.capacity)
        XCTAssertNotNil(kept["t\(overflow - 1)"])
        XCTAssertNil(kept["t0"])
    }

    func testResolutionIsNotDestructive() {
        // A failed `windows.create` leaves the redirector tab open, and a
        // reload has to resolve again; the extension's explicit
        // `forget-private-link` is what retires a row.
        let table = PrivateLinkTokenStore.inserting(
            "https://example.com/a", token: "t1", into: [:], now: now
        )
        XCTAssertNotNil(PrivateLinkTokenStore.resolving("t1", in: table, now: now))
        XCTAssertNotNil(PrivateLinkTokenStore.resolving("t1", in: table, now: now))
    }

    func testRoundTripThroughTheContainer() throws {
        let target = URL(string: "https://example.com/a")!
        let token = try XCTUnwrap(PrivateLinkTokenStore.mint(target))
        XCTAssertNotNil(
            token.range(of: "^[0-9a-f]{32}$", options: .regularExpression), token
        )
        XCTAssertEqual(PrivateLinkTokenStore.resolve(token), target.absoluteString)
        // What the extension sends once the private window is up.
        PrivateLinkTokenStore.forget(token)
        XCTAssertNil(PrivateLinkTokenStore.resolve(token))
    }

    func testContainerRowStopsResolvingAfterTheTTL() throws {
        let target = URL(string: "https://example.com/a")!
        let token = try XCTUnwrap(PrivateLinkTokenStore.mint(target, now: now))
        XCTAssertEqual(PrivateLinkTokenStore.resolve(token, now: now), target.absoluteString)
        XCTAssertNil(
            PrivateLinkTokenStore.resolve(token, now: now + PrivateLinkTokenStore.ttl)
        )
    }
}
