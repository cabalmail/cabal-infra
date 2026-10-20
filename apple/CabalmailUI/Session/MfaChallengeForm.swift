import SwiftUI
import CabalmailKit

/// The sign-in form's second-factor step (identity plan Phase 1): the
/// password was accepted and Cognito wants a TOTP (or SMS) code before it
/// issues tokens. `AppState` holds the mid-challenge client. Its own view so
/// the code, the auto-submit and the in-flight guard live with the step
/// that uses them; `SignInView` swaps it in while `appState.status` is
/// `.mfaCodeRequired`.
struct MfaChallengeForm: View {
    let method: MfaMethod
    /// The challenge was answered and the session is live.
    let onSignedIn: () -> Void

    @Environment(AppState.self) private var appState
    @FocusState private var codeFieldFocused: Bool
    @State private var mfaCode: String = ""
    /// Guards the six-digit auto-submit against firing while a submission
    /// is already in flight (e.g. a paste landing right after the sixth
    /// typed digit).
    @State private var isSubmittingMfa = false

    var body: some View {
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
                    .textEntry(.digits)
                    .accessibilityIdentifier("mfa.code")
                    .focused($codeFieldFocused)
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
                        .foregroundStyle(ColorTokens.dangerFg)
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
            // While a code is being checked, Back would show the password
            // form over a sign-in that may still complete (#1826).
            .disabled(isSubmittingMfa)
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
        .disabled(isSubmittingMfa)
        .accessibilityIdentifier("mfa.back")
        #endif
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
            mfaCode = ""
            onSignedIn()
        }
    }
}
