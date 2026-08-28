import SwiftUI
import AppKit
import CabalmailKit

/// macOS Settings window: General preferences.
///
/// Address and folder administration used to live here as extra tabs, but they
/// now belong to the main window's mailbox sidebar (`AddressListView` /
/// `FolderListView` carry the full request/revoke and create/delete
/// affordances). `SettingsView` brings its own category sidebar + detail
/// split view (System-Settings style), so this host just renders it directly.
///
/// The window is session-scoped. On the other platforms the settings surface
/// lives inside `SignedInRootView`, so `ContentView`'s status switch tears it
/// down along with the rest of the signed-in hierarchy when the user signs
/// out. The macOS Settings scene is an independent window that switch never
/// touches — without help it would outlive the session, still showing the
/// departed account's form. So when the session ends (Sign Out in the Account
/// section here, or an auth-expiry bounce elsewhere) this view closes its own
/// window and surfaces the main window, which has already flipped to the
/// sign-in form.
struct SettingsTabsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @State private var hostWindow: NSWindow?

    var body: some View {
        SettingsView()
            .background(HostingWindowReader(window: $hostWindow))
            .onChange(of: appState.status) { previous, current in
                guard previous == .signedIn, current != .signedIn else { return }
                // Land focus on the sign-in form before this window goes
                // away: bring the existing main window forward, or spawn
                // one if the user had closed it.
                if !MainMailWindow.bringToFront() {
                    openWindow(id: mainWindowID)
                }
                hostWindow?.close()
            }
    }
}

/// Captures the AppKit window hosting the Settings form so the sign-out
/// observer above can close it. SwiftUI gives the `Settings` scene no id to
/// target through `dismissWindow(id:)`, so the one sure handle on the window
/// is the hosting `NSWindow` itself, reached through a view in its hierarchy.
private struct HostingWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // `view.window` is nil until the view lands in a window; resolve
        // it after the current layout pass.
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if window !== nsView.window { window = nsView.window }
        }
    }
}
