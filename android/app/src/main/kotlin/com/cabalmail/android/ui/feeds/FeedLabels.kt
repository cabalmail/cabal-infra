package com.cabalmail.android.ui.feeds

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import com.cabalmail.android.R
import com.cabalmail.kit.models.RssItemFilter
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssOpenMode
import com.cabalmail.kit.models.RssOrderingMode
import com.cabalmail.kit.models.RssRemoteContentMode
import com.cabalmail.kit.models.RssStyling

@Composable
internal fun RssItemFilter.label(): String =
    stringResource(
        when (this) {
            RssItemFilter.ALL -> R.string.filter_all
            RssItemFilter.UNREAD -> R.string.filter_unread
            RssItemFilter.FAVORITE -> R.string.feed_filter_favorites
        },
    )

@Composable
internal fun RssOrderingMode.label(): String =
    stringResource(
        when (this) {
            RssOrderingMode.NEWEST_FIRST -> R.string.feed_order_newest_first
            RssOrderingMode.OLDEST_FIRST -> R.string.feed_order_oldest_first
            RssOrderingMode.NEWEST_DAY_OLDEST_WITHIN -> R.string.feed_order_newest_day_oldest_within
            RssOrderingMode.OLDEST_DAY_NEWEST_WITHIN -> R.string.feed_order_oldest_day_newest_within
        },
    )

/** The health level's words: the badge's content description and the list header. */
@Composable
internal fun FeedHealthLevel.summary(): String? =
    when (this) {
        FeedHealthLevel.Healthy -> null
        is FeedHealthLevel.Failing ->
            pluralStringResource(R.plurals.feeds_health_failing, consecutiveFailures, consecutiveFailures)
        FeedHealthLevel.Stopped -> stringResource(R.string.feeds_health_stopped)
    }

@Composable
internal fun unreadLabel(count: Int): String = pluralStringResource(R.plurals.feeds_unread_count, count, count)

/** A scope's title from the loaded catalog, with the Apple fallbacks. */
@Composable
internal fun scopeTitle(
    scope: RssItemScope,
    state: FeedsUiState,
): String =
    when (scope) {
        RssItemScope.All -> stringResource(R.string.feeds_all)
        is RssItemScope.Folder -> state.title(scope) ?: stringResource(R.string.feed_folder_fallback)
        is RssItemScope.Subscription -> state.title(scope) ?: stringResource(R.string.feed_title_fallback)
    }

@Composable
internal fun RssOpenMode.label(): String =
    stringResource(
        when (this) {
            RssOpenMode.SUMMARY -> R.string.feed_open_mode_summary
            RssOpenMode.ARTICLE -> R.string.feed_open_mode_article
        },
    )

@Composable
internal fun RssStyling.label(): String =
    stringResource(
        when (this) {
            RssStyling.READER -> R.string.feed_styling_reader
            RssStyling.NATIVE -> R.string.feed_styling_native
        },
    )

@Composable
internal fun RssRemoteContentMode.label(): String =
    stringResource(
        when (this) {
            RssRemoteContentMode.INHERIT -> R.string.feed_remote_inherit
            RssRemoteContentMode.SHOW -> R.string.feed_remote_show
            RssRemoteContentMode.HIDE -> R.string.feed_remote_hide
        },
    )
