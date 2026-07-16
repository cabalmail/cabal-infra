import SwiftUI
import CabalmailKit

// Compose-related helpers for `MessageDetailView`. Lifted out of the main
// file so the struct body stays under SwiftLint's type_body_length cap;
// the methods read state off the view's `model` + `envelope` + `folder`
// and route their actions back through them.

extension MessageDetailView {
    /// Opens compose pre-populated for a `reply` / `replyAll` / `forward`.
    /// Pulls the user's address list so `ReplyBuilder` can pick a default
    /// From by matching the original message's recipients against owned
    /// addresses (per the React app's 0.3.0 behavior). Threads from the
    /// fetched message's headers when the body has loaded — the list
    /// envelope may lack the threading fields (Phase 0 of the draft-sync
    /// plan).
    func beginCompose(_ mode: ReplyBuilder.ReplyMode) {
        guard let client = appState.client else { return }
        Task { @MainActor in
            let addresses = (try? await client.addresses()) ?? []
            let seed = ReplyBuilder.build(
                from: model?.threadedEnvelope ?? envelope,
                body: model?.plainText,
                mode: mode,
                userAddresses: addresses
            )
            if mode == .forward {
                stashForwardAttachments(for: seed)
            }
            presentCompose(seed: seed)
        }
    }

    /// Forwarding includes the original message's attachments. The detail
    /// view model decoded them to temp files during the MIME parse, so
    /// re-read the bytes and stash them on `AppState` keyed by the seed
    /// id — they can't ride the Codable `Draft` through `openWindow`, and
    /// `ComposeView` consumes the stash on appearance. Inline `cid:`
    /// images stay behind: they live in the quoted body, not the
    /// attachment strip, matching the React composer's scope.
    private func stashForwardAttachments(for seed: Draft) {
        guard let source = model?.attachments, !source.isEmpty else { return }
        let loaded: [Attachment] = source.compactMap { attachment in
            guard let data = try? Data(contentsOf: attachment.fileURL) else { return nil }
            return Attachment(
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                data: data
            )
        }
        if loaded.count < source.count {
            appState.showToast(Toast(
                kind: .warning,
                message: "Some attachments couldn't be carried into the forward."
            ))
        }
        guard !loaded.isEmpty else { return }
        appState.stashComposeAttachments(loaded, for: seed.id)
    }

    /// Opens compose resuming the open Drafts-folder message: recipients,
    /// subject, and body from the fetched draft, with the server
    /// coordinates wired so the first re-save replaces this copy and a
    /// send discards it.
    func beginResumeDraft() {
        guard let model else { return }
        Task { @MainActor in
            let seed = await model.resumeDraftSeed()
            presentCompose(seed: seed)
        }
    }

    /// Routes to the app-wide compose receiver (`ComposeRequestRouter` on
    /// `SignedInRootView`): a compose window on macOS / iPadOS / visionOS,
    /// the root-hosted sheet on iPhone. Root-hosted rather than view-local
    /// so a mailto: arriving mid-reply and this reply flow never race two
    /// sheet presentations against each other.
    func presentCompose(seed: Draft) {
        appState.requestCompose(seed: seed)
    }
}
