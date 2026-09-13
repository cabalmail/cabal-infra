package com.cabalmail.android.ui.feeds

import android.content.Context
import android.net.Uri
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/** The OPML file plumbing: a picked document's text, and an export written where the FileProvider can serve it. */
object FeedOpmlFiles {
    /** At most this much OPML is read; the API caps imports at 2 MB anyway. */
    private const val MAX_BYTES = 4L * 1024 * 1024

    suspend fun readText(
        context: Context,
        uri: Uri,
    ): String? =
        withContext(Dispatchers.IO) {
            runCatching {
                context.contentResolver.openInputStream(uri)?.use { stream ->
                    val bytes = stream.readBytes()
                    if (bytes.size > MAX_BYTES) null else String(bytes, Charsets.UTF_8)
                }
            }.getOrNull()
        }

    /** Writes the export into [dir] (the FileProvider's attachments path) and returns the file. */
    suspend fun writeExport(
        dir: File,
        filename: String,
        opml: String,
        io: CoroutineDispatcher = Dispatchers.IO,
    ): File =
        withContext(io) {
            dir.mkdirs()
            val safe = filename.ifBlank { "cabalmail-feeds.opml" }.replace(Regex("[^A-Za-z0-9._-]"), "_")
            File(dir, safe).apply { writeText(opml, Charsets.UTF_8) }
        }
}
