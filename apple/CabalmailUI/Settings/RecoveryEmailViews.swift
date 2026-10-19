import SwiftUI
import CabalmailKit

/// The recovery email's form sections, for the Account settings page and
/// the sheet after sign-in alike (auth parity B4). `RecoveryEmailModel`
/// holds the flow.
struct RecoveryEmailSections: View {
    @Bindable var model: RecoveryEmailModel

    var body: some View {
        switch model.step {
        case .loading:
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking your recovery email…")
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(ColorTokens.dangerFg)
                Button("Try Again") { Task { await model.load() } }
                    .accessibilityIdentifier("recovery.retry")
            }
        case .showing:
            showingSection
        case .editing:
            editingSections
        case .verifying:
            verifyingSections
        }
        if let notice = model.notice {
            Section {
                Label(notice, systemImage: "paperplane")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("recovery.notice")
            }
        }
        if let message = model.errorMessage {
            SignUpErrorSection(message: message)
        }
    }

    private var showingSection: some View {
        Section {
            Text(model.statusText)
                .accessibilityIdentifier("recovery.status")
            if model.address != nil, !model.isVerified {
                Button("Verify Address") { Task { await model.sendCode() } }
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("recovery.verifyAddress")
            }
            Button(model.address == nil ? "Add Recovery Email" : "Change Address") { model.startEditing() }
                .disabled(model.isWorking)
                .accessibilityIdentifier("recovery.edit")
        }
    }

    @ViewBuilder private var editingSections: some View {
        Section {
            TextField(model.address == nil ? "Recovery email" : "New recovery email", text: $model.draft)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .textEntry(.email)
                .accessibilityIdentifier("recovery.address")
                .submitLabel(.go)
                .onSubmit { Task { await model.save() } }
        } footer: {
            Text(model.editingHelp)
        }
        Section {
            AuthFormActions(
                primary: .init(title: "Save and Send Code", identifier: "recovery.save", isEnabled: model.canSave) {
                    Task { await model.save() }
                },
                isWorking: model.isWorking,
                secondary: [
                    .init(title: "Cancel", identifier: "recovery.cancel", isEnabled: !model.isWorking) {
                        model.cancel()
                    },
                ]
            )
        }
    }

    @ViewBuilder private var verifyingSections: some View {
        Section {
            Text("Enter the code we sent to \(model.address ?? "your email").")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Verification code", text: $model.code)
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()
                .textEntry(.digits)
                .accessibilityIdentifier("recovery.code")
                .submitLabel(.go)
                .onSubmit { Task { await model.verify() } }
        }
        Section {
            AuthFormActions(
                primary: .init(title: "Verify", identifier: "recovery.verify", isEnabled: model.canVerify) {
                    Task { await model.verify() }
                },
                isWorking: model.isWorking,
                secondary: [
                    .init(title: "Send New Code", identifier: "recovery.resend", isEnabled: !model.isWorking) {
                        Task { await model.sendCode() }
                    },
                    .init(title: "Cancel", identifier: "recovery.cancel", isEnabled: !model.isWorking) {
                        model.cancel()
                    },
                ]
            )
        }
    }
}

/// Settings › Account › Recovery Email: the one place to add an address
/// after sign-up, which a phone-only account (plan D5) is never asked for.
struct RecoveryEmailSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var model: RecoveryEmailModel?

    var body: some View {
        SettingsForm(title: "Recovery Email") {
            if let model {
                RecoveryEmailSections(model: model)
            }
        }
        .task {
            guard model == nil, let client = appState.client else { return }
            let loaded = RecoveryEmailModel(auth: client.authService, smsEnabled: client.configuration.smsEnabled)
            model = loaded
            await loaded.load()
        }
    }
}

/// The sheet the check after an interactive sign-in raises (auth parity
/// B4; `docs/auth.md`, "After sign-in"): the same sections, which the user
/// can skip. It never blocks the sign-in that raised it.
struct RecoveryEmailPromptSheet: View {
    let prompt: RecoveryEmailPrompt
    let onDismiss: () -> Void
    @State private var model: RecoveryEmailModel

    init(prompt: RecoveryEmailPrompt, auth: AuthService, smsEnabled: Bool, onDismiss: @escaping () -> Void) {
        self.prompt = prompt
        self.onDismiss = onDismiss
        _model = State(initialValue: RecoveryEmailModel(auth: auth, smsEnabled: smsEnabled, prompt: prompt))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(intro)
                        .foregroundStyle(.secondary)
                }
                RecoveryEmailSections(model: model)
            }
            .groupedFormStyleOnMac()
            .navigationTitle(title)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.isVerified ? "Done" : "Skip for Now", action: onDismiss)
                        .accessibilityIdentifier("recovery.dismiss")
                }
            }
        }
        .frame(minWidth: 420, minHeight: 380)
    }

    private var title: String {
        if case .verify = prompt { return "Verify Your Email" }
        return "Add a Recovery Email"
    }

    private var intro: String {
        if case .verify(let address) = prompt {
            return "Verify \(address) so it can be used to recover your account."
        }
        return "Add an address outside Cabalmail so you can get back in if you forget your password. "
            + "You can also do this later in Settings › Account."
    }
}
