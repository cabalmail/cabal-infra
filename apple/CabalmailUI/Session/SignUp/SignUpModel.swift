import Foundation
import Observation
import CabalmailKit

/// The native sign-up flow (auth parity B2): the form, the confirmation
/// code, and the account-created result, against the control domain the
/// sign-in form already holds. `docs/auth.md` ("Sign-up") is the contract;
/// the webmail's `SignUp` view is the reference for the rules and copy.
///
/// Sign-up makes no session. It talks to Cognito through a bare
/// `CognitoAuthService` over an in-memory store, since none of its calls
/// return tokens, so nothing reaches the keychain or the session's caches.
/// The new account signs in through the ordinary form afterwards.
@Observable
@MainActor
final class SignUpModel {
    enum Step: Equatable {
        /// Reading `config.json`, which says what the form asks for.
        case loading
        /// `config.json` could not be read; the message says why.
        case unavailable(String)
        case form
        /// Cognito sent a confirmation code here.
        case confirm(CodeDelivery)
        case created(Created)
    }

    enum Created: Equatable {
        /// The user entered the code Cognito sent to this medium.
        case confirmedByCode(CodeDelivery.Medium)
        /// `check_invite` confirmed the account itself (no SMS, no code).
        case autoConfirmed
    }

    let controlDomain: String
    private(set) var step: Step = .loading
    private(set) var configuration: Configuration?

    var username = ""
    var password = ""
    var confirmPassword = ""
    var email = ""
    var phone = ""
    var invitationCode = ""
    var smsConsent = false
    var code = ""

    private(set) var isWorking = false
    /// What went wrong with the last submit, confirm or resend.
    private(set) var errorMessage: String?
    /// A resend's outcome, shown on the code step.
    private(set) var notice: String?
    /// False once Cognito has said "too many codes"; the contract says to
    /// stop offering Resend for a while, and leaving the screen resets it.
    private(set) var canResend = true

    @ObservationIgnored private let loadConfiguration: @MainActor (String) async throws -> Configuration
    @ObservationIgnored private let makeAuthService: (Configuration) -> AuthService
    @ObservationIgnored private var auth: AuthService?
    /// The username Cognito holds the pending account under, for confirm
    /// and resend, whatever the field says by then.
    @ObservationIgnored private var submittedUsername: String?

    init(
        controlDomain: String,
        loadConfiguration: @escaping @MainActor (String) async throws -> Configuration,
        makeAuthService: @escaping (Configuration) -> AuthService = SignUpModel.liveAuthService
    ) {
        self.controlDomain = controlDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        self.loadConfiguration = loadConfiguration
        self.makeAuthService = makeAuthService
    }

    nonisolated static func liveAuthService(_ configuration: Configuration) -> AuthService {
        CognitoAuthService(configuration: configuration, secureStore: InMemorySecureStore())
    }

    /// The username the account is created under, for the sign-in form to
    /// prefill once the flow is done.
    var createdUsername: String? {
        if case .created = step { return submittedUsername }
        return nil
    }

    // MARK: - Loading the configuration

    func load() async {
        step = .loading
        do {
            let loaded = try await loadConfiguration(controlDomain)
            configuration = loaded
            auth = makeAuthService(loaded)
            step = .form
        } catch {
            step = .unavailable(SignUpErrorText.configurationMessage(for: error))
        }
    }

    // MARK: - What the form asks for (docs/auth.md, "Sign-up"; plan D5)

    /// With SMS on, the phone (with consent) is required and the email is
    /// optional; without, the email is required and no phone is collected.
    var smsEnabled: Bool { configuration?.smsEnabled ?? true }
    var invitationRequired: Bool { configuration?.invitationRequired ?? false }

    /// The username as sent: trimmed and lowercased, since `check_invite`
    /// accepts lowercase only and a phone keyboard capitalizes a first
    /// letter all too easily.
    var normalizedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The phone as sent: E.164, so the spaces, dashes, dots and brackets
    /// people type are dropped. Cognito refuses anything else.
    var normalizedPhone: String {
        phone.filter { Self.isASCIIDigit($0) || $0 == "+" }
    }

    /// The code as sent: its digits, whatever else a paste carried.
    var normalizedCode: String { code.filter(Self.isASCIIDigit) }

