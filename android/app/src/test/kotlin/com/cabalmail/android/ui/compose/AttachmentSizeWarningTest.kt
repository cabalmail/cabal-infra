package com.cabalmail.android.ui.compose

import com.cabalmail.kit.models.DraftAttachment
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class AttachmentSizeWarningTest {
    private fun attachment(size: Long, name: String = "f.bin") =
        DraftAttachment(filename = name, mimeType = "application/octet-stream", path = "/$name", size = size)

    @Test
    fun `matches the threshold the other two composers use`() {
        assertEquals(20L * 1024 * 1024, AttachmentSizeWarning.WARN_BYTES)
    }

    @Test
    fun `no attachments never warns`() {
        assertFalse(AttachmentSizeWarning.exceedsWarning(emptyList()))
        assertEquals(0L, AttachmentSizeWarning.totalBytes(emptyList()))
    }

    @Test
    fun `warns on the total, not on any one attachment`() {
        // Four 6 MB files: none is close to the threshold on its own.
        val many = List(4) { attachment(6L * 1024 * 1024, "f$it.bin") }
        assertEquals(24L * 1024 * 1024, AttachmentSizeWarning.totalBytes(many))
        assertTrue(AttachmentSizeWarning.exceedsWarning(many))
    }

    @Test
    fun `a total exactly on the threshold does not warn`() {
        val exact = listOf(attachment(AttachmentSizeWarning.WARN_BYTES))
        assertFalse(AttachmentSizeWarning.exceedsWarning(exact))
        assertTrue(AttachmentSizeWarning.exceedsWarning(listOf(attachment(AttachmentSizeWarning.WARN_BYTES + 1))))
    }

    @Test
    fun `sums past the range of an Int`() {
        // 3 GB of attachments: a total accumulated in Int would overflow and
        // could read as under the threshold.
        val huge = List(3) { attachment(1024L * 1024 * 1024, "g$it.bin") }
        assertEquals(3L * 1024 * 1024 * 1024, AttachmentSizeWarning.totalBytes(huge))
        assertTrue(AttachmentSizeWarning.exceedsWarning(huge))
    }

    @Test
    fun `formats the total the way the warning reads it`() {
        assertEquals("24.0 MB", formatSize(24L * 1024 * 1024))
        assertEquals("512 KB", formatSize(512L * 1024))
        assertEquals("900 B", formatSize(900L))
    }
}
