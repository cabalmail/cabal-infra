import Foundation
import XCTest
import CabalmailKit
@testable import Cabalmail

// Test doubles + fixture factory for the app-layer unit tests. The
// CabalmailKit test target has its own stubs (TestHelpers.swift), but
// those are internal to that target, so the handful we need here are
// (re)defined against the Kit's public protocol surface.

/// Scripted `ImapClient` double. Only the members the bulk paths use are
/// functional — `setFlags` / `move` record their calls and pop a scripted
/// result — and everything else traps loudly, so a test that wanders onto
/// an unexpected wire path fails instead of silently no-oping.
actor FakeImapClient: ImapClient {
    struct FlagCall {
        let folder: String
        let uids: Set<UInt32>
        let flags: Set<Flag>
        let operation: FlagOperation
    }

    struct MoveCall {
        let folder: String
        let uids: Set<UInt32>
        let destination: String
        let markSeen: Bool
    }

    private(set) var flagCalls: [FlagCall] = []
    private(set) var moveCalls: [MoveCall] = []
    // FIFO scripts; an empty queue means "succeed". Seeded via the
    // scriptFlagResults / scriptMoveResults helpers below.
    private var flagResults: [Result<Void, Error>] = []
    private var moveResults: [Result<Void, Error>] = []

    func scriptFlagResults(_ results: [Result<Void, Error>]) {
        flagResults = results
    }

    func scriptMoveResults(_ results: [Result<Void, Error>]) {
        moveResults = results
    }

    func setFlags(
        folder: String,
        uids: [UInt32],
        flags: Set<Flag>,
        operation: FlagOperation
    ) async throws {
        flagCalls.append(FlagCall(
            folder: folder, uids: Set(uids), flags: flags, operation: operation
        ))
        if !flagResults.isEmpty {
            try flagResults.removeFirst().get()
        }
    }

    func move(folder: String, uids: [UInt32], destination: String, markSeen: Bool) async throws {
        moveCalls.append(MoveCall(
            folder: folder, uids: Set(uids), destination: destination, markSeen: markSeen
        ))
        if !moveResults.isEmpty {
            try moveResults.removeFirst().get()
        }
    }

    // Lifecycle no-ops — the view model may touch these harmlessly.
    func connectAndAuthenticate() async throws {}
    func disconnect() async {}
    func invalidate() async {}

    // Everything below is off the bulk paths: trap.
    func listFolders() async throws -> [Folder] { try trap() }
    func createFolder(name: String, parent: String?) async throws { try trapVoid() }
    func deleteFolder(path: String) async throws { try trapVoid() }
    func subscribe(path: String) async throws { try trapVoid() }
    func unsubscribe(path: String) async throws { try trapVoid() }
    func status(path: String, flagged: Bool) async throws -> FolderStatus { try trap() }
    func envelopes(
        folder: String, range: ClosedRange<UInt32>, sort: SortCriterion
    ) async throws -> [Envelope] { try trap() }
    func envelopes(
        folder: String, offset: UInt32, limit: UInt32, sort: SortCriterion
    ) async throws -> [Envelope] { try trap() }
    func topEnvelopes(
        folder: String, limit: UInt32, totalMessages: UInt32, sort: SortCriterion
    ) async throws -> [Envelope] { try trap() }
    func fetchBody(folder: String, uid: UInt32) async throws -> RawMessage { try trap() }
    func fetchPart(folder: String, uid: UInt32, partId: String) async throws -> Data { try trap() }
    func append(folder: String, message: Data, flags: Set<Flag>) async throws { try trapVoid() }

    private func trap<T>() throws -> T {
        throw CabalmailError.protocolError("FakeImapClient: unexpected call")
    }

    private func trapVoid() throws {
        throw CabalmailError.protocolError("FakeImapClient: unexpected call")
    }
}

/// Minimal `AuthService` conformance — the bulk paths never authenticate.
actor NullAuthService: AuthService {
    func signIn(username: String, password: String) async throws {}
    func signUp(username: String, password: String, email: String?, phone: String?) async throws {}
    func confirmSignUp(username: String, code: String) async throws {}
    func resendConfirmationCode(username: String) async throws {}
    func forgotPassword(username: String) async throws {}
    func confirmForgotPassword(username: String, code: String, newPassword: String) async throws {}
    func signOut() async throws {}
    func currentIdToken() async throws -> String { "test-token" }
    func currentImapCredentials() async throws -> ImapCredentials {
        ImapCredentials(username: "tester", password: "secret")
    }
    func currentTokens() async -> AuthTokens? { nil }
}

struct NullSmtpClient: SmtpClient {
    func send(_ message: OutgoingMessage) async throws {
        throw CabalmailError.protocolError("NullSmtpClient: unexpected send")
    }
}

/// HTTP transport that refuses every request — nothing in these tests may
/// reach the network.
struct NullHTTPTransport: HTTPTransport {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw CabalmailError.transport("NullHTTPTransport: unexpected request")
    }
}

enum TestFixtures {
    static func makeConfiguration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
        )
    }

    /// Full client around the fake IMAP transport. Caches land in a
    /// per-invocation temp directory (the bulk paths prune them; empty
    /// caches make that a no-op).
    static func makeClient(imap: FakeImapClient) throws -> CabalmailClient {
        let config = makeConfiguration()
        let auth = NullAuthService()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-tests-\(UUID().uuidString)")
        return CabalmailClient(
            configuration: config,
            authService: auth,
            apiClient: URLSessionApiClient(
                configuration: config,
                authService: auth,
                transport: NullHTTPTransport()
            ),
            imapClient: imap,
            smtpClient: NullSmtpClient(),
            addressCache: AddressCache(),
            envelopeCache: try EnvelopeCache(directory: tmp.appendingPathComponent("e")),
            bodyCache: try MessageBodyCache(directory: tmp.appendingPathComponent("b")),
            draftStore: try DraftStore(directory: tmp.appendingPathComponent("d")),
            outbox: try Outbox(directory: tmp.appendingPathComponent("o"))
        )
    }

    /// View model over `folder` with the given rows already loaded, ready
    /// for selection / bulk-op calls. No lifecycle task runs — the model's
    /// init is pure assignment and `loadInitial()` is never called.
    @MainActor
    static func makeModel(
        imap: FakeImapClient,
        envelopes: [Envelope],
        folderPath: String = "INBOX",
        appState: AppState = AppState()
    ) throws -> MessageListViewModel {
        let model = MessageListViewModel(
            folder: Folder(path: folderPath, attributes: [], isSubscribed: true),
            client: try makeClient(imap: imap),
            preferences: Preferences(store: InMemoryPreferenceStore()),
            appState: appState
        )
        model.envelopes = envelopes
        return model
    }

    static func makeEnvelope(uid: UInt32, flags: Set<Flag> = []) -> Envelope {
        Envelope(
            uid: uid,
            subject: "Subject \(uid)",
            from: [EmailAddress(name: "Sender", mailbox: "sender\(uid)", host: "example.com")],
            flags: flags
        )
    }
}
