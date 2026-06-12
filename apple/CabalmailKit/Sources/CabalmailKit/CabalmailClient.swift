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
    public nonisolated let outbox: Outbox

    /// Retained so the path monitor outlives initialization. The underlying
    /// `NWPathMonitor` stops when this property is released. Only `make(...)`
    /// sets it — tests that build the client via the memberwise initializer
    /// leave it nil and skip proactive invalidation.
    #if canImport(Network)
    private nonisolated let pathMonitor: NetworkPathMonitor?
    /// Retained so Reachability observers and the send queue's drain task
    /// outlive initialization. Phase 7 — the offline banner streams from
    /// here, and `SendQueue` subscribes to drain the outbox on reconnect.
    public nonisolated let reachability: Reachability?
    private nonisolated let sendQueue: SendQueue?
    #endif

    /// Opt-in crash / hang reporter. Starts disabled — the Settings toggle
    /// calls `setCrashReportingEnabled(_:)` to flip it. Retained across
    /// start/stop cycles so subscriber registration with `MXMetricManager`
    /// is balanced.
    public nonisolated let metricKitCollector: MetricKitCollector

    public init(
        configuration: Configuration,
        authService: AuthService,
        apiClient: ApiClient,
        imapClient: ImapClient,
        smtpClient: SmtpClient,
        addressCache: AddressCache,
        envelopeCache: EnvelopeCache,
        bodyCache: MessageBodyCache,
        draftStore: DraftStore,
        outbox: Outbox
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
        self.outbox = outbox
        self.metricKitCollector = MetricKitCollector()
        #if canImport(Network)
        self.pathMonitor = nil
        self.reachability = nil
        self.sendQueue = nil
        #endif
    }

    #if canImport(Network)
    /// Production factory: hand a `Configuration` and a `SecureStore` and get
    /// back a client wired against the real Cognito, API Gateway, and mail
    /// tiers. Overrides let tests supply fakes for any of the pieces.
    ///
    /// As of issue #371 the IMAP and SMTP work happens behind the Lambda
    /// API rather than via direct mail-protocol sockets — `imapClient` is
    /// an `ApiBackedImapClient`, and `send(_:)` posts to `/send` instead
    /// of running its own SMTP submission. `LiveSmtpClient` is still wired
    /// as `smtpClient` so anything left calling that surface keeps working,
    /// but the production send path no longer touches it.
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
        let imap = ApiBackedImapClient(api: api, host: configuration.imapHost)
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
        let outbox = try Outbox(directory: cacheDirectory.appendingPathComponent("outbox"))
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
            outbox: outbox,
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
        outbox: Outbox,
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
        self.outbox = outbox
        self.metricKitCollector = MetricKitCollector()
        if monitorNetworkPath {
            let imap = imapClient
            self.pathMonitor = NetworkPathMonitor {
                Task { await imap.invalidate() }
            }
            let reach = Reachability()
            self.reachability = reach
            // Sender closure retries the same `/send` Lambda the foreground
            // path uses, so a queued message behaves identically to a fresh
            // one (Outbox APPEND + SMTP submission + Sent move all run
            // server-side; see `lambda/api/send/function.py`).
            let api = apiClient
            let imapHost = configuration.imapHost
            let smtpHost = configuration.smtpHost
            let queue = SendQueue(outbox: outbox) { message in
                try await Self.submit(message, api: api, imapHost: imapHost, smtpHost: smtpHost)
            }
            self.sendQueue = queue
            Task { await queue.bind(reachability: reach.changes()) }
        } else {
            self.pathMonitor = nil
            self.reachability = nil
            self.sendQueue = nil
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

    /// Toggles the caller's favorite flag on an address. Invalidates the
    /// address cache so the next `addresses(...)` call sees the new state.
    public func setFavorite(address: String, favorite: Bool) async throws {
        try await apiClient.setFavorite(address: address, favorite: favorite)
        await addressCache.invalidate()
    }

    /// Fetches the user's display-name preference. The `/send` Lambda uses
    /// it server-side as the From header's display name, so this value only
    /// drives the Settings field - outgoing mail picks it up with no client
    /// involvement. Empty string means unset.
    public func displayName() async throws -> String {
        try await apiClient.fetchDisplayName()
    }

    /// Persists the display-name preference server-side, where it is shared
    /// with the other clients (the React app edits the same row).
    public func setDisplayName(_ name: String) async throws {
        try await apiClient.updateDisplayName(name)
    }

    /// Submits an outgoing message via the Cabalmail `/send` Lambda.
    ///
    /// Issue #371 — the same Lambda the React app uses now handles the
    /// full submission flow: APPEND to the user's `Outbox`, SMTP submit,
    /// and move into `Sent` all happen server-side (see
    /// `lambda/api/send/function.py`). The Apple client used to do these
    /// three steps itself over IMAP/SMTP sockets; centralizing them in the
    /// Lambda eliminates the network-edge cases that motivated this issue
    /// (sleep/wake, sparse-UID corruption, sendmail auth races).
    ///
    /// A fresh Message-ID is still generated client-side so reply
    /// threading stays intact whether the sender or a recipient composes
    /// the next reply.
    ///
    /// `sentFolder` is accepted for source compatibility; the Lambda
    /// hard-codes the `Sent` destination so the parameter is currently
    /// unused. Wiring it through requires a Lambda change.
    ///
    /// When the Lambda call fails with a transport-class error, the
    /// message is persisted to the `Outbox` and `SendOutcome.queued(_)`
    /// is returned instead of thrown — `SendQueue` drains it when
    /// reachability returns. Application-level rejections (auth failure,
    /// recipient refusal) still throw so the user can correct them
    /// immediately.
    @discardableResult
    public func send(_ message: OutgoingMessage, sentFolder: String = "Sent") async throws -> SendOutcome {
        let messageID = message.messageId ?? "<\(UUID().uuidString)@\(message.from.host)>"
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
        do {
            try await Self.submit(
                stamped,
                api: apiClient,
                imapHost: configuration.imapHost,
                smtpHost: configuration.smtpHost
            )
        } catch let error as CabalmailError where Self.shouldQueue(error) {
            let entry = try await outbox.enqueue(stamped)
            CabalmailLog.warn(
                "CabalmailClient",
                "transport error from /send; queued message \(entry.id)"
            )
            #if canImport(Network)
            await sendQueue?.kickDrain()
            #endif
            return .queued(entry.id)
        }
        return .sent
    }

    /// Pushes the current compose buffer to the user's IMAP `Drafts` folder
    /// via the `/send` Lambda's `draft=true` branch. The Lambda APPENDs the
    /// composed message with the `\Draft` flag and skips SMTP / Outbox /
    /// Sent entirely, so a saved draft surfaces on every device that lists
    /// `Drafts`.
    ///
    /// Errors propagate to the caller — the compose UI surfaces them as a
    /// banner rather than silently retrying, because losing draft text to a
    /// transient blip without telling the user is worse than asking them to
    /// retry. Local `DraftStore` autosave continues to feed the on-disk
    /// JSON copy so the draft survives a crash between Save Draft presses.
    public func saveDraft(_ message: OutgoingMessage) async throws {
        let messageID = message.messageId ?? "<\(UUID().uuidString)@\(message.from.host)>"
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
        try await Self.submit(
            stamped,
            api: apiClient,
            imapHost: configuration.imapHost,
            smtpHost: configuration.smtpHost,
            draft: true
        )
    }

    /// Activate or deactivate MetricKit diagnostic collection. The Settings
    /// toggle bridges its `Preferences.crashReportingEnabled` value into
    /// this method so a user opt-in immediately starts receiving crash and
    /// hang payloads (the next reports arrive at *the following* launch,
    /// per MetricKit's delivery semantics).
    public nonisolated func setCrashReportingEnabled(_ enabled: Bool) {
        if enabled {
            metricKitCollector.start()
        } else {
            metricKitCollector.stop()
        }
    }
}

// `submit(...)` + `shouldQueue(...)` + `SendOutcome` live in
// `CabalmailClient+Send.swift` to keep this file under the lint
// `file_length` ceiling.
