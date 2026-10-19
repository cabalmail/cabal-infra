import SwiftUI
import CabalmailKit

/// Phase 4 sign-in form — the smallest UI that drives `CognitoAuthService`
/// end-to-end against a real Cognito pool.
///
/// Capture is three-field: control domain (cached across launches),
/// username, password. On submit, `AppState.signIn(...)` loads
/// `/config.json`, constructs a `CabalmailClient`, and authenticates.
/// Create Account swaps the form for the sign-up steps (`SignUpView`)
/// against the control domain typed here, inside the same chrome.
struct SignInView: View {
    /// Return-key focus chain: Return advances through the credential
    /// fields and submits from the last one, so sign-in is completable
    /// by keyboard alone.
    private enum Field: Hashable {
        case controlDomain, username, password
    }

    @Environment(AppState.self) private var appState

    /// This form's sign-in finished, with or without a second factor:
    /// `ContentView` then runs the recovery-email check in this window
    /// (auth parity B4).
    var onSignedIn: () -> Void = {}

    @FocusState private var focusedField: Field?
    @State private var controlDomain: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    /// The sign-up flow while it is showing in place of this form.
    @State private var signUp: SignUpModel?

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
                #if os(macOS)
                MacSignInChrome { currentForm }
                #else
                currentForm
                #endif
            }
            .navigationTitle("Cabalmail")
        }
        .onAppear {
            controlDomain = appState.controlDomain
            username = appState.lastUsername
        }
    }

    @ViewBuilder private var currentForm: some View {
        if let signUp {
            SignUpView(model: signUp, onFinish: finishSignUp)
        } else if let method = mfaMethod {
            MfaChallengeForm(method: method, onSignedIn: signedIn)
        } else {
            credentialForm
        }
    }

    private var credentialForm: some View {
        Form {
                Section("Server") {
                    // On macOS, the grouped form shows the title as the row's
                    // leading label, so the example moves into the prompt;
                    // on iOS only the placeholder is visible, so it keeps
                    // carrying the full hint.
                    Group {
                        #if os(macOS)
                        TextField(
                            "Control domain",
                            text: $controlDomain,
                            prompt: Text("mail.example.com")
                        )
                        #else
                        TextField("Control domain (e.g. mail.example.com)", text: $controlDomain)
                        #endif
                    }
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textEntry(.url)
                        .accessibilityIdentifier("signin.controlDomain")
                        .focused($focusedField, equals: .controlDomain)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .username }
                }
                Section("Account") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textEntry(.verbatim)
                        .accessibilityIdentifier("signin.username")
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("signin.password")
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit {
                            guard isFormValid, appState.status != .signingIn else { return }
                            Task { await submit() }
                        }
                }
                if case .error(let message) = appState.status {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(ColorTokens.dangerFg)
                    }
                } else if appState.signedOutReason == .sessionExpired {
                    // Why you are looking at this form: an expiry drops the
                    // session under the user, on the launch path and while
                    // the app is running alike (issue #1703). A deliberate
                    // Sign Out leaves the reason nil and the form blank.
                    Section {
                        Label(
                            "Your session expired — sign in again.",
                            systemImage: "clock.badge.exclamationmark"
                        )
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("signin.reason")
                    }
                }
                Section {
                    #if os(macOS)
                    HStack {
                        Spacer()
                        if appState.status == .signingIn {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button("Sign In") {
                            Task { await submit() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isFormValid || appState.status == .signingIn)
                        .accessibilityIdentifier("signin.submit")
                    }
                    #else
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
                    .accessibilityIdentifier("signin.submit")
                    #endif
                }
                CreateAccountSection(controlDomain: controlDomain, isSigningIn: appState.status == .signingIn) {
                    signUp = appState.makeSignUp(controlDomain: controlDomain)
                }
        }
    }

    /// Back from sign-up, filling in the new account's username so the next
    /// step is its password.
    private func finishSignUp(username: String?) {
        signUp = nil
        if let username {
            self.username = username
            password = ""
            focusedField = .password
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
        if appState.status == .signedIn { signedIn() }
    }

    /// This form's sign-in completed, with or without a second factor.
    private func signedIn() {
        password = ""
        onSignedIn()
    }

}

#if os(macOS)
/// macOS chrome around the sign-in and MFA forms. A bare `Form` renders in
/// the sparse, unpadded "columns" style on macOS, so this wraps whichever
/// step is showing in Settings-style grouped boxes, caps the width so the
/// fields don't stretch across a large mail window, and tops the card with
/// the same mark/title pairing as `RestoringSplash` (see `ContentView`) so
/// launch and sign-in share their chrome.
private struct MacSignInChrome<FormContent: View>: View {
    @ViewBuilder var form: FormContent

    var body: some View {
        VStack(spacing: 12) {
            Image("CabalmailMark")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .foregroundStyle(ColorTokens.brandForest)
                .accessibilityHidden(true)
            Text("Cabalmail")
                .font(.title2.weight(.semibold))
            form
                .formStyle(.grouped)
                // The grouped scroll background is a slightly different
                // gray than the window; hiding it lets the section boxes
                // sit directly on the window background so the width cap
                // doesn't read as a full-height colored column.
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 480)
        }
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The main WindowGroup carries no size constraints (the mail UI
        // handles any size), so a short restored window would push the
        // action buttons below the fold. Sizing the sign-in content sets
        // the window's minimum while signed out; the constraint lifts
        // once the mail UI takes over.
        .frame(minWidth: 500, minHeight: 560)
    }
}
#endif
