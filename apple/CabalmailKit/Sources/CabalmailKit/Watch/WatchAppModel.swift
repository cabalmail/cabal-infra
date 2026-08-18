import Foundation

/// The two Kit services a hand-off turns into: the client the model talks to,
/// and the adopt step that seeds this device's keychain from the phone's
/// tokens. Bundled so `WatchAppModel` can take both through one injection
/// point — tests supply a fake pair and never touch the network or the
/// keychain (see `WatchAppModelTests`).
public struct WatchSession {
    public let apiClient: any ApiClient
    public let adopt: (AuthTokens, String) async throws -> Void

    public init(
        apiClient: any ApiClient,
        adopt: @escaping (AuthTokens, String) async throws -> Void
    ) {
        self.apiClient = apiClient
        self.adopt = adopt
    }
}

/// Observable root for the watch app: owns the credential lifecycle and the
/// address list.
///
/// Credentials arrive from the paired iPhone as a `WatchHandoff` in the
/// WCSession application context (see WatchSessionBridge.swift on the phone
/// side) — the two devices don't share a keychain, so the session has to be
/// handed over. The watch persists the `Configuration` in UserDefaults and
/// adopts the tokens into its own keychain via `CognitoAuthService.adopt`,
/// after which it refreshes ID tokens autonomously for the refresh token's
/// lifetime. When that expires (or the phone signs out) the app falls back
/// to `.waiting`, which tells the user to open Cabalmail on their iPhone.
///
/// Lives in the Kit rather than the watch app target so `swift test` can
/// reach it (#1124): every service it depends on is already a Kit type, and
/// the one piece that is genuinely watchOS-bound — the `WCSession` delegate
/// that feeds `apply`/`clear` — stays behind in `CabalmailWatch` as
/// `WatchSessionRelay`. That split is the same one `WatchHandoff` already
/// makes: the codec is pure Foundation so it can be tested, and only the
/// transport imports WatchConnectivity.
@MainActor
@Observable
public final class WatchAppModel {
    public enum Phase {
        /// No credentials — ask the user to open the iPhone app.
        case waiting
        case loading
        case ready([Address])
        case failed(String)
    }

    public private(set) var phase: Phase = .waiting

    /// Deployment configuration from the last hand-off; drives the domain
    /// picker in the new-address flow.
    public private(set) var configuration: Configuration?

    /// Apex domains the signed-in user is entitled to mint on, per the
    /// `/list_my_domains` Lambda. Nil means "not yet fetched"; the
    /// new-address view refreshes it on appear.
    public private(set) var allowedDomainNames: Set<String>?

    /// Configured domains intersected with the caller's `/list_my_domains`
    /// allow list — the picker in `NewAddressView` reads this so the wrist
    /// never offers an apex the `/new` Lambda would then reject.
    public var domains: [MailDomain] {
        let all = configuration?.domains ?? []
        guard let allowed = allowedDomainNames else { return all }
        return all.filter { allowed.contains($0.domain) }
    }

    private let secureStore: any SecureStore
    private let defaults: UserDefaults
    private let makeSession: @MainActor (Configuration, any SecureStore) -> WatchSession
    private var apiClient: (any ApiClient)?

    private static let configurationDefaultsKey = "cabalmail.watch.configuration"

    /// - Parameter makeSession: How a `Configuration` becomes a live session.
    ///   Defaults to the real Cognito/URLSession pair; tests inject a fake.
    public init(
        secureStore: any SecureStore = KeychainSecureStore(),
        defaults: UserDefaults = .standard,
        makeSession: @escaping @MainActor (Configuration, any SecureStore) -> WatchSession = WatchAppModel.liveSession
    ) {
        self.secureStore = secureStore
        self.defaults = defaults
        self.makeSession = makeSession
    }

    /// The shipping session: a Cognito auth service and the URLSession API
    /// client that authenticates against it.
    public static func liveSession(
        configuration: Configuration,
        secureStore: any SecureStore
    ) -> WatchSession {
        let auth = CognitoAuthService(configuration: configuration, secureStore: secureStore)
        return WatchSession(
            apiClient: URLSessionApiClient(configuration: configuration, authService: auth),
            adopt: { tokens, username in try await auth.adopt(tokens: tokens, username: username) }
        )
    }

    /// Launch entry point: try to restore a previously handed-off session
    /// from local storage. Idempotent, so the app's `.task` can call it
    /// across scene re-attaches. Arming the WCSession receiver is the app
    /// target's job (`WatchSessionRelay`).
    public func start() {
        #if DEBUG
        if seedPreviewStateIfRequested() { return }
        #endif
        if apiClient == nil {
            restoreFromStorage()
        }
    }

    public func refresh() async {
        await loadAddresses()
    }

    /// Populates `allowedDomainNames` from the API. Silent-fails to "trust
    /// the configured list" so a transient error leaves the wrist usable —
    /// the `/new` Lambda is the authoritative gate either way.
    public func loadAllowedDomains() async {
        guard let apiClient else { return }
        do {
            let list = try await apiClient.listMyDomains()
            allowedDomainNames = Set(list)
        } catch {
            allowedDomainNames = Set((configuration?.domains ?? []).map(\.domain))
        }
    }

    // MARK: - Hand-off intake

    public func apply(_ handoff: WatchHandoff) {
        guard let data = try? JSONEncoder().encode(handoff.configuration) else { return }
        defaults.set(data, forKey: Self.configurationDefaultsKey)
        configuration = handoff.configuration
        let session = makeSession(handoff.configuration, secureStore)
        apiClient = session.apiClient
        Task {
            do {
                try await session.adopt(handoff.tokens, handoff.username)
                await loadAddresses()
            } catch {
                phase = .failed("Couldn't store the credentials from your iPhone.")
            }
        }
    }

