import SwiftUI

// Window targeting for the `AppState` command ticks (defect 11 of the
// 2026-10 rearchitecture audit).
//
// `AppState` is one per process, so a menu command that bumps one of its
// tick counters reached every mounted list and reader in every main window:
// with two iPad or Mac windows, Cmd+R opened two replies and Cmd+T toggled
// two selections. Each main window now carries an identity, published to
// its own views through the environment and to the menu commands through
// `focusedSceneValue`. A command names the window it is aimed at when it
// bumps a tick (`AppState.requestReply(in:)` and friends), and the
// observers answer through `onWindowCommand`, which drops a tick aimed at
// another window.
//
// This is the narrow fix. The tick bus itself stays; replacing it with
// per-window command targets read through `@FocusedValue` is the
// rearchitecture's workstream 3.1.

extension EnvironmentValues {
    /// The main window this view lives in. Nil outside a main window (the
    /// compose and Settings scenes, previews, tests), where a command tick
    /// is answered as before.
    @Entry var commandWindowID: UUID?
}

/// Gives one main window its identity and reports when it comes to the
/// front, so a command issued while a compose window is key still reaches
/// the main window the user was last in rather than every one of them.
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

/// `.onChange(of:)` for an `AppState` command tick, delivered only when the
/// command is aimed at this view's window (or at no window in particular).
private struct WindowCommandObserver<Tick: Equatable>: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.commandWindowID) private var windowID
    let tick: Tick
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: tick) { _, _ in
            guard appState.commandReaches(windowID) else { return }
            action()
        }
    }
}

extension View {
    /// Installs the window identity on a main window's root. Apply once per
    /// main `WindowGroup`, outside the `.environment(appState)` it reads
    /// nothing from (the state is passed in for that reason).
    public func mainWindowCommandScope(_ appState: AppState) -> some View {
        modifier(MainWindowCommandScope(appState: appState))
    }

    /// Runs `action` when `tick` changes and the command behind it is aimed
    /// at this window. Use in place of `.onChange(of:)` for every
    /// `AppState` command tick a menu or another window can bump.
    func onWindowCommand<Tick: Equatable>(_ tick: Tick, perform action: @escaping () -> Void) -> some View {
        modifier(WindowCommandObserver(tick: tick, action: action))
    }
}
