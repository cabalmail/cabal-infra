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
/// Settings tab (which has no sheet) - so the same `SettingsView` body serves
/// both presentations.
///
/// Lives here as a `View` extension rather than a per-view helper so
/// `SettingsView` stays under SwiftLint's `type_body_length` cap.
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

/// Regular-width iOS / iPadOS / visionOS settings sheet (General only).
///
/// Address and folder management used to live here as extra tabs, but they now
/// belong to the always-visible mailbox sidebar (`AddressListView` /
/// `FolderListView` carry the full request/revoke and create/delete
/// affordances). So this sheet is just General preferences, presented from
/// `SignedInRootView` via `AppState.settingsRequestTick` (sidebar gear button /
/// ⌘, command) at regular width, where the section tab bar is gone.
///
/// `SettingsView` supplies its own `NavigationStack` + Done button on iOS (its
/// `#else` branch + `settingsSheetDoneButton()`), so it renders normally inside
/// the sheet.
struct SettingsSheet: View {
    var body: some View {
        SettingsView()
            .environment(\.inSettingsSheet, true)
    }
}
#endif
