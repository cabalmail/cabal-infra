import Foundation

/// Which requests `URLSessionHTTPTransport` may send a second time after a
/// dropped connection, a timeout or a spurious cancel.
///
/// The transport can't tell whether the first copy reached the server, so a
/// request is replayed only when a second copy, landing after the first,
/// leaves the user no worse off than the failure would: it changes nothing
/// the first didn't (or nothing a failure wouldn't leave behind anyway), and
/// what it answers points the user at the right next step. Reads qualify,
/// and so do the writes listed here. A write whose second copy would answer
/// a misleading error ("already exists", "changed on another device") or do
/// its work twice is sent once, and a failure reaches the caller as a
/// network error. `docs/request-replay.md` lists every request the Kit
/// makes, what a second copy does on the server, and the line each verdict
/// rests on.
///
/// A write that isn't listed is sent once, so a new endpoint has to be added
/// here, with its row in that table, before it is retried.
enum RequestReplayPolicy {
    static func allowsReplay(_ request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        let method = request.httpMethod?.uppercased() ?? "GET"
        // Checked first: a presigned URL's last path component is the user's
        // file name, which could spell an endpoint's.
        if isPresigned(url) {
            return method == "GET" || method == "PUT"
        }
        if let operation = cognitoOperation(request) {
            return replaySafeCognitoOperations.contains(operation)
        }
        if method == "GET" {
            return true
        }
        return replaySafeWrites.contains(url.lastPathComponent)
    }

    /// The Lambda writes whose second copy leaves the user no worse off.
    static let replaySafeWrites: Set<String> = [
        // Mail. A repeated move, flag or purge of UIDs that already moved
        // answers 200 like the first (checked on stage, 2026-10-17); /send is
        // deduplicated by Message-ID. A second draft save leaves a stray copy
        // in Drafts, but so does a failed one, since the next save appends
        // afresh; the retry at least answers the truth. Not /empty_trash: a
        // second copy after a timeout lands up to a minute later and would
        // also delete whatever reached Trash in between.
        "move_messages", "set_flag", "purge_messages",
        "mark_folder_read", "send", "save_draft", "upload_url",
        // Folders and addresses.
        "subscribe_folder", "unsubscribe_folder",
        "new", "suspend_address", "reinstate_address", "set_favorite",
        // Administration. Enabling an enabled user, disabling a disabled
        // one and writing or deleting the same grant all succeed with the
        // same end state. Not /confirm_user or /delete_user: their second
        // copy answers an error for the work the first did.
        "enable_user", "disable_user", "set_user_domain_access",
        // Settings and push.
        "set_preferences", "set_nav_state",
        "push_register", "push_deregister", "push_envelope",
        // Feeds.
        "rss_update_folder", "rss_update_subscription",
        "rss_set_item_state", "rss_mark_all_read",
    ]

    /// The Cognito operations whose second copy leaves the user no worse
    /// off. A second RespondToAuthChallenge meets a used session and asks the
    /// user to sign in again, which the failure would have asked too; the
    /// retry saves the likelier case, a first copy lost on a connection that
    /// went stale while the user typed the code.
    static let replaySafeCognitoOperations: Set<String> = [
        "InitiateAuth", "RespondToAuthChallenge", "GetUser", "SetUserMFAPreference",
    ]

    /// A presigned S3 URL carries its signature in the query.
    static func isPresigned(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name == "X-Amz-Signature" || $0.name == "Signature" }
    }

    /// The operation a Cognito request names in `X-Amz-Target`, or nil for
    /// any other request.
    static func cognitoOperation(_ request: URLRequest) -> String? {
        let prefix = "AWSCognitoIdentityProviderService."
        guard request.url?.host?.hasPrefix("cognito-idp.") == true,
              let target = request.value(forHTTPHeaderField: "X-Amz-Target"),
              target.hasPrefix(prefix)
        else { return nil }
        return String(target.dropFirst(prefix.count))
    }

    /// How the Debug Log names a request: the method and the endpoint or
    /// Cognito operation, never a presigned URL's file name.
    static func logName(_ request: URLRequest) -> String {
        let method = request.httpMethod?.uppercased() ?? "GET"
        guard let url = request.url else { return method }
        if isPresigned(url) { return "\(method) presigned S3 URL" }
        if let operation = cognitoOperation(request) { return "Cognito \(operation)" }
        return "\(method) \(url.lastPathComponent)"
    }
}
