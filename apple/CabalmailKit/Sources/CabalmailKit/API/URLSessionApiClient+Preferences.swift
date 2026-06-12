import Foundation

// MARK: - Preferences

extension URLSessionApiClient {
    public func fetchDisplayName() async throws -> String {
        let request = try await get("/get_preferences")
        let data = try await send(request, expectedStatuses: 200..<300)
        struct Payload: Decodable { let name: String? }
        let decoded = try? JSONDecoder().decode(Payload.self, from: data)
        // A missing key (older Lambda deployment) reads the same as an
        // unset name: empty string.
        return decoded?.name ?? ""
    }

    public func updateDisplayName(_ name: String) async throws {
        let request = try await put("/set_preferences", json: ["name": name])
        _ = try await send(request, expectedStatuses: 200..<300)
    }
}
