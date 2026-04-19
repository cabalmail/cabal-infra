import Foundation

/// Top-level facade for the Apple client.
///
/// Owns the `AuthService` session and exposes ready-to-use `ApiClient`,
/// `ImapClient`, and `SmtpClient` instances plus their caches. The app
/// target holds a single shared `CabalmailClient` instance in its
/// `@Observable` root and injects it into views via `.environment`.
public actor CabalmailClient {
    public let configuration: Configuration
    public let authService: AuthService
    public let apiClient: ApiClient
    public let imapClient: ImapClient
    public let smtpClient: SmtpClient
    public let addressCache: AddressCache
    public let envelopeCache: EnvelopeCache
    public let bodyCache: MessageBodyCache

    public init(
        configuration: Configuration,
        authService: AuthService,
        apiClient: ApiClient,
        imapClient: ImapClient,
        smtpClient: SmtpClient,
        addressCache: AddressCache,
        envelopeCache: EnvelopeCache,
        bodyCache: MessageBodyCache
    ) {
        self.configuration = configuration
        self.authService = authService
        self.apiClient = apiClient
        self.imapClient = imapClient
        self.smtpClient = smtpClient
        self.addressCache = addressCache
        self.envelopeCache = envelopeCache
        self.bodyCache = bodyCache
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
        return CabalmailClient(
            configuration: configuration,
            authService: auth,
            apiClient: api,
            imapClient: imap,
            smtpClient: smtp,
            addressCache: addresses,
            envelopeCache: envelopes,
            bodyCache: bodies
        )
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
}
