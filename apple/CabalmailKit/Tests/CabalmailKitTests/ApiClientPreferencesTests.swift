import XCTest
@testable import CabalmailKit

/// Wire-level tests for the `/get_preferences` / `/set_preferences` pair
/// backing the display-name setting. The preference is stored server-side
/// (shared with the React app) and consumed by the `/send` Lambda when it
/// composes the From header, so the client surface is just these two calls.
final class ApiClientPreferencesTests: XCTestCase {
    private func makeConfiguration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
        )
    }

    func testFetchDisplayNameDecodesPreferencesRow() async throws {
        // Real wire shape from `lambda/api/get_preferences/function.py`:
        // the full preferences row; only `name` matters to this client.
        let body = #"{"theme":"light","accent":"forest","density":"compact","name":"Chris Carr"}"#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let name = try await client.fetchDisplayName()
        XCTAssertEqual(name, "Chris Carr")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertTrue(requests[0].url!.absoluteString.contains("/get_preferences"))
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "idtoken")
    }

    func testFetchDisplayNameDefaultsToEmptyWhenAbsent() async throws {
        // An older get_preferences deployment omits the `name` key; that
        // must read as "no display name", not an error.
        let body = #"{"theme":"light","accent":"forest","density":"compact"}"#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let name = try await client.fetchDisplayName()
        XCTAssertEqual(name, "")
    }

    func testUpdateDisplayNamePutsPartialBody() async throws {
        let http = RecordingHTTPTransport(responses: [(Data(#"{"name":"Chris Carr"}"#.utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        try await client.updateDisplayName("Chris Carr")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "PUT")
        XCTAssertTrue(requests[0].url!.absoluteString.contains("/set_preferences"))
        let payload = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? [String: Any]
        // The body must carry only `name` - set_preferences merges per-key,
        // and a fuller payload would stomp the web client's theme settings.
        XCTAssertEqual(payload?.count, 1)
        XCTAssertEqual(payload?["name"] as? String, "Chris Carr")
    }

    // MARK: - App preferences (cross-device settings sync)

    func testFetchAppPreferencesDecodesAppMap() async throws {
        // get_preferences returns the whole row; the Apple client reads only
        // the namespaced `app` sub-object.
        let body = #"""
        {"theme":"light","accent":"forest","density":"compact","name":"Chris",\#
        "app":{"theme":"dark","dispose_action":"trash","signature":"Cheers"}}
        """#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let prefs = try await client.fetchAppPreferences()
        XCTAssertEqual(prefs["theme"], "dark")
        XCTAssertEqual(prefs["dispose_action"], "trash")
        XCTAssertEqual(prefs["signature"], "Cheers")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertTrue(requests[0].url!.absoluteString.contains("/get_preferences"))
    }

    func testFetchAppPreferencesEmptyWhenAbsent() async throws {
        // A user who has only ever used the web client (or an older Lambda)
        // has no `app` key; that must read as "none saved", not an error.
        let body = #"{"theme":"light","accent":"forest","density":"compact"}"#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let prefs = try await client.fetchAppPreferences()
        XCTAssertTrue(prefs.isEmpty)
    }

    func testSaveAppPreferencesWrapsInAppEnvelope() async throws {
        let http = RecordingHTTPTransport(responses: [(Data(#"{"app":{"theme":"dark"}}"#.utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        try await client.saveAppPreferences(["theme": "dark", "dispose_action": "trash"])
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "PUT")
        XCTAssertTrue(requests[0].url!.absoluteString.contains("/set_preferences"))
        let payload = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? [String: Any]
        // The body must carry only the `app` envelope - set_preferences merges
        // per top-level key, so this must not disturb `name` or the web
        // client's theme/accent/density.
        XCTAssertEqual(payload?.count, 1)
        let app = payload?["app"] as? [String: Any]
        XCTAssertEqual(app?["theme"] as? String, "dark")
        XCTAssertEqual(app?["dispose_action"] as? String, "trash")
    }
}
