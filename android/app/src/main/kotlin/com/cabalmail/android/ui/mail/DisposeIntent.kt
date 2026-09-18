package com.cabalmail.android.ui.mail

import com.cabalmail.kit.settings.DisposeAction

/**
 * What a dispose actually does in a given folder, mirroring the Apple
 * clients' `DisposeIntent`: the preference names the destination, but the
 * folder reconciles it so a dispose never targets the folder it acts in —
 * Trash purges, and archiving from Archive restores to the inbox.
 */
internal sealed interface DisposeIntent {
    data class Move(
        val action: DisposeAction,
    ) : DisposeIntent {
        val destination: String
            get() =
                when (action) {
                    DisposeAction.ARCHIVE -> MessageListViewModel.ARCHIVE_FOLDER
                    DisposeAction.TRASH -> MessageListViewModel.TRASH_FOLDER
                }
    }

    /** Archive-from-Archive: back to the inbox. */
    data object Restore : DisposeIntent

    /** Trash-from-Trash: permanent, confirm first. */
    data object Purge : DisposeIntent

    /** Red-tinted affordances: anything that ends in (or empties) Trash. */
    val isDestructive: Boolean
        get() = this == Purge || (this as? Move)?.action == DisposeAction.TRASH

    /**
     * The server move this dispose makes, or null for [Purge], which deletes
     * rather than moves. Every surface that disposes reads the destination
     * and the read flag from here, so the two cannot drift apart: a move
     * archives or trashes and is marked read in the same call (archived ==
     * read, matching the Apple and React clients), while a restore puts the
     * message back in the inbox and leaves the read state alone.
     */
    val moveTarget: MoveTarget?
        get() =
            when (this) {
                is Move -> MoveTarget(destination, markSeen = true)
                Restore -> MoveTarget(INBOX_FOLDER, markSeen = false)
                Purge -> null
            }

    /** Where a dispose sends the message, and whether the same call marks it read. */
    data class MoveTarget(
        val destination: String,
        val markSeen: Boolean,
    )

    companion object {
        const val INBOX_FOLDER = "INBOX"

        /** The dispose button's primary action under [preference] in [folder]. */
        fun standard(
            preference: DisposeAction,
            folder: String,
        ): DisposeIntent =
            when {
                folder == MessageListViewModel.TRASH_FOLDER -> Purge
                folder == MessageListViewModel.ARCHIVE_FOLDER && preference == DisposeAction.ARCHIVE -> Restore
                else -> Move(preference)
            }

        /**
         * A split-menu pick of [action], reconciled against [folder]. Unlike
         * [standard], an explicit archive inside Trash stays a real archive
         * (a rescue), and an explicit trash outside Trash is a plain move.
         */
        fun explicit(
            action: DisposeAction,
            folder: String,
        ): DisposeIntent =
            when (action) {
                DisposeAction.ARCHIVE ->
                    if (folder == MessageListViewModel.ARCHIVE_FOLDER) Restore else Move(DisposeAction.ARCHIVE)
                DisposeAction.TRASH ->
                    if (folder == MessageListViewModel.TRASH_FOLDER) Purge else Move(DisposeAction.TRASH)
            }
    }
}
