package com.cabalmail.kit.rss

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.File
import java.sql.Connection
import java.sql.DriverManager

/**
 * The feed database's upgrade steps ([RssMigrations]) on real SQLite,
 * against the schemas Room's compiler exports under `android/kit/schemas`.
 *
 * Room checks a migrated file against the schema it expects when the
 * database opens, and refuses one that differs; on a device that takes the
 * Feeds screens with it. So each step is run here on a database built from
 * the older exported schema, and what it leaves is compared, table by
 * table, column by column and index by index, with a database built from
 * the newer one. The rows a user would lose are checked too: the queue of
 * unsent marks is the reason an upgrade migrates rather than rebuilds.
 *
 * What this does not run is Room itself (its open-time check, and the DAO's
 * SQL): the kit's tests have no Android runtime. An upgrade install on an
 * emulator covers the first.
 */
class RssMigrationTest {
    private val directory = File("schemas/com.cabalmail.kit.rss.RssDatabase")

    private fun exportedVersions(): List<Int> =
        directory
            .listFiles { file -> file.extension == "json" }
            .orEmpty()
            .map { it.nameWithoutExtension.toInt() }
            .sorted()

    private fun exported(version: Int): JsonObject =
        Json
            .parseToJsonElement(File(directory, "$version.json").readText())
            .jsonObject
            .getValue("database")
            .jsonObject

    private fun memory(): Connection = DriverManager.getConnection("jdbc:sqlite::memory:")

    private fun Connection.run(sql: String) = createStatement().use { it.execute(sql) }

    private fun Connection.rows(sql: String): List<List<String?>> =
        createStatement().use { statement ->
            statement.executeQuery(sql).use { result ->
                val columns = result.metaData.columnCount
                buildList {
                    while (result.next()) add((1..columns).map { result.getString(it) })
                }
            }
        }

    /** A database as Room creates it at [version]: every table, index and trigger of the exported schema. */
    private fun created(version: Int): Connection =
        memory().also { connection ->
            val database = exported(version)
            for (entity in database.getValue("entities").jsonArray.map { it.jsonObject }) {
                val table = entity.getValue("tableName").jsonPrimitive.content

                fun statement(sql: String) = connection.run(sql.replace("\${TABLE_NAME}", table))
                statement(entity.getValue("createSql").jsonPrimitive.content)
                entity["indices"]?.jsonArray?.forEach {
                    statement(
                        it.jsonObject
                            .getValue("createSql")
                            .jsonPrimitive.content,
                    )
                }
                entity["contentSyncTriggers"]?.jsonArray?.forEach { statement(it.jsonPrimitive.content) }
            }
        }

    /**
     * What Room compares when it checks a file: every table's columns
     * (name, type, not-null, default, place in the primary key), every
     * index (its columns, and whether it is unique) and every trigger.
     * A column's position is left out, as Room leaves it out: a migration
     * can only add a column at the end.
     */
    private fun Connection.shape(): Map<String, Any> {
        val shape = sortedMapOf<String, Any>()
        for ((type, name, sql) in rows("SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")) {
            name!!
            shape["$type $name"] =
                when (type) {
                    "table" ->
                        rows("PRAGMA table_info(`$name`)")
                            .map { (_, column, declared, notNull, default, key) ->
                                "$column $declared notnull=$notNull default=$default pk=$key"
                            }.toSortedSet()
                    "index" -> {
                        val table = rows("SELECT tbl_name FROM sqlite_master WHERE name = '$name'").single().single()
                        val unique = rows("PRAGMA index_list(`$table`)").single { it[1] == name }[2]
                        "unique=$unique " + rows("PRAGMA index_info(`$name`)").map { it[2] }
                    }
                    else -> sql.orEmpty()
                }
        }
        return shape
    }

    private operator fun <T> List<T>.component6(): T = this[5]

    // ----------------------------------------------------------- every step

