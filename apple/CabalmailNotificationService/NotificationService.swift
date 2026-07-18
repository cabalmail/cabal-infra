import Foundation
import os
import Security
import UserNotifications

/// Fallback-path diagnostics. The *user-facing* posture stays silent (any
/// failure ships the generic "New mail"), but each bail-out logs its reason
/// so a `log show --predicate 'subsystem == "com.cabalmail.nse"'` names the
/// failing guard instead of requiring elimination — the macOS keychain gap
/// that motivated this took a whole debugging session to localize without it.
let nseLog = Logger(subsystem: "com.cabalmail.nse", category: "enrich")

/// Notification Service Extension: enriches the wake-signal push.
///
/// The APNs payload deliberately carries no message content — just
/// `{"aps": {"alert": "New mail", "mutable-content": 1, ...},
///   "msgRef": {"folder": "INBOX", "uid": 4271, "msg_id": "<...>"}}`
/// (see docs/0.11.0/push-notifications.md). This extension wakes on each
/// delivery, calls the `/push_envelope` Lambda with the Cognito ID token
/// the main app mirrors for it, and rewrites the alert into
/// sender / subject / snippet. Any failure — no credentials, expired
/// token, timeout, non-2xx, undecodable body — delivers the original
/// "New mail" content instead. Never block, never crash: a hung NSE gets
/// its process killed and the user sees nothing at all.
///
/// Deliberately tiny: Foundation + UserNotifications only, no CabalmailKit.
/// The two inputs arrive via containers both processes share (written by
/// CabalmailKit's `PushEnrichmentStore`):
/// - `api_url` in the App Group `UserDefaults`, and
/// - the ID token JSON in the shared keychain access group.
final class NotificationService: UNNotificationServiceExtension {
    private let state = DeliveryState()

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        state.begin(content: request.content, handler: contentHandler)
        guard let query = EnvelopeQuery(userInfo: request.content.userInfo) else {
            nseLog.error("fallback: no parseable msgRef in payload")
            state.deliverFallback()
            return
        }
        guard let endpoint = PushHandoff.enrichmentEndpoint() else {
            nseLog.error("fallback: no api_url in the App Group container")
            state.deliverFallback()
            return
        }
        guard let token = PushHandoff.currentIdToken() else {
            nseLog.error("fallback: no usable ID token in the shared keychain")
            state.deliverFallback()
            return
        }
        let state = self.state
        // The region-isolation checker emits a spurious "pattern ... does
        // not understand" warning for this Task even though every capture
        // is Sendable (endpoint/token/query are value types; DeliveryState
        // is @unchecked Sendable with lock-guarded state). Extraction,
        // Task.detached, and nonisolated(unsafe) on the local (Xcode 26.6
        // toolchain - it warns "unnecessary" and changes nothing) all fail
        // to silence it; accepted as noise until a toolchain fixes the
        // checker or the Swift 6 language-mode migration forces the issue.
        Task {
            let envelope = await Self.fetchEnvelope(endpoint: endpoint, token: token, query: query)
            state.deliver(envelope)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Out of wall time: ship whatever we have (the unenriched original —
        // an enriched copy would already have been delivered).
        state.deliverFallback()
    }

    /// One POST to `/push_envelope`. The 8-second timeout leaves headroom
    /// inside the NSE's ~30s budget for `serviceExtensionTimeWillExpire`
    /// to deliver the fallback cleanly.
    private static func fetchEnvelope(
        endpoint: URL,
        token: String,
        query: EnvelopeQuery
    ) async -> PushEnvelope? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: query.requestBody) else {
            return nil
        }
        request.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            nseLog.error("fallback: /push_envelope request failed (network)")
            return nil
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            nseLog.error("fallback: /push_envelope returned \(status)")
            return nil
        }
        guard let envelope = try? JSONDecoder().decode(PushEnvelope.self, from: data) else {
            nseLog.error("fallback: /push_envelope response failed to decode")
            return nil
        }
        return envelope
    }
}

/// The `msgRef` coordinates, parsed from the payload. `uid` is a
/// best-effort hint; `msg_id` is authoritative — both are forwarded and
/// `/push_envelope` resolves the real uid server-side.
private struct EnvelopeQuery: Sendable {
    let folder: String
    let uid: UInt32?
    let messageID: String?

    init?(userInfo: [AnyHashable: Any]) {
        guard
            let ref = userInfo["msgRef"] as? [String: Any],
            let folder = ref["folder"] as? String, !folder.isEmpty
        else { return nil }
        self.folder = folder
        // 0 is the dispatch Lambda's explicit "no hint" sentinel (procmail
        // could not read Dovecot's next-uid); map it to nil so it is never
        // forwarded as if it were a real UID.
        let rawUid = (ref["uid"] as? NSNumber)?.uint32Value
        self.uid = rawUid == 0 ? nil : rawUid
        let rawMessageID = ref["msg_id"] as? String
        self.messageID = (rawMessageID?.isEmpty ?? true) ? nil : rawMessageID
    }