    var normalizedInvitationCode: String {
        invitationCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var usernameIsValid: Bool { Self.isValidUsername(normalizedUsername) }

    var emailIsValid: Bool {
        normalizedEmail.isEmpty ? smsEnabled : Self.isAddressShaped(normalizedEmail)
    }

    var phoneIsValid: Bool { !smsEnabled || Self.isE164(normalizedPhone) }
    var passwordIsValid: Bool { password.count >= Self.minimumPasswordLength }
    var passwordsMatch: Bool { !confirmPassword.isEmpty && confirmPassword == password }
    var consentIsValid: Bool { !smsEnabled || smsConsent }
    var invitationCodeIsValid: Bool { !invitationRequired || !normalizedInvitationCode.isEmpty }

    var canSubmit: Bool {
        step == .form && !isWorking && usernameIsValid && emailIsValid && phoneIsValid
            && passwordIsValid && passwordsMatch && consentIsValid && invitationCodeIsValid
    }

    var canConfirm: Bool { !isWorking && normalizedCode.count == 6 }

    /// The first thing still keeping Create Account disabled, in the order
    /// the fields appear, so a disabled button never goes unexplained.
    var missingRequirement: String? {
        if !usernameIsValid {
            return normalizedUsername.isEmpty
                ? "Choose a username."
                : "Usernames are 3 to 32 lowercase letters, numbers and hyphens, with at least one "
                    + "letter and no hyphen at either end."
        }
        if !phoneIsValid {
            return normalizedPhone.isEmpty
                ? "Enter your phone number."
                : "Enter the phone number with its country code, starting with +."
        }
        if !emailIsValid {
            return normalizedEmail.isEmpty ? "Enter a recovery email." : "That email address doesn't look right."
        }
        if !invitationCodeIsValid { return "Enter your invitation code." }
        if !passwordIsValid { return "Use a password of at least \(Self.minimumPasswordLength) characters." }
        if !passwordsMatch { return confirmPassword.isEmpty ? "Confirm your password." : "The passwords don't match." }
        if !consentIsValid { return "Agree to receive SMS to continue." }
        return nil
    }

    // MARK: - Submitting

    func submit() async {
        guard canSubmit, let auth else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        let name = normalizedUsername
        do {
            let result = try await auth.signUp(
                username: name,
                password: password,
                email: normalizedEmail.isEmpty ? nil : normalizedEmail,
                phone: smsEnabled ? normalizedPhone : nil,
                invitationCode: normalizedInvitationCode.isEmpty ? nil : normalizedInvitationCode
            )
            submittedUsername = name
            password = ""
            confirmPassword = ""
            switch result {
            case .confirmationCodeSent(let delivery):
                code = ""
                step = .confirm(delivery)
            case .confirmed:
                step = .created(.autoConfirmed)
            }
        } catch {
            errorMessage = SignUpErrorText.message(for: error)
        }
    }

    func confirm() async {
        guard case .confirm(let delivery) = step, canConfirm,
              let auth, let name = submittedUsername else { return }
        isWorking = true
        errorMessage = nil
        notice = nil
        defer { isWorking = false }
        do {
            try await auth.confirmSignUp(username: name, code: normalizedCode)
            step = .created(.confirmedByCode(delivery.medium))
        } catch CabalmailError.invalidCredentials {
            // ConfirmSignUp's NotAuthorizedException: the account is
            // already confirmed (a second tap, or an admin confirmed it).
            step = .created(.confirmedByCode(delivery.medium))
        } catch {
            errorMessage = SignUpErrorText.message(for: error)
        }
    }

    func resend() async {
        guard case .confirm(let previous) = step, canResend,
              let auth, let name = submittedUsername else { return }
        isWorking = true
        errorMessage = nil
        notice = nil
        defer { isWorking = false }
        do {
            let delivery = try await auth.resendConfirmationCode(username: name) ?? previous
            step = .confirm(delivery)
            notice = "A new code is on its way to \(Self.describe(delivery))."
        } catch {
            if SignUpErrorText.isRateLimit(error) { canResend = false }
            errorMessage = SignUpErrorText.message(for: error)
        }
    }

    // MARK: - Copy that depends on the deployment

    /// The webmail's checkbox text, word for word (`SignUp/index.jsx`), with
    /// the brand built the same way: `Cabalmail (<operator>)` when
    /// `config.json` names the operator, Cabalmail alone otherwise.
    var smsConsentText: String {
        let brand = configuration?.operatorName.map { "Cabalmail (\($0))" } ?? "Cabalmail"
        return "I agree to receive transactional SMS from \(brand) — signup verification, "
            + "password reset, and sign-in codes — at the phone number above. Message "
            + "frequency varies; message and data rates may apply. Reply HELP for help or "
            + "STOP to opt out at any time."
    }

    /// The front-door legal pages the webmail links, on `www.` of the
    /// deployment's control domain.
    var termsURL: URL? { legalPage("terms.html") }
    var privacyURL: URL? { legalPage("privacy.html") }

    private func legalPage(_ name: String) -> URL? {
        guard let domain = configuration?.controlDomain, !domain.isEmpty else { return nil }
        return URL(string: "https://www.\(domain)/\(name)")
    }

    /// "your phone (+*******0123)", "your email (a***@e***)".
    static func describe(_ delivery: CodeDelivery) -> String {
        let medium = delivery.medium == .email ? "your email" : "your phone"
        guard let destination = delivery.destination, !destination.isEmpty else { return medium }
        return "\(medium) (\(destination))"
    }

    // MARK: - Rules

    /// The webmail's rule, which `check_invite` also enforces: 3–32
    /// lowercase letters, digits and hyphens, no hyphen at either end, and
    /// at least one letter.
    static func isValidUsername(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$"#, options: .regularExpression) != nil
            && name.contains { $0.isLetter }
    }

    static func isAddressShaped(_ address: String) -> Bool {
        address.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    /// `+`, a country code that doesn't start with 0, and 7 to 15 digits in all.
    static func isE164(_ phone: String) -> Bool {
        phone.range(of: #"^\+[1-9][0-9]{6,14}$"#, options: .regularExpression) != nil
    }

    /// `Character.isNumber` alone also takes other scripts' digits and
    /// fractions, which Cognito would refuse; `isASCII` also rules out a
    /// digit carrying a combining mark.
    static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// The webmail's floor. The pool's own policy (Cognito's default: upper
    /// and lower case, a digit and a symbol) is checked by Cognito, and its
    /// refusal says which part failed.
    static let minimumPasswordLength = 12
}
