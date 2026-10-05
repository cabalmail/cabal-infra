import XCTest
@testable import CabalmailKit

/// `ApiBackedImapClient.idle(folder:)`, the polling stream that stands in for
/// IMAP IDLE. Its first poll runs before the stream is returned, so an
/// unreachable API fails the open and `MailboxWatcher`'s backoff can grow
/// (#1797); `MailboxWatcherTests` covers that end to end.
final class ApiBackedImapClientIdleTests: XCTestCase {
    private func makeClient(_ transport: HTTPTransport, pollInterval: TimeInterval = 60) -> ApiBackedImapClient {
        let api = URLSessionApiClient(
            configuration: Configuration(
                controlDomain: "cabalmail.example",
                domains: [MailDomain(domain: "cabalmail.example")],
                invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
                cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
            ),
            authService: StubAuthService(),
            transport: transport
        )
        return ApiBackedImapClient(api: api, host: "imap.example.com", pollInterval: pollInterval)
    }

    private static func status(uidNext: Int, messages: Int) -> (Data, Int) {
        let body = #"{"messages":\#(messages),"unseen":0,"uid_validity":1,"uid_next":\#(uidNext)}"#
        return (Data(body.utf8), 200)
    }

    func testOpeningFailsWhenTheFirstPollFails() async {
        let client = makeClient(ScriptedHTTPTransport { _ in throw CabalmailError.network("offline") })
        do {
            _ = try await client.idle(folder: "INBOX")
            XCTFail("an unreachable API must fail the open, not just the stream")
        } catch {
            // Expected: the watcher sees a failed open and backs off.
        }
    }

    /// A maintenance window opens the stream rather than failing the open
    /// (which would churn watcher reopens), the stream polls quietly through
    /// it, and the first poll that succeeds becomes the baseline.
    func testMaintenanceOpensTheStreamAndPollsThroughTheWindow() async throws {
        let body = #"{"status":"maintenance","message":"Down for maintenance","retry_after":30}"#
        let maintenance = (Data(body.utf8), 503)
        let http = RecordingHTTPTransport(responses: [
            maintenance,
            maintenance,
            Self.status(uidNext: 100, messages: 10),
            Self.status(uidNext: 101, messages: 11),
        ])
        let stream = try await makeClient(http, pollInterval: 0.01).idle(folder: "INBOX")
        // Bounded: once the script runs out the transport throws and the
        // stream finishes, so `next()` cannot wait forever.
        var events = stream.makeAsyncIterator()
        let first = try await events.next()
        XCTAssertEqual(first, IdleEvent(kind: .exists(101)))
    }

    func testTheOpeningPollIsTheBaselineForNewMail() async throws {
        let http = RecordingHTTPTransport(responses: [
            Self.status(uidNext: 100, messages: 10),
            Self.status(uidNext: 101, messages: 11),
        ])
        let stream = try await makeClient(http, pollInterval: 0.01).idle(folder: "INBOX")
        var events = stream.makeAsyncIterator()
        let first = try await events.next()
        XCTAssertEqual(first, IdleEvent(kind: .exists(101)))
    }
}
