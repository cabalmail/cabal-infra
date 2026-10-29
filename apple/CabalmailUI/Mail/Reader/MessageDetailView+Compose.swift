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
    /// plan). The model is read after the address fetch, so a body that
    /// lands meanwhile is still quoted.
    func beginCompose(_ mode: ReplyBuilder.ReplyMode) {
        guard let client = appState.client else { return }
        Task { @MainActor in
            let addresses = await Self.replyAddresses(client: client)
            let seed = ReplyBuilder.build(
                from: model?.threadedEnvelope ?? envelope,
                body: model?.plainText,
                mode: mode,
                userAddresses: addresses,
                sourceFolder: folder.path
            )
            let attachments = mode == .forward ? carriedAttachments(into: "the forward") : []
            presentCompose(seed: seed, attachments: attachments + (model?.inlineParts ?? []))
        }
    }

    /// The addresses a reply's From is matched against. Offline that's the
    /// list an earlier fetch saved, so a reply still goes out from the
    /// address the message was sent to rather than the default.
    static func replyAddresses(client: CabalmailClient) async -> [Address] {
        (try? await client.addressesForSending().addresses) ?? []
    }

    /// A forward or a resumed draft includes the message's attachments. The
    /// detail view model decoded them to temp files during the MIME parse,
    /// so re-read the bytes; they ride the compose request beside the seed
    /// (the window value is a recycled slot, not the draft), and
    /// `ComposeView` takes them on appearance. A reply, a forward and a
    /// resumed draft also carry the message's inline images
    /// (`inlineParts`), which go on the wire only if the body still shows
    /// them (`ComposeInlineImages`).
    private func carriedAttachments(into destination: String) -> [Attachment] {
        guard let source = model?.attachments, !source.isEmpty else { return [] }
        let loaded: [Attachment] = source.compactMap { attachment in
            guard let data = try? Data(contentsOf: attachment.fileURL) else { return nil }
            return Attachment(
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                data: data
            )
        }
        if loaded.count < source.count {
            showToast(Toast(
                kind: .warning,
                message: "Some attachments couldn't be carried into \(destination)."
            ))
        }
        return loaded
    }

    /// Opens compose resuming the open Drafts-folder message: recipients,
    /// subject, body, attachments and inline images from the fetched draft,
    /// with the server coordinates wired so the first re-save replaces this
    /// copy and a send discards it. Without its attachments the first
    /// autosave replaced the server copy with one that had none.
    func beginResumeDraft() {
        guard let model else { return }
        Task { @MainActor in
            let seed = await model.resumeDraftSeed()
            presentCompose(seed: seed, attachments: carriedAttachments(into: "the draft") + model.inlineParts)
        }
    }

    /// Routes to this window's compose surface (`ComposeRequestRouter` on
    /// `SignedInRootView`): a compose window on macOS and visionOS, the
    /// root-hosted sheet on iOS. Root-hosted rather than view-local
    /// so a mailto: arriving mid-reply and this reply flow never race two
    /// sheet presentations against each other.
    func presentCompose(seed: Draft, attachments: [Attachment] = []) {
        appState.compose.open(seed: seed, attachments: attachments, from: commandWindowID)
    }
}
