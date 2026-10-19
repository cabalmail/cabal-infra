import SwiftUI
import CabalmailKit

/// Sign-up's code step: the code Cognito sent to `delivery`, with a resend
/// and the way back. Leaving here leaves the account unconfirmed, which an
/// administrator can still confirm from Users.
struct SignUpCodeStep: View {
    @Bindable var model: SignUpModel
    let delivery: CodeDelivery
    let onFinish: (String?) -> Void

    @FocusState private var codeFieldFocused: Bool

    var body: some View {
        Form {
            Section {
                Text("Enter the code we sent to \(SignUpModel.describe(delivery)).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Verification code", text: $model.code)
                    .textContentType(.oneTimeCode)
                    .autocorrectionDisabled()
                    .textEntry(.digits)
                    .accessibilityIdentifier("signup.code")
                    .focused($codeFieldFocused)
                    .submitLabel(.go)
                    .onSubmit { Task { await model.confirm() } }
            } header: {
                Text("Verify your account")
            } footer: {
                Text("If you leave now, an administrator can still confirm the account.")
            }
            if let notice = model.notice {
                Section {
                    Label(notice, systemImage: "paperplane")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("signup.notice")
                }
            }
            if let message = model.errorMessage {
                SignUpErrorSection(message: message)
            }
            Section {
                AuthFormActions(
                    primary: .init(title: "Verify", identifier: "signup.verify", isEnabled: model.canConfirm) {
                        Task { await model.confirm() }
                    },
                    isWorking: model.isWorking,
                    secondary: [
                        .init(
                            title: "Send New Code",
                            identifier: "signup.resend",
                            isEnabled: model.canResend && !model.isWorking
                        ) {
                            Task { await model.resend() }
                        },
                        .backToSignIn(model, onFinish),
                    ]
                )
            }
        }
        .onAppear { codeFieldFocused = true }
    }
}