    @Test
    fun `every version has its exported schema and a step from the one before`() {
        val versions = exportedVersions()

        assertEquals(
            (1..RssDatabase.VERSION).toList(),
            versions,
            "a schema file for every version, in android/kit/schemas",
        )
        assertEquals(
            (1 until RssDatabase.VERSION).toSet(),
            RssMigrations.STEPS.keys,
            "a version with no step from the one before is rebuilt from nothing, and the unsent marks with it",
        )
        assertEquals(
            RssMigrations.STEPS.keys.map { it to it + 1 },
            RssMigrations.all().map { it.startVersion to it.endVersion },
        )
        for (version in versions) {
            assertEquals(version, exported(version).getValue("version").jsonPrimitive.int)
        }
    }

    @Test
    fun `each step leaves the schema Room expects of the next version`() {
        for ((from, statements) in RssMigrations.STEPS) {
            val migrated = created(from)
            statements.forEach { migrated.run(it) }

            assertEquals(created(from + 1).shape(), migrated.shape(), "version $from to ${from + 1}")
        }
    }

    @Test
    fun `the comparison sees a column, a default, an index and a trigger`() {
        // The test above passes only if `shape` can tell two schemas apart.
        fun changed(sql: String): Boolean = created(1).also { it.run(sql) }.shape() != created(1).shape()

        assertTrue(changed("ALTER TABLE rss_items ADD COLUMN flags TEXT NOT NULL DEFAULT '[]'"))
        assertTrue(changed("CREATE INDEX extra ON rss_pending (feed_id)"))
        assertTrue(changed("DROP INDEX index_rss_items_feed_id_sort_key"))
        assertTrue(changed("DROP TRIGGER room_fts_content_sync_rss_items_fts_AFTER_INSERT"))
        val wrongDefault = created(1).also { it.run("ALTER TABLE rss_items ADD COLUMN flags TEXT NOT NULL DEFAULT ''") }
        val nullable = created(1).also { it.run("ALTER TABLE rss_items ADD COLUMN flags TEXT DEFAULT '[]'") }
        val right = created(1).also { it.run("ALTER TABLE rss_items ADD COLUMN flags TEXT NOT NULL DEFAULT '[]'") }
        assertTrue(wrongDefault.shape() != right.shape())
        assertTrue(nullable.shape() != right.shape())
    }

    // ------------------------------------------------- version 1 to version 2

    /** A version 1 file in use: a feed with two items, their search index, cursors and a queue. */
    private fun versionOneInUse(): Connection =
        created(1).also { database ->
            database.run("INSERT INTO rss_folders VALUES ('d1', '', 'News', 0, 'unread')")
            database.run(
                "INSERT INTO rss_subscriptions VALUES ('s1', 'f1', 'd1', '', 'newest_first', 'summary', 'reader', " +
                    "'inherit', 'unread', 0, '', '2026-01-01T00:00:00Z', 'u1', '2025-12-01T00:00:00Z', '')",
            )
            for (n in 1..2) {
                database.run(
                    "INSERT INTO rss_items (feed_id, sort_key, item_id, guid, title, author, url, published_at, " +
                        "updated_at, fetched_at, fetched_key, summary_html, content_html, body_text, is_read, " +
                        "is_favorite, state_is_explicit, cached_at) VALUES ('f1', 'k$n', 'i$n', 'g$n', 'Title $n', " +
                        "'', 'https://example.com/$n', '2026-01-0${n}T10:00:00Z', '', '', 'fk$n', '<p>s</p>', '', " +
                        "'lighthouse keeper $n', ${n - 1}, ${n - 1}, 1, '2026-01-05T00:00:00Z')",
                )
            }
            database.run(
                "INSERT INTO rss_feed_sync VALUES ('f1', 'since-9', 'older-3', 0, '2026-01-05T00:00:00Z', 'state-7')",
            )
            database.run("INSERT INTO rss_feed_sync VALUES ('f2', 'since-2', '', 1, '2026-01-04T00:00:00Z', '')")
            database.run("INSERT INTO rss_pending VALUES (4, 'read', 'f1', 'k1', '', 1, '2026-01-05T01:00:00Z')")
            database.run("INSERT INTO rss_pending VALUES (5, 'favorite', 'f1', 'k1', '', 1, '2026-01-05T01:00:01Z')")
            database.run(
                "INSERT INTO rss_pending VALUES (9, 'mark_all_read', 'f1', '', 's1', 0, '2026-01-05T01:00:02Z')",
            )
        }

