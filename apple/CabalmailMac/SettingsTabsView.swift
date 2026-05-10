import SwiftUI
import CabalmailKit

/// macOS Settings window: General / Addresses / Folders tabs.
///
/// Folders and Addresses are administration views — set up email aliases,
/// manage IMAP folder structure — so they belong in Settings rather than
/// jostling for room with the mail UI in the main window. The tab style
/// is the macOS-default tab bar (no explicit `.tabViewStyle` modifier),
/// which renders the canonical pill-shaped row at the top of a Settings
/// window the way System Settings, Xcode, and Mail's Preferences do.
///
/// Each address / folder tab is wrapped in `RequiresSignIn` so opening
/// the Settings window before the user has signed in shows a brief
/// placeholder rather than spinning forever waiting for a server it
/// can't reach.
struct SettingsTabsView: View {
    var body: some View {
        TabView {
            SettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            RequiresSignIn { AddressesView() }
                .tabItem { Label("Addresses", systemImage: "at") }
            RequiresSignIn { FoldersAdminView() }
                .tabItem { Label("Folders", systemImage: "folder") }
        }
    }
}
