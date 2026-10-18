import XCTest
@testable import CabalmailKit
import CabalmailKitTestSupport

/// Wire-level tests for the administration endpoints behind the native Users
/// view (auth parity plan, C2). Request and reply shapes are the Lambdas':
/// `lambda/api/{list_users,confirm_user,enable_user,disable_user,delete_user,
/// list_user_domain_access,set_user_domain_access}/function.py`.
final class AdminApiClientTests: XCTestCase {
    private func client(_ http: RecordingHTTPTransport) -> URLSessionApiClient {
        URLSessionApiClient(
            configuration: TestFixtures.makeConfiguration(), authService: StubAuthService(), transport: http
        )
    }

    private func ok(_ body: String = #"{"status":"ok"}"#) -> (Data, Int) { (Data(body.utf8), 200) }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testListUsersDecodesTheLambdaEnvelope() async throws {
        let body = """
        {"Users": [
          {"username": "alice", "status": "CONFIRMED", "enabled": true,
           "created": "2024-01-02T03:04:05.123456+00:00", "osid": "2001"},
          {"username": "bob", "status": "UNCONFIRMED", "enabled": true,
           "created": "2024-01-02T03:04:05+00:00", "osid": ""},
          {"username": "carol", "status": "FORCE_CHANGE_PASSWORD", "enabled": false}
        ]}
        """
        let http = RecordingHTTPTransport(responses: [ok(body)])
        let users = try await client(http).listUsers()

        XCTAssertEqual(users.map(\.username), ["alice", "bob", "carol"])
        XCTAssertEqual(users[0].osid, "2001")
        XCTAssertNil(users[1].osid, "an empty osid reads as none assigned")
        XCTAssertEqual(users[0].created, Date(timeIntervalSince1970: 1_704_164_645))
        XCTAssertEqual(users[1].created, Date(timeIntervalSince1970: 1_704_164_645))
        XCTAssertNil(users[2].created)
        XCTAssertFalse(users[2].enabled)
        XCTAssertEqual(users.map(\.isPending), [false, true, true])

        let sent = await http.requests
        let request = try XCTUnwrap(sent.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertTrue(request.url!.absoluteString.hasSuffix("/list_users"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "idtoken")
    }

    func testListUsersRejectsAReplyWithoutTheEnvelope() async {
        let http = RecordingHTTPTransport(responses: [ok("[]")])
        do {
            _ = try await client(http).listUsers()
            XCTFail("expected a decoding error")
        } catch {
            XCTAssertEqual(error as? CabalmailError, .decoding("list_users returned an unexpected reply"))
        }
    }

    /// The server is the authority: a 403 surfaces as `.http(403)` with the
    /// Lambda's own sentence for the user.
    func testANonAdminGets403WithTheServersSentence() async {
        let http = RecordingHTTPTransport(responses: [(Data(#"{"Error":"Admin access required"}"#.utf8), 403)])
        do {
            _ = try await client(http).listUsers()
            XCTFail("expected a 403")
        } catch let error as CabalmailError {
            guard case .http(status: 403, _) = error else { return XCTFail("expected .http(403), got \(error)") }
            XCTAssertEqual(error.localizedDescription, "Admin access required.")
        } catch {
            XCTFail("expected a CabalmailError, got \(error)")
        }
    }

    func testUserActionsSendTheUsernameToTheirEndpoint() async throws {
        let http = RecordingHTTPTransport(responses: [ok(), ok(), ok(), ok()])
        let api = client(http)
        try await api.confirmUser("alice")
        try await api.enableUser("bob")
        try await api.disableUser("carol")
        try await api.deleteUser("dave")

        let requests = await http.requests
        XCTAssertEqual(requests.map { $0.httpMethod }, ["PUT", "PUT", "PUT", "DELETE"])
        XCTAssertEqual(requests.map { $0.url!.lastPathComponent },
                       ["confirm_user", "enable_user", "disable_user", "delete_user"])
        XCTAssertEqual(try requests.map { try jsonBody($0)["username"] as? String }, ["alice", "bob", "carol", "dave"])
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testDeletingYourOwnAccountSurfacesTheServersRefusal() async {
        let http = RecordingHTTPTransport(responses: [(Data(#"{"Error":"Cannot delete your own account"}"#.utf8), 400)])
        do {
            try await client(http).deleteUser("alice")
            XCTFail("expected a 400")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Cannot delete your own account.")
        }
    }

    func testListUserDomainAccessDecodesTheAllowList() async throws {
        let body = #"{"Allowances":[{"user":"alice","domain":"cabalmail.example"},"#
            + #"{"user":"bob","domain":"b.example"}]}"#
        let http = RecordingHTTPTransport(responses: [ok(body)])
        let allowances = try await client(http).listUserDomainAccess()
        XCTAssertEqual(allowances, [
            DomainAllowance(user: "alice", domain: "cabalmail.example"),
            DomainAllowance(user: "bob", domain: "b.example"),
        ])
        let sent = await http.requests
        let request = try XCTUnwrap(sent.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertTrue(request.url!.absoluteString.hasSuffix("/list_user_domain_access"))
    }

    /// `allowed` has to reach the Lambda as a JSON boolean: it refuses
    /// anything else with "Body requires user (str), domain (str), allowed
    /// (bool)."
    func testSetUserDomainAccessSendsABooleanAllowed() async throws {
        let http = RecordingHTTPTransport(responses: [ok(), ok()])
        let api = client(http)
        try await api.setUserDomainAccess(user: "alice", domain: "cabalmail.example", allowed: true)
        try await api.setUserDomainAccess(user: "alice", domain: "cabalmail.example", allowed: false)

        let requests = await http.requests
        XCTAssertEqual(requests.map { $0.httpMethod }, ["PUT", "PUT"])
        XCTAssertEqual(requests[0].url!.lastPathComponent, "set_user_domain_access")
        let first = try XCTUnwrap(String(data: XCTUnwrap(requests[0].httpBody), encoding: .utf8))
        let second = try XCTUnwrap(String(data: XCTUnwrap(requests[1].httpBody), encoding: .utf8))
        XCTAssertTrue(first.contains(#""allowed":true"#), first)
        XCTAssertTrue(second.contains(#""allowed":false"#), second)
        XCTAssertEqual(try jsonBody(requests[0])["user"] as? String, "alice")
        XCTAssertEqual(try jsonBody(requests[0])["domain"] as? String, "cabalmail.example")
    }

    func testCreatedDatesParseWithAndWithoutFractionalSeconds() {
        let expected = Date(timeIntervalSince1970: 1_704_164_645)
        XCTAssertEqual(PoolUser.parseCreated("2024-01-02T03:04:05+00:00"), expected)
        XCTAssertEqual(PoolUser.parseCreated("2024-01-02T03:04:05.1+00:00"), expected)
        XCTAssertEqual(PoolUser.parseCreated("2024-01-02T03:04:05.123456+00:00"), expected)
        XCTAssertNil(PoolUser.parseCreated("yesterday"))
    }
}
