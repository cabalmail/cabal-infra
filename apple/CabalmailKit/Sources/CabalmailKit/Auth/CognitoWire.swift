import Foundation

/// One call to Cognito's user-pool JSON API (`docs/auth.md`, "Transport and
/// errors"): the `POST` with its `X-Amz-Target`, and the reply mapped onto
/// `CabalmailError`. `CognitoAuthService` makes every call through this,
/// so the session logic and the wire stay apart.
struct CognitoWire: Sendable {
    let region: String
    let transport: HTTPTransport

    private func endpoint() throws -> URL {
        guard let url = URL(string: "https://cognito-idp.\(region).amazonaws.com/") else {
            throw CabalmailError.notConfigured
        }
        return url
    }

    /// - Parameter notAuthorized: what a `NotAuthorizedException` means for
    ///   this call. Cognito answers it both to a sign-in with a bad password
    ///   and to a refresh whose token has expired or been revoked, and only
    ///   the caller knows which it asked for (#1288).
    func call(
        _ target: String,
        body: sending [String: Any],
        notAuthorized: CabalmailError = .invalidCredentials
    ) async throws -> [String: Any] {
        var request = URLRequest(url: try endpoint())
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("AWSCognitoIdentityProviderService.\(target)", forHTTPHeaderField: "X-Amz-Target")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport.perform(request)
        guard (200..<300).contains(response.statusCode) else {
            let (code, message) = parseError(data)
            if code == "NotAuthorizedException" {
                throw notAuthorized
            }
            if code == "UserLambdaValidationException" {
                // A pool trigger (require_admin_mfa, check_invite, ...)
                // rejected the call; the trigger's own message is the
                // user-facing part, not Cognito's wrapper around it.
                throw CabalmailError.server(
                    code: code,
                    message: Self.stripLambdaTriggerWrapper(from: message)
                )
            }
            throw CabalmailError.server(code: code, message: message)
        }
        do {
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } catch {
            // A 2xx whose body isn't JSON at all - an empty body, or an HTML
            // page from something in the network path answering for Cognito -
            // used to throw Foundation's NSError straight out of the package,
            // where callers that branch on `CabalmailError` couldn't catch it
            // (#1902). Same normalization the Lambda client's `decodeReply`
            // does (#1805), and the detail names the call, never the body:
            // these replies carry tokens.
            throw CabalmailError.decoding("\(target) returned an unexpected reply")
        }
    }

    private func parseError(_ data: Data) -> (code: String, message: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("Unknown", String(data: data, encoding: .utf8) ?? "")
        }
        // Cognito errors come back either as `{__type: "...", message: "..."}`
        // or `{code: "...", message: "..."}` depending on the operation.
        let code = (obj["__type"] as? String)
            .flatMap { $0.split(separator: "#").last.map(String.init) }
            ?? (obj["code"] as? String)
            ?? "Unknown"
        let message = obj["message"] as? String ?? obj["Message"] as? String ?? ""
        return (code, message)
    }

    /// Cognito reports a Lambda-trigger rejection as
    /// "<TriggerName> failed with error <trigger message>." — the wrapper
    /// leaks the trigger's name and, when the trigger message has its own
    /// terminal period, produces a doubled one. Return just the trigger's
    /// message. Internal (not private) for direct unit coverage.
    static func stripLambdaTriggerWrapper(from message: String) -> String {
        var text = message
        if let range = text.range(of: " failed with error ") {
            // Only strip when the lead-in is a bare trigger name; a space
            // means the phrase occurs mid-sentence in a real message.
            let lead = text[..<range.lowerBound]
            if !lead.isEmpty && !lead.contains(" ") {
                text = String(text[range.upperBound...])
            }
        }
        while text.hasSuffix("..") {
            text.removeLast()
        }
        return text
    }
}
