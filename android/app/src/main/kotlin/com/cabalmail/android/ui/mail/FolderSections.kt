package com.cabalmail.android.ui.mail

import com.cabalmail.kit.models.FolderStatus
import com.cabalmail.kit.settings.AppPreferences

/** The pills above the mail tab's folder list, in display order. */
enum class FolderFilterPill { ALL, SUBSCRIBED, UNREAD }

/**
 * The folder list's filter: [subscribed] and [unread] are independent
 * toggles; "All" is the state with both off. Persisted per device (not
 * synced), defaulting to Subscribed on, Unread off.
 */
data class FolderListFilter(
    val subscribed: Boolean = true,
    val unread: Boolean = false,
) {
    val isAll: Boolean get() = !subscribed && !unread

    /** Whether [pill] draws selected. */
    fun isOn(pill: FolderFilterPill): Boolean =
        when (pill) {
            FolderFilterPill.ALL -> isAll
            FolderFilterPill.SUBSCRIBED -> subscribed
            FolderFilterPill.UNREAD -> unread
        }

    /** The filter after a tap on [pill]: All clears both, the others flip themselves. */
    fun toggled(pill: FolderFilterPill): FolderListFilter =
        when (pill) {
            FolderFilterPill.ALL -> FolderListFilter(subscribed = false, unread = false)
            FolderFilterPill.SUBSCRIBED -> copy(subscribed = !subscribed)
            FolderFilterPill.UNREAD -> copy(unread = !unread)
        }

    /**
     * Whether the list needs every folder's STATUS to be honest: Unread
     * without Subscribed shows unsubscribed folders too, and only their
     * unseen counts say whether they belong.
     */
    val needsAllStatuses: Boolean get() = unread && !subscribed
}

/** The persisted (per-device) folder filter. */
val AppPreferences.folderListFilter: FolderListFilter
    get() = FolderListFilter(subscribed = folderFilterSubscribed, unread = folderFilterUnread)

/**
 * The folder-switch menu's two groups (see [FolderSections.switchMenu]):
 * [primary] is drawn at the top level, [other] under a submenu when it is
 * not empty.
 */
data class FolderSwitchMenu(
    val primary: List<String>,
    val other: List<String>,
)

/**
 * The folder list's filtering rules (parity with the Apple clients' folder
 * pills). Pure so the rules are testable without Compose.
 */
object FolderSections {
    /**
     * The rows the list draws, in server order: a folder passes when it is
     * subscribed (if [FolderListFilter.subscribed]) and has unread mail (if
     * [FolderListFilter.unread]). The [selected] folder is always kept, so
     * the folder being read never vanishes when its last unread is read.
     */
    fun rows(
        folders: List<String>,
        subscribed: Set<String>,
        statuses: Map<String, FolderStatus>,
        filter: FolderListFilter,
        selected: String?,
    ): List<String> =
        folders.filter { folder ->
            folder == selected ||
                (
                    (!filter.subscribed || folder in subscribed) &&
                        (!filter.unread || hasUnread(statuses[folder]))
                )
        }

    /**
     * The folders whose STATUS is fetched proactively on refresh:
     * subscription is the user's signal about attention, so unsubscribed
     * folders are strictly on-demand — matching the Apple clients. Without
     * subscription data (older responses, nothing subscribed) every folder
     * keeps its badge. [includeAll] widens the walk to every folder, for
     * the one filter state that cannot be honest without it (see
     * [FolderListFilter.needsAllStatuses]).
     */
    fun statusTargets(
        folders: List<String>,
        subscribed: Set<String>,
        includeAll: Boolean = false,
    ): List<String> = if (includeAll || subscribed.isEmpty()) folders else folders.filter { it in subscribed }

    /**
     * The folder-switch menu behind the message list's title: subscribed
     * folders at the top level, the rest one tap further under an "Other
     * folders" submenu, with the fallback that with nothing subscribed
     * everything is top-level. Server order throughout, INBOX pinned
     * first. Parity with the Apple clients' `FolderSwitchMenuPolicy`.
     */
    fun switchMenu(
        folders: List<String>,
        subscribed: Set<String>,
    ): FolderSwitchMenu =
        if (subscribed.isEmpty()) {
            FolderSwitchMenu(primary = folders, other = emptyList())
        } else {
            FolderSwitchMenu(
                primary = folders.filter { it in subscribed },
                other = folders.filterNot { it in subscribed },
            )
        }

    /**
     * Whether the row's name renders in the highlight color. Keyed off the
     * unseen count itself, not the badge, which can show totals under the
     * TOTAL/BOTH display modes. A missing status (unsubscribed folder, not
     * yet fetched) counts as no unread, so those rows rest dim rather than
     * guessing.
     */
    fun hasUnread(status: FolderStatus?): Boolean = (status?.unseen ?: 0) > 0
}
