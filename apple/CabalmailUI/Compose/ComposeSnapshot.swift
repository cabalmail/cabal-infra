import Foundation
import CabalmailKit

/// Everything a composer starts from: a fresh seed's fields, or a whole
/// composer's state when "Open in New Window" moves it from the iOS sheet
/// to a window of its own (`ComposeWindowMove`).
///
/// A moved draft is the same draft, not a new one built from it: the same
/// ID (so the local autosave keeps writing one file), the same server copy
/// and replace chain (so Save Draft replaces it rather than adding a second,
/// and a send prunes every UID the Drafts list may be showing, #1071), the
/// same intent (so the title and the focus rule hold), and the body as it
/// stands in both panes. Rebuilding the window from a `Draft` lost the
/// intent and the attachments, and would have signed the body a second
/// time.
///
/// What a move cannot carry: the rich pane's undo history, its caret and
/// selection, the form's scroll offset, and a photo still being read in.
struct ComposeSnapshot {
    let draftID: UUID
    let fromAddress: String?
    /// See `ComposeViewModel.fromSeededFromPreference`.
    let fromSeededFromPreference: Bool
    let toText: String
    let ccText: String
    let bccText: String
    let subject: String
    let markdownBody: String
    let seededMarkdownBody: String
    /// The rich pane's markup, read through the checked bridge. Nil for a
    /// seed, whose rich pane is rendered from `markdownBody` once the editor
    /// is up.
    let richHTML: String?
    let richMirrorsMarkdown: Bool
    let editorMode: ComposeViewModel.EditorMode
    let attachments: [ComposeViewModel.ComposeAttachment]
    let inlineImages: ComposeInlineImages
    let serverDraftRef: DraftServerRef?
    let replacedServerDraftUIDs: [UInt32]
    let inReplyTo: String?
    let references: [String]
    let composeIntent: ComposeIntent
    let replySourceFolder: String?
    let replySourceUid: UInt32?
    let isResumedServerDraft: Bool
    /// The From picker's list, so a moved composer's picker is not empty
    /// while its own load runs.
    let availableAddresses: [Address]

    /// The live composer's state, for the window it is moving to. Throws
    /// when the editor bridge cannot answer: a rich pane read as `""` would
    /// hand the window an empty message.
    ///
    /// Read after any save in flight has landed (the move runs inside the
    /// server draft queue), so `serverDraftRef` is the copy that save
    /// adopted, not the one it replaced.
    @MainActor
    static func capture(from model: ComposeViewModel) async throws -> ComposeSnapshot {
        let richHTML = try await model.editorController.checked.getHTML()
        return ComposeSnapshot(
            draftID: model.draftId,
            fromAddress: model.fromAddress,
            fromSeededFromPreference: model.fromSeededFromPreference,
            toText: model.toText,
            ccText: model.ccText,
            bccText: model.bccText,
            subject: model.subject,
            markdownBody: model.markdownBody,
            seededMarkdownBody: model.seededMarkdownBody,
            richHTML: richHTML,
            richMirrorsMarkdown: model.richMirrorsMarkdown,
            editorMode: model.editorMode,
            attachments: model.attachments,
            inlineImages: model.inlineImages,
            serverDraftRef: model.serverDraftRef,
            replacedServerDraftUIDs: model.replacedServerDraftUIDs,
            inReplyTo: model.inReplyTo,
            references: model.references,
            composeIntent: model.composeIntent,
            replySourceFolder: model.replySourceFolder,
            replySourceUid: model.replySourceUid,
            isResumedServerDraft: model.isResumedServerDraft,
            availableAddresses: model.availableAddresses
        )
    }
}

// In an extension so the memberwise initializer `capture(from:)` builds with
// stays.
extension ComposeSnapshot {
    /// A new composer's start: a reply, forward, new message, mailto or
    /// resumed draft. The only place the signature is added, so a moved
    /// composer, which starts from `capture(from:)`, is never signed twice.
    @MainActor
    init(seed: Draft, preferences: Preferences) {
        // Default From falls back to the user's preference *only* when the
        // seed didn't already pick one. Reply-builder's "From = original
        // addressee" behavior (Phase 5) therefore still wins over the
        // preferences default — the relationship-scoped-address idiom
        // requires replies to reuse the address the correspondent already
        // wrote to.
        let fromAddress = seed.fromAddress ?? preferences.defaultFromAddress
        // Append the preference signature to the seeded body, but only once.
        // Replies / forwards seed with an attribution + quoted body; the
        // signature goes *above* that block so the user's reply text lands
        // with the signature on the line above the quoted original (the
        // same shape every UNIX mail client has produced since Pine).
        let seededBody = SignatureFormatter.seedBody(base: seed.body, signature: preferences.signature)
        self.init(
            draftID: seed.id,
            fromAddress: fromAddress,
            fromSeededFromPreference: seed.fromAddress == nil && preferences.defaultFromAddress != nil,
            toText: seed.to.joined(separator: ", "),
            ccText: seed.cc.joined(separator: ", "),
            bccText: seed.bcc.joined(separator: ", "),
            subject: seed.subject,
            markdownBody: seededBody,
            seededMarkdownBody: seededBody,
            richHTML: nil,
            richMirrorsMarkdown: true,
            editorMode: .rich,
            attachments: [],
            inlineImages: ComposeInlineImages(),
            serverDraftRef: seed.serverRef,
            replacedServerDraftUIDs: [],
            inReplyTo: seed.inReplyTo,
            references: seed.references,
            composeIntent: seed.composeIntent ?? .new,
            replySourceFolder: seed.replySourceFolder,
            replySourceUid: seed.replySourceUid,
            isResumedServerDraft: seed.serverRef != nil,
            availableAddresses: []
        )
    }
}
