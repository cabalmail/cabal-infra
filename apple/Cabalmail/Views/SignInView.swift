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
    /// Return-key focus chain: Return advances through the credential
    /// fields and submits from the last one, so sign-in is completable
    /// by keyboard alone.
    private enum Field: Hashable {
        case controlDomain, username, password, mfaCode
    }

    @Environment(AppState.self) private var appState

    @FocusState private var focusedField: Field?
    @State private var controlDomain: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var mfaCode: String = ""
    /// Guards the six-digit auto-submit against firing while a submission
    /// is already in flight (e.g. a paste landing right after the sixth
    /// typed digit).
    @State private var isSubmittingMfa = false

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
        if let method = mfaMethod {
            mfaForm(method: method)
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
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .accessibilityIdentifier("signin.controlDomain")
                        .focused($focusedField, equals: .controlDomain)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .username }
                }
                Section("Account") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        #endif
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
                            .foregroundStyle(.red)
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
                // Same label/prompt split as the control-domain field: the
                // grouped macOS form would otherwise show "123456" as the
                // row label.
                Group {
                    #if os(macOS)
                    TextField("Code", text: $mfaCode, prompt: Text("123456"))
                    #else
                    TextField("123456", text: $mfaCode)
                    #endif
                }
                    .textContentType(.oneTimeCode)
                    .autocorrectionDisabled()
                    #if os(iOS) || os(visionOS)
                    .keyboardType(.numberPad)
                    #endif
                    .accessibilityIdentifier("mfa.code")
                    .focused($focusedField, equals: .mfaCode)
                    // The on-screen number pad has no Return key; this is
                    // for hardware keyboards, where Return completes MFA
                    // without reaching for Verify (the auto-submit below
                    // usually beats it to the punch on the sixth digit).
                    .submitLabel(.go)
                    .onSubmit {
                        guard mfaCode.count == 6, !isSubmittingMfa else { return }
                        Task { await submitMfa() }
                    }
                    .onChange(of: mfaCode) { _, newValue in
                        normalizeAndAutoSubmit(newValue)
                    }
            }
            if let mfaError = appState.mfaError {
                Section {
                    Label(mfaError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            Section { mfaActions }
        }
    }

    /// Verify / cancel controls for the MFA step. macOS gets the standard
    /// dialog arrangement — cancel leading, prominent default action
    /// trailing — while iOS keeps the stacked full-width form rows.
    @ViewBuilder private var mfaActions: some View {
        #if os(macOS)
        HStack {
            Button("Back to sign in", role: .cancel) {
                mfaCode = ""
                appState.cancelMfaChallenge()
            }
            .accessibilityIdentifier("mfa.back")
            Spacer()
            if isSubmittingMfa {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Verify") {
                Task { await submitMfa() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(mfaCode.count < 6 || isSubmittingMfa)
            .accessibilityIdentifier("mfa.verify")
        }
        #else
        Button("Verify") {
            Task { await submitMfa() }
        }
        .disabled(mfaCode.count < 6 || isSubmittingMfa)
        .accessibilityIdentifier("mfa.verify")
        Button("Back to sign in", role: .cancel) {
            mfaCode = ""
            appState.cancelMfaChallenge()
        }
        .accessibilityIdentifier("mfa.back")
        #endif
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

    /// Keeps the code field digits-only (the `.numberPad` keyboard doesn't
    /// constrain hardware-keyboard or pasted input) and submits as soon as
    /// six digits are present — the standard OTP pattern, so completing the
    /// code never requires reaching the Verify button. Normalization
    /// re-fires `onChange` with the cleaned string, which is when the
    /// six-digit check runs.
    private func normalizeAndAutoSubmit(_ newValue: String) {
        let digits = String(newValue.filter(\.isNumber).prefix(6))
        guard digits == newValue else {
            mfaCode = digits
            return
        }
        guard digits.count == 6, !isSubmittingMfa else { return }
        Task { await submitMfa() }
    }

    private func submitMfa() async {
        guard !isSubmittingMfa else { return }
        isSubmittingMfa = true
        defer { isSubmittingMfa = false }
        await appState.submitMfaCode(mfaCode)
        if appState.status == .signedIn {
            password = ""
            mfaCode = ""
        }
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
                .foregroundStyle(Color("LogoTint"))
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
