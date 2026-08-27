package com.cabalmail.android.ui.compose

import com.cabalmail.kit.models.ComposeIntent

/** Which caption the compose screen's app bar carries. */
enum class ComposeTitleKind { NEW, REPLY, FORWARD, DRAFT }

/**
 * The compose screen's title (#1290).
 *
 * A resumed draft used to read "New message", because [DraftResume] seeds
 * it as [ComposeIntent.NEW] on purpose — that decides *quoting*, not what
 * the screen is, and a screen arriving with From and Subject already
 * filled is plainly not a new message. So the resumed case is asked as its
 * own question and answered first, matching the Apple clients' "Draft".
 *
 * "Resumed" means the session opened over a copy that already exists in
 * the Drafts folder. It is read once, when the buffer loads, so the title
 * cannot change under the user when the 60 s autosave lands a server copy
 * mid-compose.
 */
object ComposeTitle {
    fun forSession(
        intent: ComposeIntent,
        resumedFromServer: Boolean,
    ): ComposeTitleKind =
        when {
            resumedFromServer -> ComposeTitleKind.DRAFT
            intent == ComposeIntent.REPLY || intent == ComposeIntent.REPLY_ALL -> ComposeTitleKind.REPLY
            intent == ComposeIntent.FORWARD -> ComposeTitleKind.FORWARD
            else -> ComposeTitleKind.NEW
        }
}
