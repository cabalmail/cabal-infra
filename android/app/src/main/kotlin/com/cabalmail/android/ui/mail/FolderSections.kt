package com.cabalmail.android.ui.mail

import com.cabalmail.kit.models.FolderStatus

/** The two collapsible sections of the mail tab's folder list. */
enum class FolderSection { SUBSCRIBED, ALL }

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
 * The folder list's sectioning rules (parity with the Apple clients'
 * `FolderSectionDisclosure`): Subscribed expanded by default, All folders —
 * the full list, subscribed included — collapsed by default. Pure so the
 * rules are testable without Compose, the same reason Apple extracted its
 * copy out of the `List`.
 */
object FolderSections {
    /**
     * Whether to draw the two sections at all. With nothing subscribed the
     * split would leave the Subscribed section empty and everything a tap
     * away, so the list falls back to the flat, unsectioned form.
     */
    fun sectioned(subscribed: Set<String>): Boolean = subscribed.isNotEmpty()

    /** The Subscribed section's rows: the server-ordered list, filtered. */
    fun subscribedRows(
        folders: List<String>,
        subscribed: Set<String>,
    ): List<String> = folders.filter { it in subscribed }

    /** The rows a section actually draws; collapsed means none. */
    fun visibleRows(
        rows: List<String>,
        isExpanded: Boolean,
    ): List<String> = if (isExpanded) rows else emptyList()

    /**
     * Rotation for the header chevron, in degrees: one glyph rotated
     * (0° collapsed, 90° expanded), as in the Apple sidebar.
     */
    fun chevronRotation(isExpanded: Boolean): Float = if (isExpanded) 90f else 0f

    /**
     * The folders whose STATUS is fetched proactively on refresh:
     * subscription is the user's signal about attention, so unsubscribed
     * folders are strictly on-demand — matching the Apple clients. Without
     * subscription data (older responses, nothing subscribed) every folder
     * keeps its badge, as before the sections existed.
     */
    fun statusTargets(
        folders: List<String>,
        subscribed: Set<String>,
    ): List<String> = if (subscribed.isEmpty()) folders else folders.filter { it in subscribed }

    /**
     * The folder-switch menu behind the message list's title: subscribed
     * folders at the top level, the rest one tap further under an "Other
     * folders" submenu — the same split as the two sections here, with the
     * same fallback: with nothing subscribed everything is top-level. Server
     * order throughout, INBOX pinned first. Parity with the Apple clients'
     * `FolderSwitchMenuPolicy`.
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
