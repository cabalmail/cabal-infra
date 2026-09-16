package com.cabalmail.kit.settings

import com.cabalmail.kit.models.RssItemFilter

/**
 * The client's preference set (plan §6.3), one enum per server-validated
 * wire vocabulary. Wire values are the cross-client JSON contract shared
 * with the Apple and web clients (`APP_ALLOWED` in
 * `lambda/api/set_preferences/function.py`); the enum names are Kotlin's.
 */
interface WireEnum {
    val wire: String
}

enum class MarkAsRead(
    override val wire: String,
) : WireEnum {
    MANUAL("manual"),
    ON_OPEN("on_open"),
}

enum class LoadRemoteContent(
    override val wire: String,
) : WireEnum {
    OFF("off"),
    ASK("ask"),
    ALWAYS("always"),
}

enum class DisposeAction(
    override val wire: String,
) : WireEnum {
    ARCHIVE("archive"),
    TRASH("trash"),
}

/**
 * What a mail list row's swipe does (`swipe_leading` / `swipe_trailing`).
 * Named for layout direction, not left / right, so the same value means
 * the same gesture under RTL. [DISPOSE] follows [DisposeAction] and the
 * in-Trash purge override; [NONE] disables that edge.
 */
enum class MailSwipeAction(
    override val wire: String,
) : WireEnum {
    TOGGLE_READ("toggle_read"),
    TOGGLE_FLAG("toggle_flag"),
    DISPOSE("dispose"),
    NONE("none"),
}

/** What a feed item row's swipe does (`rss_swipe_leading` / `rss_swipe_trailing`). */
enum class FeedSwipeAction(
    override val wire: String,
) : WireEnum {
    TOGGLE_READ("toggle_read"),
    TOGGLE_FAVORITE("toggle_favorite"),
    NONE("none"),
}

/** Which message the reader opens after a dispose; falls back to the list when none fits. */
enum class DisposeAdvance(
    override val wire: String,
) : WireEnum {
    NEXT("next"),
    NEXT_UNREAD("next_unread"),
    PREVIOUS_UNREAD("previous_unread"),
    FIRST_UNREAD("first_unread"),
}

/** `SYSTEM` defers to the platform; the web's flat `theme` knows only light/dark. */
enum class AppTheme(
    override val wire: String,
) : WireEnum {
    SYSTEM("system"),
    LIGHT("light"),
    DARK("dark"),
}

enum class BodyRenderMode(
    override val wire: String,
) : WireEnum {
    ORIGINAL("original"),
    READER("reader"),
}

enum class FolderCountDisplay(
    override val wire: String,
) : WireEnum {
    UNREAD("unread"),
    TOTAL("total"),
    BOTH("both"),
}

/** The shared palette (web + Apple); seeds Material 3 when dynamic color is off. */
enum class Accent(
    override val wire: String,
) : WireEnum {
    INK("ink"),
    OXBLOOD("oxblood"),
    FOREST("forest"),
    AZURE("azure"),
    AMBER("amber"),
    PLUM("plum"),
}

enum class Density(
    override val wire: String,
) : WireEnum {
    COMPACT("compact"),
    NORMAL("normal"),
    ROOMY("roomy"),
}

/** Message-list default sort (Android-local; not part of the server contract). */
enum class DefaultSort(
    override val wire: String,
) : WireEnum {
    RECEIVED("received"),
    SENT("sent"),
    FROM("from"),
    SUBJECT("subject"),
}

inline fun <reified T> wireEnum(raw: String?): T? where T : Enum<T>, T : WireEnum =
    raw?.let { value ->
        enumValues<T>().firstOrNull {
            it.wire == value
        }
    }

/**
 * Every preference the Android client honours, with the plan's defaults.
 * Two storage tiers: everything up to [signature] is server-synced (the
 * flat `name`/`accent`/`density` fields plus the per-client `app` map, so
 * web, Apple, and Android converge); [dynamicColor] and the default sort
 * are Android-local.
 */
