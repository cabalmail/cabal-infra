import XCTest
@testable import CabalmailKit

/// Wire-level tests for the `/get_nav_state` / `/set_nav_state` pair backing
/// the cross-client navigation cursor (last folder/message/scroll). The server
/// stamps `updated_at` and stores `client_id`, so the client sends everything
/// except `updated_at` and reads the full row back.
final class ApiClientNavStateTests: XCTestCase {
    private func makeConfiguration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
        )
    }

    private func makeClient(_ http: RecordingHTTPTransport) -> URLSessionApiClient {
        URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
    }

    func testLoadNavStateDecodesCursor() async throws {
        // Real wire shape from `lambda/api/set_nav_state/function.py`.
        let body = """
        {"folder":"Lists.Cabal","message_id":"<abc@x>","uid":4123,\
        "uid_validity":1690000000,"list_scroll":320,"msg_scroll":0,\
        "msg_anchor":"i2.0.5|-12",\
        "client_id":"other-install","updated_at":1719600000000}
        """
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let cursor = try await makeClient(http).loadNavState()
        XCTAssertEqual(cursor?.folder, "Lists.Cabal")
        XCTAssertEqual(cursor?.messageID, "<abc@x>")
        XCTAssertEqual(cursor?.uid, 4123)
        XCTAssertEqual(cursor?.uidValidity, 1_690_000_000)
        XCTAssertEqual(cursor?.listScroll, 320)
        XCTAssertEqual(cursor?.messageScroll, 0)
        XCTAssertEqual(cursor?.messageAnchor, "i2.0.5|-12")
        XCTAssertEqual(cursor?.clientID, "other-install")
        XCTAssertEqual(cursor?.updatedAt, 1_719_600_000_000)

        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertTrue(requests[0].url!.absoluteString.contains("/get_nav_state"))
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "idtoken")
    }

    func testLoadNavStateNilWhenNoCursorSaved() async throws {
        // No cursor yet: the Lambda returns `{}`, which must read as nil, not
        // an error.
        let http = RecordingHTTPTransport(responses: [(Data("{}".utf8), 200)])
        let cursor = try await makeClient(http).loadNavState()
        XCTAssertNil(cursor)
    }

    func testSaveNavStatePutsBodyWithoutUpdatedAt() async throws {
        let http = RecordingHTTPTransport(responses: [(Data("{}".utf8), 200)])
        let client = makeClient(http)
        let state = NavState(
            folder: "INBOX",
            messageID: "<m@x>",
            uid: 99,
            listScroll: 12,
            messageAnchor: "i3.1|40",
            clientID: "this-install",
            updatedAt: 1   // must be dropped from the body; server stamps it
        )
        try await client.saveNavState(state)

        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "PUT")
        XCTAssertTrue(requests[0].url!.absoluteString.contains("/set_nav_state"))
        let payload = try JSONSerialization.jsonObject(
            with: requests[0].httpBody ?? Data()
        ) as? [String: Any]
        XCTAssertEqual(payload?["folder"] as? String, "INBOX")
        XCTAssertEqual(payload?["message_id"] as? String, "<m@x>")
        XCTAssertEqual(payload?["uid"] as? Int, 99)
        XCTAssertEqual(payload?["list_scroll"] as? Int, 12)
        XCTAssertEqual(payload?["msg_anchor"] as? String, "i3.1|40")
        XCTAssertEqual(payload?["client_id"] as? String, "this-install")
        // The client never sends recency; the server owns updated_at.
        XCTAssertNil(payload?["updated_at"])
        // Unset optionals are omitted entirely (no null clutter on the row).
        XCTAssertNil(payload?["uid_validity"])
        XCTAssertNil(payload?["msg_scroll"])
    }
}

/// Unit tests for the `NavState` value type and the install identifier — no
/// network involved.
final class NavStateModelTests: XCTestCase {
    func testIsForeignDistinguishesOrigin() {
        let cursor = NavState(folder: "INBOX", clientID: "A")
        XCTAssertTrue(cursor.isForeign(to: "B"))
        XCTAssertFalse(cursor.isForeign(to: "A"))
        // An unknown origin is never offered back (can't prove it's foreign).
        let unknown = NavState(folder: "INBOX", clientID: "")
        XCTAssertFalse(unknown.isForeign(to: "B"))
    }

    func testInstallIdentityIsStableAcrossCalls() {
        let defaults = UserDefaults(suiteName: "nav-state-install-id-test")!
        defaults.removeObject(forKey: InstallIdentity.defaultsKey)
        let first = InstallIdentity.clientID(defaults: defaults)
        let second = InstallIdentity.clientID(defaults: defaults)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
        defaults.removeObject(forKey: InstallIdentity.defaultsKey)
    }
}
