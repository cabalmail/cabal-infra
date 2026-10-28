import CabalmailKit

/// What a composer that has closed tells the rest of the app: the Drafts
/// list's rows it retired, the replied-to message's `\Answered` flag, and
/// the sent or queued toast.
///
/// Only for a composer that ended. One that moved to a window of its own
/// ("Open in New Window") reports nothing: its draft is still open, in the
/// window, which reports for it when it closes. Nor does that window before
/// it has claimed the draft (`holdsDraft`).
@MainActor
struct ComposeOutcomeReport {
    let model: ComposeViewModel
    let appState: AppState

    /// Save Draft or Discard closed the composer.
    ///
    /// A save replaced the server copy, expunging the UID an open Drafts
    /// list — and the reader this dismissal returns to — is still holding.
    /// Hand the list the whole chain plus the survivor so it can swap rather
    /// than strand the user on content the server no longer has (#1078). An
    /// emptied body takes the `.discardEmpty` exit through the same button
    /// and reports a chain with no survivor (#1081); a first save reports
    /// the survivor with nothing retired, and rides the same refresh into
    /// the list (#1083).
    ///
    /// A discard expunged the copy the list and the reader are holding. Say
    /// so, or the row survives and Edit Draft on it reopens the discarded
    /// draft with Send live (#1081). Same event as Save Draft; the
    /// replacement has no survivor, so the policy drops the reader rather
    /// than re-pointing it.
    func draftRetired() {
        guard model.holdsDraft, let replacement = model.retiredDraftReplacement else { return }
        appState.mailStore.events.post(.draftReplaced(folderPath: "Drafts", replacement: replacement), from: nil)
    }

    /// Send succeeded.
    func sent() {
        // Sending from a draft discards the server copy, so the Drafts list
        // is showing a message that no longer exists. Prune it through the
        // same event the reader's archive/move actions post instead of
        // waiting for the next background reconcile (the folder is
        // unsubscribed by default, so that took over a minute). "Drafts" is
        // the mailbox `/save_draft` pins every draft to; see
        // `MessageDetailViewModel.isDraftsFolder`.
        // Every UID the session held, not just the last: a 60s autosave
        // replaces the copy under a new UID and the open list is still
        // rendering the old one (#1071).
        let retired = model.supersededDraftUIDs.map { MessageRef(folder: FolderTree.draftsPath, uid: $0) }
        appState.mailStore.events.post(.removed(retired), from: nil)
        // A reply left the device (or the outbox owns it now): mark the
        // original `\Answered` so the list's replied arrow appears without
        // waiting for a refresh.
        if let folder = model.replySourceFolder, let uid = model.replySourceUid {
            appState.mailStore.markAnswered(MessageRef(folder: folder, uid: uid), client: appState.client)
        }
        // Surface the outcome as a toast on the shared AppState so the user
        // sees confirmation after the sheet dismisses. `.queued` means the
        // message is in the outbox and `SendQueue` will drain it on
        // reconnect — callers should understand their message isn't lost.
        switch model.lastSendOutcome {
        case .sent:
            appState.showToast(.init(kind: .success, message: "Message sent."))
        case .queued:
            appState.showToast(.init(kind: .warning, message: "Message queued — will send when back online."))
        case .none:
            break
        }
    }
}
