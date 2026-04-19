import Foundation
@testable import CabalmailKit

// MARK: - HTTP fake

struct ScriptedHTTPTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await handler(request)
    }
}

/// Records every request and replies from a FIFO queue of canned responses.
actor RecordingHTTPTransport: HTTPTransport {
    private var responses: [(Data, Int)]
    private(set) var requests: [URLRequest] = []

    init(responses: [(Data, Int)]) {
        self.responses = responses
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw CabalmailError.transport("RecordingHTTPTransport ran out of responses")
        }
        let (data, status) = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (data, response)
    }
}

// MARK: - Byte-stream fake

/// Byte-stream whose reads drain a FIFO queue of preloaded chunks.
///
/// Tests preload the entire server-side transcript before invoking the
/// client under test. If the client reads past the scripted data, `read()`
/// suspends forever — turn on `autoEOFOnDrain` to return empty Data
/// instead, which the connection layer interprets as a closed peer.
actor ScriptedByteStream: ByteStream {
    private enum Chunk {
        case data(Data)
        case error(Error)
    }

    private var inbound: [Chunk]
    private(set) var outbound = Data()
    let autoEOFOnDrain: Bool
    private var isClosed = false

    init(inbound: [Data] = [], autoEOFOnDrain: Bool = false) {
        self.inbound = inbound.map { .data($0) }
        self.autoEOFOnDrain = autoEOFOnDrain
    }

    func enqueue(_ data: Data) {
        inbound.append(.data(data))
    }

    func enqueue(_ string: String) {
        inbound.append(.data(Data(string.utf8)))
    }

    /// Scripts a transport failure at the next `read()`. Used to simulate a
    /// dead socket after sleep/wake or a network change.
    func enqueueError(_ error: Error) {
        inbound.append(.error(error))
    }

    func read() async throws -> Data {
        while true {
            if !inbound.isEmpty {
                switch inbound.removeFirst() {
                case .data(let data): return data
                case .error(let error): throw error
                }
            }
            if isClosed || autoEOFOnDrain {
                return Data()
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func write(_ data: Data) async throws {
        outbound.append(data)
    }

    func startTLS(host: String) async throws -> ByteStream { self }

    func close() async {
        isClosed = true
    }

    var outboundString: String {
        String(bytes: outbound, encoding: .utf8) ?? ""
    }
}

struct ScriptedConnectionFactory: ImapConnectionFactory, SmtpConnectionFactory {
    let stream: ScriptedByteStream

    func makeConnection() async throws -> ByteStream {
        stream
    }
}

/// Connection factory that hands out pre-built streams in order — one per
/// `makeConnection()` call. Used to simulate a dead socket being replaced
/// by a fresh one on reconnect.
actor RotatingConnectionFactory: ImapConnectionFactory {
    private var streams: [ScriptedByteStream]
    private(set) var madeCount: Int = 0

    init(streams: [ScriptedByteStream]) {
        self.streams = streams
    }

    func makeConnection() async throws -> ByteStream {
        guard !streams.isEmpty else {
            throw CabalmailError.transport("RotatingConnectionFactory exhausted")
        }
        madeCount += 1
        return streams.removeFirst()
    }
}

// MARK: - Auth fake

/// AuthService double with scripted behavior. Every method is no-op by
/// default; tests can seed credentials and a fixed ID token.
actor StubAuthService: AuthService {
    var tokens: AuthTokens?
    var credentials: ImapCredentials
    var idTokenCallCount = 0

    init(
        tokens: AuthTokens? = AuthTokens(
            idToken: "idtoken",
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600)
        ),
        credentials: ImapCredentials = ImapCredentials(username: "alice", password: "hunter2")
    ) {
        self.tokens = tokens
        self.credentials = credentials
    }

    func signIn(username: String, password: String) async throws {
        credentials = ImapCredentials(username: username, password: password)
    }

    func signUp(username: String, password: String, email: String?, phone: String?) async throws {}
    func confirmSignUp(username: String, code: String) async throws {}
    func resendConfirmationCode(username: String) async throws {}
    func forgotPassword(username: String) async throws {}
    func confirmForgotPassword(username: String, code: String, newPassword: String) async throws {}

    func signOut() async throws {
        tokens = nil
    }

    func currentIdToken() async throws -> String {
        idTokenCallCount += 1
        guard let tokens else { throw CabalmailError.notSignedIn }
        return tokens.idToken
    }

    func currentImapCredentials() async throws -> ImapCredentials {
        credentials
    }

    func currentTokens() async -> AuthTokens? {
        tokens
    }
}
