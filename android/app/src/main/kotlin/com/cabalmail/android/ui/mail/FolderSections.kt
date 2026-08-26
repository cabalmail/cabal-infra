package com.cabalmail.android.ui.mail

/** The two collapsible sections of the mail tab's folder list. */
enum class FolderSection { SUBSCRIBED, ALL }

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
}
