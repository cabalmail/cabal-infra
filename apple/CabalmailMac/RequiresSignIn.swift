import SwiftUI
import CabalmailKit

/// Wraps a view that needs an authenticated `AppState.client`.
///
/// When the user is signed in, `content()` renders normally. Otherwise
/// we show a brief `ContentUnavailableView` rather than letting the
/// inner view spin forever waiting for a server connection that isn't
/// there. Used by the macOS Settings tabs (Addresses, Folders) so
/// opening Settings before signing in degrades gracefully.
struct RequiresSignIn<Content: View>: View {
    @Environment(AppState.self) private var appState
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            switch appState.status {
            case .signedIn:
                content()
            default:
                ContentUnavailableView(
                    "Sign in required",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text(
                        "Sign in from the main Cabalmail window to use this view."
                    )
                )
            }
        }
    }
}
