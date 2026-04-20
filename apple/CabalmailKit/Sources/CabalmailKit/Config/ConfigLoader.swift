import Foundation

/// Loads the runtime `Configuration` from a control domain's `/config.json`.
///
/// Phase 1 decision #2 (see `apple/README.md`) makes the client
/// environment-agnostic: the same build works against dev/stage/prod by
/// pointing at a different control domain. This loader is what reads that
/// indirection at sign-in time.
public enum ConfigLoader {
    /// Fetches `https://{controlDomain}/config.json` and decodes it into a
    /// `Configuration`. Validates the URL scheme up front so an accidentally
    /// plain `http://` host can't leak the Cognito IDs.
    public static func load(
        controlDomain: String,
        transport: HTTPTransport = URLSessionHTTPTransport()
    ) async throws -> Configuration {
        let sanitized = controlDomain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")

        guard let url = URL(string: "https://\(sanitized)/config.json") else {
            throw CabalmailError.notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await transport.perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw CabalmailError.server(
                code: String(response.statusCode),
                message: "Failed to fetch config.json from \(sanitized)"
            )
        }
        do {
            return try JSONDecoder().decode(Configuration.self, from: data)
        } catch {
            throw CabalmailError.decoding("config.json: \(error.localizedDescription)")
        }
    }
}
