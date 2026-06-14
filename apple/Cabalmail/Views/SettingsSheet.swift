import SwiftUI
import CabalmailKit

#if !os(macOS)
/// True when a view is hosted inside `SettingsSheet` (the regular-width iOS
/// modal), so it should offer a Done button to dismiss. False everywhere
/// else - the macOS Settings scene and the compact-width section tabs both
/// supply their own dismissal chrome.
///
/// An environment flag rather than a size-class check: a sheet's content can
/// report a compact `horizontalSizeClass` even on iPad, so size class can't
/// distinguish "I'm in the sheet" from "I'm a compact tab."
private struct InSettingsSheetKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var inSettingsSheet: Bool {
        get { self[InSettingsSheetKey.self] }
        set { self[InSettingsSheetKey.self] = newValue }
    }
}

/// True when the regular-width single-rail layout is active, so the mailbox
/// sidebar should show the Settings gear (the gear opens `SettingsSheet`;
/// compact width reaches the same sections through its Settings tab instead).
///
/// Set by `SignedInRootView` on the regular-width branch and read by
/// `FolderListView`. A plain environment flag rather than a `horizontalSizeClass`
/// check because the sidebar is a narrow `NavigationSplitView` column and
/// reports a compact size class even on a regular-width iPad.
private struct ShowsSettingsGearKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var showsSettingsGear: Bool {
        get { self[ShowsSettingsGearKey.self] }
        set { self[ShowsSettingsGearKey.self] = newValue }
    }
}

/// Adds a Done button that dismisses the enclosing `SettingsSheet`, but only
/// when the view is actually hosted in it. A no-op in the compact-width
/// section tabs (which have no sheet) - so the same `SettingsView` /
/// `AddressesView` / `FoldersAdminView` body serves both presentations.
///
/// Lives here as a `View` extension rather than a per-view helper so the
/// three section views stay under SwiftLint's `type_body_length` cap.
private struct SettingsSheetDoneButton: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.inSettingsSheet) private var inSettingsSheet

    func body(content: Content) -> some View {
        content.toolbar {
            if inSettingsSheet {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

extension View {
    func settingsSheetDoneButton() -> some View {
        modifier(SettingsSheetDoneButton())
    }
}

/// Regular-width iOS / iPadOS / visionOS settings + administration sheet.
///
/// The mobile mirror of the macOS Settings window (`SettingsTabsView`, #385):
/// General, Addresses, and Folders are configuration surfaces, so they live
/// in a deliberate modal rather than competing for a column in the main mail
/// window. Presented from `SignedInRootView` via `AppState.settingsRequestTick`
/// (sidebar gear button / ⌘, command); only used at regular width, where the
/// section tab bar is gone.
///
/// Each tab supplies its own `NavigationStack` on iOS (see the `#else`
/// branches in `SettingsView`, `AddressesView`, `FoldersAdminView`), so
/// titles, per-view toolbars, and the Done button render normally inside the
/// tab. The sheet only opens while signed in, so the views' models always
/// have a live client and the macOS `RequiresSignIn` guard isn't needed here.
struct SettingsSheet: View {
    var body: some View {
        TabView {
            SettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AddressesView()
                .tabItem { Label("Addresses", systemImage: "at") }
            FoldersAdminView()
                .tabItem { Label("Folders", systemImage: "folder") }
        }
        .environment(\.inSettingsSheet, true)
    }
}
#endif
