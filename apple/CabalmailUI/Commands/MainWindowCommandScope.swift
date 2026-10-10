import SwiftUI

// Each main window's identity.
//
// `AppState` is one per process, and several things in it are for one
// window: a compose request opens in the window it came from
// (`ComposeCoordinator`), a deep link in the window the system aimed it at
// (`DeepLinkRouter`), a mail event is answered by the window that sent it,
// and only the window last in front records the place the app resumes from
// (`WindowRecorder`). So each main window carries an identity, published to
// its own views through the environment, and reports when it comes to the
// front. The menus' commands need none of this: they go to the window in
// front through its own `WindowCommands`.

extension EnvironmentValues {
    /// The main window this view lives in. Nil outside a main window (the
    /// compose and Settings scenes, previews, tests).
    @Entry var commandWindowID: UUID?
}

/// Gives one main window its identity and reports when it comes to the
/// front, so a request made while a compose window is key (a mailto: link,
/// a closing composer) still reaches the main window the user was last in.
private struct MainWindowCommandScope: ViewModifier {
    let appState: AppState
    @Environment(\.appearsActive) private var appearsActive
    @State private var windowID = UUID()

    func body(content: Content) -> some View {
        content
            .environment(\.commandWindowID, windowID)
            .onAppear {
                if appearsActive { appState.noteActiveMainWindow(windowID) }
            }
            .onChange(of: appearsActive) { _, active in
                if active { appState.noteActiveMainWindow(windowID) }
            }
            .onDisappear { appState.forgetMainWindow(windowID) }
    }
}

extension View {
    /// Installs the window identity on a main window's root. Apply once per
    /// main `WindowGroup`, as its outermost modifier: it reads nothing from
    /// the `.environment(appState)` inside it (the state is passed in for
    /// that reason), and the launch chain inside it routes a Spotlight result
    /// to this window by the identity.
    public func mainWindowCommandScope(_ appState: AppState) -> some View {
        modifier(MainWindowCommandScope(appState: appState))
    }
}
