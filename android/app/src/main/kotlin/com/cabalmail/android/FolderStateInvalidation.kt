package com.cabalmail.android

/**
 * Which cross-screen mutations leave another screen's folder state stale
 * (#1734).
 *
 * The Mail tab's folder rail and the Folders screen each hold their own copy
 * of the folder list, and neither used to invalidate the other: a folder
 * created on one was missing from the other until that screen's own poll came
 * round (30-60 s measured, and a tab switch did not shorten it), a deleted one
 * lingered as a row that opened on a server error, and a folder emptied in the
 * Mail tab kept its old count on the Folders screen — which hides the delete
 * affordance entirely, since deleting is gated on the folder being empty.
 *
 * Moving messages raises the same staleness twice over: the message list was
 * the one mutator that announced nothing at all, and a move lands the
 * messages somewhere, so the destination's count is wrong too.
 *
 * Both screens now reload off [MailEventBus], and the rule for who reloads on
 * what lives here rather than in two `when` blocks that can drift apart. This
 * is deliberately narrower than "any mutation refetches everything": the
 * standing ruling (#737/#843) is that a poll-reconciled badge is by design.
 * What is not by design is the object the user just created or destroyed on
 * this device staying wrong for the better part of a minute.
 */
object FolderStateInvalidation {
    /**
     * Whether [event] changed the set of folders, so a screen listing folders
     * has to refetch it.
     */
    fun listIsStale(event: MailEvent): Boolean = event is MailEvent.FolderListChanged

    /**
     * The folders whose message count [event] moved; empty when it moved
     * none. A move moves two of them — the folder the messages left and the
     * one they landed in — and the destination is as wrong as the source
     * until it is refetched.
     *
     * A count is not cosmetic on the Folders screen: it gates the delete
     * affordance, so a stale one leaves no way to delete the folder you just
     * emptied and nothing on screen saying why.
     */
    fun staleCountFolders(event: MailEvent): Set<String> =
        when (event) {
            is MailEvent.Removed -> setOfNotNull(event.folder, event.destination)
            is MailEvent.Reconcile -> setOf(event.folder)
            // A flag write moves unread, not the message count the Folders
            // screen shows; the folder set is the other function's business.
            is MailEvent.FlagChanged, is MailEvent.FolderListChanged -> emptySet()
        }
}
