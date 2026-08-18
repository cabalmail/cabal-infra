package com.cabalmail.kit.cache

import com.cabalmail.kit.models.Draft
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.File
import java.io.InputStream

/**
 * The local draft buffer (plan §5.3): one JSON file per draft under
 * app-internal storage, written atomically (temp + rename) so a crash
 * mid-autosave never leaves a torn draft. Attachments the user picks are
 * copied into the draft's own directory so they survive process death and
 * need no persistable URI grant.
 *
 * Layout: `<root>/<id>.json` and `<root>/<id>/attachments/<filename>`.
 */
class DraftStore(
    private val root: File,
) {
    private val json = Json { ignoreUnknownKeys = true }

    /** Every persisted draft, most recently edited first. */
    suspend fun list(): List<Draft> =
        withContext(Dispatchers.IO) {
            root
                .listFiles { file -> file.isFile && file.name.endsWith(".json") }
                .orEmpty()
                .mapNotNull { file -> runCatching { json.decodeFromString<Draft>(file.readText()) }.getOrNull() }
                .sortedByDescending { it.updatedAt }
        }

    suspend fun load(id: String): Draft? =
        withContext(Dispatchers.IO) {
            val file = fileFor(id)
            if (!file.isFile) {
                return@withContext null
            }
            runCatching { json.decodeFromString<Draft>(file.readText()) }.getOrNull()
        }

    suspend fun save(draft: Draft) {
        withContext(Dispatchers.IO) {
            root.mkdirs()
            val file = fileFor(draft.id)
            val temp = File(root, "${file.name}.tmp")
            temp.writeText(json.encodeToString(Draft.serializer(), draft))
            if (!temp.renameTo(file)) {
                // Windows-style rename-over-existing failure; fall back to
                // a plain copy so the save still lands.
                temp.copyTo(file, overwrite = true)
                temp.delete()
            }
        }
    }

    /**
     * Drops blank drafts that never gained content or a server copy —
     * the seed a "new message" tap stages and the user then backs out of.
     */
    suspend fun pruneEmpty() {
        list().filter { it.isEmpty && it.serverRef == null }.forEach { delete(it.id) }
    }

    /** Removes the draft and every attachment copy it owned. */
    suspend fun delete(id: String) {
        withContext(Dispatchers.IO) {
            fileFor(id).delete()
            File(root, safe(id)).deleteRecursively()
        }
    }

    /**
     * Copies [source] into the draft's attachment directory as
     * [filename] (deduplicated with a numeric suffix) and returns the
     * resulting file. Streams; never buffers the whole attachment.
     */
    suspend fun importAttachment(
        draftId: String,
        filename: String,
        source: InputStream,
    ): File =
        withContext(Dispatchers.IO) {
            val dir = attachmentDir(draftId).apply { mkdirs() }
            var target = File(dir, safeFilename(filename))
            var counter = 1
            while (target.exists()) {
                val base = safeFilename(filename)
                val dot = base.lastIndexOf('.')
                val stem = if (dot > 0) base.substring(0, dot) else base
                val ext = if (dot > 0) base.substring(dot) else ""
                target = File(dir, "$stem-$counter$ext")
                counter += 1
            }
            source.use { input -> target.outputStream().use { output -> input.copyTo(output) } }
            target
        }

    fun attachmentDir(draftId: String): File = File(File(root, safe(draftId)), "attachments")

    private fun fileFor(id: String): File = File(root, "${safe(id)}.json")

    private fun safe(id: String): String = id.replace(Regex("""[^A-Za-z0-9._-]"""), "_")

    private fun safeFilename(name: String): String =
        name
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .replace(Regex("""[^A-Za-z0-9._ ()-]"""), "_")
            .ifBlank { "attachment" }
}
