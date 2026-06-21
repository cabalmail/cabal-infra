import XCTest
@testable import CabalmailKit

/// Regression coverage for the sign-out crash (`EXC_BAD_ACCESS` in
/// `-[MXMetricManager removeSubscriber:]`).
///
/// MetricKit subscription is process-global. When the `MetricKitCollector`
/// was owned by `CabalmailClient`, signing out released the client, ran the
/// collector's `deinit`, and unsubscribed from `MXMetricManager` on a
/// background queue *after* the collector had been freed -- a use-after-free.
///
/// These tests pin the invariant that fixes it: the collector is the
/// process-lifetime singleton, and releasing a `CabalmailClient` does not
/// deallocate it.
final class MetricKitCollectorLifecycleTests: XCTestCase {
    private func makeConfiguration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
        )
    }

    private func makeClient() throws -> CabalmailClient {
        let config = makeConfiguration()
        let auth = StubAuthService()
        let api = URLSessionApiClient(
            configuration: config,
            authService: auth,
            transport: RecordingHTTPTransport(responses: [])
        )
        let imap = LiveImapClient(
            factory: ScriptedConnectionFactory(stream: ScriptedByteStream()),
            authService: auth
        )
        let smtp = LiveSmtpClient(
            factory: ScriptedConnectionFactory(stream: ScriptedByteStream()),
            authService: auth
        )
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let envelopes = try EnvelopeCache(directory: tmp.appendingPathComponent("e"))
        let bodies = try MessageBodyCache(directory: tmp.appendingPathComponent("b"))
        let drafts = try DraftStore(directory: tmp.appendingPathComponent("d"))
        let outbox = try Outbox(directory: tmp.appendingPathComponent("o"))
        return CabalmailClient(
            configuration: config,
            authService: auth,
            apiClient: api,
            imapClient: imap,
            smtpClient: smtp,
            addressCache: AddressCache(),
            envelopeCache: envelopes,
            bodyCache: bodies,
            draftStore: drafts,
            outbox: outbox
        )
    }

    func testClientUsesProcessSingletonCollector() throws {
        let client = try makeClient()
        XCTAssertTrue(
            client.metricKitCollector === MetricKitCollector.shared,
            "Client must reuse the process-wide collector, not its own instance"
        )
    }

    func testCollectorOutlivesClientRelease() throws {
        weak var weakCollector: MetricKitCollector?
        do {
            let client = try makeClient()
            weakCollector = client.metricKitCollector
            XCTAssertNotNil(weakCollector)
        }
        // The client is gone; the collector must NOT have been deallocated
        // (the singleton holds it for the process lifetime). A nil here would
        // mean the subscriber can again be freed while registered with
        // MXMetricManager -- the exact dangling-pointer condition that crashed
        // the app on sign-out.
        XCTAssertNotNil(
            weakCollector,
            "Releasing a client must not deallocate the MetricKit subscriber"
        )
        XCTAssertTrue(weakCollector === MetricKitCollector.shared)
    }
}
