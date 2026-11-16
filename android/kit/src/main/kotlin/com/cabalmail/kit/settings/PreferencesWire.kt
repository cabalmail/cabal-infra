package com.cabalmail.kit.settings

import com.cabalmail.kit.models.Preferences
import com.cabalmail.kit.models.PreferencesUpdate
import com.cabalmail.kit.models.RssItemFilter

/**
 * Marshalling between [AppPreferences] and the `/get_preferences` /
 * `/set_preferences` wire shape. Pure, so the mapping is unit-tested
 * without a store or a network.
 */
object PreferencesWire {
    /** `app` map keys — the exact names `set_preferences` validates. */
    object AppKey {
        const val MARK_AS_READ = "mark_as_read"
        const val LOAD_REMOTE_CONTENT = "load_remote_content"
        const val DEFAULT_FROM_ADDRESS = "default_from_address"
        const val SIGNATURE = "signature"
        const val DISPOSE_ACTION = "dispose_action"
        const val DISPOSE_ADVANCE = "dispose_advance"
        const val THEME = "theme"
        const val DEFAULT_BODY_RENDER_MODE = "default_body_render_mode"
        const val FOLDER_COUNT_DISPLAY = "folder_count_display"
        const val FLAG_PALETTE = "flag_palette"
        const val RSS_MARK_AS_READ = "rss_mark_as_read"
        const val SWIPE_LEADING = "swipe_leading"
        const val SWIPE_TRAILING = "swipe_trailing"
        const val RSS_SWIPE_LEADING = "rss_swipe_leading"
        const val RSS_SWIPE_TRAILING = "rss_swipe_trailing"

        /** The All Feeds list's sticky pill; validated by the server's `filter:` prefix arm. */
        const val FILTER_FEEDS_ALL = "filter:feeds:all"
    }

    /**
     * Prefix of the row's flat keys (`name`, `accent`, `density`, `theme`)
     * in a values map ([toValues]), which holds the `app` map's keys bare.
     * No `app` key starts with it.
     */
    const val FLAT = "/"
    private const val FLAT_THEME = FLAT + "theme"
    private const val FLAT_ACCENT = FLAT + "accent"
    private const val FLAT_DENSITY = FLAT + "density"
    private const val FLAT_NAME = FLAT + "name"

    /**
     * This device's synced settings as one map of key to wire value: what
     * [SettingsSyncLedger] keeps its books in. The `app` map's keys are
     * bare and the flat keys carry the [FLAT] prefix.
     */
    fun toValues(preferences: AppPreferences): Map<String, String> {
        val update = toUpdate(preferences)
        return buildMap {
            update.theme?.let { put(FLAT_THEME, it) }
            update.accent?.let { put(FLAT_ACCENT, it) }
            update.density?.let { put(FLAT_DENSITY, it) }
            update.name?.let { put(FLAT_NAME, it) }
            putAll(update.app.orEmpty())
        }
    }

    /** The request that writes [values] (a part of [toValues]) and nothing else. */
    fun toUpdate(values: Map<String, String>): PreferencesUpdate =
        PreferencesUpdate(
            theme = values[FLAT_THEME],
            accent = values[FLAT_ACCENT],
            density = values[FLAT_DENSITY],
            name = values[FLAT_NAME],
            app = values.filterKeys { !it.startsWith(FLAT) }.takeIf { it.isNotEmpty() },
        )

    /** The server's row in the keys of [toValues]. */
    fun rowValues(remote: Preferences): Map<String, String> =
        buildMap {
            put(FLAT_THEME, remote.theme)
            put(FLAT_ACCENT, remote.accent)
            put(FLAT_DENSITY, remote.density)
            put(FLAT_NAME, remote.name)
            putAll(remote.app)
        }

    /**
     * The values a [SettingsSyncLedger.rebase] said to apply, as a server
     * response [applyRemote] can take: a flat key that is not to be
     * applied carries [current]'s value, and an `app` key that is not is
     * left out, so both stay as they are. The flat theme only ever seeds
     * the `app` theme, so it is dropped while that one is [owed].
     */
    fun remoteFor(
        current: AppPreferences,
        apply: Map<String, String>,
        owed: Set<String>,
    ): Preferences =
        Preferences(
            theme = apply[FLAT_THEME].takeUnless { AppKey.THEME in owed }.orEmpty(),
            accent = apply[FLAT_ACCENT] ?: current.accent.wire,
            density = apply[FLAT_DENSITY] ?: current.density.wire,
            name = apply[FLAT_NAME] ?: current.displayName,
            app = apply.filterKeys { !it.startsWith(FLAT) },
        )

