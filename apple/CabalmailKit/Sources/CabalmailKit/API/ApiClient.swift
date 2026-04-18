import Foundation

/// Cabalmail-specific HTTP endpoints fronted by API Gateway + Lambda.
///
/// Per the Phase 3 plan (`docs/0.6.0/ios-client-plan.md`), these are the only
/// endpoints the Apple client still needs server-side: mail operations speak
/// IMAP/SMTP directly. That's `list` / `new` / `revoke` for addresses, plus
/// `fetch_bimi` for the BIMI logo lookup surfaced next to the From field in
/// the message view.
public protocol ApiClient: Sendable {
    func listAddresses() async throws -> [Address]

    func newAddress(
        username: String,
        subdomain: String,
        tld: String,
        comment: String?,
        address: String
    ) async throws

    func revokeAddress(address: String, subdomain: String, tld: String, publicKey: String?) async throws

    /// Returns the BIMI logo URL for the sender domain, or nil if the domain
    /// has no BIMI record. The Lambda returns a JSON object shaped
    /// `{"url": "..."}`; a 404 / missing key maps to nil.
    func fetchBimiURL(senderDomain: String) async throws -> URL?
}

/// URLSession-backed implementation. Token attachment and 401 retry logic
/// live here so every endpoint benefits, matching the React app's axios
/// interceptor pattern.
public actor URLSessionApiClient: ApiClient {
    private let configuration: Configuration
    private let authService: AuthService
    private let transport: HTTPTransport

    public init(
        configuration: Configuration,
        authService: AuthService,
        transport: HTTPTransport = URLSessionHTTPTransport()
    ) {
        self.configuration = configuration
        self.authService = authService
        self.transport = transport
    }

    // MARK: - Addresses

    public func listAddresses() async throws -> [Address] {
        let request = try await get("/list")
        let data = try await send(request, expectedStatuses: 200..<300)
        // The list Lambda returns either a JSON array directly or `{"addresses": [...]}`.
        // Support both shapes so we decouple the client from the exact Lambda wire.
        if let direct = try? JSONDecoder().decode([Address].self, from: data) {
            return direct
        }
        struct Wrapper: Decodable { let addresses: [Address] }
        return try JSONDecoder().decode(Wrapper.self, from: data).addresses
    }

    public func newAddress(
        username: String,
        subdomain: String,
        tld: String,
        comment: String?,
        address: String
    ) async throws {
        let body: [String: Any?] = [
            "username": username,
            "subdomain": subdomain,
            "tld": tld,
            "comment": comment,
            "address": address,
        ]
        let request = try await post("/new", json: body.compactMapValues { $0 })
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    public func revokeAddress(
        address: String,
        subdomain: String,
        tld: String,
        publicKey: String?
    ) async throws {
        let body: [String: Any?] = [
            "address": address,
            "subdomain": subdomain,
            "tld": tld,
            "public_key": publicKey,
        ]
        let request = try await delete("/revoke", json: body.compactMapValues { $0 })
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    // MARK: - BIMI

    public func fetchBimiURL(senderDomain: String) async throws -> URL? {
        var request = try await get("/fetch_bimi")
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "sender_domain", value: senderDomain)
        ]
        request.url = components.url
        let data = try await send(request, expectedStatuses: 200..<300)
        struct Payload: Decodable { let url: String? }
        let decoded = try? JSONDecoder().decode(Payload.self, from: data)
        guard let raw = decoded?.url, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    // MARK: - Wire helpers

    private func endpointURL(_ path: String) -> URL {
        // `invokeUrl` is the API Gateway stage URL; paths in the Lambda layer
        // sit directly under it (see `terraform/infra/modules/app/apigw.tf`).
        configuration.invokeUrl.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }

    private func get(_ path: String) async throws -> URLRequest {
        var request = URLRequest(url: endpointURL(path))
        request.httpMethod = "GET"
        return try await attachAuth(request)
    }

    private func post(_ path: String, json: [String: Any]) async throws -> URLRequest {
        var request = URLRequest(url: endpointURL(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await attachAuth(request)
    }

    private func delete(_ path: String, json: [String: Any]) async throws -> URLRequest {
        var request = URLRequest(url: endpointURL(path))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await attachAuth(request)
    }

    private func attachAuth(_ base: URLRequest) async throws -> URLRequest {
        var request = base
        let token = try await authService.currentIdToken()
        request.setValue(token, forHTTPHeaderField: "Authorization")
        return request
    }

    /// Sends a request with automatic one-shot retry on HTTP 401. The first
    /// 401 forces a token refresh via `AuthService.currentIdToken()` and
    /// replays the request with the new token attached; a second 401 surfaces
    /// as `.authExpired` so the UI can send the user back to the sign-in view.
    private func send(_ request: URLRequest, expectedStatuses: Range<Int>) async throws -> Data {
        let (data, response) = try await transport.perform(request)
        if response.statusCode == 401 {
            var replayed = request
            // Drop the stale token before asking for a fresh one so a cached
            // hit doesn't reattach the token the server just rejected.
            replayed.setValue(nil, forHTTPHeaderField: "Authorization")
            let refreshed = try await authService.currentIdToken()
            replayed.setValue(refreshed, forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await transport.perform(replayed)
            if retryResponse.statusCode == 401 {
                throw CabalmailError.authExpired
            }
            guard expectedStatuses.contains(retryResponse.statusCode) else {
                throw CabalmailError.server(
                    code: String(retryResponse.statusCode),
                    message: String(data: retryData, encoding: .utf8) ?? ""
                )
            }
            return retryData
        }
        guard expectedStatuses.contains(response.statusCode) else {
            throw CabalmailError.server(
                code: String(response.statusCode),
                message: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }
}
