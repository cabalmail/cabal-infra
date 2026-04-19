import SwiftUI
import CabalmailKit

/// Signed-in tab root — Mail / Addresses / Folders / Settings.
///
/// Uses the SwiftUI 18 `TabView(selection:)` + `Tab { … }` surface with the
/// `.sidebarAdaptable` style so iPhone gets a tab bar, iPad / visionOS get
/// a sidebar that collapses to a tab bar in compact trait environments,
/// and macOS shows a sidebar by default. The Settings tab is hidden on
/// macOS because the Settings scene wired to ⌘, in `CabalmailMacApp`
/// already covers that ground per the plan.
struct SignedInRootView: View {
    enum Section: Hashable {
        case mail
        case addresses
        case folders
        case settings
    }

    @State private var selected: Section = .mail

    var body: some View {
        TabView(selection: $selected) {
            Tab("Mail", systemImage: "tray", value: Section.mail) {
                MailRootView()
            }
            Tab("Addresses", systemImage: "at", value: Section.addresses) {
                AddressesView()
            }
            Tab("Folders", systemImage: "folder", value: Section.folders) {
                FoldersAdminView()
            }
            #if !os(macOS)
            // macOS uses the dedicated `Settings` scene (⌘,) for preferences
            // — showing the same screen as a tab would be redundant and
            // non-idiomatic. Every other platform gets the tab.
            Tab("Settings", systemImage: "gear", value: Section.settings) {
                SettingsView()
            }
            #endif
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
