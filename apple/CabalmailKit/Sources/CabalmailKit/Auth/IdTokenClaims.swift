import Foundation

/// The claims the Apple client reads from a Cognito ID token.
///
/// No signature check: the token came straight from Cognito over TLS, and
/// what the client reads from it is a display hint. Authorization stays on
/// the server, which checks admin membership itself
/// (`lambda/api/_shared/admin_limits.py`); see `docs/auth.md`, "Admin
/// recognition".
public struct IdTokenClaims: Sendable, Equatable {
    /// The `cognito:groups` claim as a list of group names; empty when the
    /// claim is absent or the token is malformed.
    public let groups: [String]

    public init(idToken: String) {
        groups = Self.payload(of: idToken).map(Self.groups(in:)) ?? []
    }

    /// Whether the token names the `admin` group, matched as a whole name
    /// the way the server does: a group whose name merely contains "admin"
    /// (`nonadmin`, `admin-readonly`) is not the admin group.
    public var isAdmin: Bool { groups.contains("admin") }

    /// Cognito puts a JSON array in the token. API Gateway renders the same
    /// claim as a string (`admin`, `admin,users`, `[admin users]`), so
    /// that is accepted too, split on commas and whitespace once the
    /// brackets are trimmed, as `admin_limits.is_admin` splits it.
    private static func groups(in payload: [String: Any]) -> [String] {
        switch payload["cognito:groups"] {
        case let list as [Any]:
            return list.compactMap { $0 as? String }
        case let rendered as String:
            return rendered
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .replacingOccurrences(of: ",", with: " ")
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
        default:
            return []
        }
    }

    /// The payload segment of a compact JWT, decoded: base64url without
    /// padding, which `Data(base64Encoded:)` rejects until it is mapped back
    /// to the base64 alphabet and padded.
    private static func payload(of token: String) -> [String: Any]? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

extension AuthTokens {
    /// Whether this session's ID token names the `admin` group. A hint for
    /// what to show, never for what to allow.
    public var isAdmin: Bool { IdTokenClaims(idToken: idToken).isAdmin }
}

extension AuthService {
    /// Whether the signed-in user is an administrator, read from the tokens
    /// stored right now: false when signed out. Nothing is cached, so the
    /// answer follows a refresh (a group granted or removed takes effect
    /// with the next token Cognito issues), a sign-out, and an account
    /// switch. A display hint; a 403 from the server is the authority.
    public func isAdmin() async -> Bool {
        await currentTokens()?.isAdmin ?? false
    }
}
