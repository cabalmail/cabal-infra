import SwiftUI
import CabalmailKit
#if canImport(AppKit)
import AppKit
#endif

// Compose-related helpers for `MessageDetailView`. Lifted out of the main
// file so the struct body stays under SwiftLint's type_body_length cap;
// the methods read state off the view's `model` + `envelope` + `folder`
// and route their actions back through them.

extension MessageDetailView {
    @ViewBuilder
    func composeSheet(for seed: Draft) -> some View {
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

    /// Opens compose pre-populated for a `reply` / `replyAll` / `forward`.
    /// Pulls the user's address list so `ReplyBuilder` can pick a default
    /// From by matching the original message's recipients against owned
    /// addresses (per the React app's 0.3.0 behavior).
    func beginCompose(_ mode: ReplyBuilder.ReplyMode) {
        guard let client = appState.client else { return }
        Task { @MainActor in
            let addresses = (try? await client.addresses()) ?? []
            let seed = ReplyBuilder.build(
                from: envelope,
                body: model?.plainText,
                mode: mode,
                userAddresses: addresses
            )
            presentCompose(seed: seed)
        }
    }

    /// macOS / iPadOS / visionOS open compose in its own scene; iPhone
    /// keeps the sheet so the message stays on-screen behind it.
    func presentCompose(seed: Draft) {
        if composeOpensInWindow {
            openWindow(id: composeWindowID, value: seed)
            #if canImport(AppKit)
            // SwiftUI's openWindow occasionally drops the new compose
            // scene behind the main mail window when triggered from a
            // menu-bar shortcut. Force the app forward so the new
            // window comes to the user instead of stranding it under
            // whatever they were just reading.
            NSApp.activate(ignoringOtherApps: true)
            #endif
        } else {
            composeSeed = seed
        }
    }
}