    private fun migratedToTwo(): Connection =
        versionOneInUse().also { database ->
            RssMigrations.V1_TO_V2.forEach {
                database.run(it)
            }
        }

    @Test
    fun `the upgrade to version 2 keeps the queue of unsent marks, in order`() {
        val before = versionOneInUse().rows("SELECT * FROM rss_pending ORDER BY id")

        val after = migratedToTwo().rows("SELECT * FROM rss_pending ORDER BY id")

        assertEquals(3, after.size)
        assertEquals(before, after.map { it.dropLast(1) }, "every row as it was")
        assertEquals(listOf("", "", ""), after.map { it.last() }, "and no slot, which only a flag change has")
    }

    @Test
    fun `the upgrade to version 2 keeps the items and their marks, with no flag`() {
        val before = versionOneInUse().rows("SELECT * FROM rss_items ORDER BY id")

        val database = migratedToTwo()
        val after = database.rows("SELECT * FROM rss_items ORDER BY id")

        assertEquals(before, after.map { it.dropLast(1) })
        assertEquals(listOf(RssStoredFlags.NONE, RssStoredFlags.NONE), after.map { it.last() })
        assertEquals(
            listOf(listOf("i1"), listOf("i2")),
            database.rows(
                "SELECT i.item_id FROM rss_items i JOIN rss_items_fts f ON f.rowid = i.id " +
                    "WHERE rss_items_fts MATCH 'lighth*' ORDER BY i.id",
            ),
            "the search index still answers",
        )
        assertEquals(1, database.rows("SELECT * FROM rss_folders").size)
        assertEquals(1, database.rows("SELECT * FROM rss_subscriptions").size)
    }

    @Test
    fun `the upgrade to version 2 empties the state cursors and leaves the others`() {
        val after = migratedToTwo().rows("SELECT * FROM rss_feed_sync ORDER BY feed_id")

        // The state sync starts over, so flags set on another device while
        // this one ran the older build arrive; the item cursors stay, so
        // nothing is fetched twice.
        assertEquals(
            listOf(
                listOf("f1", "since-9", "older-3", "0", "2026-01-05T00:00:00Z", ""),
                listOf("f2", "since-2", "", "1", "2026-01-04T00:00:00Z", ""),
            ),
            after,
        )
    }

    @Test
    fun `after the upgrade the store's flag writes work on the old rows`() {
        val database = migratedToTwo()

        // The statements the DAO runs for a flag set on an item: the item's
        // column, then the queue's row for that item and slot.
        database.run("""UPDATE rss_items SET flags = '["cabal-flag-01"]' WHERE feed_id = 'f1' AND sort_key = 'k1'""")
        database.run(
            "DELETE FROM rss_pending WHERE kind = 'flag' AND feed_id = 'f1' AND sort_key = 'k1' AND slot = 'cabal-flag-01'",
        )
        database.run(
            "INSERT INTO rss_pending (kind, feed_id, sort_key, subscription_id, value, created_at, slot) " +
                "VALUES ('flag', 'f1', 'k1', '', 1, '2026-01-06T00:00:00Z', 'cabal-flag-01')",
        )
        // A read mark's replace names the empty slot, and so leaves the flag row.
        database.run("DELETE FROM rss_pending WHERE kind = 'read' AND feed_id = 'f1' AND sort_key = 'k1' AND slot = ''")

        assertEquals(
            listOf(listOf("favorite", ""), listOf("mark_all_read", ""), listOf("flag", "cabal-flag-01")),
            database.rows("SELECT kind, slot FROM rss_pending ORDER BY id"),
        )
        assertEquals(
            listOf(listOf("""["cabal-flag-01"]"""), listOf("[]")),
            database.rows("SELECT flags FROM rss_items ORDER BY id"),
        )
        assertEquals(
            listOf(listOf("10")),
            database.rows("SELECT id FROM rss_pending WHERE kind = 'flag'"),
            "ids keep counting up from the old queue's, so order still holds",
        )
    }
}
