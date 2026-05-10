import SwiftUI
import CabalmailKit

/// Wrapper for the macOS Addresses / Folders auxiliary windows.
///
/// Both auxiliary scenes share the main window's `AppState` (so they see
/// the same Cognito session) but they shouldn't render their content
/// when the user isn't signed in: there's no client to read addresses
/// or folder metadata from. This wrapper hosts whichever view is in the
/// trailing closure when `appState.status == .signedIn`, and otherwise
/// shows a brief placeholder pointing the user back at the main window.
struct SecondaryWindowRoot<Content: View>: View {
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
