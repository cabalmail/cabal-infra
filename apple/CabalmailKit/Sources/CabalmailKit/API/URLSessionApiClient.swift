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
    /// Announces the second 401 below as an ended session (issue #1703).
    /// Optional because tests construct the client without a listener.
    let sessionInvalidation: SessionInvalidationMonitor?

    public init(
        configuration: Configuration,
        authService: AuthService,
        transport: HTTPTransport = URLSessionHTTPTransport(),
        sessionInvalidation: SessionInvalidationMonitor? = nil
    ) {
        self.configuration = configuration
        self.authService = authService
        self.transport = transport
        self.sessionInvalidation = sessionInvalidation
    }
}

// MARK: - Addresses

extension URLSessionApiClient {
    public func listAddresses() async throws -> [Address] {
        let request = try await get("/list")
        let data = try await send(request, expectedStatuses: 200..<300)
        // The `/list` Lambda actually returns `{"Items": [...]}` — a thin
        // wrapper over the DynamoDB scan output (see
        // `lambda/api/list/function.py`). The plain array and
        // `{"addresses": [...]}` are fallbacks in case the Lambda wire
        // changes, tried first so that the strict decode is the real shape:
        // when nothing fits, the error and the log name where an `Items`
        // reply stopped (`Items[3].subdomain`), not a missing `addresses`.
        if let direct = try? JSONDecoder().decode([Address].self, from: data) {
            return direct
        }
        if let lowercase = try? JSONDecoder().decode(LowercaseAddressesWrapper.self, from: data) {
            return lowercase.addresses
        }
        return try decodeReply(ItemsWrapper.self, from: data, for: request).Items
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

    public func suspendAddress(address: String) async throws {
        let request = try await put("/suspend_address", json: [
            "address": address,
        ])
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    public func reinstateAddress(address: String) async throws {
        let request = try await put("/reinstate_address", json: [
            "address": address,
        ])
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
        // An answer that isn't a followable URL (the signing failure's
        // "Error", #1804) is a failed lookup, not "no logo": thrown, so
        // `BimiUrlCache` asks again rather than caching a blank avatar.
        guard let url = URL(followableReplyString: raw) else {
            throw CabalmailError.decoding("fetch_bimi returned invalid url")
        }
        return url
    }

    public func listMyDomains() async throws -> [String] {
        let request = try await get("/list_my_domains")
        let data = try await send(request, expectedStatuses: 200..<300)
        // Real Lambda wire shape (`lambda/api/list_my_domains/function.py`):
        // `{"Domains": [<apex>...]}`. A missing or non-list key reads as
        // "no allowed apexes" rather than an error, so a partially-migrated
        // deployment surfaces an explicit empty picker instead of crashing.
        struct Payload: Decodable {
            // swiftlint:disable:next identifier_name
            let Domains: [String]?
        }
        let decoded = try? JSONDecoder().decode(Payload.self, from: data)
        return decoded?.Domains ?? []
    }
}

// MARK: - Folders

extension URLSessionApiClient {
    public func listFolders(host: String) async throws -> ApiFolderList {
        let request = try await get("/list_folders", query: [URLQueryItem(name: "host", value: host)])
        let data = try await send(request, expectedStatuses: 200..<300)
        return try decodeReply(ApiFolderList.self, from: data, for: request)
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
        return try decodeReply(ApiFolderStatus.self, from: data, for: request)
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
    /// 401 forces a token refresh via `AuthService.refreshIdToken(replacing:)`
    /// and replays the request with the new token attached; a second 401
    /// surfaces as `.authExpired` so the UI can send the user back to the
    /// sign-in view.
    func send(_ request: URLRequest, expectedStatuses: Range<Int>) async throws -> Data {
        let (data, response) = try await transport.perform(request)
        if response.statusCode == 401 {
            return try await retryAfterAuthRefresh(request, expectedStatuses: expectedStatuses)
        }
        guard expectedStatuses.contains(response.statusCode) else {
            if let maintenance = cabalMaintenanceError(data, response) { throw maintenance }
            throw CabalmailError.http(status: response.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func retryAfterAuthRefresh(
        _ original: URLRequest,
        expectedStatuses: Range<Int>
    ) async throws -> Data {
        var replayed = original
        // Not `currentIdToken()`: by the local clock the rejected token can
        // still look fresh (a skewed clock, a revoked token), and that call
        // would hand it straight back. Passing the rejected token lets a
        // burst of 401s share one refresh.
        let rejected = original.value(forHTTPHeaderField: "Authorization")
        let refreshed = try await authService.refreshIdToken(replacing: rejected)
        replayed.setValue(refreshed, forHTTPHeaderField: "Authorization")
        let (retryData, retryResponse) = try await transport.perform(replayed)
        if retryResponse.statusCode == 401 {
            // The server rejected a token we had just refreshed: the session
            // is over, not stale. Announce before throwing so the app tears
            // it down once rather than the caller printing the error.
            sessionInvalidation?.sessionDidExpire()
            throw CabalmailError.authExpired
        }
        guard expectedStatuses.contains(retryResponse.statusCode) else {
            if let maintenance = cabalMaintenanceError(retryData, retryResponse) { throw maintenance }
            throw CabalmailError.http(
                status: retryResponse.statusCode,
                body: String(data: retryData, encoding: .utf8) ?? ""
            )
        }
        return retryData
    }

    /// Decodes a 2xx reply to `request` as `type`. Every strict decode in the
    /// client goes through here, so a reply that doesn't parse (an HTML
    /// error page or an empty body behind a 200, or a shape that drifted from
    /// the Lambda's) throws `CabalmailError.decoding` naming the endpoint,
    /// rather than letting `Swift.DecodingError` out of the package to be
    /// shown with Foundation's generic copy (#1805). The log line says where
    /// the decode stopped, never what the body held, because replies carry
    /// message content. Reads that deliberately fall back to a default on an
    /// unparseable body keep their `try?` at the call site.
    func decodeReply<T: Decodable>(_ type: T.Type, from data: Data, for request: URLRequest) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            let endpoint = request.url?.lastPathComponent ?? "The API"
            CabalmailLog.warn("API", "\(endpoint) reply didn't decode as \(T.self): \(error.whereItStopped)")
            throw CabalmailError.decoding("\(endpoint) returned an unexpected reply")
        }
    }
}

private extension DecodingError {
    /// The failure's kind and coding path (`uploads[0].url`) and nothing
    /// else: `debugDescription` and the underlying error can quote the
    /// reply ("Unexpected character '<' around line 1, column 1").
    var whereItStopped: String {
        switch self {
        case .typeMismatch(let type, let context):
            return "expected \(type) at \(Self.path(context))"
        case .valueNotFound(let type, let context):
            return "no \(type) value at \(Self.path(context))"
        case .keyNotFound(let key, let context):
            return "no \"\(key.stringValue)\" key at \(Self.path(context))"
        case .dataCorrupted(let context):
            return "unreadable data at \(Self.path(context))"
        @unknown default:
            return "an unknown decoding failure"
        }
    }

    static func path(_ context: Context) -> String {
        let path = context.codingPath.reduce(into: "") { path, key in
            if let index = key.intValue {
                path += "[\(index)]"
            } else {
                path += path.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return path.isEmpty ? "the top level" : path
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
/// generic `.http` error. Returns nil for any other status or body shape, so
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
