import SwiftUI
import CabalmailKit

/// Top-level router — branches on `AppState.status`.
///
/// Signed out: the sign-in form drives Cognito auth through `AppState`.
/// Restoring: neutral splash while `AppState.restoreIfPossible()` validates
/// the Keychain-persisted tokens in the background — shown instead of the
/// sign-in form so we don't flash the form for a frame on every cold launch
/// even when the user has stored credentials.
/// Signed in: `SignedInRootView` renders the tabbed layout (Mail, Addresses,
/// Folders, Settings). Both receive `AppState` and `Preferences` from the
/// App-level `@Environment` tree hoisted in `CabalmailApp` / `CabalmailMacApp`.
public struct ContentView: View {
    @Environment(AppState.self) private var appState
    /// The window's identity, for the navigator it builds.
    @Environment(\.commandWindowID) private var windowID
    /// The window's route, kept with its scene so a window the system
    /// restores comes back where it was (`StoredRoute`). Here, the one view a
    /// window keeps mounted across a sign-out, which clears it.
    @SceneStorage("route") private var storedRoute: Data?
    /// Set when this window's sign-in form completes a sign-in, so the
    /// recovery-email check runs once, here and in no other window
    /// (auth parity B4).
    @State private var checkRecoveryEmail = false
    /// What that check asks, while its sheet is up.
    @State private var recoveryPrompt: RecoveryEmailPrompt?

    public init() {}

    public var body: some View {
        Group {
            switch appState.status {
            case .signedIn:
                SignedInRootView(appState: appState, windowID: windowID, storedRoute: $storedRoute)
                    .task(id: checkRecoveryEmail) { await runRecoveryEmailCheck() }
                    .sheet(isPresented: recoveryPromptShown) { recoveryPromptSheet }
            case .restoring:
                RestoringSplash()
            default:
                SignInView(onSignedIn: { checkRecoveryEmail = true })
            }
        }
        .onChange(of: appState.accountForgottenTick) {
            storedRoute = nil
            recoveryPrompt = nil
        }
    }

    /// `docs/auth.md`, "After sign-in": one advisory check, which never
    /// blocks the sign-in (`RecoveryEmailCheck`).
    private func runRecoveryEmailCheck() async {
        guard checkRecoveryEmail, let client = appState.client else { return }
        checkRecoveryEmail = false
        recoveryPrompt = await RecoveryEmailCheck.prompt(
            auth: client.authService,
            smsEnabled: client.configuration.smsEnabled
        )
    }

    private var recoveryPromptShown: Binding<Bool> {
        Binding(get: { recoveryPrompt != nil }, set: { if !$0 { recoveryPrompt = nil } })
    }

    @ViewBuilder private var recoveryPromptSheet: some View {
        if let prompt = recoveryPrompt, let client = appState.client {
            RecoveryEmailPromptSheet(
                prompt: prompt,
                auth: client.authService,
                smsEnabled: client.configuration.smsEnabled,
                onDismiss: { recoveryPrompt = nil }
            )
        }
    }
}

/// Neutral splash shown while `AppState.restoreIfPossible()` is validating
/// the stored Cognito tokens. Kept deliberately minimal — pairs the Cabalmail
/// mark with the bundle name so a resumed user sees the same chrome as at
/// launch rather than a generic spinner that looks like a hang. Reuses the
/// sidebar's `CabalmailMark` asset and `LogoTint` colorset (see
/// `SidebarBranding`) so the launch mark matches the one above the folder list.
private struct RestoringSplash: View {
    var body: some View {
        VStack(spacing: 16) {
            Image("CabalmailMark")
                .resizable()
                .scaledToFit()
                .frame(width: 132, height: 132)
                .foregroundStyle(ColorTokens.brandForest)
                .accessibilityHidden(true)
            Text("Cabalmail")
                .font(.title)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .environment(Preferences(store: InMemoryPreferenceStore()))
}
