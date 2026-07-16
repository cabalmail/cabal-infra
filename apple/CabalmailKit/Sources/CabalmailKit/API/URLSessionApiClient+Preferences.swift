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

    public func fetchAppPreferences() async throws -> [String: String] {
        let request = try await get("/get_preferences")
        let data = try await send(request, expectedStatuses: 200..<300)
        struct Payload: Decodable { let app: [String: String]? }
        let decoded = try? JSONDecoder().decode(Payload.self, from: data)
        // A missing `app` key (older Lambda deployment, or a user who has
        // only ever used the web client) reads as "no synced preferences".
        return decoded?.app ?? [:]
    }

    public func saveAppPreferences(_ prefs: [String: String]) async throws {
        // Wrap in the `app` envelope: set_preferences merges per top-level
        // key, so this replaces only the `app` map and leaves `name` and the
        // web client's theme/accent/density untouched.
        let request = try await put("/set_preferences", json: ["app": prefs])
        _ = try await send(request, expectedStatuses: 200..<300)
    }
}
