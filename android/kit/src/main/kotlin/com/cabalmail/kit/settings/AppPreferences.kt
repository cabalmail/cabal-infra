package com.cabalmail.kit.settings

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
    /** Null = From picker starts empty (wire encoding: empty string). */
    val defaultFromAddress: String? = null,
    val signature: String = "",
    // ---- local only
    val dynamicColor: Boolean = true,
    /** Background new-mail notifications (plan §7.3); off until the user opts in. */
    val notificationsEnabled: Boolean = false,
    val defaultSort: DefaultSort = DefaultSort.RECEIVED,
    val defaultSortDescending: Boolean = true,
)
