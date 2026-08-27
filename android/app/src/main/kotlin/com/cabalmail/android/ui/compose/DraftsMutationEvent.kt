package com.cabalmail.android.ui.compose

import com.cabalmail.android.MailEvent
import com.cabalmail.android.ui.mail.MessageDetailViewModel.Companion.DRAFTS_FOLDER

/**
 * What a compose session owes an open Drafts list once it has changed the
 * server copy (#1290).
 *
 * A pure rule rather than an inline `if` so it can be tested directly. The
 * composer is the only mutator of the Drafts folder that is not itself a
 * message-list screen, and it announced nothing on [MailEvent] at all, so
 * a draft the user had just discarded stayed in the list — with the count
 * pill still counting it — until the 60 s foreground poll came round.
 */
object DraftsMutationEvent {
    /**
     * [removedUid] is the copy the round trip took out of Drafts, or null
     * when it removed nothing it can name. [appended] is true when the same
     * round trip also wrote a replacement copy.
     *
     * Only a removal with nothing appended can be applied optimistically:
     * the list can drop a row it already holds, but it cannot derive an
     * appended row's envelope from here, and a discard the server declined
     * (`discarded: false` inside a 200) must not drop a row that is still
     * there. Both of those refetch instead.
     */
    fun forDraftsChange(
        removedUid: Long?,
        appended: Boolean,
    ): MailEvent =
        if (removedUid != null && !appended) {
            MailEvent.Removed(DRAFTS_FOLDER, setOf(removedUid))
        } else {
            MailEvent.Reconcile(DRAFTS_FOLDER)
        }
}
