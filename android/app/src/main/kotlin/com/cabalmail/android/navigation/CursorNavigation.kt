package com.cabalmail.android.navigation

/** The mail hub every list entry sits above; where a cursor open rewinds to. */
internal const val MAIL_HUB_ROUTE = "folders"

/**
 * The back stack a resume cursor (or a notification tap) should produce.
 *
 * `messages/{folder}?uid={uid}` is one destination for every folder, so
 * `launchSingleTop` on its own reuses whichever list entry is on top whatever
 * folder that entry is showing. The reused entry keeps its view model — and so
 * its message list and filter pills — on the old folder while the route
 * argument, and so the title, moves to the new one (#1289). Rewinding to the
 * mail hub first is what the in-app folder swap already does; this is the same
 * shape, so both surfaces agree.
 *
 * @param encodedFolder the target folder, already URL-encoded for the route.
 */
internal data class CursorNavigation(
    /** The list route to open. */
    val listRoute: String,
    /** Route to rewind to before opening the list, or null to stack on top. */
    val popUpTo: String?,
    /** A reader to push above the list, or null when the list carries the uid. */
    val readerRoute: String?,
)

internal fun cursorNavigation(
    encodedFolder: String,
    uid: Long?,
    compactWidth: Boolean,
): CursorNavigation {
    val selected = uid?.takeIf { it > 0 }
    // Wide windows preselect the message in the detail pane; phones push a
    // reader above the list.
    if (!compactWidth && selected != null) {
        return CursorNavigation(
            listRoute = "messages/$encodedFolder?uid=$selected",
            popUpTo = MAIL_HUB_ROUTE,
            readerRoute = null,
        )
    }
    return CursorNavigation(
        listRoute = "messages/$encodedFolder",
        popUpTo = MAIL_HUB_ROUTE,
        readerRoute = selected?.let { "message/$encodedFolder/$it" },
    )
}
