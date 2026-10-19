import SwiftUI

/// The sign-in form's way into sign-up: a Create Account row, available
/// once a control domain is typed, since the account is made on that
/// server (auth parity B2).
struct CreateAccountSection: View {
    let controlDomain: String
    let isSigningIn: Bool
    let start: () -> Void

    var body: some View {
        Section {
            Button("Create Account", action: start)
                .disabled(!canStart)
                .accessibilityIdentifier("signin.createAccount")
        } footer: {
            Text("New here? Create an account on the server above.")
        }
    }

    private var canStart: Bool {
        !controlDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSigningIn
    }
}
