import SwiftUI
import CabalmailKit

/// The sign-up steps (auth parity B2), drawn in place of the sign-in form
/// and inside its chrome: the form (`SignUpFormStep`), the confirmation
/// code (`SignUpCodeStep`), and the account-created result. `SignUpModel`
/// holds the flow; these draw it.
struct SignUpView: View {
    @Bindable var model: SignUpModel
    /// Back to the sign-in form, with the new account's username once one
    /// has been created.
    let onFinish: (String?) -> Void

    var body: some View {
        Group {
            switch model.step {
            case .loading:
                loadingForm
            case .unavailable(let message):
                unavailableForm(message)
            case .form:
                SignUpFormStep(model: model, onFinish: onFinish)
            case .confirm(let delivery):
                SignUpCodeStep(model: model, delivery: delivery, onFinish: onFinish)
            case .created(let created):
                createdForm(created)
            }
        }
        .task {
            if model.step == .loading { await model.load() }
        }
    }

    // MARK: - Loading

    private var loadingForm: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking \(model.controlDomain)…")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Back to sign in") { onFinish(nil) }
                    .accessibilityIdentifier("signup.back")
            }
        }
    }

    private func unavailableForm(_ message: String) -> some View {
        Form {
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(ColorTokens.dangerFg)
            }
            Section {
                AuthFormActions(
                    primary: .init(title: "Try Again", identifier: "signup.retry") {
                        Task { await model.load() }
                    },
                    secondary: [.backToSignIn(model, onFinish)]
                )
            }
        }
    }

    // MARK: - Done

    private func createdForm(_ created: SignUpModel.Created) -> some View {
        Form {
            Section {
                Label("Account created", systemImage: "checkmark.circle")
                    .font(.headline)
                    .accessibilityIdentifier("signup.created")
                Text(createdText(created))
            }
            Section {
                AuthFormActions(
                    primary: .init(title: "Back to sign in", identifier: "signup.done") {
                        onFinish(model.createdUsername)
                    }
                )
            }
        }
    }

    /// "Pending admin approval" in practice is the domain grant: the account
    /// can sign in now, and creates addresses once an administrator grants
    /// it mail domains (`docs/auth.md`, "Sign-up").
    private func createdText(_ created: SignUpModel.Created) -> String {
        let approval = "An administrator still has to approve it before you can create addresses. "
            + "You can sign in now."
        switch created {
        case .confirmedByCode(.phone):
            return "Your phone number is verified. " + approval
        case .confirmedByCode(.email):
            return "Your email address is verified. " + approval
        case .autoConfirmed:
            return approval
        }
    }
}

/// A refused step's sentence, on the form and the code step alike.
struct SignUpErrorSection: View {
    let message: String

    var body: some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(ColorTokens.dangerFg)
                .accessibilityIdentifier("signup.error")
        }
    }
}

extension AuthFormActions.Action {
    /// Every sign-up step's way back to the sign-in form, carrying the new
    /// username once there is an account.
    @MainActor
    static func backToSignIn(_ model: SignUpModel, _ onFinish: @escaping (String?) -> Void) -> Self {
        .init(title: "Back to sign in", identifier: "signup.back", isEnabled: !model.isWorking) {
            onFinish(model.createdUsername)
        }
    }
}
