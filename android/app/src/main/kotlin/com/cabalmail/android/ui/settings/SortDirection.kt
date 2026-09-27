package com.cabalmail.android.ui.settings

/**
 * The direction half of a message sort, named for the axis it turns rather
 * than for one of the four fields it can be applied to.
 *
 * The preference itself stays the boolean `defaultSortDescending` the wire
 * format and every consumer already use; this is the shape the surfaces draw
 * it in. It exists because "Newest first" named a date ordering on a control
 * that also orders by sender and by subject, where the word describes nothing
 * on screen — and because that same string was a real, date-meaning option in
 * the feed list's Order menu one tab away (#1730).
 */
enum class SortDirection {
    ASCENDING,
    DESCENDING,
    ;

    /** The stored form: `defaultSortDescending` / `MessageListUiState.sortDescending`. */
    val descending: Boolean
        get() = this == DESCENDING

    companion object {
        fun of(descending: Boolean): SortDirection = if (descending) DESCENDING else ASCENDING
    }
}
