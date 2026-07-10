import CabalmailKit
import Foundation
import WatchConnectivity

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
@MainActor
@Observable
final class WatchAppModel {
    enum Phase {
        /// No credentials — ask the user to open the iPhone app.
        case waiting
        case loading
        case ready([Address])
        case failed(String)
    }

    private(set) var phase: Phase = .waiting

    private let secureStore: any SecureStore
    private let defaults: UserDefaults
    private var apiClient: URLSessionApiClient?
    /// Retains the WCSession delegate (the session holds it weakly).
    private var sessionRelay: SessionRelay?

    private static let configurationDefaultsKey = "cabalmail.watch.configuration"

    init(secureStore: any SecureStore = KeychainSecureStore(), defaults: UserDefaults = .standard) {
        self.secureStore = secureStore
        self.defaults = defaults
    }

    /// Launch entry point: arm the WCSession receiver and try to restore a
    /// previously handed-off session from local storage. Idempotent, so the
    /// app's `.task` can call it across scene re-attaches.
    func start() {
        activateSessionIfPossible()
        if apiClient == nil {
            restoreFromStorage()
        }
    }

    func refresh() async {
        await loadAddresses()
    }

    // MARK: - Hand-off intake

    func apply(_ handoff: WatchHandoff) {
        guard let data = try? JSONEncoder().encode(handoff.configuration) else { return }
        defaults.set(data, forKey: Self.configurationDefaultsKey)
        let auth = CognitoAuthService(
            configuration: handoff.configuration,
            secureStore: secureStore
        )
        apiClient = URLSessionApiClient(
            configuration: handoff.configuration,
            authService: auth
        )
        Task {
            do {
                try await auth.adopt(tokens: handoff.tokens, username: handoff.username)
                await loadAddresses()
            } catch {
                phase = .failed("Couldn't store the credentials from your iPhone.")
            }
        }
    }

    /// The phone signed out (or the session died): drop everything local.
    func clear() {
        try? secureStore.remove(SecureStoreKey.authTokens)
        try? secureStore.remove(SecureStoreKey.imapUsername)
        defaults.removeObject(forKey: Self.configurationDefaultsKey)
        apiClient = nil
        phase = .waiting
    }

    // MARK: - Internals

    private func activateSessionIfPossible() {
        guard WCSession.isSupported(), sessionRelay == nil else { return }
        let relay = SessionRelay(model: self)
        sessionRelay = relay
        let session = WCSession.default
        session.delegate = relay
        session.activate()
    }

    private func restoreFromStorage() {
        guard
            let data = defaults.data(forKey: Self.configurationDefaultsKey),
            let configuration = try? JSONDecoder().decode(Configuration.self, from: data),
            ((try? secureStore.get(SecureStoreKey.authTokens)) ?? nil) != nil
        else {
            phase = .waiting
            return
        }
        let auth = CognitoAuthService(configuration: configuration, secureStore: secureStore)
        apiClient = URLSessionApiClient(configuration: configuration, authService: auth)
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

/// WCSession delegate. Split out of the model because WCSession requires an
/// NSObject delegate and calls it on its own queue; the relay decodes the
/// context off the main actor (`WatchHandoff` is Sendable, the raw context
/// dictionary is not) and hops to the model with the typed result.
private final class SessionRelay: NSObject, WCSessionDelegate {
    private weak var model: WatchAppModel?

    init(model: WatchAppModel) {
        self.model = model
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        guard activationState == .activated else { return }
        // A context pushed while this app was dead is waiting on the
        // session rather than being redelivered through the delegate.
        let context = session.receivedApplicationContext
        guard !context.isEmpty else { return }
        dispatch(context)
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        dispatch(context)
    }

    private func dispatch(_ context: [String: Any]) {
        if let handoff = WatchHandoff.from(applicationContext: context) {
            Task { @MainActor [weak model] in model?.apply(handoff) }
        } else if WatchHandoff.isSignedOut(applicationContext: context) {
            Task { @MainActor [weak model] in model?.clear() }
        }
        // Unknown version → ignore. An out-of-step phone app shouldn't
        // wipe a working watch session.
    }
}
