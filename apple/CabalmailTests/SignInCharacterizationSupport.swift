import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What the workstream 0.8 sign-in characterization suites
/// (`SignInCharacterizationTests.swift`, `SignInMfaCharacterizationTests.swift`)
/// script and expect, kept in one place so the code path's "wired exactly
/// like a password sign-in" is checked against the very list the password
/// path pins, not a second copy of it.
enum SignInScript {
    static let domain = "cabalmail.example"
    static let password = "hunter2"
    static let domainKey = "cabalmail.controlDomain"
    static let usernameKey = "cabalmail.lastUsername"
    static let mismatch = "That code did not match. Please try again."
    static let configurationOnly = ["loadConfiguration cabalmail.example"]
    /// What `signIn` asks of the environment before Cognito answers.
    static let clientBuilt = configurationOnly + ["makeSecureStore", "makeClient"]

    /// What a sign-in that gets tokens records after `clientBuilt`, the same
    /// for both entry paths (tokens for the password, or for the code).
    static func wired(_ username: String) -> [String] {
        [
            "publishControlDomain cabalmail.example",
            "requestBadgeAuthorization",
            "requestContactsAccess",
            "sessionDidStart tokens=stored",
            "pushSessionToWatch \(username)",
        ]
    }

    /// A whole sign-in over a wired session: the badge poller the first
    /// sign-in started is still running, so the badge prompt is not asked for.
    static func rewired(_ username: String) -> [String] {
        clientBuilt + wired(username).filter { $0 != "requestBadgeAuthorization" }
    }

    static func jsonBody(of request: URLRequest?) throws -> [String: Any] {
        let data = try XCTUnwrap(request?.httpBody, "no request body")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// `SessionHarness.awaitConfigurationLoad()`, bounded: a sign-in that
    /// stops loading config.json, or loads it later than expected, fails here
    /// after `defaultWaitTimeout` instead of hanging the run.
    @MainActor
    static func awaitHeldLoad(
        in world: SessionHarness, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let arrived = XCTestExpectation(description: "the held configuration load arrived")
        Task { @MainActor in
            await world.awaitConfigurationLoad()
            arrived.fulfill()
        }
        let result = await XCTWaiter().fulfillment(of: [arrived], timeout: defaultWaitTimeout)
        if result != .completed {
            XCTFail("no configuration load was held within \(Int(defaultWaitTimeout))s", file: file, line: line)
        }
    }

    /// Has every client the environment builds from now on use `mail`'s
    /// caches: the harness's own client (its `makeClient` event, auth service
    /// and API client) with these envelope and body caches. In production
    /// every client is built over one Application Support directory, so a
    /// wipe by one client clears what another cached; the harness gives each
    /// client a directory of its own, and this stands in for the shared one.
    /// The client returned is not the one appended to `world.clients`.
    @MainActor
    static func seatClients(of world: SessionHarness, over mail: SignInCachedMail) {
        let build = world.appState.sessionEnvironment.makeClient
        world.appState.sessionEnvironment.makeClient = { configuration, store, monitor in
            let built = try build(configuration, store, monitor)
            return CabalmailClient(
                configuration: built.configuration,
                authService: built.authService,
                apiClient: built.apiClient,
                imapClient: built.imapClient,
                addressCache: built.addressCache,
                envelopeCache: mail.envelopes,
                bodyCache: mail.bodies,
                draftStore: built.draftStore,
                outbox: built.outbox,
                folderStateCache: built.folderStateCache
            )
        }
    }
}

/// An envelope cache and a body cache, seeded with one INBOX message (its
/// envelope snapshot and its `.eml` body): the observable a local wipe clears.
struct SignInCachedMail {
    let envelopes: EnvelopeCache
    let bodies: MessageBodyCache

    init(of client: CabalmailClient) {
        envelopes = client.envelopeCache
        bodies = client.bodyCache
    }

    init(directory: URL) throws {
        envelopes = try EnvelopeCache(directory: directory.appendingPathComponent("envelopes"))
        bodies = try MessageBodyCache(directory: directory.appendingPathComponent("bodies"))
    }

    func seed() async throws {
        let snapshot = EnvelopeCache.Snapshot(
            uidValidity: 1, uidNext: 2, envelopes: [1: TestFixtures.makeEnvelope(uid: 1)]
        )
        try await envelopes.store(snapshot, for: "INBOX")
        try await bodies.store(folder: "INBOX", uidValidity: 1, uid: 1, bytes: Data("From: bob\r\n\r\nhi".utf8))
    }

    /// Asserts the seeded snapshot and body are both still there, or both gone.
    func assertPresent(_ present: Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let snapshot = await envelopes.snapshot(for: "INBOX")
        let body = await bodies.fetch(folder: "INBOX", uidValidity: 1, uid: 1)
        XCTAssertEqual(snapshot != nil, present, "envelope snapshot", file: file, line: line)
        XCTAssertEqual(body != nil, present, "message body", file: file, line: line)
    }
}
