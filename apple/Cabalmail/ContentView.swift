import SwiftUI
import CabalmailKit

/// Top-level router — branches on `AppState.status`.
///
/// Signed out: the sign-in form drives Cognito auth through `AppState`.
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
            default:
                SignInView()
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .environment(Preferences(store: InMemoryPreferenceStore()))
}
