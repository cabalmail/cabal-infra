import Foundation

/// Top-level facade for the Apple client.
///
/// Owns the `AuthService` session and exposes ready-to-use `ApiClient`,
/// `ImapClient`, and `SmtpClient` instances plus their caches. The app
/// target holds a single shared `CabalmailClient` instance in its
/// `@Observable` root and injects it into views via `.environment`.
public actor CabalmailClient {
    // All stored properties are `nonisolated` because they're immutable
    // `Sendable` references — `Configuration` is a value type, and every
    // service / cache here is either its own actor or a `Sendable` protocol
    // existential. Letting views read e.g. `client.configuration.domains`
    // synchronously avoids forcing every read-only consumer through an
    // actor hop; mutating flows still funnel through this actor's methods.
    public nonisolated let configuration: Configuration
    public nonisolated let authService: AuthService
    public nonisolated let apiClient: ApiClient
    public nonisolated let imapClient: ImapClient
    public nonisolated let smtpClient: SmtpClient
    public nonisolated let addressCache: AddressCache
    public nonisolated let envelopeCache: EnvelopeCache
    public nonisolated let bodyCache: MessageBodyCache
    public nonisolated let draftStore: DraftStore

    /// Retained so the path monitor outlives initialization. The underlying
    /// `NWPathMonitor` stops when this property is released. Only `make(...)`
    /// sets it — tests that build the client via the memberwise initializer
    /// leave it nil and skip proactive invalidation.
    #if canImport(Network)
    private nonisolated let pathMonitor: NetworkPathMonitor?
    #endif

    public init(
        configuration: Configuration,
        authService: AuthService,
        apiClient: ApiClient,
        imapClient: ImapClient,
        smtpClient: SmtpClient,
        addressCache: AddressCache,
        envelopeCache: EnvelopeCache,
        bodyCache: MessageBodyCache,
        draftStore: DraftStore
    ) {
        self.configuration = configuration
        self.authService = authService
        self.apiClient = apiClient
        self.imapClient = imapClient
        self.smtpClient = smtpClient
        self.addressCache = addressCache
        self.envelopeCache = envelopeCache
        self.bodyCache = bodyCache
        self.draftStore = draftStore
        #if canImport(Network)
        self.pathMonitor = nil
        #endif
    }

    #if canImport(Network)
    /// Production factory: hand a `Configuration` and a `SecureStore` and get
    /// back a client wired against the real Cognito, API Gateway, and mail
    /// tiers. Overrides let tests supply fakes for any of the pieces.
    public static func make(
        configuration: Configuration,
        secureStore: SecureStore,
        httpTransport: HTTPTransport = URLSessionHTTPTransport(),
        cacheDirectory: URL,
        bodyCacheCapacityBytes: UInt64 = 200 * 1024 * 1024
    ) throws -> CabalmailClient {
        let auth = CognitoAuthService(
            configuration: configuration,
            transport: httpTransport,
            secureStore: secureStore
        )
        let api = URLSessionApiClient(
            configuration: configuration,
            authService: auth,
            transport: httpTransport
        )
        let imap = LiveImapClient(
            factory: NetworkImapConnectionFactory(host: configuration.imapHost),
            authService: auth
        )
        let smtp = LiveSmtpClient(
            factory: NetworkSmtpConnectionFactory(host: configuration.smtpHost),
            authService: auth
        )
        let addresses = AddressCache()
        let envelopes = try EnvelopeCache(directory: cacheDirectory.appendingPathComponent("envelopes"))
        let bodies = try MessageBodyCache(
            directory: cacheDirectory.appendingPathComponent("bodies"),
            capacityBytes: bodyCacheCapacityBytes
        )
        let drafts = try DraftStore(directory: cacheDirectory.appendingPathComponent("drafts"))
        return CabalmailClient(
            configuration: configuration,
            authService: auth,
            apiClient: api,
            imapClient: imap,
            smtpClient: smtp,
            addressCache: addresses,
            envelopeCache: envelopes,
            bodyCache: bodies,
            draftStore: drafts,
            monitorNetworkPath: true
        )
    }

    /// Designated init used by `make(...)` — installs a `NetworkPathMonitor`
    /// that calls `imapClient.invalidate()` whenever the active path shifts.
    /// Separated from the public memberwise initializer so tests can keep
    /// constructing bare clients without touching `Network.framework`.
    private init(
        configuration: Configuration,
        authService: AuthService,
        apiClient: ApiClient,
        imapClient: ImapClient,
        smtpClient: SmtpClient,
        addressCache: AddressCache,
        envelopeCache: EnvelopeCache,
        bodyCache: MessageBodyCache,
        draftStore: DraftStore,
        monitorNetworkPath: Bool
    ) {
        self.configuration = configuration
        self.authService = authService
        self.apiClient = apiClient
        self.imapClient = imapClient
        self.smtpClient = smtpClient
        self.addressCache = addressCache
        self.envelopeCache = envelopeCache
        self.bodyCache = bodyCache
        self.draftStore = draftStore
        if monitorNetworkPath {
            let imap = imapClient
            self.pathMonitor = NetworkPathMonitor {
                Task { await imap.invalidate() }
            }
        } else {
            self.pathMonitor = nil
        }
    }
    #endif

    // MARK: - Higher-level flows

    /// Returns the signed-in user's address list, consulting the in-memory
    /// cache first and invalidating on mutation. Views call this instead of
    /// the raw `ApiClient` to match the React app's implicit cache behavior.
    public func addresses(forceRefresh: Bool = false) async throws -> [Address] {
        if !forceRefresh, let cached = await addressCache.get() {
            return cached
        }
        let fresh = try await apiClient.listAddresses()
        await addressCache.set(fresh)
        return fresh
    }

    public func requestAddress(
        username: String,
        subdomain: String,
        tld: String,
        comment: String?,
        address: String
    ) async throws {
        try await apiClient.newAddress(
            username: username,
            subdomain: subdomain,
            tld: tld,
            comment: comment,
            address: address
        )
        await addressCache.invalidate()
    }

    public func revokeAddress(address: String, subdomain: String, tld: String, publicKey: String?) async throws {
        try await apiClient.revokeAddress(
            address: address,
            subdomain: subdomain,
            tld: tld,
            publicKey: publicKey
        )
        await addressCache.invalidate()
    }

    /// Submits an outgoing message via SMTP and, on success, `APPEND`s an
    /// identical copy to the `Sent` IMAP folder so the sender sees it in
    /// their sent mailbox on every other client. Sendmail + Dovecot in the
    /// Cabalmail container stack don't auto-append — the React app's backend
    /// does the equivalent in the `send` Lambda (see
    /// `lambda/api/send/function.py`). Mirroring that here keeps the Apple
    /// client feature-parity with the web UI.
    ///
    /// A fresh Message-ID is generated once and stamped on both copies so
    /// `In-Reply-To` / `References` chains stay intact across a later reply
    /// composed from either the Sent folder or the recipient's copy.
    ///
    /// The APPEND is best-effort: a succeeded-send with a failed Sent-folder
    /// APPEND does *not* throw, because the user's message was delivered.
    /// The tradeoff is a mailbox that eventually drifts from what recipients
    /// see — acceptable because the alternative is reporting a send failure
    /// for a message that was already accepted for relay.
    ///
    /// `sentFolder` defaults to `"Sent"` because that's the name the
    /// Dovecot config creates. Phase 6 settings will let the user override.
    public func send(_ message: OutgoingMessage, sentFolder: String = "Sent") async throws {
        let messageID = message.messageId ?? "\(UUID().uuidString)@\(message.from.host)"
        let stamped = OutgoingMessage(
            from: message.from,
            to: message.to,
            cc: message.cc,
            bcc: message.bcc,
            subject: message.subject,
            textBody: message.textBody,
            htmlBody: message.htmlBody,
            inReplyTo: message.inReplyTo,
            references: message.references,
            attachments: message.attachments,
            extraHeaders: message.extraHeaders,
            messageId: messageID
        )
        try await smtpClient.send(stamped)
        let payload = MessageBuilder.build(stamped, messageID: messageID)
        try? await imapClient.connectAndAuthenticate()
        try? await imapClient.append(
            folder: sentFolder,
            message: payload,
            flags: [.seen]
        )
    }
}
