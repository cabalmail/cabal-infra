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

    // MARK: - Synced settings (cross-device settings sync)

    private func settingsClient(_ responses: [(Data, Int)]) -> (URLSessionApiClient, RecordingHTTPTransport) {
        let http = RecordingHTTPTransport(responses: responses)
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        return (client, http)
    }

    func testFetchSyncedSettingsDecodesTheAppMapAndTheVersion() async throws {
        // get_preferences returns the whole row; the Apple client reads only
        // the namespaced `app` sub-object and the row's version.
        let body = #"""
        {"theme":"light","accent":"forest","density":"compact","name":"Chris","version":7,\#
        "app":{"theme":"dark","dispose_action":"trash","signature":"Cheers"}}
        """#
        let (client, http) = settingsClient([(Data(body.utf8), 200)])
        let row = try await client.fetchSyncedSettings()
        XCTAssertEqual(row, SyncedSettingsRow(
            app: ["theme": "dark", "dispose_action": "trash", "signature": "Cheers"], version: 7
        ))
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertTrue(requests[0].url!.absoluteString.contains("/get_preferences"))
    }

    func testFetchSyncedSettingsIsEmptyAndUnversionedWhenAbsent() async throws {
        // A user who has only ever used the web client has no `app` key, and
        // a server that predates the version answers none; neither is an
        // error.
        let body = #"{"theme":"light","accent":"forest","density":"compact"}"#
        let (client, _) = settingsClient([(Data(body.utf8), 200)])
        let row = try await client.fetchSyncedSettings()
        XCTAssertEqual(row, SyncedSettingsRow(app: [:], version: nil))
    }

    /// A reply that does not decode is a failed pull. Read as an empty row
    /// (as it was before), it would make every value this device holds
    /// look like one only this device holds, and the next push would send
    /// them all.
    func testFetchSyncedSettingsThrowsOnAReplyItCannotRead() async throws {
        let (client, _) = settingsClient([(Data(#"{"app":{"theme":7}}"#.utf8), 200)])
        do {
            _ = try await client.fetchSyncedSettings()
            XCTFail("an unreadable row must not read as an empty one")
        } catch CabalmailError.decoding {
            // Expected.
        }
    }

    func testSaveSyncedSettingsWrapsInAppEnvelopeAndNamesTheVersion() async throws {
        let (client, http) = settingsClient([(Data(#"{"app":{"theme":"dark"},"version":8}"#.utf8), 200)])
        let result = try await client.saveSyncedSettings(
            ["theme": "dark", "dispose_action": "trash"], expectedVersion: 7
        )
        XCTAssertEqual(result, .saved(version: 8))
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "PUT")
        XCTAssertTrue(requests[0].url!.absoluteString.contains("/set_preferences"))
        let payload = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? [String: Any]
        // The body must carry only the `app` envelope and the version -
        // set_preferences merges per top-level key, so this must not disturb
        // `name` or the web client's theme/accent/density.
        XCTAssertEqual(payload.map { Set($0.keys) }, ["app", "expectedVersion"])
        XCTAssertEqual(payload?["expectedVersion"] as? Int, 7)
        let app = payload?["app"] as? [String: Any]
        XCTAssertEqual(app?["theme"] as? String, "dark")
        XCTAssertEqual(app?["dispose_action"] as? String, "trash")
    }

    /// Against a server that predates the version the client has none to
    /// name, and the answer carries none.
    func testSaveSyncedSettingsWithoutAVersionSendsNone() async throws {
        let (client, http) = settingsClient([(Data(#"{"app":{"theme":"dark"}}"#.utf8), 200)])
        let result = try await client.saveSyncedSettings(["theme": "dark"], expectedVersion: nil)
        XCTAssertEqual(result, .saved(version: nil))
        let requests = await http.requests
        let payload = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(payload.map { Set($0.keys) }, ["app"])
    }

    /// The 409: nothing was written, and the body is the row as it is.
    func testSaveSyncedSettingsAnswersTheRowWhenItHasMovedOn() async throws {
        let body = #"""
        {"Error":"Preferences changed on another device; merge and send again.","theme":"light",\#
        "accent":"forest","density":"compact","name":"","version":9,"app":{"signature":"Theirs"}}
        """#
        let (client, _) = settingsClient([(Data(body.utf8), 409)])
        let result = try await client.saveSyncedSettings(["theme": "dark"], expectedVersion: 7)
        XCTAssertEqual(result, .stale(SyncedSettingsRow(app: ["signature": "Theirs"], version: 9)))
    }

    /// Any other refusal is still an error for the caller to tell apart.
    func testSaveSyncedSettingsThrowsTheServersRefusal() async throws {
        let (client, _) = settingsClient([(Data(#"{"Error":"Invalid value for app."}"#.utf8), 400)])
        do {
            _ = try await client.saveSyncedSettings(["signature": "x"], expectedVersion: 7)
            XCTFail("a 400 is not a result")
        } catch CabalmailError.http(status: 400, _) {
            // Expected.
        }
    }
}
