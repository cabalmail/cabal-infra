import Foundation

/// Where Cognito sent a one-time code, from a reply's `CodeDeliveryDetails`.
public struct CodeDelivery: Sendable, Equatable {
    public enum Medium: Sendable, Equatable {
        case email
        /// A text message (`DeliveryMedium: SMS`).
        case phone
    }

    public let medium: Medium
    /// Masked by Cognito (`a***@e***`, `+*******1234`); nil when the reply
    /// leaves it out.
    public let destination: String?

    public init(medium: Medium, destination: String?) {
        self.medium = medium
        self.destination = destination
    }

    /// Nil when the reply carries no `CodeDeliveryDetails`: Cognito sent no
    /// code. Anything but `EMAIL` reads as a phone, as the webmail reads it.
    init?(details: Any?) {
        guard let details = details as? [String: Any] else { return nil }
        medium = (details["DeliveryMedium"] as? String) == "EMAIL" ? .email : .phone
        destination = details["Destination"] as? String
    }
}

/// Outcome of `signUp`. Either way the account exists; the sign-up screens
/// call it pending admin approval, which in practice is the domain grant
/// (`docs/auth.md`, "Sign-up").
public enum SignUpResult: Sendable, Equatable {
    /// Cognito sent a confirmation code. Finish with `confirmSignUp`,
    /// offering `resendConfirmationCode`.
    case confirmationCodeSent(CodeDelivery)
    /// `check_invite` confirmed the account itself, because the pool has no
    /// SMS and so no code to send. There is nothing to enter.
    case confirmed

    init(reply: [String: Any]) {
        if let delivery = CodeDelivery(details: reply["CodeDeliveryDetails"]) {
            self = .confirmationCodeSent(delivery)
        } else {
            self = .confirmed
        }
    }
}

extension CabalmailError {
    /// `check_invite` refusing the invitation code: a
    /// `UserLambdaValidationException` whose message names the code. A
    /// refused username is the same exception with the trigger's own
    /// sentence, and stays `.server` so a screen can show that sentence.
    var isInvitationCodeRefusal: Bool {
        guard case .server(code: "UserLambdaValidationException", message: let message) = self else {
            return false
        }
        return message.range(of: "invitation code", options: .caseInsensitive) != nil
    }
}
