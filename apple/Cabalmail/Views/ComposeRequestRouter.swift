import SwiftUI
import CabalmailKit
#if canImport(AppKit)
import AppKit
#endif

/// Routes app-level compose requests to the platform's compose surface
/// from a host that is always in the visible hierarchy.
///
/// `AppState.requestCompose(seed:)` (mailto: URLs) and the zero-arg
/// `requestCompose()` (macOS File > New Message, toolbar buttons, reply /
/// forward actions route their seeds through the same funnel) park an
/// optional seed and bump `composeRequestTick`; this modifier — installed
/// once on `SignedInRootView` — is the single consumer.
///
/// Window platforms (macOS, iPadOS, visionOS) hand off to the compose
/// `WindowGroup`, which layers a new scene regardless of what the main
/// window is showing. iPhone presents the compose sheet from here, the
/// signed-in root.
///
/// History: the sheet used to live on `MessageListView`. SwiftUI cannot
/// present a sheet from a view in a background tab, so a `mailto:` that
/// arrived while the user was on the Addresses or Settings tab set the
/// sheet state on a view that couldn't present it — the app just stayed
/// on its current screen (an App Review rejection for the default-mail-
/// client request), and the orphaned sheet then popped up whenever the
/// user next visited the Mail tab. Hosting the sheet on the signed-in
/// root presents from any tab, folder, or modal state.
struct ComposeRequestRouter: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    @Environment(\.openWindow) private var openWindow
    @State private var composeSeed: Draft?

    func body(content: Content) -> some View {
        content
            .task {
                // Cold-launch mailto: `.onOpenURL` in the app entry parks
                // the seed before any signed-in view exists. Drain it on
                // first mount. This also covers "mailto while signed out":
                // the seed waits out the sign-in flow and compose opens
                // over the fresh session.
                if let seed = appState.consumePendingComposeSeed() {
                    present(seed: seed)
                }
            }
            .onChange(of: appState.composeRequestTick) { _, _ in
                // Menu shortcuts and toolbar buttons pass no seed; the
                // mailto: handler parks one. Fall back to a fresh draft
                // for the former.
                if composeOpensInWindow || composeSeed == nil {
                    let seed = appState.consumePendingComposeSeed()
                        ?? ReplyBuilder.newDraft()
                    present(seed: seed)
                }
                // else: the iPhone sheet is already showing a compose.
                // Leave the seed parked — `drainParkedSeed` picks it up
                // when the current sheet closes — so an incoming mailto:
                // never replaces a draft the user is typing.
            }
            .sheet(item: $composeSeed, onDismiss: drainParkedSeed) { seed in
                composeSheet(for: seed)
            }
    }

    /// Window platforms open a compose scene; iPhone presents the sheet
    /// hosted by this modifier.
    private func present(seed: Draft) {
        if composeOpensInWindow {
            openWindow(id: composeWindowID, value: seed)
            #if canImport(AppKit)
            // SwiftUI's openWindow occasionally drops the new compose
            // scene behind the main mail window when triggered from a
            // menu-bar shortcut. Force the app forward so the new window
            // comes to the user instead of stranding it under whatever
            // they were just reading.
            NSApp.activate(ignoringOtherApps: true)
            #endif
        } else {
            composeSeed = seed
        }
    }

    /// A mailto: that arrived while a compose sheet was up stays parked on
    /// `AppState` (see the tick observer above). Present it once the sheet
    /// that blocked it has fully dismissed.
    private func drainParkedSeed() {
        if let seed = appState.consumePendingComposeSeed() {
            composeSeed = seed
        }
    }

    @ViewBuilder
    private func composeSheet(for seed: Draft) -> some View {
        if let client = appState.client {
            ComposeView(model: ComposeViewModel(
                seed: seed,
                client: client,
                draftStore: client.draftStore,
                preferences: preferences,
                onClose: { composeSeed = nil }
            ))
            .environment(appState)
            .environment(preferences)
        }
    }
}

extension View {
    /// Installs the app-wide compose-request receiver. Apply exactly once,
    /// on the signed-in root — a second copy would double-consume the
    /// request tick and open duplicate compose surfaces.
    func composeRequestRouter() -> some View {
        modifier(ComposeRequestRouter())
    }
}
