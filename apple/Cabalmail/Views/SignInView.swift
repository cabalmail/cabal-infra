import SwiftUI
import CabalmailKit

/// Phase 4 sign-in form — the smallest UI that drives `CognitoAuthService`
/// end-to-end against a real Cognito pool.
///
/// Capture is three-field: control domain (cached across launches),
/// username, password. On submit, `AppState.signIn(...)` loads
/// `/config.json`, constructs a `CabalmailClient`, and authenticates.
/// Phase 6 replaces this with the real sign-up / reset-password flows.
struct SignInView: View {
    @Environment(AppState.self) private var appState

    @State private var controlDomain: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var mfaCode: String = ""

    /// The pending second factor when Cognito challenged the password
    /// sign-in, nil otherwise. Drives the swap between the credential
    /// form and the code form.
    private var mfaMethod: MfaMethod? {
        if case .mfaCodeRequired(let method) = appState.status { return method }
        return nil
    }

    var body: some View {
        @Bindable var appState = appState
        NavigationStack {
            Group {
                if let method = mfaMethod {
                    mfaForm(method: method)
                } else {
                    credentialForm
                }
            }
            .navigationTitle("Cabalmail")
        }
        .onAppear {
            controlDomain = appState.controlDomain
            username = appState.lastUsername
        }
    }

    private var credentialForm: some View {
        Form {
                Section("Server") {
                    TextField("Control domain (e.g. mail.example.com)", text: $controlDomain)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                }
                Section("Account") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }
                if case .error(let message) = appState.status {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Text("Sign In")
                            Spacer()
                            if appState.status == .signingIn {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!isFormValid || appState.status == .signingIn)
                }
        }
    }

    /// Second-factor step (identity plan Phase 1): the password was
    /// accepted and Cognito wants a TOTP (or SMS) code before it issues
    /// tokens. `AppState` holds the mid-challenge client.
    private func mfaForm(method: MfaMethod) -> some View {
        Form {
            Section("Two-factor code") {
                Text(method == .totp
                    ? "Enter the 6-digit code from your authenticator app."
                    : "Enter the code we just sent to your phone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("123456", text: $mfaCode)
                    .textContentType(.oneTimeCode)
                    .autocorrectionDisabled()
                    #if os(iOS) || os(visionOS)
                    .keyboardType(.numberPad)
                    #endif
            }
            if let mfaError = appState.mfaError {
                Section {
                    Label(mfaError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button("Verify") {
                    Task { await submitMfa() }
                }
                .disabled(mfaCode.count < 6)
                Button("Back to sign in", role: .cancel) {
                    mfaCode = ""
                    appState.cancelMfaChallenge()
                }
            }
        }
    }

    private var isFormValid: Bool {
        !controlDomain.isEmpty && !username.isEmpty && !password.isEmpty
    }

    private func submit() async {
        await appState.signIn(
            controlDomain: controlDomain,
            username: username,
            password: password
        )
        if appState.status == .signedIn {
            password = ""
        }
    }

    private func submitMfa() async {
        await appState.submitMfaCode(mfaCode)
        if appState.status == .signedIn {
            password = ""
            mfaCode = ""
        }
    }
}
