package com.cabalmail.android.ui.settings

/**
 * How the per-device push folder opt-in is scoped, derived from (and stored
 * as) the wire representation on the device's token row: empty set = INBOX
 * only (the server default), `{"*"}` = every folder, anything else = exact
 * membership. Pure, so the mapping is unit-tested without Compose.
 */
sealed interface PushFolderScope {
    data object InboxOnly : PushFolderScope

    data object All : PushFolderScope

    data class Custom(
        val folders: Set<String>,
    ) : PushFolderScope

    companion object {
        fun of(pushFolders: Set<String>): PushFolderScope =
            when {
                pushFolders.isEmpty() -> InboxOnly
                "*" in pushFolders -> All
                else -> Custom(pushFolders)
            }
    }
}

/**
 * The stored (= wire) set for a scope choice. A custom selection with
 * nothing checked collapses to the INBOX-only default — the wire encodes
 * both identically, so the UI must not pretend they differ.
 */
internal fun pushFoldersFor(scope: PushFolderScope): Set<String> =
    when (scope) {
        PushFolderScope.InboxOnly -> emptySet()
        PushFolderScope.All -> setOf("*")
        is PushFolderScope.Custom -> scope.folders
    }
