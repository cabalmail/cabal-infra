import SwiftUI
import CabalmailKit

/// Sign-up's form: username, the contacts the deployment asks for (plan
/// D5), the invitation code when one is required, the password, and SMS
/// consent when SMS is on. `SignUpModel` holds the values and the rules.
struct SignUpFormStep: View {
    @Bindable var model: SignUpModel
    let onFinish: (String?) -> Void

    private enum Field: Hashable {
        case username, phone, email, invitation, password, confirmPassword
    }

    @FocusState private var focusedField: Field?

    var body: some View {
        Form {
            Section {
                TextField("Username", text: $model.username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textEntry(.verbatim)
                    .accessibilityIdentifier("signup.username")
                    .focused($focusedField, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focusedField = model.smsEnabled ? .phone : .email }
            } header: {
                Text("New account on \(model.controlDomain)")
            } footer: {
                Text("3 to 32 lowercase letters, numbers and hyphens, with at least one letter.")
            }
            contactSection
            if model.invitationRequired {
                Section {
                    TextField("Invitation code", text: $model.invitationCode)
                        .autocorrectionDisabled()
                        .textEntry(.verbatim)
                        .accessibilityIdentifier("signup.invitationCode")
                        .focused($focusedField, equals: .invitation)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                } footer: {
                    Text("Sign-up is by invitation. Enter the code you were given.")
                }
            }
            passwordSection
            if model.smsEnabled {
                Section {
                    Toggle(isOn: $model.smsConsent) {
                        Text(model.smsConsentText)
                            .font(.footnote)
                    }
                    .accessibilityIdentifier("signup.smsConsent")
                }
            }
            if let message = model.errorMessage {
                SignUpErrorSection(message: message)
            }
            Section {
                AuthFormActions(
                    primary: .init(title: "Create Account", identifier: "signup.submit", isEnabled: model.canSubmit) {
                        submit()
                    },
                    isWorking: model.isWorking,
                    secondary: [.backToSignIn(model, onFinish)]
                )
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let missing = model.missingRequirement {
                        Text(missing)
                            .accessibilityIdentifier("signup.missing")
                    }
                    Text(termsText)
                }
            }
        }
    }

    /// The phone (required with SMS) and the recovery email (optional with
    /// SMS, required without): `docs/auth.md`, "Sign-up".
    private var contactSection: some View {
        Section {
            if model.smsEnabled {
                TextField("Phone number", text: $model.phone)
                    .textContentType(.telephoneNumber)
                    .textEntry(.phone)
                    .accessibilityIdentifier("signup.phone")
                    .focused($focusedField, equals: .phone)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .email }
            }
            TextField(model.smsEnabled ? "Recovery email (optional)" : "Recovery email", text: $model.email)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .textEntry(.email)
                .accessibilityIdentifier("signup.email")
                .focused($focusedField, equals: .email)
                .submitLabel(.next)
                .onSubmit { focusedField = model.invitationRequired ? .invitation : .password }
        } header: {
            Text("Verification and recovery")
        } footer: {
            Text(model.smsEnabled
                ? "We text a code to your phone to verify the account; include the country code, "
                    + "starting with +. A recovery email outside Cabalmail is optional, and gets you "
                    + "back in if you lose your phone."
                : "Use an address outside Cabalmail. It's how you get back in if you forget your password.")
        }
    }

    private var passwordSection: some View {
        Section {
            SecureField("Password", text: $model.password)
                .textContentType(.newPassword)
                .accessibilityIdentifier("signup.password")
                .focused($focusedField, equals: .password)
                .submitLabel(.next)
                .onSubmit { focusedField = .confirmPassword }
            SecureField("Confirm password", text: $model.confirmPassword)
                .textContentType(.newPassword)
                .accessibilityIdentifier("signup.confirmPassword")
                .focused($focusedField, equals: .confirmPassword)
                .submitLabel(.go)
                .onSubmit(submit)
        } footer: {
            Text("At least \(SignUpModel.minimumPasswordLength) characters, mixing upper- and lowercase "
                + "letters, numbers and symbols.")
        }
    }

    /// The webmail's line under its form, with the same two links.
    private var termsText: AttributedString {
        var text = AttributedString("By creating an account you agree to the ")
        var terms = AttributedString("Terms")
        terms.link = model.termsURL
        var privacy = AttributedString("Privacy Policy")
        privacy.link = model.privacyURL
        text.append(terms)
        text.append(AttributedString(" and "))
        text.append(privacy)
        text.append(AttributedString("."))
        return text
    }

    private func submit() {
        guard model.canSubmit else { return }
        Task { await model.submit() }
    }
}