    /// The phone signed out (or the session died): drop everything local.
    public func clear() {
        try? secureStore.remove(SecureStoreKey.authTokens)
        try? secureStore.remove(SecureStoreKey.imapUsername)
        defaults.removeObject(forKey: Self.configurationDefaultsKey)
        configuration = nil
        apiClient = nil
        phase = .waiting
    }

    // MARK: - Address lifecycle

    /// Mints a new relationship-scoped address and returns the composed
    /// string for the confirmation screen. The list refreshes in the
    /// background so it's current when the user dismisses.
    public func createAddress(
        username: String,
        subdomain: String,
        domain: String,
        comment: String?
    ) async throws {
        guard let apiClient else { throw CabalmailError.notSignedIn }
        let address = "\(username)@\(subdomain).\(domain)"
        try await apiClient.newAddress(
            username: username,
            subdomain: subdomain,
            tld: domain,
            comment: comment,
            address: address
        )
        Task { await loadAddresses() }
    }

    /// Revokes a burned address. The row is pruned locally only after the
    /// call succeeds (mirroring the iOS view model) — a failed revoke must
    /// not make the address look gone while it still delivers.
    public func revoke(_ address: Address) async {
        guard let apiClient else { return }
        do {
            try await apiClient.revokeAddress(
                address: address.address,
                subdomain: address.subdomain,
                tld: address.tld,
                publicKey: address.publicKey
            )
            if case .ready(let addresses) = phase {
                phase = .ready(addresses.filter { $0.address != address.address })
            }
        } catch {
            // Re-sync with the server rather than guessing at state; if the
            // API is down this lands on the retry-able failure screen.
            await loadAddresses()
        }
    }

    /// Suspends or reinstates an address. The row is updated locally only
    /// after the call succeeds (same rationale as revoke): a failed suspend
    /// must not make the address look paused while it still delivers.
    public func setSuspended(_ address: Address, to suspended: Bool) async {
        guard let apiClient else { return }
        do {
            if suspended {
                try await apiClient.suspendAddress(address: address.address)
            } else {
                try await apiClient.reinstateAddress(address: address.address)
            }
            if case .ready(let addresses) = phase {
                phase = .ready(addresses.map {
                    var updated = $0
                    if updated.address == address.address {
                        updated.suspended = suspended
                    }
                    return updated
                })
            }
        } catch {
            // Re-sync with the server rather than guessing at state.
            await loadAddresses()
        }
    }

    // MARK: - Internals

    private func restoreFromStorage() {
        guard
            let data = defaults.data(forKey: Self.configurationDefaultsKey),
            let configuration = try? JSONDecoder().decode(Configuration.self, from: data),
            ((try? secureStore.get(SecureStoreKey.authTokens)) ?? nil) != nil
        else {
            phase = .waiting
            return
        }
        self.configuration = configuration
        apiClient = makeSession(configuration, secureStore).apiClient
        Task { await loadAddresses() }
    }

    private func loadAddresses() async {
        guard let apiClient else { return }
        phase = .loading
        do {
            let addresses = try await apiClient.listAddresses()
            phase = .ready(addresses.sorted { lhs, rhs in
                if lhs.favorite != rhs.favorite {
                    return lhs.favorite
                }
                return lhs.address.localizedCaseInsensitiveCompare(rhs.address) == .orderedAscending
            })
        } catch let error as CabalmailError {
            switch error {
            case .authExpired, .invalidCredentials, .notSignedIn:
                // The refresh token is gone — a stale session shouldn't keep
                // failing quietly. Back to the reconnect prompt.
                clear()
            default:
                phase = .failed("Couldn't load your addresses.")
            }
        } catch {
            phase = .failed("Couldn't load your addresses.")
        }
    }
}

#if DEBUG
extension WatchAppModel {
    /// Simulator/screenshot scaffolding. The watch can't sign in by itself,
    /// so every state past `.waiting` is unreachable without a paired,
    /// signed-in iPhone — which automated visual checks don't have. Launching
    /// with CABAL_WATCH_PREVIEW=list (or =new, which additionally auto-pushes
    /// the new-address flow) seeds a fake signed-in session instead. The API
    /// client stays nil, so nothing can reach the network from this state.
    public var previewAutoPushNewAddress: Bool {
        ["new", "created"].contains(
            ProcessInfo.processInfo.environment["CABAL_WATCH_PREVIEW"] ?? ""
        )
    }

    public var previewAutoPushDetail: Bool {
        ProcessInfo.processInfo.environment["CABAL_WATCH_PREVIEW"] == "detail"
    }

    fileprivate func seedPreviewStateIfRequested() -> Bool {
        guard let mode = ProcessInfo.processInfo.environment["CABAL_WATCH_PREVIEW"],
              ["list", "new", "created", "detail"].contains(mode) else {
            return false
        }
        configuration = Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.com"), MailDomain(domain: "cabalmail.net")],
            invokeUrl: URL(string: "https://api.invalid/preview")!,
            cognito: .init(region: "us-east-1", userPoolId: "preview", clientId: "preview")
        )
        phase = .ready([
            Address(
                address: "h7k2m9pq@x4n8w2jb.cabalmail.com",
                subdomain: "x4n8w2jb",
                tld: "cabalmail.com",
                comment: "Hardware store",
                favorite: true
            ),
            Address(
                address: "q3v8t1zr@p9c5d7ka.cabalmail.com",
                subdomain: "p9c5d7ka",
                tld: "cabalmail.com",
                comment: "Newsletter"
            ),
            Address(
                address: "b2f6s4mx@r8g3h5ne.cabalmail.net",
                subdomain: "r8g3h5ne",
                tld: "cabalmail.net"
            ),
        ])
        return true
    }
}
#endif
