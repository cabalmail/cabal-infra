import SwiftUI
import CabalmailKit

/// Top-level router — branches on `AppState.status`.
///
/// Phase 4 keeps this trivial: sign-in form when signed out, the Phase-4-
/// interim `SignedInView` after. Later steps replace `SignedInView` with
/// the folder / message / detail split.
struct ContentView: View {
    @State private var appState = AppState()

    var body: some View {
        Group {
            switch appState.status {
            case .signedIn:
                MailRootView()
            default:
                SignInView()
            }
        }
        .environment(appState)
    }
}

#Preview {
    ContentView()
}