data class AppPreferences(
    // ---- synced: flat fields
    val displayName: String = "",
    val accent: Accent = Accent.FOREST,
    val density: Density = Density.COMPACT,
    // ---- synced: `app` map
    val theme: AppTheme = AppTheme.SYSTEM,
    val markAsRead: MarkAsRead = MarkAsRead.MANUAL,
    val loadRemoteContent: LoadRemoteContent = LoadRemoteContent.OFF,
    val bodyRenderMode: BodyRenderMode = BodyRenderMode.ORIGINAL,
    val folderCountDisplay: FolderCountDisplay = FolderCountDisplay.UNREAD,
    val disposeAction: DisposeAction = DisposeAction.ARCHIVE,
    val disposeAdvance: DisposeAdvance = DisposeAdvance.NEXT_UNREAD,
    /** Null = From picker starts empty (wire encoding: empty string). */
    val defaultFromAddress: String? = null,
    val signature: String = "",
    /**
     * The custom-flag palette (rules-composition plan, Phase 3), in display
     * order; rides the `app` map as a JSON-encoded string.
     */
    val flagPalette: List<FlagPaletteEntry> = emptyList(),
    /**
     * True once the `flag_palette` key has any reason to ride the payload:
     * a server pull carried it, or a palette existed locally at some point
     * (a user act that must sync, including a later deletion). While false
     * the push omits the key entirely — `set_preferences` rejects the whole
     * map on any unknown key, so an eager send against a not-yet-upgraded
     * server would break every preference push from this build.
     */
    val flagPaletteSyncable: Boolean = false,
    /**
     * The filter pill each mail folder's list opens on, by folder path
     * (sticky per folder; a folder absent here opens on All). Rides the
     * `app` map as one `filter:mail:<path>` key per folder — see
     * [MailFolderFilters]. A present entry is its own proof the server
     * knows the key shape (it exists only once a user set it, here or on
     * another device), so no syncable gate is needed.
     */
    val mailFolderFilters: Map<String, MailFolderFilter> = emptyMap(),
    /**
     * The feed reader's own mark-as-read mode (`rss_mark_as_read`, its own
     * key so mail and feed habits can differ; rss plan, phase 5). Null =
     * never set here or on another device, which reads as
     * [MarkAsRead.MANUAL] and keeps the key off the wire — the same gate
     * [flagPaletteSyncable] applies, since a server that predates the key
     * 400s the whole map. Once set (locally, or by a fetched map carrying
     * it) the key rides on every push, the default value included.
     */
    val rssMarkAsRead: MarkAsRead? = null,
    /**
     * The pill the All Feeds list opens on (`filter:feeds:all`; a single
     * feed's or feed folder's pill lives on its server row instead). Null =
     * never set, which reads as [RssItemFilter.DEFAULT_FOR_FEEDS] and stays
     * off the wire, with the same reasoning as [rssMarkAsRead].
     */
    val feedsAllFilter: RssItemFilter? = null,
    /**
     * The mail list's swipe bindings (`swipe_leading` / `swipe_trailing`)
     * and the feed list's (`rss_swipe_leading` / `rss_swipe_trailing`).
     * Null = never set, which reads as the historical arrangement (leading
     * toggles read, trailing disposes / favorites) and stays off the wire,
     * with the same reasoning as [rssMarkAsRead].
     */
    val swipeLeading: MailSwipeAction? = null,
    val swipeTrailing: MailSwipeAction? = null,
    val rssSwipeLeading: FeedSwipeAction? = null,
    val rssSwipeTrailing: FeedSwipeAction? = null,
    // ---- local only
    val dynamicColor: Boolean = true,
    /** Background new-mail notifications (plan §7.3); off until the user opts in. */
    val notificationsEnabled: Boolean = false,
    /**
     * Push folder opt-in, per device like the Apple clients (it lives on
     * this device's token row via `/push_register`, never in the synced
     * preferences). Wire semantics verbatim: empty = INBOX only (the
     * server default), `{"*"}` = every folder, anything else = exact
     * membership — a set without INBOX gets no INBOX pushes. The
     * 15-minute fallback poll is unaffected (INBOX only).
     */
    val pushFolders: Set<String> = emptySet(),
    val defaultSort: DefaultSort = DefaultSort.RECEIVED,
    val defaultSortDescending: Boolean = true,
    /**
     * Mail-tab folder section disclosure, per device like the Apple clients'
     * `@AppStorage` keys. All folders starts collapsed: it is mostly folders
     * the user has explicitly opted out of proactive tracking on.
     */
    val folderSectionSubscribedExpanded: Boolean = true,
    val folderSectionAllExpanded: Boolean = false,
    /** Feed folders the user has collapsed in the feed list, per device like the Apple clients. */
    val feedCollapsedFolders: Set<String> = emptySet(),
) {
    val effectiveRssMarkAsRead: MarkAsRead
        get() = rssMarkAsRead ?: MarkAsRead.MANUAL

    val effectiveFeedsAllFilter: RssItemFilter
        get() = feedsAllFilter ?: RssItemFilter.DEFAULT_FOR_FEEDS

    val effectiveSwipeLeading: MailSwipeAction
        get() = swipeLeading ?: MailSwipeAction.TOGGLE_READ

    val effectiveSwipeTrailing: MailSwipeAction
        get() = swipeTrailing ?: MailSwipeAction.DISPOSE

    val effectiveRssSwipeLeading: FeedSwipeAction
        get() = rssSwipeLeading ?: FeedSwipeAction.TOGGLE_READ

    val effectiveRssSwipeTrailing: FeedSwipeAction
        get() = rssSwipeTrailing ?: FeedSwipeAction.TOGGLE_FAVORITE
}
