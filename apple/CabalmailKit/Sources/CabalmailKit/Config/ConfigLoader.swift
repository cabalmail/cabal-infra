import Foundation

/// Loads the runtime `Configuration` from a control domain's `/config.json`.
///
/// Phase 1 decision #2 (see `docs/apple.md`) makes the client
/// environment-agnostic: the same build works against dev/stage/prod by
/// pointing at a different control domain. This loader is what reads that
/// indirection at sign-in time.
public enum ConfigLoader {
    /// Fetches `https://{controlDomain}/config.json` and decodes it into a
    /// `Configuration`. Validates the URL scheme up front so an accidentally
    /// plain `http://` host can't leak the Cognito IDs.
    ///
    /// With a `cache`, a successful fetch is remembered for the domain and a
    /// failed one falls back to the remembered copy, so a launch with no
    /// network still gets a configuration instead of landing on the sign-in
    /// form. Only failures that say nothing about whether
    /// the remembered copy is still right fall back: no network, a non-2xx
    /// or undecodable body (a captive portal answers with its own page). The
    /// original error is rethrown when nothing is cached.
    public static func load(
        controlDomain: String,
        transport: HTTPTransport = URLSessionHTTPTransport(),
        cache: ConfigurationCache? = nil
    ) async throws -> Configuration {
        let sanitized = controlDomain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")

        guard let url = URL(string: "https://\(sanitized)/config.json") else {
            throw CabalmailError.notConfigured
        }

        do {
            let configuration = try await fetch(url: url, domain: sanitized, transport: transport)
            cache?.save(configuration, controlDomain: sanitized)
            return configuration
        } catch let error as CabalmailError where error.allowsCachedConfiguration {
            if let cached = cache?.load(controlDomain: sanitized) {
                return cached
            }
            throw error
        }
    }

    private static func fetch(
        url: URL,
        domain: String,
        transport: HTTPTransport
    ) async throws -> Configuration {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await transport.perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw CabalmailError.server(
                code: String(response.statusCode),
                message: "Failed to fetch config.json from \(domain)"
            )
        }
        do {
            return try JSONDecoder().decode(Configuration.self, from: data)
        } catch {
            throw CabalmailError.decoding("config.json: \(error.localizedDescription)")
        }
    }
}

private extension CabalmailError {
    var allowsCachedConfiguration: Bool {
        switch self {
        case .server, .decoding:
            return true
        default:
            return isUnreachable
        }
    }
}

/// The last good `Configuration` per control domain, in plain
/// `UserDefaults`. `config.json` is public and per deployment, not per
/// account, so it is not cleared on sign-out: the next sign-in against the
/// same domain is served the same file anyway.
///
/// `@unchecked Sendable` for its one stored property: `UserDefaults` is
/// documented thread-safe but Foundation does not mark it `Sendable`.
public final class ConfigurationCache: @unchecked Sendable {
    public static let keyPrefix = "cabalmail.config."

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(controlDomain: String) -> Configuration? {
        guard let data = defaults.data(forKey: Self.key(controlDomain)) else { return nil }
        return try? JSONDecoder().decode(Configuration.self, from: data)
    }

    public func save(_ configuration: Configuration, controlDomain: String) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: Self.key(controlDomain))
    }

    private static func key(_ controlDomain: String) -> String {
        keyPrefix + controlDomain.lowercased()
    }
}
