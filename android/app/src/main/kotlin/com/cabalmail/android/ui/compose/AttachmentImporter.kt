package com.cabalmail.android.ui.compose

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import com.cabalmail.kit.cache.DraftStore
import com.cabalmail.kit.models.DraftAttachment
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Copies a picked or shared `content://` URI into the draft's own
 * directory (via [DraftStore.importAttachment]) and describes it. The copy
 * is what lets a draft outlive the URI grant and process death.
 */
class AttachmentImporter(
    private val context: Context,
    private val draftStore: DraftStore,
) {
    /** Null when the URI cannot be opened. */
    suspend fun import(
        draftId: String,
        uri: Uri,
    ): DraftAttachment? =
        withContext(Dispatchers.IO) {
            val resolver = context.contentResolver
            val mimeType = resolver.getType(uri) ?: guessMime(uri)
            val displayName = displayName(uri) ?: fallbackName(uri, mimeType)
            val stream = runCatching { resolver.openInputStream(uri) }.getOrNull() ?: return@withContext null
            val file = draftStore.importAttachment(draftId, displayName, stream)
            DraftAttachment(
                filename = file.name,
                mimeType = mimeType,
                path = file.absolutePath,
                size = file.length(),
            )
        }

    private fun displayName(uri: Uri): String? =
        runCatching {
            context.contentResolver
                .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (column >= 0 && cursor.moveToFirst()) cursor.getString(column) else null
                }
        }.getOrNull()?.takeIf { it.isNotBlank() }
            ?: uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.contains('.') }

    private fun guessMime(uri: Uri): String {
        val extension = uri.lastPathSegment?.substringAfterLast('.', "").orEmpty()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension.lowercase())
            ?: "application/octet-stream"
    }

    private fun fallbackName(
        uri: Uri,
        mimeType: String,
    ): String {
        val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType)
        val stem = uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() } ?: "attachment"
        return if (extension != null && !stem.endsWith(".$extension")) "$stem.$extension" else stem
    }
}
