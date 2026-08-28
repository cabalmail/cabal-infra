package com.cabalmail.kit.settings

import com.cabalmail.kit.models.Preferences
import com.cabalmail.kit.models.PreferencesUpdate

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
    }

    /**
     * The full synced payload. Every key this build knows is sent each time
     * (the server merges per key, so keys a newer client added survive).
     * The flat `theme` mirrors [AppPreferences.theme] for the web only when
     * it is an explicit light/dark — `system` has no web equivalent, so the
     * web keeps whatever it last set.
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
                    // One exception to "send every key": `flag_palette`
                    // rides only once syncable — a server that predates the
                    // key 400s the whole map on it (see
                    // [AppPreferences.flagPaletteSyncable]).
                    if (preferences.flagPalette.isNotEmpty() || preferences.flagPaletteSyncable) {
                        put(AppKey.FLAG_PALETTE, FlagPalette.encode(preferences.flagPalette))
                    }
                },
        )

    /**
     * Applies a server response over [current] (server wins on login).
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
        )
    }
}
