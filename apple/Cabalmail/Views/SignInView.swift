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

    var body: some View {
        @Bindable var appState = appState
        NavigationStack {
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
            .navigationTitle("Cabalmail")
        }
        .onAppear {
            controlDomain = appState.controlDomain
            username = appState.lastUsername
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
}
