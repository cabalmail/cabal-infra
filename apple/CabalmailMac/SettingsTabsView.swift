import SwiftUI
import CabalmailKit

/// macOS Settings window: General preferences.
///
/// Address and folder administration used to live here as extra tabs, but they
/// now belong to the main window's mailbox sidebar (`AddressListView` /
/// `FolderListView` carry the full request/revoke and create/delete
/// affordances). With only General left there's no tab bar to show, so the
/// Settings window renders `SettingsView` directly.
struct SettingsTabsView: View {
    var body: some View {
        SettingsView()
    }
}
