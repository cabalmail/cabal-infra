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

    public func fetchSyncedSettings() async throws -> SyncedSettingsRow {
        let request = try await get("/get_preferences")
        let data = try await send(request, expectedStatuses: 200..<300)
        return try decodeReply(SyncedSettingsPayload.self, from: data, for: request).row
    }

    public func saveSyncedSettings(
        _ changes: [String: String], expectedVersion: Int?
    ) async throws -> SyncedSettingsSaveResult {
        // Wrap in the `app` envelope: set_preferences merges per key, so
        // this writes only these members of the `app` map and leaves
        // `name` and the web client's theme/accent/density untouched.
        var body: [String: Any] = ["app": changes]
        if let expectedVersion { body["expectedVersion"] = expectedVersion }
        let request = try await put("/set_preferences", json: body)
        do {
            let data = try await send(request, expectedStatuses: 200..<300)
            // A server that predates the version answers none.
            let answered = try? JSONDecoder().decode(SyncedSettingsPayload.self, from: data)
            return .saved(version: answered?.version)
        } catch CabalmailError.http(409, let body) {
            // The row as it is now, in `/get_preferences`' shape.
            return .stale(try decodeReply(SyncedSettingsPayload.self, from: Data(body.utf8), for: request).row)
        }
    }
}

/// `/get_preferences`' reply, and the body of `/set_preferences`' 409: the
/// part of the row the Apple clients read.
private struct SyncedSettingsPayload: Decodable {
    /// Absent for a user who has only ever used the web client.
    let app: [String: String]?
    /// Absent from a server that predates the version.
    let version: Int?

    var row: SyncedSettingsRow { SyncedSettingsRow(app: app ?? [:], version: version) }
}
