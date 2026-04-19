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
struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.status {
            case .signedIn:
                SignedInRootView()
            case .restoring:
                RestoringSplash()
            default:
                SignInView()
            }
        }
    }
}

/// Neutral splash shown while `AppState.restoreIfPossible()` is validating
/// the stored Cognito tokens. Kept deliberately minimal — mirrors the bundle
/// name so a resumed user sees the same chrome as at launch rather than a
/// generic spinner that looks like a hang.
private struct RestoringSplash: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.tint)
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
