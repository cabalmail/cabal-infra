import SwiftUI

#if os(iOS)
/// The split's Settings sheet, presented from the window's navigation
/// (`SceneNavigator.showsSettingsSheet`) rather than the split's own view
/// state. That is what carries Settings across a fold: the split has no tab
/// bar, so folding with the sheet up opens the Settings tab, and unfolding
/// from the Settings tab opens the sheet. A sheet held as view state went
/// with the split.
///
/// The gear button and the ⌘, command both send this window's Settings
/// command; routing through the command (rather than a direct binding)
/// keeps the trigger working whichever column has focus.
struct SettingsSheetPresenter: ViewModifier {
    @Environment(SceneNavigator.self) private var navigator
    /// The sheet's binding, a mirror of the navigator's state. A write the
    /// sheet makes as a fold tears the split down lands here and dies with
    /// the view; only a dismissal this view sees reaches the navigator.
    @State private var presented = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $presented) {
                SettingsSheet()
            }
            .onChange(of: navigator.showsSettingsSheet, initial: true) { _, shows in
                if presented != shows { presented = shows }
            }
            .onChange(of: presented) { _, isUp in
                guard !isUp else { return }
                // A turn later, so a fold's layout change lands first: then a
                // sheet the fold took down is not taken for a dismissal.
                Task { @MainActor in navigator.settingsSheetDismissed() }
            }
            .answersCommand(.settings) {
                navigator.openSettingsSheet()
            }
    }
}

extension View {
    /// Presents the split's Settings sheet from the window's tab state
    /// (`SettingsSheetPresenter`).
    func settingsSheetPresenter() -> some View {
        modifier(SettingsSheetPresenter())
    }
}
#endif
