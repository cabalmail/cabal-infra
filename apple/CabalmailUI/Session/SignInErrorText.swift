import Foundation
import CabalmailKit

/// What the sign-in form says when a sign-in, a second factor or the launch
/// restore fails: canned copy for the errors a person can act on, the
/// server's own words where they were written for people, and a labelled
/// detail otherwise.
enum SignInErrorText {
    static func message(for error: CabalmailError) -> String {
        // Most cases fall through to a canned or "prefix: detail" format;
        // split into two switches so neither exceeds the cyclomatic cap.
        if let canned = canned(for: error) { return canned }
        switch error {
        case .network(let detail):              return "Network error: \(detail)"
        case .transport(let detail):            return "Transport error: \(detail)"
        case .protocolError(let text):          return "Protocol error: \(text)"
        case .server(_, let text):              return "Server error: \(text)"
        case .decoding(let text):               return "Response error: \(text)"
        default:                                return error.localizedDescription
        }
    }

    private static func canned(for error: CabalmailError) -> String? {
        switch error {
        case .invalidCredentials: return "Incorrect username or password."
        case .notConfigured:      return "Control domain is invalid."
        case .authExpired:        return "Session expired. Please sign in again."
        case .cancelled:          return "Cancelled."
        case .notSignedIn:        return "Not signed in."
        // Planned IMAP redeploy: show the API's friendly copy verbatim, no
        // "Server error:" prefix.
        case .maintenance(let message): return message
        // A Cognito trigger rejected the sign-in (e.g. the MFA-enrollment
        // gate). The Kit has already stripped Cognito's trigger wrapper;
        // what remains is the trigger's own user-facing copy, so show it
        // verbatim like .maintenance above.
        case .server(code: "UserLambdaValidationException", message: let message): return message
        default:                  return nil
        }
    }
}
