import Foundation
import CabalmailKit

/// What the sign-up screens say when Cognito refuses a step
/// (`docs/auth.md`, "Transport and errors" and "Sign-up"). The Kit leaves
/// most of these as `.server(code:message:)`, whose general description
/// names only the exception, so each one a person can act on gets its own
/// sentence here.
enum SignUpErrorText {
    static func message(for error: Error) -> String {
        guard let error = error as? CabalmailError else { return error.localizedDescription }
        if case .server(let code, let message) = error, let text = serverMessage(code: code, message: message) {
            return text
        }
        // `.invalidInvitationCode` carries the contract's own wording.
        return error.localizedDescription
    }

    /// Cognito's per-user limit on sending codes, or on attempts.
    static func isRateLimit(_ error: Error) -> Bool {
        guard case .server(let code, _) = error as? CabalmailError else { return false }
        return rateLimitCodes.contains(code)
    }

    /// Why `config.json` could not be read, for the screen that stands in
    /// for the form.
    static func configurationMessage(for error: Error) -> String {
        let detail = (error as? CabalmailError)?.localizedDescription ?? error.localizedDescription
        return "Couldn't reach this server's sign-up. \(detail)"
    }

    private static let rateLimitCodes: Set<String> = [
        "LimitExceededException", "TooManyRequestsException", "TooManyFailedAttemptsException",
    ]

    private static func serverMessage(code: String, message: String) -> String? {
        if rateLimitCodes.contains(code) {
            return "Too many attempts. Please try again later."
        }
        switch code {
        case "UserLambdaValidationException":
            // check_invite refusing the username. The Kit has already
            // stripped Cognito's wrapper; the rest is written for people.
            return sentence(message)
        case "UsernameExistsException":
            return "That username is taken. Choose another."
        case "InvalidPasswordException":
            // "Password did not conform with policy: Password must have
            // uppercase characters" - the part after the colon says what
            // to change.
            let reason = message.components(separatedBy: "policy: ").last ?? message
            return sentence(reason)
        case "InvalidParameterException":
            // "Invalid phone number format.", "Invalid email address format."
            return sentence(message)
        case "CodeMismatchException":
            return "That code did not match. Check it and try again."
        case "ExpiredCodeException":
            return "That code has expired. Send a new one."
        case "CodeDeliveryFailureException":
            return "Couldn't send a verification code. Check the phone number or email and try again."
        default:
            return nil
        }
    }

    /// Cognito's messages arrive with and without a full stop.
    private static func sentence(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    }
}
