import Foundation

// MARK: - URLSession-backed implementation

/// URLSession-backed implementation. Token attachment and 401 retry logic
/// live here so every endpoint benefits, matching the React app's axios
/// interceptor pattern.
///
/// Method groups are split across `URLSessionApiClient.swift` (state,
/// addresses, folders, wire helpers) and `URLSessionApiClient+Messages.swift`
/// (messages, operations, send) so each file stays under SwiftLint's
/// `file_length` limit. Wire helpers are `internal` rather than `private`
/// so the message-extension file can reach them.
public actor URLSessionApiClient: ApiClient {
    let configuration: Configuration
    let authService: AuthService
    let transport: HTTPTransport

    public init(
        configuration: Configuration,
        authService: AuthService,
        transport: HTTPTransport = URLSessionHTTPTransport()
    ) {
        self.configuration = configuration
        self.authService = authService
        self.transport = transport
    }
}

// MARK: - Addresses

extension URLSessionApiClient {
    public func listAddresses() async throws -> [Address] {
        let request = try await get("/list")
        let data = try await send(request, expectedStatuses: 200..<300)
        // The `/list` Lambda actually returns `{"Items": [...]}` — a thin
        // wrapper over the DynamoDB scan output (see
        // `lambda/api/list/function.py`). Check that first, with the plain
        // array and `{"addresses": [...]}` kept as fallbacks in case the
        // Lambda wire changes.
        if let wrapped = try? JSONDecoder().decode(ItemsWrapper.self, from: data) {
            return wrapped.Items
        }
        if let direct = try? JSONDecoder().decode([Address].self, from: data) {
            return direct
        }
        return try JSONDecoder().decode(LowercaseAddressesWrapper.self, from: data).addresses
    }

    // The `Items` key is PascalCase because the Lambda emits the shape
    // DynamoDB's scan response uses; the struct name is uppercased to match
    // so Codable finds the key without a custom CodingKeys map.
    private struct ItemsWrapper: Decodable {
        // swiftlint:disable:next identifier_name
        let Items: [Address]
    }

    private struct LowercaseAddressesWrapper: Decodable {
        let addresses: [Address]
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

    public func setFavorite(address: String, favorite: Bool) async throws {
        let request = try await put("/set_favorite", json: [
            "address": address,
            "favorite": favorite,
        ])
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    public func fetchBimiURL(senderDomain: String) async throws -> URL? {
        let request = try await get(
            "/fetch_bimi",
            query: [URLQueryItem(name: "sender_domain", value: senderDomain)]
        )
        let data = try await send(request, expectedStatuses: 200..<300)
        struct Payload: Decodable { let url: String? }
        let decoded = try? JSONDecoder().decode(Payload.self, from: data)
        guard let raw = decoded?.url, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}

// MARK: - Folders

extension URLSessionApiClient {
    public func listFolders(host: String) async throws -> ApiFolderList {
        let request = try await get("/list_folders", query: [URLQueryItem(name: "host", value: host)])
        let data = try await send(request, expectedStatuses: 200..<300)
        return try JSONDecoder().decode(ApiFolderList.self, from: data)
    }

    public func createFolder(host: String, parent: String, name: String) async throws {
        let request = try await put("/new_folder", json: [
            "host": host,
            "parent": parent,
            "name": name,
        ])
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    public func deleteFolder(host: String, name: String) async throws {
        let request = try await delete("/delete_folder", json: [
            "host": host,
            "name": name,
        ])
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    public func subscribeFolder(host: String, folder: String) async throws {
        let request = try await put("/subscribe_folder", json: [
            "host": host,
            "folder": folder,
        ])
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    public func unsubscribeFolder(host: String, folder: String) async throws {
        let request = try await put("/unsubscribe_folder", json: [
            "host": host,
            "folder": folder,
        ])
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    public func folderStatus(host: String, folder: String, flagged: Bool) async throws -> ApiFolderStatus {
        var query = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "folder", value: folder),
        ]
        // Opt-in flagged count: the Lambda runs a SEARCH FLAGGED only when asked
        // (`?flagged=1`), so the badge/idle polls keep the cheap STATUS path.
        if flagged { query.append(URLQueryItem(name: "flagged", value: "1")) }
        let request = try await get("/folder_status", query: query)
        let data = try await send(request, expectedStatuses: 200..<300)
        return try JSONDecoder().decode(ApiFolderStatus.self, from: data)
    }
}

// MARK: - Wire helpers

extension URLSessionApiClient {
    private func endpointURL(_ path: String) -> URL {
        // `invokeUrl` is the API Gateway stage URL; paths in the Lambda layer
        // sit directly under it (see `terraform/infra/modules/app/apigw.tf`).
        configuration.invokeUrl.appendingPathComponent(
            path.hasPrefix("/") ? String(path.dropFirst()) : path
        )
    }

    func get(_ path: String, query: [URLQueryItem] = []) async throws -> URLRequest {
        var components = URLComponents(url: endpointURL(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return try await attachAuth(request)
    }

    func post(_ path: String, json: [String: Any]) async throws -> URLRequest {
        var request = URLRequest(url: endpointURL(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await attachAuth(request)
    }

    func put(_ path: String, json: [String: Any]) async throws -> URLRequest {
        var request = URLRequest(url: endpointURL(path))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await attachAuth(request)
    }

    func delete(_ path: String, json: [String: Any] = [:]) async throws -> URLRequest {
        var request = URLRequest(url: endpointURL(path))
        request.httpMethod = "DELETE"
        if !json.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
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
    func send(_ request: URLRequest, expectedStatuses: Range<Int>) async throws -> Data {
        let (data, response) = try await transport.perform(request)
        if response.statusCode == 401 {
            return try await retryAfterAuthRefresh(request, expectedStatuses: expectedStatuses)
        }
        guard expectedStatuses.contains(response.statusCode) else {
            if let maintenance = cabalMaintenanceError(data, response) { throw maintenance }
            throw CabalmailError.server(
                code: String(response.statusCode),
                message: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }

    private func retryAfterAuthRefresh(
        _ original: URLRequest,
        expectedStatuses: Range<Int>
    ) async throws -> Data {
        var replayed = original
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
            if let maintenance = cabalMaintenanceError(retryData, retryResponse) { throw maintenance }
            throw CabalmailError.server(
                code: String(retryResponse.statusCode),
                message: String(data: retryData, encoding: .utf8) ?? ""
            )
        }
        return retryData
    }
}

/// Shape of the API's planned-maintenance 503 body
/// (`lambda/api/_shared/helper.py` `maintenance_response`).
private struct CabalMaintenanceBody: Decodable {
    let status: String
    let message: String?
}

/// Maps a 503 `{"status":"maintenance"}` response to `.maintenance` so an IMAP
/// redeploy surfaces friendly "temporarily unavailable" copy instead of a
/// generic `.server` error. Returns nil for any other status or body shape, so
/// unrelated 503s fall through to the normal error path.
private func cabalMaintenanceError(
    _ data: Data,
    _ response: HTTPURLResponse
) -> CabalmailError? {
    guard response.statusCode == 503,
          let body = try? JSONDecoder().decode(CabalMaintenanceBody.self, from: data),
          body.status == "maintenance" else {
        return nil
    }
    return .maintenance(
        message: body.message
            ?? "Email access is temporarily unavailable due to planned maintenance."
    )
}
