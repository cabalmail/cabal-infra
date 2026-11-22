import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A window's stored route across builds, now that it can name a smart view
/// (`AppRoute.smartView`): a route stored by a build from before the key
/// still restores, a route this build stores is still read by those builds,
/// and a smart view this build does not know costs the window nothing else.
@MainActor
final class AppRouteSmartViewTests: XCTestCase {
    private static let alice = StoredRoute.Account(controlDomain: "cabalmail.example", username: "alice")

    /// A window's scene storage exactly as release 1.57.0 writes it: a
    /// window in feeds with a message open in the folder beneath.
    private static let storedBy1570 = """
        {"account":{"controlDomain":"cabalmail.example","username":"alice"},\
        "route":{"section":"feeds",\
        "mail":{"folderPath":"Lists","messageUID":7,"messageID":"<seven@example.com>"},\
        "feeds":{"scope":"sub:s","item":{"feedID":"f","sortKey":"k"}}},\
        "wasLastUsed":true}
        """

    /// The route that storage holds.
    private var route: AppRoute {
        var route = AppRoute(section: .feeds)
        route.mail = AppRoute.Mail(
            folderPath: "Lists", message: MessageRef(folder: "Lists", uid: 7, messageId: "<seven@example.com>")
        )
        route.feeds = AppRoute.Feeds(scope: .subscription("s"))
        route.feeds.item = AppRoute.Item(RssItem(feedId: "f", subscriptionId: "s", itemId: "i", sortKey: "k"))
        return route
    }

    /// The stored route's JSON with `smartView` set to `value`.
    private func stored(smartView value: Any) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(Self.storedBy1570.utf8)) as? [String: Any]
        )
        var route = try XCTUnwrap(object["route"] as? [String: Any])
        route["smartView"] = value
        object["route"] = route
        return try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: Routes stored by older builds

    func testARouteStoredByTheLastReleaseStillRestores() throws {
        let stored = try XCTUnwrap(StoredRoute.stored(in: Data(Self.storedBy1570.utf8), for: Self.alice))

        XCTAssertEqual(stored.route, route)
        XCTAssertNil(stored.route.smartView)
        XCTAssertEqual(stored.route.mail.message?.messageId, "<seven@example.com>")
        XCTAssertEqual(stored.wasLastUsed, true)
    }

    /// The control for the lenient read: the keys a route always had are
    /// still required, so a store that is not a route does not come back as
    /// an empty one.
    func testARouteMissingAHalfStillFailsToDecode() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(Self.storedBy1570.utf8)) as? [String: Any]
        )
        var route = try XCTUnwrap(object["route"] as? [String: Any])
        route.removeValue(forKey: "mail")
        object["route"] = route
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertNil(StoredRoute.stored(in: data, for: Self.alice))
    }

    // MARK: Routes this build stores

    /// With no smart view the route is stored key for key as 1.57.0 stores
    /// it, so a window's scene storage is not rewritten by the update and a
    /// build from before the key reads it.
    func testARouteWithNoSmartViewIsStoredAsBefore() throws {
        let data = try JSONEncoder().encode(route)

        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let released = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(Self.storedBy1570.utf8)) as? [String: Any]
        )
        XCTAssertEqual(written, try XCTUnwrap(released["route"] as? NSDictionary))
        XCTAssertNil(written["smartView"])
    }

    /// The route as release 1.57.0 declares it: three keys, compiler-made
    /// coding. What that build makes of a route this one stored.
    private struct ReleasedRoute: Codable, Equatable {
        var section: ResumeSession.Section
        var mail: AppRoute.Mail
        var feeds: AppRoute.Feeds
    }

    func testABuildFromBeforeTheKeyReadsARouteThatNamesASmartView() throws {
        var newer = route
        newer.smartView = .flagged
        let data = try JSONEncoder().encode(newer)
        XCTAssertEqual(
            (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["smartView"] as? String, "flagged"
        )

        let older = try JSONDecoder().decode(ReleasedRoute.self, from: data)

        XCTAssertEqual(older, ReleasedRoute(section: route.section, mail: route.mail, feeds: route.feeds))
    }

    // MARK: The smart view

    func testASmartViewRoundTrips() throws {
        var route = route
        route.smartView = .flagged

        let decoded = try JSONDecoder().decode(AppRoute.self, from: JSONEncoder().encode(route))

        XCTAssertEqual(decoded, route)
        XCTAssertEqual(decoded.smartView, .flagged)
    }

    func testAStoredSmartViewIsRead() throws {
        let stored = try XCTUnwrap(StoredRoute.stored(in: try stored(smartView: "flagged"), for: Self.alice))

        XCTAssertEqual(stored.route.smartView, .flagged)
        XCTAssertEqual(stored.route.mail, route.mail)
        XCTAssertEqual(stored.route.feeds, route.feeds)
    }

    /// A later build's smart view, by a name or in a shape this build does
    /// not know, reads as none. The window keeps its folder, its open
    /// message and its feed list rather than losing the whole route.
    func testASmartViewThisBuildDoesNotKnowCostsNothingElse() throws {
        for unknown in ["someLaterView", ["kind": "flag", "slot": 3], 7, NSNull()] as [Any] {
            let stored = try XCTUnwrap(
                StoredRoute.stored(in: try stored(smartView: unknown), for: Self.alice), "\(unknown)"
            )
            XCTAssertNil(stored.route.smartView, "\(unknown)")
            XCTAssertEqual(stored.route, route, "\(unknown)")
        }
    }

    // MARK: The window

    /// No sidebar offers a smart view yet, so a window given a stored route
    /// that names one opens on the route's own place, and its next store
    /// does not carry the name on.
    func testAWindowOpensAStoredSmartViewOnTheRoutesPlace() async throws {
        let suiteName = "AppRouteSmartViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        let coordinator = NavStateCoordinator(
            client: client, clientID: "this-install", store: ResumeSessionStore(defaults: defaults)
        )
        var stored = AppRoute(section: .mail)
        stored.mail = AppRoute.Mail(folderPath: "Archive")
        stored.smartView = .flagged

        let navigator = SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: .mail, storedRoute: stored,
            feedsLaunchTarget: { _, _ in nil }
        )
        XCTAssertNil(navigator.route.smartView)
        await navigator.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertEqual(navigator.selectedFolder?.path, "Archive")
        XCTAssertEqual(navigator.route.mail.folderPath, "Archive")
        XCTAssertNil(navigator.route.smartView)
    }

    // MARK: The open item

    func testTheOpenItemIsTheSectionsOwn() {
        var route = route
        XCTAssertEqual(route.openItem, .feed(feedID: "f", sortKey: "k"))

        route.section = .mail
        XCTAssertEqual(route.openItem, .mail(MessageRef(folder: "Lists", uid: 7)))

        route.mail.message = nil
        XCTAssertNil(route.openItem)
        route.section = .feeds
        route.feeds.item = nil
        XCTAssertNil(route.openItem)
    }
}
