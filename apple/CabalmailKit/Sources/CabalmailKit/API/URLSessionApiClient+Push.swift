import Foundation

// MARK: - Push notifications
//
// The `/push_register` / `/push_deregister` Lambdas maintain the
// `cabal-push-tokens` table the push-dispatch Lambda fans out to (see
// `docs/0.11.x/push-notifications.md`). Same wire conventions as every
// other endpoint: flat path under the API Gateway stage, Cognito ID token
// in the Authorization header, snake_case JSON body.

extension URLSessionApiClient {
    public func registerPushDevice(_ registration: PushDeviceRegistration) async throws {
        var body: [String: Any] = [
            "device_token": registration.deviceToken,
            "bundle_id": registration.bundleId,
            "platform": registration.platform,
            "app_version": registration.appVersion,
            "locale": registration.locale,
        ]
        // Omitted (not null) when unset, so the Lambda's upsert preserves
        // whatever folder selection the row already carries.
        if let folders = registration.enabledFolders {
            body["enabled_folders"] = folders
        }
        let request = try await post("/push_register", json: body)
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    public func deregisterPushDevice(token: String) async throws {
        let request = try await post("/push_deregister", json: [
            "device_token": token,
        ])
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    public func fetchPushEnvelope(
        folder: String,
        uid: UInt32?,
        messageID: String?
    ) async throws -> PushEnvelope {
        var body: [String: Any] = ["folder": folder]
        // Omitted (not null) when unset — same posture as the NSE's
        // `EnvelopeQuery.requestBody`; the Lambda resolves by whichever
        // coordinates it receives (msg_id authoritative, uid a hint).
        if let uid { body["uid"] = Int(uid) }
        if let messageID { body["msg_id"] = messageID }
        let request = try await post("/push_envelope", json: body)
        let data = try await send(request, expectedStatuses: 200..<300)
        return try JSONDecoder().decode(PushEnvelope.self, from: data)
    }
}
