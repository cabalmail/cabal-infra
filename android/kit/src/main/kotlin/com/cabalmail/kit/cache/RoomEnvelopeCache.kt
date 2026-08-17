package com.cabalmail.kit.cache

import android.content.Context
import androidx.room.ColumnInfo
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.Upsert
import com.cabalmail.kit.models.Envelope
import kotlinx.serialization.json.Json

/**
 * Room-backed [EnvelopeCache]. Envelopes are stored as their wire JSON
 * rather than exploded into columns: the cache's only read pattern is
 * by-(folder, uid), and a schema that shadows every envelope field would
 * need a migration each time the wire model grows.
 *
 * The DAO is exercised on-device (Room's JVM story needs Robolectric, which
 * the kit test suite deliberately avoids); the cache *contract* is covered
 * by the [InMemoryEnvelopeCache] unit tests.
 */
@Entity(
    tableName = "envelopes",
    primaryKeys = ["folder", "uid"],
    indices = [Index("lastAccess")],
)
data class CachedEnvelopeRow(
    val folder: String,
    val uid: Long,
    val json: String,
    @ColumnInfo(name = "lastAccess") val lastAccess: Long,
)

@Entity(tableName = "folder_meta")
data class FolderMetaRow(
    @PrimaryKey val folder: String,
    val uidValidity: Long,
)

@Dao
interface EnvelopeDao {
    @Upsert
    suspend fun upsert(rows: List<CachedEnvelopeRow>)

    @Query("SELECT * FROM envelopes WHERE folder = :folder AND uid IN (:uids)")
    suspend fun read(
        folder: String,
        uids: List<Long>,
    ): List<CachedEnvelopeRow>

    @Query("UPDATE envelopes SET lastAccess = :now WHERE folder = :folder AND uid IN (:uids)")
    suspend fun touch(
        folder: String,
        uids: List<Long>,
        now: Long,
    )

    @Query("DELETE FROM envelopes WHERE folder = :folder")
    suspend fun deleteFolder(folder: String)

    @Query("DELETE FROM envelopes")
    suspend fun deleteAll()

    @Query(
        "DELETE FROM envelopes WHERE rowid IN (SELECT rowid FROM envelopes " +
            "ORDER BY lastAccess DESC LIMIT -1 OFFSET :max)",
    )
    suspend fun trimToNewest(max: Int)

    @Query("SELECT uidValidity FROM folder_meta WHERE folder = :folder")
    suspend fun uidValidity(folder: String): Long?

    @Upsert
    suspend fun setMeta(meta: FolderMetaRow)

    @Query("DELETE FROM folder_meta")
    suspend fun deleteAllMeta()
}

@Database(entities = [CachedEnvelopeRow::class, FolderMetaRow::class], version = 1, exportSchema = false)
abstract class EnvelopeDatabase : RoomDatabase() {
    abstract fun dao(): EnvelopeDao

    companion object {
        fun open(context: Context): EnvelopeDatabase =
            Room
                .databaseBuilder(context, EnvelopeDatabase::class.java, "envelope_cache.db")
                // A cache rebuilds itself; never block an upgrade on it.
                .fallbackToDestructiveMigration()
                .build()
    }
}

class RoomEnvelopeCache(
    private val dao: EnvelopeDao,
    private val maxEntries: Int = InMemoryEnvelopeCache.DEFAULT_MAX_ENTRIES,
    private val clock: () -> Long = System::currentTimeMillis,
) : EnvelopeCache {
    companion object {
        /**
         * Opens the on-disk cache. The factory keeps Room types inside kit —
         * consumers see only the [EnvelopeCache] interface.
         */
        fun open(context: Context): EnvelopeCache = RoomEnvelopeCache(EnvelopeDatabase.open(context).dao())
    }

    private val json = Json { ignoreUnknownKeys = true }

    override suspend fun reconcile(
        folder: String,
        uidValidity: Long,
    ) {
        val known = dao.uidValidity(folder)
        if (known != null && known != uidValidity) {
            dao.deleteFolder(folder)
        }
        if (known != uidValidity) {
            dao.setMeta(FolderMetaRow(folder, uidValidity))
        }
    }

    override suspend fun read(
        folder: String,
        uids: List<Long>,
    ): Map<Long, Envelope> {
        if (uids.isEmpty()) {
            return emptyMap()
        }
        val rows = dao.read(folder, uids)
        dao.touch(folder, rows.map { it.uid }, clock())
        return rows
            .mapNotNull { row ->
                runCatching { row.uid to json.decodeFromString<Envelope>(row.json) }.getOrNull()
            }.toMap()
    }

    override suspend fun write(
        folder: String,
        envelopes: Collection<Envelope>,
    ) {
        if (envelopes.isEmpty()) {
            return
        }
        val now = clock()
        dao.upsert(
            envelopes.map { envelope ->
                CachedEnvelopeRow(
                    folder = folder,
                    uid = envelope.id,
                    json = json.encodeToString(Envelope.serializer(), envelope),
                    lastAccess = now,
                )
            },
        )
        dao.trimToNewest(maxEntries)
    }

    override suspend fun invalidateFolder(folder: String) {
        dao.deleteFolder(folder)
    }

    override suspend fun clear() {
        dao.deleteAll()
        dao.deleteAllMeta()
    }
}