    var requestBody: [String: Any] {
        var body: [String: Any] = ["folder": folder]
        if let uid { body["uid"] = Int(uid) }
        if let messageID { body["msg_id"] = messageID }
        return body
    }
}

/// Decoded `/push_envelope` response. `uid` is the server-resolved UID (the
/// payload's was a pre-delivery hint); `deliver` writes it back into the
/// notification's msgRef so the main app's actions target the right message.
private struct PushEnvelope: Decodable, Sendable {
    let from: String
    let subject: String
    let snippet: String
    let uid: UInt32?
}

/// Deliver-once box shared between `didReceive`'s enrichment task and
/// `serviceExtensionTimeWillExpire`. A lock (rather than an actor) because
/// both callers are synchronous system entry points; `@unchecked Sendable`
/// is sound as every access to the mutable fields happens under `lock`.
private final class DeliveryState: @unchecked Sendable {
    private let lock = NSLock()
    private var original: UNNotificationContent?
    private var handler: ((UNNotificationContent) -> Void)?

    func begin(content: UNNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        original = content
        self.handler = handler
    }

    /// Delivers the enriched content, or the untouched original when
    /// enrichment came back empty. Subsequent calls are no-ops.
    func deliver(_ envelope: PushEnvelope?) {
        lock.lock()
        guard let handler, let original else {
            lock.unlock()
            return
        }
        self.handler = nil
        let content: UNNotificationContent
        if let envelope,
           let enriched = original.mutableCopy() as? UNMutableNotificationContent {
            enriched.title = envelope.from
            enriched.body = envelope.subject + "\n" + envelope.snippet
            // The payload's uid was a pre-delivery hint; the server resolved
            // the real one by Message-ID. Rewrite msgRef so Mark as Read /
            // Archive / Open act on the message this notification shows.
            if let resolved = envelope.uid, resolved != 0,
               var ref = enriched.userInfo["msgRef"] as? [String: Any] {
                ref["uid"] = Int(resolved)
                var info = enriched.userInfo
                info["msgRef"] = ref
                enriched.userInfo = info
            }
            content = enriched
        } else {
            content = original
        }
        lock.unlock()
        handler(content)
    }

    func deliverFallback() {
        deliver(nil)
    }
}

/// Reads the two values the main app mirrors via CabalmailKit's
/// `PushEnrichmentStore` — keep key names in sync with that type.
private enum PushHandoff {
    static let appGroupID = "group.com.cabalmail.Cabalmail"
    static let apiURLDefaultsKey = "cabal.push.api_url"
    static let keychainService = "com.cabalmail.push"
    static let keychainAccount = "push.auth"

    /// `<api_url>/push_envelope`, or nil before the app has ever signed in.
    static func enrichmentEndpoint() -> URL? {
        guard
            let raw = UserDefaults(suiteName: appGroupID)?.string(forKey: apiURLDefaultsKey),
            let base = URL(string: raw)
        else { return nil }
        return base.appendingPathComponent("push_envelope")
    }

    /// The mirrored Cognito ID token, or nil when absent or already expired
    /// (the NSE has no way to refresh — the design accepts the "New mail"
    /// fallback for that window; see the plan's open questions). No
    /// `kSecAttrAccessGroup` in the query: a read searches every group this
    /// extension can access, which avoids re-deriving the team-ID prefix.
    static func currentIdToken() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess {
            // iOS resolves a group-less search across every entitled access
            // group; macOS does not reliably include the shared group, so
            // retry with it named explicitly. The team prefix comes from the
            // Info.plist AppIdentifierPrefix key (project.yml routes the
            // build setting through; empty in unsigned builds).
            guard
                let prefix = Bundle.main.object(
                    forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
                !prefix.isEmpty
            else {
                nseLog.error("keychain: group-less read failed (\(status)) and no AppIdentifierPrefix for the explicit retry")
                return nil
            }
            query[kSecAttrAccessGroup as String] = prefix + "com.cabalmail.shared"
            status = SecItemCopyMatching(query as CFDictionary, &item)
        }
        guard status == errSecSuccess, let data = item as? Data else {
            nseLog.error("keychain: shared-group read failed (\(status))")
            return nil
        }
        guard let payload = try? JSONDecoder().decode(TokenPayload.self, from: data)
        else { return nil }
        // 60s of leeway: a token the API would reject mid-flight isn't
        // worth the round trip; clock skew smaller than that still tries.
        guard payload.expiresAt.timeIntervalSinceNow > -60 else {
            nseLog.error("keychain: mirrored token expired; enrichment skipped")
            return nil
        }
        return payload.idToken
    }

    /// Mirror of `PushEnrichmentStore.TokenPayload`'s wire shape.
    private struct TokenPayload: Decodable {
        let idToken: String
        let expiresAt: Date

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case expiresAt = "expires_at"
        }
    }
}
