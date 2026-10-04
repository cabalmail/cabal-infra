import Foundation
import CabalmailKit

/// An `HTTPTransport` that plays Cognito's user-pool API for a session's
/// whole life: password sign-in, the MFA answer and token refresh, plus the
/// Cabalmail API behind it. Each Cognito operation answers from its own FIFO
/// script; an operation with nothing scripted throws, so a test that wanders
/// onto an unexpected call fails instead of hanging. Every request is
/// recorded in order as a short label ("InitiateAuth USER_PASSWORD_AUTH",
/// "RespondToAuthChallenge", "InitiateAuth REFRESH_TOKEN_AUTH",
/// "API GET /list_folders").
public actor ScriptedCognito: HTTPTransport {
    /// One scripted Cognito answer.
    public enum Answer: Sendable {
        /// `AuthenticationResult` with these tokens (a refresh carries no
        /// refresh token, like Cognito's).
        case tokens(id: String, refresh: String? = "REFRESH", expiresIn: Int = 3600)
        /// An MFA challenge such as `SOFTWARE_TOKEN_MFA` or `SMS_MFA`.
        case challenge(name: String, session: String)
        /// A Cognito error body, e.g. `NotAuthorizedException`.
        case error(type: String, message: String = "refused")
        /// The request never reaches Cognito.
        case unreachable
    }

    /// The Cognito operations a session makes, as scripts are keyed.
    public enum Operation: String, Sendable {
        case passwordSignIn = "InitiateAuth USER_PASSWORD_AUTH"
        case refresh = "InitiateAuth REFRESH_TOKEN_AUTH"
        case mfaAnswer = "RespondToAuthChallenge"
    }

    private var scripts: [Operation: [Answer]] = [:]
    private var apiStatuses: [Int] = []
    public private(set) var trail: [String] = []
    public private(set) var requests: [URLRequest] = []

    public init() {}

    /// Queues answers for the next calls of `operation`.
    public func script(_ operation: Operation, _ answers: Answer...) {
        scripts[operation, default: []].append(contentsOf: answers)
    }

    /// HTTP statuses for the next API calls; unscripted, the API answers
    /// 200 with an empty JSON array.
    public func answerAPI(_ statuses: [Int]) {
        apiStatuses = statuses
    }

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let url = request.url else { throw CabalmailError.transport("ScriptedCognito: no URL") }
        guard url.host?.hasPrefix("cognito-idp.") == true else {
            trail.append("API \(request.httpMethod ?? "GET") \(url.path)")
            let status = apiStatuses.isEmpty ? 200 : apiStatuses.removeFirst()
            return (Data((status == 200 ? "[]" : "unauthorized").utf8), Self.response(url, status))
        }
        let label = Self.label(request)
        trail.append(label)
        guard let operation = Operation(rawValue: label),
              var queue = scripts[operation], !queue.isEmpty else {
            throw CabalmailError.transport("ScriptedCognito: nothing scripted for \(label)")
        }
        let answer = queue.removeFirst()
        scripts[operation] = queue
        return try Self.reply(answer, to: url)
    }

    private static func reply(_ answer: Answer, to url: URL) throws -> (Data, HTTPURLResponse) {
        switch answer {
        case let .tokens(id, refresh, expiresIn):
            var result: [String: Any] = [
                "IdToken": id, "AccessToken": "access-\(id)", "ExpiresIn": expiresIn, "TokenType": "Bearer",
            ]
            if let refresh { result["RefreshToken"] = refresh }
            return (try JSONSerialization.data(withJSONObject: ["AuthenticationResult": result]), response(url, 200))
        case let .challenge(name, session):
            let body: [String: Any] = ["ChallengeName": name, "Session": session, "ChallengeParameters": [:]]
            return (try JSONSerialization.data(withJSONObject: body), response(url, 200))
        case let .error(type, message):
            let body = ["__type": type, "message": message]
            return (try JSONSerialization.data(withJSONObject: body), response(url, 400))
        case .unreachable:
            throw CabalmailError.network("The Internet connection appears to be offline.")
        }
    }

    private static func label(_ request: URLRequest) -> String {
        let target = request.value(forHTTPHeaderField: "X-Amz-Target")?
            .replacingOccurrences(of: "AWSCognitoIdentityProviderService.", with: "") ?? "?"
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
        return [target, body?["AuthFlow"] as? String].compactMap { $0 }.joined(separator: " ")
    }

    private static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}