    /**
     * This device's synced settings as a request: every key this build
     * knows. It is what the account's row is compared with, never what is
     * sent: a push carries the part of it a user's edit changed
     * ([SettingsSyncLedger.changes]). The flat `theme` mirrors
     * [AppPreferences.theme] for the web only when it is an explicit
     * light/dark — `system` has no web equivalent, so the web keeps
     * whatever it last set.
     */
    fun toUpdate(preferences: AppPreferences): PreferencesUpdate =
        PreferencesUpdate(
            theme = preferences.theme.takeIf { it != AppTheme.SYSTEM }?.wire,
            accent = preferences.accent.wire,
            density = preferences.density.wire,
            name = preferences.displayName,
            app =
                buildMap {
                    put(AppKey.MARK_AS_READ, preferences.markAsRead.wire)
                    put(AppKey.LOAD_REMOTE_CONTENT, preferences.loadRemoteContent.wire)
                    put(AppKey.DEFAULT_FROM_ADDRESS, preferences.defaultFromAddress.orEmpty())
                    put(AppKey.SIGNATURE, preferences.signature)
                    put(AppKey.DISPOSE_ACTION, preferences.disposeAction.wire)
                    put(AppKey.DISPOSE_ADVANCE, preferences.disposeAdvance.wire)
                    put(AppKey.THEME, preferences.theme.wire)
                    put(AppKey.DEFAULT_BODY_RENDER_MODE, preferences.bodyRenderMode.wire)
                    put(AppKey.FOLDER_COUNT_DISPLAY, preferences.folderCountDisplay.wire)
                    // One exception to "every key": `flag_palette` is here
                    // only once syncable — a server that predates the key
                    // 400s the whole request on it (see
                    // [AppPreferences.flagPaletteSyncable]).
                    if (preferences.flagPalette.isNotEmpty() || preferences.flagPaletteSyncable) {
                        put(AppKey.FLAG_PALETTE, FlagPalette.encode(preferences.flagPalette))
                    }
                    // One key per mail folder whose pill the user has set
                    // (see [AppPreferences.mailFolderFilters]).
                    putAll(MailFolderFilters.toWire(preferences.mailFolderFilters))
                    // The feed reader's keys ride once they have ever been
                    // set (see [AppPreferences.rssMarkAsRead]).
                    preferences.rssMarkAsRead?.let { put(AppKey.RSS_MARK_AS_READ, it.wire) }
                    preferences.feedsAllFilter?.let { put(AppKey.FILTER_FEEDS_ALL, it.wire) }
                    // Likewise the swipe bindings (see [AppPreferences.swipeLeading]).
                    preferences.swipeLeading?.let { put(AppKey.SWIPE_LEADING, it.wire) }
                    preferences.swipeTrailing?.let { put(AppKey.SWIPE_TRAILING, it.wire) }
                    preferences.rssSwipeLeading?.let { put(AppKey.RSS_SWIPE_LEADING, it.wire) }
                    preferences.rssSwipeTrailing?.let { put(AppKey.RSS_SWIPE_TRAILING, it.wire) }
                },
        )

    /**
     * Applies a server response over [current]. The caller hands it only
     * the values this device does not owe the server ([remoteFor]).
     * Missing or unrecognized values leave the current value untouched;
     * local-only fields are never touched. When the `app` map carries no
     * theme yet (a user who has only ever used the web), the flat
     * light/dark theme seeds it.
     */
    fun applyRemote(
        current: AppPreferences,
        remote: Preferences,
    ): AppPreferences {
        val app = remote.app
        val appTheme = wireEnum<AppTheme>(app[AppKey.THEME]) ?: wireEnum<AppTheme>(remote.theme)
        return current.copy(
            displayName = remote.name,
            accent = wireEnum<Accent>(remote.accent) ?: current.accent,
            density = wireEnum<Density>(remote.density) ?: current.density,
            theme = appTheme ?: current.theme,
            markAsRead = wireEnum<MarkAsRead>(app[AppKey.MARK_AS_READ]) ?: current.markAsRead,
            loadRemoteContent =
                wireEnum<LoadRemoteContent>(app[AppKey.LOAD_REMOTE_CONTENT]) ?: current.loadRemoteContent,
            bodyRenderMode =
                wireEnum<BodyRenderMode>(app[AppKey.DEFAULT_BODY_RENDER_MODE]) ?: current.bodyRenderMode,
            folderCountDisplay =
                wireEnum<FolderCountDisplay>(app[AppKey.FOLDER_COUNT_DISPLAY]) ?: current.folderCountDisplay,
            disposeAction = wireEnum<DisposeAction>(app[AppKey.DISPOSE_ACTION]) ?: current.disposeAction,
            disposeAdvance = wireEnum<DisposeAdvance>(app[AppKey.DISPOSE_ADVANCE]) ?: current.disposeAdvance,
            defaultFromAddress =
                if (app.containsKey(AppKey.DEFAULT_FROM_ADDRESS)) {
                    app.getValue(AppKey.DEFAULT_FROM_ADDRESS).ifEmpty { null }
                } else {
                    current.defaultFromAddress
                },
            signature = app[AppKey.SIGNATURE] ?: current.signature,
            // An unparseable palette leaves the current one untouched, like
            // every other unrecognized remote value; a present key of any
            // shape proves the server knows it.
            flagPalette =
                app[AppKey.FLAG_PALETTE]?.let(FlagPalette::decode) ?: current.flagPalette,
            flagPaletteSyncable =
                current.flagPaletteSyncable || app.containsKey(AppKey.FLAG_PALETTE),
            mailFolderFilters = MailFolderFilters.mergeRemote(current.mailFolderFilters, app),
            rssMarkAsRead = wireEnum<MarkAsRead>(app[AppKey.RSS_MARK_AS_READ]) ?: current.rssMarkAsRead,
            feedsAllFilter = wireEnum<RssItemFilter>(app[AppKey.FILTER_FEEDS_ALL]) ?: current.feedsAllFilter,
            swipeLeading = wireEnum<MailSwipeAction>(app[AppKey.SWIPE_LEADING]) ?: current.swipeLeading,
            swipeTrailing = wireEnum<MailSwipeAction>(app[AppKey.SWIPE_TRAILING]) ?: current.swipeTrailing,
            rssSwipeLeading = wireEnum<FeedSwipeAction>(app[AppKey.RSS_SWIPE_LEADING]) ?: current.rssSwipeLeading,
            rssSwipeTrailing = wireEnum<FeedSwipeAction>(app[AppKey.RSS_SWIPE_TRAILING]) ?: current.rssSwipeTrailing,
        )
    }
}
