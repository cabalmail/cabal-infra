import XCTest
@testable import CabalmailKit

/// Wire-level tests for the `/push_register` / `/push_deregister` pair
/// backing APNs token lifecycle (docs/0.11.0/push-notifications.md), plus
/// the shared-container mirroring that hands the ID token to the
/// Notification Service Extension.
final class ApiClientPushTests: XCTestCase {
    private func makeConfiguration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
        )
    }

    func testRegisterPushDevicePostsSnakeCaseBody() async throws {
        let http = RecordingHTTPTransport(responses: [(Data("{}".utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        try await client.registerPushDevice(PushDeviceRegistration(
            deviceToken: "ab12cd34",
            bundleId: "com.cabalmail.Cabalmail",
            appVersion: "0.6.0",
            locale: "en_US"
        ))
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(
            requests[0].url?.absoluteString,
            "https://api.cabalmail.example/prod/push_register"
        )
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "idtoken")
        let payload = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(payload?["device_token"] as? String, "ab12cd34")
        XCTAssertEqual(payload?["bundle_id"] as? String, "com.cabalmail.Cabalmail")
        XCTAssertEqual(payload?["platform"] as? String, "ios")
        XCTAssertEqual(payload?["app_version"] as? String, "0.6.0")
        XCTAssertEqual(payload?["locale"] as? String, "en_US")
        // Nil folder selection is OMITTED (not null) so the Lambda's upsert
        // preserves whatever the row already carries.
        XCTAssertNil(payload?["enabled_folders"])
        XCTAssertEqual(payload?.count, 5)
    }

    func testRegisterPushDeviceIncludesEnabledFoldersWhenSet() async throws {
        let http = RecordingHTTPTransport(responses: [(Data("{}".utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        try await client.registerPushDevice(PushDeviceRegistration(
            deviceToken: "ab12cd34",
            bundleId: "com.cabalmail.Cabalmail",
            appVersion: "0.6.0",
            locale: "en_US",
            enabledFolders: ["*"]
        ))
        let requests = await http.requests
        let payload = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(payload?["enabled_folders"] as? [String], ["*"])
    }

    func testDeregisterPushDevicePostsToken() async throws {
        let http = RecordingHTTPTransport(responses: [(Data("{}".utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        try await client.deregisterPushDevice(token: "ab12cd34")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(
            requests[0].url?.absoluteString,
            "https://api.cabalmail.example/prod/push_deregister"
        )
        let payload = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(payload?.count, 1)
        XCTAssertEqual(payload?["device_token"] as? String, "ab12cd34")
    }

    func testFetchPushEnvelopePostsFolderOnlyWhenHintsAreNil() async throws {
        let response = """
        {"from": "Ada Lovelace <ada@example.com>", "subject": "Hello", \
        "snippet": "First line", "uid": 4271}
        """
        let http = RecordingHTTPTransport(responses: [(Data(response.utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let envelope = try await client.fetchPushEnvelope(
            folder: "INBOX",
            uid: nil,
            messageID: nil
        )
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(
            requests[0].url?.absoluteString,
            "https://api.cabalmail.example/prod/push_envelope"
        )
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "idtoken")
        let payload = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(payload?["folder"] as? String, "INBOX")
        // Nil hints are OMITTED (not null) so the Lambda resolves purely by
        // whichever coordinates the payload actually carried.
        XCTAssertEqual(payload?.count, 1)
        XCTAssertEqual(envelope.from, "Ada Lovelace <ada@example.com>")
        XCTAssertEqual(envelope.subject, "Hello")
        XCTAssertEqual(envelope.snippet, "First line")
        XCTAssertEqual(envelope.uid, 4271)
    }

    func testFetchPushEnvelopeForwardsUidAndMessageID() async throws {
        let response = """
        {"from": "Ada <ada@example.com>", "subject": "Hi", "snippet": ""}
        """
        let http = RecordingHTTPTransport(responses: [(Data(response.utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let envelope = try await client.fetchPushEnvelope(
            folder: "INBOX",
            uid: 4271,
            messageID: "<abc@mx.example>"
        )
        let requests = await http.requests
        let payload = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(payload?["folder"] as? String, "INBOX")
        XCTAssertEqual(payload?["uid"] as? Int, 4271)
        XCTAssertEqual(payload?["msg_id"] as? String, "<abc@mx.example>")
        XCTAssertEqual(payload?.count, 3)
        // A response without `uid` decodes with a nil resolved uid — callers
        // then keep the original hint for the notification's msgRef.
        XCTAssertNil(envelope.uid)
    }

    func testFetchPushEnvelopeSurfacesServerError() async throws {
        let http = RecordingHTTPTransport(responses: [(Data("boom".utf8), 500)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        do {
            _ = try await client.fetchPushEnvelope(folder: "INBOX", uid: nil, messageID: nil)
            XCTFail("Expected server error")
        } catch let error as CabalmailError {
            guard case .server(let code, _) = error else {
                return XCTFail("Expected .server, got \(error)")
            }
            XCTAssertEqual(code, "500")
        }
    }

    func testRegisterPushDeviceSurfacesServerError() async throws {
        let http = RecordingHTTPTransport(responses: [(Data("boom".utf8), 500)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        do {
            try await client.registerPushDevice(PushDeviceRegistration(
                deviceToken: "ab12cd34",
                bundleId: "com.cabalmail.Cabalmail",
                appVersion: "0.6.0",
                locale: "en_US"
            ))
            XCTFail("Expected server error")
        } catch let error as CabalmailError {
            guard case .server(let code, _) = error else {
                return XCTFail("Expected .server, got \(error)")
            }
            XCTAssertEqual(code, "500")
        }
    }
}

/// The NSE handoff: `PushMirroringSecureStore` must mirror exactly the
/// Cognito-token writes into `PushEnrichmentStore`, and leave every other
/// key untouched.
final class PushEnrichmentStoreTests: XCTestCase {
    private func makeTokens(idToken: String, expiresAt: Date) -> AuthTokens {
        AuthTokens(
            idToken: idToken,
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: expiresAt
        )
    }

    func testMirrorsAuthTokenWritesIntoSharedStore() throws {
        let base = InMemorySecureStore()
        let shared = InMemorySecureStore()
        let store = PushMirroringSecureStore(
            base: base,
            mirror: PushEnrichmentStore(secureStore: shared, defaults: nil)
        )
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        let encoded = try JSONEncoder().encode(makeTokens(idToken: "id-1", expiresAt: expiry))
        try store.set(encoded, forKey: SecureStoreKey.authTokens)

        // The base write is untouched...
        XCTAssertEqual(try base.get(SecureStoreKey.authTokens), encoded)
        // ...and the mirror holds the NSE's payload: id token + expiry only.
        let mirrored = try XCTUnwrap(shared.get(PushEnrichmentStore.keychainAccount))
        let payload = try JSONSerialization.jsonObject(with: mirrored) as? [String: Any]
        XCTAssertEqual(payload?["id_token"] as? String, "id-1")
        XCTAssertNotNil(payload?["expires_at"])
        XCTAssertEqual(payload?.count, 2)
    }

    func testDoesNotMirrorOtherKeys() throws {
        let base = InMemorySecureStore()
        let shared = InMemorySecureStore()
        let store = PushMirroringSecureStore(
            base: base,
            mirror: PushEnrichmentStore(secureStore: shared, defaults: nil)
        )
        try store.setString("hunter2", forKey: SecureStoreKey.imapPassword)
        XCTAssertEqual(try store.getString(SecureStoreKey.imapPassword), "hunter2")
        XCTAssertNil(try shared.get(PushEnrichmentStore.keychainAccount))
    }

    func testRemovingAuthTokensClearsTheMirror() throws {
        let base = InMemorySecureStore()
        let shared = InMemorySecureStore()
        let store = PushMirroringSecureStore(
            base: base,
            mirror: PushEnrichmentStore(secureStore: shared, defaults: nil)
        )
        let encoded = try JSONEncoder().encode(makeTokens(idToken: "id-1", expiresAt: .distantFuture))
        try store.set(encoded, forKey: SecureStoreKey.authTokens)
        XCTAssertNotNil(try shared.get(PushEnrichmentStore.keychainAccount))

        try store.remove(SecureStoreKey.authTokens)
        XCTAssertNil(try base.get(SecureStoreKey.authTokens))
        XCTAssertNil(try shared.get(PushEnrichmentStore.keychainAccount))
    }

    func testUndecodableTokenBlobIsIgnored() throws {
        let base = InMemorySecureStore()
        let shared = InMemorySecureStore()
        let store = PushMirroringSecureStore(
            base: base,
            mirror: PushEnrichmentStore(secureStore: shared, defaults: nil)
        )
        // A corrupt blob must still persist to the base store (the auth
        // service owns that contract) without poisoning the mirror.
        try store.set(Data("not json".utf8), forKey: SecureStoreKey.authTokens)
        XCTAssertNotNil(try base.get(SecureStoreKey.authTokens))
        XCTAssertNil(try shared.get(PushEnrichmentStore.keychainAccount))
    }
}
