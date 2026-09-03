package com.cabalmail.android.ui.compose

import com.cabalmail.kit.models.DraftAttachment

/**
 * The composer's advisory attachment-size rule, decoupled from Compose so it
 * can be tested directly.
 *
 * The server refuses a message whose attachments total more than 25 MB
 * (`MAX_TOTAL_ATTACHMENT_BYTES` in `lambda/api/_shared/compose.py`), and on
 * Android that refusal used to be the first the user heard of it — after
 * every attachment had already uploaded. Warn past 20 MB instead, matching
 * the React (`ATTACHMENT_WARN_BYTES`) and Apple (`attachmentWarnBytes`)
 * composers, and like both of them do not block the send: the user may know
 * the recipient's server accepts more, or may be sending to themselves.
 */
object AttachmentSizeWarning {
    const val WARN_BYTES: Long = 20L * 1024 * 1024

    fun totalBytes(attachments: List<DraftAttachment>): Long = attachments.sumOf { it.size }

    /**
     * Strictly greater, as in both sibling composers: a message sitting
     * exactly on the threshold is under every ceiling this warns about.
     */
    fun exceedsWarning(attachments: List<DraftAttachment>): Boolean = totalBytes(attachments) > WARN_BYTES
}

/** Human-readable byte count for an attachment chip or the size warning. */
internal fun formatSize(bytes: Long): String =
    when {
        bytes >= 1_048_576 -> "%.1f MB".format(bytes / 1_048_576.0)
        bytes >= 1024 -> "%.0f KB".format(bytes / 1024.0)
        else -> "$bytes B"
    }
