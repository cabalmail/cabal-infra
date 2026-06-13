import Foundation
import CabalmailKit

// Threading-overlay and Drafts-folder resume helpers for
// `MessageDetailViewModel`. In a sibling extension (same pattern as
// `+Flags` / `+Purge`) so the primary type body stays under SwiftLint's
// type_body_length cap.

extension MessageDetailViewModel {
    /// The list envelope overlaid with the threading identity parsed from
    /// the fetched message, when one has been parsed. Replies seeded from
    /// an open message thread correctly even when the envelope payload
    /// (older cache snapshot, pre-rollout server) lacks the fields.
    var threadedEnvelope: Envelope {
        guard threadingMessageId != nil
                || threadingInReplyTo != nil
                || !threadingReferences.isEmpty else {
            return envelope
        }
        return envelope.withThreading(
            messageId: threadingMessageId ?? envelope.messageId,
            inReplyTo: threadingInReplyTo ?? envelope.inReplyTo,
            references: threadingReferences.isEmpty ? envelope.references : threadingReferences
        )
    }

    /// True when the open message lives in the IMAP Drafts folder — the
    /// toolbar offers "Edit Draft" there. Exact match by design: the
    /// `/save_draft` Lambda pins every draft operation to the top-level
    /// `Drafts` mailbox.
    var isDraftsFolder: Bool { folder.path == "Drafts" }

    /// Resume needs the fetched, parsed body in hand; until then the Edit
    /// Draft button stays disabled rather than seeding an empty compose.
    var canResumeDraft: Bool {
        isDraftsFolder && (htmlBody != nil || plainText != nil)
    }

    /// Builds the compose seed resuming this draft: recipients, subject,
    /// and body from the fetched message, plus the server coordinates so
    /// the first re-save replaces this copy and a send discards it. A
    /// missing UIDVALIDITY degrades to coordinates the server's guard will
    /// decline — the resumed draft then saves as a new copy (duplicate at
    /// worst, never a lost draft).
    func resumeDraftSeed() async -> Draft {
        let uidValidity = try? await currentUIDValidity()
        let ref = uidValidity.map { DraftServerRef(uid: envelope.uid, uidValidity: $0) }
        return DraftResume.seed(
            envelope: envelope,
            headers: rootHeaders,
            plainText: plainText,
            htmlBody: htmlBody,
            serverRef: ref
        )
    }
}
